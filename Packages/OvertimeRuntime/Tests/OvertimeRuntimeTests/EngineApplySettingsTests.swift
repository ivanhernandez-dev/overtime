import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing
import os

final class FakeTranscripts: Sendable {
  private struct State {
    var log: [String] = []
    var builds: [[String]] = []
    var continuations: [Int: AsyncStream<Event>.Continuation] = [:]
    var buildsHeld = false
    var startsHeld = false
    var startsWaiting = 0
  }

  static let heldBuildSeconds: Double = 30

  private let state = OSAllocatedUnfairLock(initialState: State())
  private let buildGate = DispatchSemaphore(value: 0)
  private let startGate = DispatchSemaphore(value: 0)

  func holdBuilds() {
    state.withLock { $0.buildsHeld = true }
  }

  func releaseBuilds() {
    state.withLock { $0.buildsHeld = false }
    buildGate.signal()
  }

  func holdStarts() {
    state.withLock { $0.startsHeld = true }
  }

  func releaseStarts() {
    let waiting = state.withLock { state -> Int in
      state.startsHeld = false
      defer { state.startsWaiting = 0 }
      return state.startsWaiting
    }
    for _ in 0..<waiting {
      startGate.signal()
    }
  }

  var log: [String] {
    state.withLock { $0.log }
  }

  var builds: [[String]] {
    state.withLock { $0.builds }
  }

  func record(_ entry: String) {
    state.withLock { $0.log.append(entry) }
  }

  func stream(_ index: Int) -> AsyncStream<Event> {
    let held = state.withLock { state -> Bool in
      state.log.append("stream\(index)")
      guard state.startsHeld else { return false }
      state.startsWaiting += 1
      return true
    }
    if held {
      _ = startGate.wait(timeout: .now() + Self.heldBuildSeconds)
    }
    let (stream, continuation) = AsyncStream.makeStream(of: Event.self)
    continuation.onTermination = { [self] _ in record("terminated\(index)") }
    state.withLock { $0.continuations[index] = continuation }
    return stream
  }

  func yield(_ event: Event, on index: Int) {
    let continuation = state.withLock { $0.continuations[index] }
    continuation?.yield(event)
  }

  func source(for roots: [TranscriptRoot]) -> TranscriptSource {
    let (index, held) = state.withLock { state -> (Int, Bool) in
      state.builds.append(roots.map(\.path))
      state.log.append("build\(state.builds.count)")
      return (state.builds.count, state.buildsHeld)
    }
    if held {
      _ = buildGate.wait(timeout: .now() + Self.heldBuildSeconds)
    }
    return TranscriptSource(
      seed: { [self] in
        record("seed\(index)")
        return []
      },
      stream: { [self] in stream(index) },
      health: { [self] in
        record("health\(index)")
        return roots.map { RootHealth(path: $0.path, status: .missing, origin: $0.origin) }
      }
    )
  }
}

@Suite(.serialized)
struct EngineApplySettingsTests {
  struct RunningHarness {
    let temp: TempDirectory
    let paths: Paths
    let logger: FileLogger
    let clock = SystemClock()
    let transcripts = FakeTranscripts()
    let settings: Settings
    let box: StuckWindowBox

    init(settings: Settings = Settings(transcriptRoots: ["/tmp/overtime-roots-a"])) throws {
      temp = try TempDirectory()
      paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path], homeDirectory: temp.path)
      try paths.createDirectories()
      logger = try FileLogger(decisionLog: paths.decisionLog(.shadow), errorLog: paths.errorLog(.shadow))
      self.settings = settings
      box = StuckWindowBox(seconds: settings.stuckWindowSeconds)
    }

    func engine(
      rebuilds: Bool = true, sampleTimeoutSeconds: Double = Timing.systemCallTimeoutSeconds
    ) -> Engine {
      let transcripts = transcripts
      var rebuild: (@Sendable ([TranscriptRoot]) -> TranscriptSource)?
      if rebuilds {
        rebuild = { transcripts.source(for: $0) }
      }
      let resolve: @Sendable (Settings) -> [TranscriptRoot] = {
        ($0.transcriptRoots ?? ["/tmp/overtime-roots-default"]).map { TranscriptRoot(path: $0, origin: .configured) }
      }
      return Engine(
        mode: .shadow,
        settings: settings,
        clock: clock,
        interpreter: RecordingInterpreter(logger: logger, timeZone: TimeZone(secondsFromGMT: 0)!),
        sources: EngineSources(
          transcriptSeed: { [] },
          sampleTick: { TickFacts() },
          transcriptStream: { transcripts.stream(0) },
          rebuildTranscripts: rebuild,
          resolveRoots: resolve,
          stuckWindow: box
        ),
        sampleTimeoutSeconds: sampleTimeoutSeconds
      )
    }

    func finish(_ engine: Engine, _ running: Task<Void, Never>) async -> Bool {
      await Engine.bounded(seconds: EngineApplySettingsTests.boundSeconds) {
        await engine.stop()
        await running.value
      }
    }

    func lines() -> [String] {
      guard let text = try? String(contentsOf: paths.decisionLog(.shadow), encoding: .utf8) else { return [] }
      return text.split(separator: "\n").map(String.init)
    }

    func waitUntil(timeout: Double = 3, _ condition: () async -> Bool) async -> Bool {
      let deadline = ContinuousClock.now + .milliseconds(Int(timeout * 1000))
      while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
      }
      return await condition()
    }

    func deliver(_ at: Instant, entrypoint: String? = nil, on index: Int, to engine: Engine) async -> Bool {
      transcripts.yield(.transcriptActivity(TranscriptActivity(at: at, entrypoint: entrypoint)), on: index)
      return await waitUntil { await engine.state.busy.lastTranscriptEventAt == at }
    }

    func withRoots(_ roots: [String]) -> Settings {
      var candidate = settings
      candidate.transcriptRoots = roots
      return candidate
    }
  }

  struct Harness {
    let temp: TempDirectory
    let paths: Paths
    let clock = FakeClock()
    let assertions = FakeAssertionPort()
    let recorder: HoldRecorder
    let settings: Settings

    init() throws {
      temp = try TempDirectory()
      paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path], homeDirectory: temp.path)
      recorder = HoldRecorder(stateFile: paths.stateFile(.live))
      settings = Settings(transcriptRoots: [temp.path + "/projects"])
    }

    func engine() throws -> Engine {
      let recorder = recorder
      return try Composition.makeLiveEngine(
        paths: paths,
        settings: settings,
        ports: LivePorts(
          assertions: assertions, tools: NoTools(), clamshell: FakeClamshellPort(recorder: recorder),
          stateFile: paths.stateFile(.live), makeSentinel: { FakeSentinelPort(recorder: recorder) }),
        environment: [:],
        homeDirectory: temp.path,
        once: true,
        clock: clock,
        externalDisplays: { 0 }
      )
    }

    func lines() -> [String] {
      guard let text = try? String(contentsOf: paths.decisionLog(.live), encoding: .utf8) else { return [] }
      return text.split(separator: "\n").map(String.init)
    }

    func settingsLines() -> [String] {
      lines().filter { $0.contains(" SETTINGS ") }
    }
  }

  static let boundSeconds: Double = 10
  static let timeoutSeconds: Double = 2
  static let rootA = "/tmp/overtime-roots-a"
  static let rootB = "/tmp/overtime-roots-b"
  static let rootC = "/tmp/overtime-roots-c"
  static let notRebuilt = " ERROR settings roots notRebuilt reason=timedOut retryIn="

  static func bounded<Value: Sendable>(_ work: @escaping @Sendable () async -> Value) async -> Value? {
    let box = OSAllocatedUnfairLock<Value?>(initialState: nil)
    let finished = await Engine.bounded(seconds: boundSeconds) {
      let value = await work()
      box.withLock { $0 = value }
    }
    return finished ? box.withLock { $0 } : nil
  }

  struct RetryHarness {
    let temp: TempDirectory
    let paths: Paths
    let logger: FileLogger
    let clock = FakeClock()
    let runner = DeadlineRunner()
    let transcripts = FakeTranscripts()
    let settings = Settings(transcriptRoots: [EngineApplySettingsTests.rootA])
    private let keyGate = DispatchSemaphore(value: 0)

    init() throws {
      temp = try TempDirectory()
      paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path], homeDirectory: temp.path)
      try paths.createDirectories()
      logger = try FileLogger(decisionLog: paths.decisionLog(.shadow), errorLog: paths.errorLog(.shadow))
    }

    func engine(rebuilds: Bool = true, sampleTimeoutSeconds: Double = Timing.systemCallTimeoutSeconds) -> Engine {
      let transcripts = transcripts
      var rebuild: (@Sendable ([TranscriptRoot]) -> TranscriptSource)?
      if rebuilds {
        rebuild = { transcripts.source(for: $0) }
      }
      return Engine(
        mode: .shadow,
        settings: settings,
        clock: clock,
        interpreter: RecordingInterpreter(logger: logger, timeZone: TimeZone(secondsFromGMT: 0)!),
        sources: EngineSources(
          transcriptSeed: { [] },
          sampleTick: { TickFacts() },
          transcriptStream: { transcripts.stream(0) },
          rootHealth: {
            transcripts.record("health0")
            return [RootHealth(path: EngineApplySettingsTests.rootA, status: .ok)]
          },
          rebuildTranscripts: rebuild,
          resolveRoots: { ($0.transcriptRoots ?? []).map { TranscriptRoot(path: $0, origin: .configured) } }
        ),
        sampleTimeoutSeconds: sampleTimeoutSeconds,
        deadlineRunner: runner
      )
    }

    func finish(_ engine: Engine, _ running: Task<Void, Never>) async -> Bool {
      await Engine.bounded(seconds: EngineApplySettingsTests.boundSeconds) {
        await engine.stop()
        await running.value
      }
    }

    func holdTheRebuildKeyAsAnEarlierBuildThatNeverReturned() async {
      let runner = runner
      let keyGate = keyGate
      _ = await OffPool.run {
        runner.run(timeout: 0.05, key: Engine.transcriptRebuildRunnerKey) {
          keyGate.wait(timeout: .now() + FakeTranscripts.heldBuildSeconds) == .success
        }
      }
    }

    func letTheEarlierBuildReturn() async -> Bool {
      keyGate.signal()
      return await waitUntil { runner.outstandingCount == 0 }
    }

    func withRoots(_ roots: [String]) -> Settings {
      var candidate = settings
      candidate.transcriptRoots = roots
      return candidate
    }

    func apply(_ candidate: Settings, to engine: Engine) async -> Bool? {
      await EngineApplySettingsTests.bounded { await engine.apply(settings: candidate) }
    }

    func tick(_ engine: Engine, after seconds: Double) async -> Bool {
      clock.advance(seconds: seconds)
      return await EngineApplySettingsTests.bounded { await engine.step(.tick(TickFacts())) } != nil
    }

    func tick(_ engine: Engine, after seconds: Double, until condition: () -> Bool) async -> Bool {
      clock.advance(seconds: seconds)
      return await waitUntil {
        guard await tick(engine, after: 0) else { return false }
        return condition()
      }
    }

    func lines() -> [String] {
      guard let text = try? String(contentsOf: paths.decisionLog(.shadow), encoding: .utf8) else { return [] }
      return text.split(separator: "\n").map(String.init)
    }

    func notRebuiltWaits() -> [String] {
      lines().compactMap { line in
        line.range(of: EngineApplySettingsTests.notRebuilt).map { String(line[$0.upperBound...]) }
      }
    }

    func waitUntil(timeout: Double = 5, _ condition: () async -> Bool) async -> Bool {
      let deadline = ContinuousClock.now + .milliseconds(Int(timeout * 1000))
      while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
      }
      return await condition()
    }
  }

  @Test func aThresholdChangeReblocksFromTheLastPowerReadingWithoutAnotherPowerEvent() async throws {
    let harness = try Harness()
    let engine = try harness.engine()
    await engine.step(.tick(TickFacts(fullWake: true)))
    await engine.stepPower(.battery(percent: 15))
    #expect(await engine.currentSnapshot().batteryBlocked == false)
    var candidate = harness.settings
    candidate.batteryLowPercent = 20
    candidate.batteryResumePercent = 30
    #expect(await engine.apply(settings: candidate))
    let snapshot = await engine.currentSnapshot()
    #expect(snapshot.batteryLowPercent == 20)
    #expect(snapshot.batteryResumePercent == 30)
    #expect(snapshot.batteryBlocked)
  }

  @Test func applyingWhileHeldEmitsNoReleaseEffectAndKeepsTheHold() async throws {
    let harness = try Harness()
    let engine = try harness.engine()
    await engine.step(.tick(TickFacts(fullWake: true)))
    await engine.step(.transcriptActivity(TranscriptActivity(at: harness.clock.mono())))
    #expect(await engine.state.hold.lidClose == .held)
    #expect(await engine.snapshot().holdIdle == "held")
    harness.recorder.reset()
    let assertionCallsBefore = harness.assertions.calls.count
    var candidate = harness.settings
    candidate.keepDisplayOn = true
    #expect(await engine.apply(settings: candidate))
    #expect(!harness.recorder.all.contains { $0 == .clamshell(on: false, fileOwnsHold: true) })
    #expect(!harness.recorder.all.contains { $0 == .clamshell(on: false, fileOwnsHold: false) })
    #expect(!harness.recorder.all.contains { $0 == .clamshell(on: false, fileOwnsHold: nil) })
    let assertionCallsAfter = Array(harness.assertions.calls.dropFirst(assertionCallsBefore))
    #expect(!assertionCallsAfter.contains(.release(.preventUserIdleSystemSleep)))
    #expect(await engine.state.hold.lidClose == .held)
    #expect(await engine.snapshot().holdIdle == "held")
    #expect(await engine.snapshot().wanted == true)
    #expect(harness.settingsLines().count == 1)
    #expect(harness.settingsLines().first?.hasSuffix(" SETTINGS applied keys=keepDisplayOn") == true)
  }

  @Test func applyingTheCurrentSettingsSucceedsWithoutASettingsLine() async throws {
    let harness = try Harness()
    let engine = try harness.engine()
    await engine.step(.tick(TickFacts(fullWake: true)))
    #expect(await engine.apply(settings: harness.settings))
    #expect(harness.settingsLines().isEmpty)
  }

  @Test func aCandidateThatValidatedWouldAdjustIsRejectedAndChangesNothing() async throws {
    let harness = try Harness()
    let engine = try harness.engine()
    await engine.step(.tick(TickFacts(fullWake: true)))
    var candidate = harness.settings
    candidate.batteryLowPercent = 60
    candidate.batteryResumePercent = 70
    #expect(SettingsStore.validationProblem(candidate) == nil)
    #expect(!candidate.validated().adjustments.isEmpty)
    #expect(await engine.apply(settings: candidate) == false)
    let snapshot = await engine.currentSnapshot()
    #expect(snapshot.batteryLowPercent == 10)
    #expect(snapshot.batteryResumePercent == 20)
    #expect(harness.settingsLines().isEmpty)
  }

  @Test func anInvalidCandidateIsRejectedAndChangesNothing() async throws {
    let harness = try Harness()
    let engine = try harness.engine()
    var candidate = harness.settings
    candidate.batteryLowPercent = 20
    candidate.batteryResumePercent = 20
    #expect(await engine.apply(settings: candidate) == false)
    #expect(await engine.currentSnapshot().batteryLowPercent == 10)
    #expect(harness.settingsLines().isEmpty)
  }

  @Test func aSuccessfulApplyLogsTheSortedChangedKeysWithoutValues() async throws {
    let harness = try Harness()
    let engine = try harness.engine()
    await engine.step(.tick(TickFacts(fullWake: true)))
    var candidate = harness.settings
    candidate.batteryResumePercent = 30
    candidate.batteryLowPercent = 20
    #expect(await engine.apply(settings: candidate))
    let lines = harness.settingsLines()
    #expect(lines.count == 1)
    let line = try #require(lines.first)
    let decision = try #require(line.range(of: " SETTINGS ")).upperBound
    #expect(line[decision...] == "applied keys=batteryLowPercent,batteryResumePercent")
  }

  @Test func aSettingsLineNeverCarriesAFolderEntrypointOrNetworkName() async throws {
    let harness = try Harness()
    let engine = try harness.engine()
    await engine.step(.tick(TickFacts(fullWake: true)))
    var candidate = harness.settings
    candidate.transcriptRoots = ["/Users/someone/secret-folder"]
    candidate.ignoredEntrypoints = ["private-pattern-*"]
    candidate.hotspot = "Home Network Name"
    #expect(await engine.apply(settings: candidate))
    let lines = harness.settingsLines()
    #expect(lines.count == 1)
    #expect(lines.first?.hasSuffix(" SETTINGS applied keys=hotspot,ignoredEntrypoints,transcriptRoots") == true)
    #expect(!harness.lines().contains { $0.contains("secret-folder") })
    #expect(!harness.lines().contains { $0.contains("private-pattern") })
    #expect(!harness.lines().contains { $0.contains("Home Network Name") })
  }

  @Test func choosingAutoDetectLogsOnlyItsKeyAndNoNetworkName() async throws {
    let harness = try Harness()
    let engine = try harness.engine()
    await engine.step(.tick(TickFacts(fullWake: true)))
    #expect(await engine.apply(settings: HotspotChoice.autoDetect.apply(to: harness.settings)))
    let lines = harness.settingsLines()
    #expect(lines.count == 1)
    #expect(lines.first?.hasSuffix(" SETTINGS applied keys=hotspotAutoDetect") == true)
  }

  @Test func theLiveHostForwardsApplyToTheEngine() async throws {
    let harness = try Harness()
    let engine = try harness.engine()
    let host = LiveEngineHost(engine: engine, clock: harness.clock)
    var candidate = harness.settings
    candidate.batteryResumePercent = 40
    #expect(await host.apply(settings: candidate))
    #expect(await engine.currentSnapshot().batteryResumePercent == 40)
    candidate.batteryLowPercent = 0
    #expect(await host.apply(settings: candidate) == false)
  }

  @Test func everyCopyOfALiveHostCarriesItsTokenAndAHostForARestartedEngineHasAnother() async throws {
    let harness = try Harness()
    let host = LiveEngineHost(engine: try harness.engine(), clock: harness.clock)
    let first: any EngineHosting = host
    let second: any EngineHosting = host
    #expect(first.engineToken == second.engineToken)
    let restarted: any EngineHosting = LiveEngineHost(engine: try harness.engine(), clock: harness.clock)
    #expect(restarted.engineToken != first.engineToken)
  }

  @Test func onboardingNamesTheEngineByItsTokenAndNeverByTheHostsBoxAddress() throws {
    let onboarding = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Sources/Overtime/OnboardingModel.swift")
    let source = try String(contentsOf: onboarding, encoding: .utf8)
    #expect(source.contains("host.engineToken"))
    #expect(
      !source.contains("as AnyObject"),
      "R3-IN-01: a boxed host's address can be reused by the allocator, so it never identifies an engine")
  }

  @Test func twoRootChangesRebuildTwiceAndEachNewStreamExistsBeforeTheOldOneEnds() async throws {
    let harness = try RunningHarness()
    let engine = harness.engine()
    let returned = OSAllocatedUnfairLock(initialState: false)
    let running = Task {
      await engine.run()
      returned.withLock { $0 = true }
    }
    #expect(await harness.waitUntil { harness.transcripts.log.contains("stream0") })
    let first = harness.withRoots([Self.rootB])
    let second = harness.withRoots([Self.rootC])
    #expect(await Self.bounded { await engine.apply(settings: first) } == true)
    #expect(await Self.bounded { await engine.apply(settings: second) } == true)
    #expect(harness.transcripts.builds == [[Self.rootB], [Self.rootC]])
    #expect(
      harness.transcripts.log == [
        "stream0", "build1", "seed1", "health1", "stream1", "terminated0", "build2", "seed2", "health2", "stream2",
        "terminated1",
      ])
    let at = harness.clock.mono()
    #expect(await harness.deliver(at, on: 2, to: engine))
    #expect(await engine.state.busy.lastEligibleTranscript == at)
    let health = harness.lines().filter { $0.contains(" WARN detectionHealth reason=rootMissing ") }
    #expect(health.filter { $0.hasSuffix("root=/tmp/overtime-roots-b") }.count == 1)
    #expect(health.filter { $0.hasSuffix("root=/tmp/overtime-roots-c") }.count == 1)
    #expect(returned.withLock { $0 } == false)
    #expect(await harness.finish(engine, running))
    #expect(returned.withLock { $0 })
    #expect(harness.transcripts.log.last == "terminated2")
  }

  @Test func aRebuildThatTimesOutKeepsTheOldStreamAndSaysTheFoldersWereNotApplied() async throws {
    let harness = try RunningHarness()
    harness.transcripts.holdBuilds()
    let engine = harness.engine(sampleTimeoutSeconds: Self.timeoutSeconds)
    let running = Task { await engine.run() }
    #expect(await harness.waitUntil { harness.transcripts.log.contains("stream0") })
    let candidate = harness.withRoots([Self.rootB])
    #expect(await Self.bounded { await engine.apply(settings: candidate) } == false)
    #expect(harness.transcripts.log == ["stream0", "build1"])
    #expect(harness.lines().filter { $0.hasSuffix(" SETTINGS applied keys=transcriptRoots") }.count == 1)
    #expect(await harness.deliver(harness.clock.mono(), on: 0, to: engine))
    #expect(harness.lines().filter { $0.hasSuffix(Self.notRebuilt + "10") }.count == 1)
    #expect(
      harness.lines().filter { $0.hasSuffix(" WARN detectionHealth reason=rootUnreadable root=" + Self.rootB) }.count
        == 1)
    #expect(await engine.state.health.rootIssues == [Self.rootB: .unreadable])
    #expect(await Self.bounded { await engine.apply(settings: candidate) } == false)
    #expect(harness.transcripts.log == ["stream0", "build1"])
    harness.transcripts.releaseBuilds()
    #expect(await harness.finish(engine, running))
    #expect(harness.transcripts.log.contains("terminated0"))
  }

  @Test func aFolderChangeThatWasNotAppliedIsRetriedFromATickTenSecondsLater() async throws {
    let harness = try RetryHarness()
    let engine = harness.engine()
    await harness.holdTheRebuildKeyAsAnEarlierBuildThatNeverReturned()
    let candidate = harness.withRoots([Self.rootB])
    #expect(await harness.apply(candidate, to: engine) == false)
    #expect(harness.notRebuiltWaits() == ["10"])
    #expect(await engine.state.health.rootIssues == [Self.rootB: .unreadable])

    #expect(await harness.tick(engine, after: 9.9))
    #expect(await harness.letTheEarlierBuildReturn())
    #expect(await harness.tick(engine, after: 0.1))
    #expect(await harness.waitUntil { harness.transcripts.log == ["build1", "seed1", "health1", "stream1"] })
    #expect(harness.transcripts.builds == [[Self.rootB]])
    #expect(harness.notRebuiltWaits() == ["10"])
    #expect(await harness.waitUntil { await engine.state.health.rootIssues == [Self.rootB: .missing] })
    #expect(await harness.waitUntil { await harness.apply(candidate, to: engine) == true })

    #expect(await harness.tick(engine, after: 600))
    #expect(await harness.apply(harness.withRoots([Self.rootC]), to: engine) == true)
    #expect(harness.transcripts.builds == [[Self.rootB], [Self.rootC]])
  }

  @Test func eachRetryThatFailsDoublesTheWaitBeforeTheNext() async throws {
    let harness = try RetryHarness()
    let engine = harness.engine()
    await harness.holdTheRebuildKeyAsAnEarlierBuildThatNeverReturned()
    #expect(await harness.apply(harness.withRoots([Self.rootB]), to: engine) == false)
    #expect(harness.notRebuiltWaits() == ["10"])
    #expect(await harness.tick(engine, after: 10))
    #expect(await harness.waitUntil { harness.notRebuiltWaits() == ["10", "20"] })
    #expect(await harness.tick(engine, after: 19.9))
    #expect(await harness.tick(engine, after: 0.1) { harness.notRebuiltWaits() == ["10", "20", "40"] })
    #expect(await harness.tick(engine, after: 40) { harness.notRebuiltWaits() == ["10", "20", "40", "80"] })
    #expect(harness.transcripts.builds.isEmpty)
    #expect(await engine.state.health.rootIssues == [Self.rootB: .unreadable])
    #expect(
      harness.lines().filter { $0.hasSuffix(" WARN detectionHealth reason=rootUnreadable root=" + Self.rootB) }.count
        == 1)
    #expect(await harness.letTheEarlierBuildReturn())
  }

  @Test func aNewFolderChangeStartsItsRetriesFromTheFirstWait() async throws {
    let harness = try RetryHarness()
    let engine = harness.engine()
    await harness.holdTheRebuildKeyAsAnEarlierBuildThatNeverReturned()
    #expect(await harness.apply(harness.withRoots([Self.rootB]), to: engine) == false)
    #expect(await harness.tick(engine, after: 10))
    #expect(await harness.waitUntil { harness.notRebuiltWaits() == ["10", "20"] })
    #expect(await harness.apply(harness.withRoots([Self.rootC]), to: engine) == false)
    #expect(harness.notRebuiltWaits() == ["10", "20", "10"], "R2-IN-03: another folder list is a new change")
    #expect(await engine.state.health.rootIssues == [Self.rootC: .unreadable])
    #expect(await harness.letTheEarlierBuildReturn())
  }

  @Test func aRebuildThatTimesOutKeepsTheLastStatusOfAFolderTheOldStreamStillWatches() async throws {
    let harness = try RunningHarness()
    harness.transcripts.holdBuilds()
    defer { harness.transcripts.releaseBuilds() }
    let engine = harness.engine(sampleTimeoutSeconds: Self.timeoutSeconds)
    let running = Task { await engine.run() }
    #expect(await harness.waitUntil { harness.transcripts.log.contains("stream0") })
    harness.transcripts.yield(.transcriptRoots([RootHealth(path: Self.rootA, status: .missing)]), on: 0)
    #expect(await harness.waitUntil { await engine.state.health.rootIssues == [Self.rootA: .missing] })
    let candidate = harness.withRoots([Self.rootA, Self.rootB])
    #expect(await Self.bounded { await engine.apply(settings: candidate) } == false)
    #expect(await engine.state.health.rootIssues == [Self.rootA: .missing, Self.rootB: .unreadable])
    harness.transcripts.releaseBuilds()
    #expect(await harness.finish(engine, running))
  }

  @Test func withNoStreamRunningARebuildThatTimesOutReportsEveryFolder() async throws {
    let harness = try RetryHarness()
    let engine = harness.engine()
    await harness.holdTheRebuildKeyAsAnEarlierBuildThatNeverReturned()
    #expect(await harness.apply(harness.withRoots([Self.rootA, Self.rootB]), to: engine) == false)
    #expect(
      await engine.state.health.rootIssues == [Self.rootA: .unreadable, Self.rootB: .unreadable],
      "R2-IN-03: a folder counts as still watched only while a stream runs")
    #expect(await harness.letTheEarlierBuildReturn())
  }

  @Test func aRebuildThatTimesOutReportsOnlyTheFoldersTheOldStreamDoesNotWatch() async throws {
    let harness = try RunningHarness()
    harness.transcripts.holdBuilds()
    defer { harness.transcripts.releaseBuilds() }
    let engine = harness.engine(sampleTimeoutSeconds: Self.timeoutSeconds)
    let running = Task { await engine.run() }
    #expect(await harness.waitUntil { harness.transcripts.log.contains("stream0") })
    let candidate = harness.withRoots([Self.rootA, Self.rootB])
    #expect(await Self.bounded { await engine.apply(settings: candidate) } == false)
    #expect(
      await engine.state.health.rootIssues == [Self.rootB: .unreadable],
      "R2-IN-03: the folder the old stream still watches is not reported unreadable")
    let unreadable = harness.lines().filter { $0.contains(" WARN detectionHealth reason=rootUnreadable ") }
    #expect(unreadable.count == 1)
    #expect(unreadable.first?.hasSuffix("root=" + Self.rootB) == true)
    harness.transcripts.releaseBuilds()
    #expect(await harness.finish(engine, running))
  }

  @Test func theRetryWaitsAreTheDocumentedOnes() {
    #expect(Engine.transcriptRetryBaseSeconds == 10)
    #expect(Engine.transcriptRetryCapSeconds == 300)
    #expect(
      (1...8).map { Engine.transcriptRetrySeconds(afterFailures: $0) } == [10, 20, 40, 80, 160, 300, 300, 300])
    #expect(Engine.transcriptRetrySeconds(afterFailures: 0) == 10)
    #expect(Engine.transcriptRetrySeconds(afterFailures: 1_000) == 300)
    #expect(Engine.transcriptRebuildRunnerKey == "transcriptRebuild")
  }

  @Test func goingBackToTheFoldersThatAreStillWatchedEndsTheRetriesAndReportsTheirHealth() async throws {
    let harness = try RetryHarness()
    let engine = harness.engine()
    let running = Task { await engine.run() }
    #expect(await harness.waitUntil { harness.transcripts.log == ["stream0"] })
    await harness.holdTheRebuildKeyAsAnEarlierBuildThatNeverReturned()
    #expect(await harness.apply(harness.withRoots([Self.rootB]), to: engine) == false)
    #expect(await engine.state.health.rootIssues == [Self.rootB: .unreadable])

    #expect(await harness.apply(harness.settings, to: engine) == true)
    #expect(await engine.state.health.rootIssues.isEmpty)
    #expect(harness.transcripts.log == ["stream0", "health0"])
    #expect(harness.notRebuiltWaits() == ["10"])
    #expect(await harness.apply(harness.settings, to: engine) == true)

    #expect(await harness.letTheEarlierBuildReturn())
    #expect(await harness.tick(engine, after: 600))
    #expect(await harness.apply(harness.withRoots([Self.rootC]), to: engine) == true)
    #expect(harness.transcripts.builds == [[Self.rootC]])
    #expect(harness.notRebuiltWaits() == ["10"])
    #expect(await harness.finish(engine, running))
  }

  @Test func goingBackWhileNoStreamIsRunningBuildsASourceForThoseFolders() async throws {
    let harness = try RetryHarness()
    let engine = harness.engine()
    await harness.holdTheRebuildKeyAsAnEarlierBuildThatNeverReturned()
    #expect(await harness.apply(harness.withRoots([Self.rootB]), to: engine) == false)
    #expect(await harness.letTheEarlierBuildReturn())
    #expect(await harness.apply(harness.settings, to: engine) == true)
    #expect(harness.transcripts.builds == [[Self.rootA]])
    #expect(harness.transcripts.log == ["build1", "seed1", "health1", "stream1"])
  }

  @Test func anEngineThatCannotRebuildGivesUpTheRetryAfterOneAttempt() async throws {
    let harness = try RetryHarness()
    harness.transcripts.holdStarts()
    defer { harness.transcripts.releaseStarts() }
    let engine = harness.engine(rebuilds: false, sampleTimeoutSeconds: Self.timeoutSeconds)
    let running = Task { await engine.run() }
    #expect(await harness.waitUntil { harness.notRebuiltWaits() == ["10"] })
    #expect(await harness.apply(harness.settings, to: engine) == false)
    let unavailable = " ERROR settings roots notRebuilt"
    #expect(await harness.tick(engine, after: 10))
    #expect(await harness.waitUntil { harness.lines().filter { $0.hasSuffix(unavailable) }.count == 1 })
    #expect(await harness.waitUntil { await harness.apply(harness.settings, to: engine) == true })
    #expect(await harness.tick(engine, after: 10))
    #expect(await harness.tick(engine, after: 10))
    #expect(await harness.apply(harness.settings, to: engine) == true)
    #expect(harness.lines().filter { $0.hasSuffix(unavailable) }.count == 1)
    #expect(harness.notRebuiltWaits() == ["10"])
    harness.transcripts.releaseStarts()
    #expect(await harness.finish(engine, running))
  }

  @Test func aStreamStartThatBlocksNeverHoldsTheEngineAndTheOldStreamKeepsRunning() async throws {
    let harness = try RunningHarness()
    let engine = harness.engine(sampleTimeoutSeconds: Self.timeoutSeconds)
    let running = Task { await engine.run() }
    #expect(await harness.waitUntil { harness.transcripts.log.contains("stream0") })
    harness.transcripts.holdStarts()
    defer { harness.transcripts.releaseStarts() }
    let candidate = harness.withRoots([Self.rootB])
    let applying = Task { await engine.apply(settings: candidate) }
    #expect(await harness.waitUntil { harness.transcripts.log.contains("stream1") })
    #expect(await Self.bounded { await engine.currentSnapshot() } != nil)
    #expect(await harness.deliver(harness.clock.mono(), on: 0, to: engine))
    #expect(await Self.bounded { await applying.value } == false)
    #expect(harness.transcripts.log == ["stream0", "build1", "seed1", "health1", "stream1"])
    #expect(harness.lines().filter { $0.hasSuffix(Self.notRebuilt + "10") }.count == 1)
    #expect(await engine.state.health.rootIssues == [Self.rootB: .unreadable])
    #expect(await harness.deliver(harness.clock.mono(), on: 0, to: engine))
    harness.transcripts.releaseStarts()
    #expect(await harness.waitUntil { harness.transcripts.log.contains("terminated1") })
    #expect(await harness.finish(engine, running))
    #expect(harness.transcripts.log.last == "terminated0")
  }

  @Test func aStreamStartedForFoldersThatAnotherChangeReplacedIsEndedAndTheOldStreamKeepsRunning() async throws {
    let harness = try RunningHarness()
    let engine = harness.engine(sampleTimeoutSeconds: FakeTranscripts.heldBuildSeconds)
    let running = Task { await engine.run() }
    #expect(await harness.waitUntil { harness.transcripts.log.contains("stream0") })
    harness.transcripts.holdStarts()
    defer { harness.transcripts.releaseStarts() }
    let first = harness.withRoots([Self.rootB])
    let second = harness.withRoots([Self.rootC])
    let applying = Task { await engine.apply(settings: first) }
    #expect(await harness.waitUntil { harness.transcripts.log.contains("stream1") })
    #expect(await Self.bounded { await engine.apply(settings: second) } == false)
    harness.transcripts.releaseStarts()
    #expect(await Self.bounded { await applying.value } == true)
    #expect(await harness.waitUntil { harness.transcripts.log.contains("terminated1") })
    #expect(!harness.transcripts.log.contains("terminated0"))
    #expect(await harness.deliver(harness.clock.mono(), on: 0, to: engine))
    #expect(await harness.finish(engine, running))
    #expect(harness.transcripts.log.last == "terminated0")
  }

  @Test func aStreamWhoseStartOutlivesAStopIsEnded() async throws {
    let harness = try RetryHarness()
    harness.transcripts.holdStarts()
    defer { harness.transcripts.releaseStarts() }
    let engine = harness.engine(sampleTimeoutSeconds: FakeTranscripts.heldBuildSeconds)
    let running = Task { await engine.run() }
    #expect(await harness.waitUntil { harness.transcripts.log == ["stream0"] })
    let stopping = Task { await engine.stop() }
    #expect(await Self.bounded { await stopping.value } != nil)
    #expect(harness.transcripts.log == ["stream0"])
    harness.transcripts.releaseStarts()
    #expect(await harness.waitUntil { harness.transcripts.log == ["stream0", "terminated0"] })
    #expect(await harness.finish(engine, running))
  }

  @Test func anOriginalStreamThatDoesNotStartLetsTheEngineRunAndIsBuiltAgainFromATick() async throws {
    let harness = try RetryHarness()
    harness.transcripts.holdStarts()
    defer { harness.transcripts.releaseStarts() }
    let engine = harness.engine(sampleTimeoutSeconds: Self.timeoutSeconds)
    let running = Task { await engine.run() }
    #expect(await harness.waitUntil { harness.notRebuiltWaits() == ["10"] })
    #expect(harness.transcripts.log == ["stream0"])
    #expect(await harness.waitUntil { await engine.state.health.rootIssues == [Self.rootA: .unreadable] })
    #expect(await harness.tick(engine, after: 1))
    harness.transcripts.releaseStarts()
    #expect(await harness.waitUntil { harness.transcripts.log.contains("terminated0") })
    #expect(await harness.waitUntil { harness.runner.outstandingCount == 0 })
    #expect(await harness.tick(engine, after: 9))
    #expect(
      await harness.waitUntil {
        harness.transcripts.log == ["stream0", "terminated0", "build1", "seed1", "health1", "stream1"]
      })
    #expect(harness.transcripts.builds == [[Self.rootA]])
    #expect(await harness.waitUntil { await harness.apply(harness.settings, to: engine) == true })
    #expect(harness.notRebuiltWaits() == ["10"])
    #expect(await harness.finish(engine, running))
    #expect(harness.transcripts.log.last == "terminated1")
  }

  @Test func whileFoldersAreNotAppliedAnotherSettingStillAppliesAndTheAnswerStaysNotApplied() async throws {
    let harness = try RetryHarness()
    let engine = harness.engine()
    await harness.holdTheRebuildKeyAsAnEarlierBuildThatNeverReturned()
    var candidate = harness.withRoots([Self.rootB])
    #expect(await harness.apply(candidate, to: engine) == false)
    candidate.batteryLowPercent = 15
    #expect(await harness.apply(candidate, to: engine) == false)
    #expect(await engine.currentSnapshot().batteryLowPercent == 15)
    #expect(harness.notRebuiltWaits() == ["10"])
    #expect(harness.lines().contains { $0.hasSuffix(" SETTINGS applied keys=batteryLowPercent") })
    #expect(await harness.letTheEarlierBuildReturn())
  }

  @Test func aFolderChangeThatFailedBeforeTheEngineRanStillStartsTheOriginalStream() async throws {
    let harness = try RetryHarness()
    let engine = harness.engine()
    await harness.holdTheRebuildKeyAsAnEarlierBuildThatNeverReturned()
    #expect(await harness.apply(harness.withRoots([Self.rootB]), to: engine) == false)
    let running = Task { await engine.run() }
    #expect(await harness.waitUntil { harness.transcripts.log.contains("stream0") })
    #expect(await harness.letTheEarlierBuildReturn())
    #expect(
      await Engine.bounded(seconds: Self.boundSeconds) {
        await engine.stop()
        await running.value
      })
    #expect(harness.transcripts.log.contains("terminated0"))
  }

  @Test func withoutARebuildARootChangeLogsAndKeepsTheOldStream() async throws {
    let harness = try RunningHarness()
    let engine = harness.engine(rebuilds: false)
    let running = Task { await engine.run() }
    #expect(await harness.waitUntil { harness.transcripts.log.contains("stream0") })
    let candidate = harness.withRoots([Self.rootB])
    #expect(await Self.bounded { await engine.apply(settings: candidate) } == true)
    #expect(harness.lines().filter { $0.hasSuffix(" ERROR settings roots notRebuilt") }.count == 1)
    #expect(await harness.deliver(harness.clock.mono(), on: 0, to: engine))
    #expect(harness.transcripts.log == ["stream0"])
    #expect(await harness.finish(engine, running))
    #expect(harness.transcripts.log == ["stream0", "terminated0"])
  }

  @Test func aRootChangeThatResolvesToTheSameFoldersDoesNotRebuild() async throws {
    let harness = try RunningHarness(settings: Settings(transcriptRoots: nil))
    let engine = harness.engine()
    let running = Task { await engine.run() }
    #expect(await harness.waitUntil { harness.transcripts.log.contains("stream0") })
    let candidate = harness.withRoots(["/tmp/overtime-roots-default"])
    #expect(await Self.bounded { await engine.apply(settings: candidate) } == true)
    #expect(harness.transcripts.builds.isEmpty)
    #expect(!harness.lines().contains { $0.contains(" ERROR settings roots notRebuilt") })
    #expect(await harness.finish(engine, running))
  }

  @Test func aStuckLimitChangeUpdatesTheSharedBoxWithoutARebuild() async throws {
    let harness = try RunningHarness()
    let engine = harness.engine()
    let running = Task { await engine.run() }
    #expect(await harness.waitUntil { harness.transcripts.log.contains("stream0") })
    var candidate = harness.settings
    candidate.stuckWindowSeconds = 2700
    let longer = candidate
    #expect(await Self.bounded { await engine.apply(settings: longer) } == true)
    #expect(harness.box.seconds == 2700)
    #expect(harness.transcripts.builds.isEmpty)
    #expect(harness.transcripts.log == ["stream0"])
    #expect(harness.lines().contains { $0.hasSuffix(" SETTINGS applied keys=stuckWindowSeconds") })
    #expect(await harness.finish(engine, running))
  }

  @Test func anIgnoredEntrypointChangeAppliesToTheNextActivityWithoutARebuild() async throws {
    var initial = Settings(transcriptRoots: ["/tmp/overtime-roots-a"])
    initial.ignoredEntrypoints = []
    let harness = try RunningHarness(settings: initial)
    let engine = harness.engine()
    let running = Task { await engine.run() }
    #expect(await harness.waitUntil { harness.transcripts.log.contains("stream0") })
    let first = harness.clock.mono()
    #expect(await harness.deliver(first, entrypoint: "sdk-ts", on: 0, to: engine))
    #expect(await engine.state.busy.lastEligibleTranscript == first)
    var candidate = initial
    candidate.ignoredEntrypoints = ["sdk-*"]
    let ignoring = candidate
    #expect(await Self.bounded { await engine.apply(settings: ignoring) } == true)
    let second = harness.clock.mono()
    #expect(await harness.deliver(second, entrypoint: "sdk-ts", on: 0, to: engine))
    #expect(await engine.state.busy.lastEligibleTranscript == first)
    #expect(harness.transcripts.builds.isEmpty)
    #expect(harness.transcripts.log == ["stream0"])
    #expect(await harness.finish(engine, running))
  }
}
