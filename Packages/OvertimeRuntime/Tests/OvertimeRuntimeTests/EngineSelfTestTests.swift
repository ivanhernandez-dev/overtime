import Darwin
import Foundation
import OvertimeClamshell
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing
import os

final class ScriptedSelfTestFacts: Sendable {
  private struct Script: Sendable {
    var coexistence = CoexistenceFacts(sleepDisabled: false)
    var sleepDisabled: Bool? = false
    var osBuild: String? = EngineSelfTestTests.build
    var blockSeconds: Double = 0
    var samples = 0
  }

  private let script = OSAllocatedUnfairLock(initialState: Script())
  private let gate = DispatchSemaphore(value: 0)

  var samples: Int {
    script.withLock { $0.samples }
  }

  func set(coexistence: CoexistenceFacts) {
    script.withLock { $0.coexistence = coexistence }
  }

  func set(sleepDisabled: Bool?) {
    script.withLock { $0.sleepDisabled = sleepDisabled }
  }

  func set(osBuild: String?) {
    script.withLock { $0.osBuild = osBuild }
  }

  func block(seconds: Double) {
    script.withLock { $0.blockSeconds = seconds }
  }

  func releaseBlockedSample() {
    script.withLock { $0.blockSeconds = 0 }
    gate.signal()
  }

  func coexistence() -> CoexistenceFacts {
    let (facts, block) = script.withLock { script -> (CoexistenceFacts, Double) in
      script.samples += 1
      return (script.coexistence, script.blockSeconds)
    }
    if block > 0 { _ = gate.wait(timeout: .now() + block) }
    return facts
  }

  func sleepDisabled() -> Bool? {
    script.withLock { $0.sleepDisabled }
  }

  func osBuild() -> String? {
    script.withLock { $0.osBuild }
  }
}

@Suite(.serialized)
struct EngineSelfTestTests {
  static let build = "99Z999"
  static let lidOpen = TickFacts(lidClosed: false, fullWake: true)
  static let lidClosed = TickFacts(lidClosed: true, externalDisplays: 0, fullWake: true)
  static let idle = AssertionKind.preventUserIdleSystemSleep
  static let passingRun: [HoldRecorder.Entry] = [
    .sentinel("ARM", fileOwnsHold: true),
    .clamshell(on: true, fileOwnsHold: true),
    .clamshell(on: false, fileOwnsHold: true),
    .sentinel("DISARM", fileOwnsHold: true),
  ]
  static let timedOutLine = " ERROR selftest sample timedOut"
  static let refusal = Int32(bitPattern: 0xE000_02C2)
  static let keeper = ForeignAssertion(pid: 4242, type: "PreventUserIdleSystemSleep", processName: "Keeper")

  struct SkipCase: Sendable, CustomTestStringConvertible {
    let name: String
    let coexistence: CoexistenceFacts
    let sleepDisabled: Bool?
    let lid: TickFacts
    let skip: SelfTestSkip

    var testDescription: String { name }
  }

  static let skipCases: [SkipCase] = [
    SkipCase(
      name: "Amphetamine, lid open", coexistence: CoexistenceFacts(amphetamineRunning: true, sleepDisabled: false),
      sleepDisabled: false, lid: lidOpen, skip: .amphetamine),
    SkipCase(
      name: "Amphetamine, lid closed", coexistence: CoexistenceFacts(amphetamineRunning: true, sleepDisabled: false),
      sleepDisabled: false, lid: lidClosed, skip: .amphetamine),
    SkipCase(
      name: "SleepDisabled on", coexistence: CoexistenceFacts(sleepDisabled: false), sleepDisabled: true, lid: lidOpen,
      skip: .sleepDisabled),
    SkipCase(
      name: "SleepDisabled unreadable", coexistence: CoexistenceFacts(sleepDisabled: false), sleepDisabled: nil,
      lid: lidOpen, skip: .sleepDisabled),
    SkipCase(
      name: "a named tool's assertion",
      coexistence: CoexistenceFacts(sleepDisabled: false, foreignAssertions: [keeper]), sleepDisabled: false,
      lid: lidOpen, skip: .otherTool("Keeper")),
    SkipCase(
      name: "a lid-close tool's assertion",
      coexistence: CoexistenceFacts(
        sleepDisabled: false,
        foreignAssertions: [ForeignAssertion(pid: 4243, type: "PreventUserIdleSystemSleep", processName: "NoSleep")]),
      sleepDisabled: false, lid: lidOpen, skip: .otherTool("NoSleep")),
    SkipCase(
      name: "an unconfirmed tool's assertion",
      coexistence: CoexistenceFacts(
        sleepDisabled: false,
        foreignAssertions: [ForeignAssertion(pid: 4243, type: "PreventUserIdleSystemSleep", processName: "Owly")]),
      sleepDisabled: false, lid: lidOpen, skip: .otherTool("Owly")),
    SkipCase(
      name: "an idle-only tool beside a lid-close tool",
      coexistence: CoexistenceFacts(
        sleepDisabled: false,
        foreignAssertions: [
          ForeignAssertion(pid: 4244, type: "PreventUserIdleSystemSleep", processName: "KeepingYouAwake"),
          ForeignAssertion(pid: 4245, type: "PreventUserIdleSystemSleep", processName: "Lidless"),
        ]),
      sleepDisabled: false, lid: lidOpen, skip: .otherTool("Lidless")),
    SkipCase(
      name: "an idle-only tool with SleepDisabled on",
      coexistence: CoexistenceFacts(
        sleepDisabled: false,
        foreignAssertions: [ForeignAssertion(pid: 4243, type: "PreventUserIdleSystemSleep", processName: "Lungo")]),
      sleepDisabled: true, lid: lidOpen, skip: .sleepDisabled),
    SkipCase(
      name: "Amphetamine beside an idle-only tool",
      coexistence: CoexistenceFacts(
        amphetamineRunning: true, sleepDisabled: false,
        foreignAssertions: [
          ForeignAssertion(pid: 4243, type: "PreventUserIdleSystemSleep", processName: "caffeinate")
        ]),
      sleepDisabled: false, lid: lidOpen, skip: .amphetamine),
  ]

  struct Harness {
    let temp: TempDirectory
    let paths: Paths
    let clock = FakeClock()
    let assertions = FakeAssertionPort()
    let recorder: HoldRecorder
    let clamshell: FakeClamshellPort
    let sentinels: SentinelFactory
    let facts = ScriptedSelfTestFacts()
    let runner = DeadlineRunner()

    init() throws {
      temp = try TempDirectory()
      paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path], homeDirectory: temp.path)
      recorder = HoldRecorder(stateFile: paths.stateFile(.live))
      clamshell = FakeClamshellPort(recorder: recorder)
      sentinels = SentinelFactory(recorder: recorder)
    }

    var ports: LivePorts {
      let sentinels = sentinels
      return LivePorts(
        assertions: assertions, tools: NoTools(), clamshell: clamshell, stateFile: paths.stateFile(.live),
        makeSentinel: { sentinels.make() })
    }

    var settings: Settings {
      Settings(transcriptRoots: [temp.path + "/projects"])
    }

    func composed() throws -> Engine {
      let facts = facts
      return try Composition.makeLiveEngine(
        paths: paths,
        settings: settings,
        ports: ports,
        environment: [:],
        homeDirectory: temp.path,
        once: true,
        clock: clock,
        externalDisplays: { 0 },
        coexistence: { facts.coexistence() },
        sleepDisabled: { facts.sleepDisabled() },
        osBuild: { facts.osBuild() }
      )
    }

    func direct(mode: RunMode, sampleTimeoutSeconds: Double = Timing.systemCallTimeoutSeconds) throws -> Engine {
      try paths.createDirectories()
      let logger = try FileLogger(decisionLog: paths.decisionLog(mode), errorLog: paths.errorLog(mode))
      let utc = TimeZone(secondsFromGMT: 0) ?? .current
      let interpreter: any EffectInterpreter
      if mode == .live {
        let sentinel = sentinels.make()
        try sentinel.start()
        interpreter = LiveInterpreter(ports: ports, logger: logger, sentinel: sentinel, timeZone: utc)
      } else {
        interpreter = RecordingInterpreter(logger: logger, timeZone: utc)
      }
      let facts = facts
      return Engine(
        mode: mode,
        settings: settings,
        clock: clock,
        interpreter: interpreter,
        sources: EngineSources(
          transcriptSeed: { [] },
          sampleTick: { EngineSelfTestTests.lidOpen },
          coexistence: { facts.coexistence() },
          sleepDisabled: { facts.sleepDisabled() },
          osBuild: { facts.osBuild() }
        ),
        sampleTimeoutSeconds: sampleTimeoutSeconds,
        deadlineRunner: runner
      )
    }

    var holdEntries: [HoldRecorder.Entry] {
      recorder.all.filter { entry in
        if case .sentinel("HB", _) = entry { return false }
        return true
      }
    }

    var onWrites: Int {
      recorder.all.filter { entry in
        if case .clamshell(on: true, _) = entry { return true }
        return false
      }.count
    }

    var offWrites: Int {
      recorder.all.filter { entry in
        if case .clamshell(on: false, _) = entry { return true }
        return false
      }.count
    }

    func text(_ url: URL) -> String {
      (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func decisionLog(_ mode: RunMode = .live) -> String { text(paths.decisionLog(mode)) }
    func errorLog(_ mode: RunMode = .live) -> String { text(paths.errorLog(mode)) }

    func count(of needle: String, in text: String) -> Int {
      text.components(separatedBy: needle).count - 1
    }
  }

  static func finishes(within seconds: Double = 15, _ body: @escaping @Sendable () async -> Void) async -> Bool {
    await Engine.bounded(seconds: seconds, body)
  }

  static func poll(within seconds: Double = 5, _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
    while ContinuousClock.now < deadline {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
  }

  @Test func aRequestWithTheLidOpenArmsBeforeTheOnWriteThenClearsAndPasses() async throws {
    let harness = try Harness()
    let engine = try harness.composed()
    #expect(await Self.finishes { await engine.step(.tick(Self.lidOpen)) })
    harness.recorder.reset()
    let assertionCalls = harness.assertions.calls.count
    #expect(await Self.finishes { await engine.requestSelfTest() })
    #expect(harness.holdEntries == Self.passingRun)
    #expect(
      Array(harness.assertions.calls.dropFirst(assertionCalls)) == [
        .acquireOrRenew(Self.idle, 300), .release(Self.idle),
      ])
    let snapshot = await engine.currentSnapshot()
    #expect(snapshot.selfTest == .passed)
    #expect(snapshot.osBuild == Self.build)
    #expect(snapshot.selfTestRuns == 1)
    #expect(snapshot.selfTestFailures == 0)
    #expect(!snapshot.selfTestErrorActive)
    #expect(await engine.state.persisted.ownsHold == false)
    #expect(harness.recorder.fileOwnsHold() == false)
    #expect(harness.facts.samples == 1)
    let log = harness.decisionLog()
    #expect(harness.count(of: " SELFTEST start", in: log) == 1)
    #expect(harness.count(of: " SELFTEST passed", in: log) == 1)
  }

  @Test func aRequestWithTheLidClosedWaitsAndTheFirstOpenTickRunsItWithFreshFacts() async throws {
    let harness = try Harness()
    let engine = try harness.composed()
    #expect(await Self.finishes { await engine.step(.tick(Self.lidClosed)) })
    harness.recorder.reset()
    #expect(await Self.finishes { await engine.requestSelfTest() })
    #expect(await engine.currentSnapshot().selfTest == .waiting)
    #expect(await engine.currentSnapshot().osBuild == Self.build)
    #expect(harness.facts.samples == 1)
    #expect(harness.holdEntries.isEmpty)

    harness.facts.set(osBuild: "99Z1000")
    harness.clock.advance(seconds: Timing.tickSeconds)
    #expect(await Self.finishes { await engine.step(.tick(Self.lidClosed)) })
    #expect(await engine.currentSnapshot().selfTest == .waiting)
    #expect(harness.facts.samples == 1)
    #expect(harness.holdEntries.isEmpty)

    harness.clock.advance(seconds: Timing.tickSeconds)
    #expect(await Self.finishes { await engine.step(.tick(Self.lidOpen)) })
    let snapshot = await engine.currentSnapshot()
    #expect(snapshot.selfTest == .passed)
    #expect(snapshot.osBuild == "99Z1000")
    #expect(harness.facts.samples == 2)
    #expect(harness.holdEntries == Self.passingRun)
    #expect(await engine.state.persisted.ownsHold == false)

    harness.clock.advance(seconds: Timing.tickSeconds)
    #expect(await Self.finishes { await engine.step(.tick(Self.lidOpen)) })
    #expect(harness.facts.samples == 2)
    #expect(await engine.currentSnapshot().selfTestRuns == 1)
  }

  @Test func aRequestBeforeTheFirstTickSamplesNothingAndRunsAfterIt() async throws {
    let harness = try Harness()
    let engine = try harness.composed()
    #expect(await Self.finishes { await engine.requestSelfTest() })
    #expect(harness.facts.samples == 0)
    #expect(await engine.currentSnapshot().selfTest == .waiting)
    #expect(await engine.state.selfTest.status == .notRun)
    #expect(harness.onWrites == 0)

    harness.recorder.reset()
    #expect(await Self.finishes { await engine.step(.tick(Self.lidOpen)) })
    #expect(harness.facts.samples == 1)
    #expect(await engine.currentSnapshot().selfTest == .passed)
    #expect(harness.holdEntries == Self.passingRun)
  }

  @Test func aShadowEngineIgnoresTheRequestAndNeverSamples() async throws {
    let harness = try Harness()
    let engine = try harness.direct(mode: .shadow)
    #expect(await Self.finishes { await engine.step(.tick(Self.lidOpen)) })
    #expect(await SelfTest.runnable(engine.state))
    #expect(await Self.finishes { await engine.requestSelfTest() })
    harness.clock.advance(seconds: Timing.tickSeconds)
    #expect(await Self.finishes { await engine.step(.tick(Self.lidOpen)) })
    #expect(harness.facts.samples == 0)
    #expect(await engine.state.selfTest == SelfTestState())
    #expect(await engine.currentSnapshot().selfTest == .notRun)
    #expect(await engine.currentSnapshot().selfTestRuns == 0)
    #expect(!harness.decisionLog(.shadow).contains("SELFTEST"))
    #expect(harness.recorder.all.isEmpty)
    #expect(harness.assertions.calls.isEmpty)
  }

  @Test func aTimedOutSampleKeepsTheTestWaitingLogsOnceAndRetriesAfterThirtySeconds() async throws {
    let harness = try Harness()
    let engine = try harness.direct(mode: .live, sampleTimeoutSeconds: 0.5)
    #expect(await Self.finishes { await engine.step(.tick(Self.lidOpen)) })
    harness.recorder.reset()
    harness.facts.block(seconds: 30)
    #expect(await Self.finishes { await engine.requestSelfTest() })
    #expect(harness.facts.samples == 1)
    #expect(await engine.currentSnapshot().selfTest == .waiting)
    #expect(await engine.state.selfTest.status == .notRun)
    #expect(harness.count(of: Self.timedOutLine, in: harness.errorLog()) == 1)
    #expect(harness.holdEntries.isEmpty)

    #expect(await Self.finishes { await engine.requestSelfTest() })
    #expect(harness.facts.samples == 1)
    #expect(harness.count(of: Self.timedOutLine, in: harness.errorLog()) == 1)

    harness.facts.releaseBlockedSample()
    #expect(await Self.poll { harness.runner.outstandingCount == 0 })
    harness.clock.advance(seconds: Engine.selfTestSampleRetrySeconds - 1)
    #expect(await Self.finishes { await engine.step(.tick(Self.lidOpen)) })
    #expect(harness.facts.samples == 1)
    #expect(await engine.currentSnapshot().selfTest == .waiting)
    #expect(harness.holdEntries.isEmpty)

    harness.clock.advance(seconds: 1)
    #expect(await Self.finishes { await engine.step(.tick(Self.lidOpen)) })
    #expect(harness.facts.samples == 2)
    #expect(await engine.currentSnapshot().selfTest == .passed)
    #expect(harness.holdEntries == Self.passingRun)
    #expect(harness.count(of: Self.timedOutLine, in: harness.errorLog()) == 1)
  }

  @Test func twoRequestsAtOnceSampleOnceAndRunOneTest() async throws {
    let harness = try Harness()
    let engine = try harness.direct(mode: .live)
    #expect(await Self.finishes { await engine.step(.tick(Self.lidOpen)) })
    harness.recorder.reset()
    harness.facts.block(seconds: 0.2)
    #expect(
      await Self.finishes {
        async let first: Void = engine.requestSelfTest()
        async let second: Void = engine.requestSelfTest()
        _ = await (first, second)
      })
    #expect(harness.facts.samples == 1)
    let snapshot = await engine.currentSnapshot()
    #expect(snapshot.selfTest == .passed)
    #expect(snapshot.selfTestRuns == 1)
    #expect(harness.holdEntries == Self.passingRun)
    #expect(!harness.errorLog().contains(Self.timedOutLine))
  }

  @Test func aRequestWhileATestRunsSamplesNothingAndStartsNoSecondRun() async throws {
    let harness = try Harness()
    let engine = try harness.direct(mode: .live)
    #expect(await Self.finishes { await engine.step(.tick(Self.lidOpen)) })
    harness.recorder.reset()
    harness.clamshell.holdNextWrite()
    defer { harness.clamshell.releaseHeldWrites() }
    let first = Task { await engine.requestSelfTest() }
    #expect(await Self.poll { await engine.currentSnapshot().selfTest == .running })
    #expect(await Self.finishes { await engine.requestSelfTest() })
    #expect(harness.facts.samples == 1)
    #expect(await engine.currentSnapshot().selfTest == .running)
    #expect(harness.clamshell.heldWritesReturned == 0)
    harness.clamshell.releaseHeldWrites()
    #expect(await Self.finishes { await first.value })
    let snapshot = await engine.currentSnapshot()
    #expect(snapshot.selfTest == .passed)
    #expect(snapshot.selfTestRuns == 1)
    #expect(harness.holdEntries == Self.passingRun)
  }

  @Test func aFailedArmNeverWritesTheOnBitAndReadsWatchdogNotRunning() async throws {
    let harness = try Harness()
    let engine = try harness.composed()
    #expect(await Self.finishes { await engine.step(.tick(Self.lidOpen)) })
    harness.recorder.reset()
    harness.sentinels.first.queue(.lost(errno: EPIPE), for: .arm)
    #expect(await Self.finishes { await engine.requestSelfTest() })
    let snapshot = await engine.currentSnapshot()
    #expect(snapshot.selfTest == .failed(.watchdogNotRunning))
    #expect(snapshot.selfTestErrorActive)
    #expect(snapshot.selfTestFailures == 1)
    #expect(harness.onWrites == 0)
    #expect(harness.offWrites >= 1)
    #expect(await engine.state.persisted.ownsHold == false)
    #expect(await engine.state.hold.lidClose == .released)
    #expect(harness.recorder.fileOwnsHold() == false)
    #expect(harness.sentinels.count == 2)
    #expect(harness.decisionLog().contains(" SELFTEST failed reason=watchdogNotRunning"))

    harness.recorder.reset()
    #expect(await Self.finishes { await engine.requestSelfTest() })
    #expect(await engine.currentSnapshot().selfTest == .passed)
    #expect(harness.holdEntries == Self.passingRun)
  }

  @Test func aRefusedOnWriteReadsClamshellRefusedAndALaterPassClearsTheErrorFlag() async throws {
    let harness = try Harness()
    let engine = try harness.composed()
    #expect(await Self.finishes { await engine.step(.tick(Self.lidOpen)) })
    harness.recorder.reset()
    harness.clamshell.queueOutcomes([.failed(code: Self.refusal)])
    #expect(await Self.finishes { await engine.requestSelfTest() })
    let failed = await engine.currentSnapshot()
    #expect(failed.selfTest == .failed(.clamshellRefused(Self.refusal)))
    #expect(failed.selfTestErrorActive)
    #expect(failed.selfTestFailures == 1)
    #expect(failed.selfTestRuns == 1)
    #expect(harness.holdEntries == Self.passingRun)
    #expect(await engine.state.persisted.ownsHold == false)
    #expect(harness.recorder.fileOwnsHold() == false)
    #expect(harness.decisionLog().contains(" SELFTEST failed reason=clamshellRefused code=0xE00002C2"))

    #expect(await Self.finishes { await engine.requestSelfTest() })
    let passed = await engine.currentSnapshot()
    #expect(passed.selfTest == .passed)
    #expect(!passed.selfTestErrorActive)
    #expect(passed.selfTestFailures == 1)
    #expect(passed.selfTestRuns == 2)
  }

  @Test func aRefusedIdleAssertionReadsAssertionRefusedAndStillReleasesAndClears() async throws {
    let harness = try Harness()
    let engine = try harness.composed()
    #expect(await Self.finishes { await engine.step(.tick(Self.lidOpen)) })
    harness.recorder.reset()
    let assertionCalls = harness.assertions.calls.count
    harness.assertions.queueAcquireOutcomes([.failed(code: Self.refusal)])
    #expect(await Self.finishes { await engine.requestSelfTest() })
    let snapshot = await engine.currentSnapshot()
    #expect(snapshot.selfTest == .failed(.assertionRefused(Self.refusal)))
    #expect(snapshot.selfTestErrorActive)
    #expect(harness.holdEntries == Self.passingRun)
    #expect(
      Array(harness.assertions.calls.dropFirst(assertionCalls)) == [
        .acquireOrRenew(Self.idle, 300), .release(Self.idle),
      ])
    #expect(await engine.state.persisted.ownsHold == false)
  }

  @Test func ownershipThatCannotBePersistedNeverWritesTheOnBit() async throws {
    let harness = try Harness()
    let engine = try harness.composed()
    #expect(await Self.finishes { await engine.step(.tick(Self.lidOpen)) })
    harness.recorder.reset()
    try FileManager.default.createDirectory(at: harness.paths.stateFile(.live), withIntermediateDirectories: true)
    #expect(await Self.finishes { await engine.requestSelfTest() })
    let snapshot = await engine.currentSnapshot()
    #expect(snapshot.selfTest == .failed(.stateNotSaved))
    #expect(harness.onWrites == 0)
    #expect(harness.offWrites == 1)
    #expect(await engine.state.persisted.ownsHold == false)
    #expect(harness.decisionLog().contains(" SELFTEST failed reason=stateNotSaved"))
    #expect(!harness.decisionLog().contains("0xFFFFFFFD"))
  }

  @Test(arguments: skipCases)
  func aDetectedToolOrSleepDisabledSkipsBeforeAnyClamshellOrAssertionCall(_ item: SkipCase) async throws {
    let harness = try Harness()
    let engine = try harness.composed()
    #expect(await Self.finishes { await engine.step(.tick(item.lid)) })
    harness.recorder.reset()
    let assertionCalls = harness.assertions.calls.count
    harness.facts.set(coexistence: item.coexistence)
    harness.facts.set(sleepDisabled: item.sleepDisabled)
    #expect(await Self.finishes { await engine.requestSelfTest() })
    let snapshot = await engine.currentSnapshot()
    #expect(snapshot.selfTest == .skipped(item.skip))
    #expect(!snapshot.selfTestErrorActive)
    #expect(snapshot.selfTestFailures == 0)
    #expect(snapshot.selfTestRuns == 0)
    #expect(snapshot.osBuild == Self.build)
    #expect(harness.holdEntries.isEmpty)
    #expect(harness.assertions.calls.count == assertionCalls)
    #expect(await engine.state.persisted.ownsHold == false)
    #expect(harness.count(of: " SELFTEST skipped reason=", in: harness.decisionLog()) == 1)
    #expect(!harness.decisionLog().contains("Keeper"))
  }

  @Test(arguments: ["caffeinate", "Caffeine", "KeepingYouAwake", "Lungo", "Theine"])
  func anIdleOnlyToolsAssertionLetsTheSelfTestRunAndPass(_ name: String) async throws {
    let harness = try Harness()
    let engine = try harness.composed()
    #expect(await Self.finishes { await engine.step(.tick(Self.lidOpen)) })
    harness.recorder.reset()
    harness.facts.set(
      coexistence: CoexistenceFacts(
        sleepDisabled: false,
        foreignAssertions: [ForeignAssertion(pid: 4243, type: "PreventUserIdleSystemSleep", processName: name)]))
    harness.facts.set(sleepDisabled: false)
    #expect(await Self.finishes { await engine.requestSelfTest() })
    let snapshot = await engine.currentSnapshot()
    #expect(snapshot.selfTest == .passed)
    #expect(snapshot.selfTestRuns == 1)
    #expect(harness.holdEntries == Self.passingRun)
    let log = harness.decisionLog()
    #expect(harness.count(of: " SELFTEST passed", in: log) == 1)
    #expect(harness.count(of: " SELFTEST skipped", in: log) == 0)
  }

  @Test func aToolThatAppearsWhileTheTestWaitsSkipsItOnTheFirstOpenTick() async throws {
    let harness = try Harness()
    let engine = try harness.composed()
    #expect(await Self.finishes { await engine.step(.tick(Self.lidClosed)) })
    harness.recorder.reset()
    #expect(await Self.finishes { await engine.requestSelfTest() })
    #expect(await engine.currentSnapshot().selfTest == .waiting)
    harness.facts.set(coexistence: CoexistenceFacts(amphetamineRunning: true, sleepDisabled: false))
    harness.clock.advance(seconds: Timing.tickSeconds)
    #expect(await Self.finishes { await engine.step(.tick(Self.lidOpen)) })
    #expect(await engine.currentSnapshot().selfTest == .skipped(.amphetamine))
    #expect(harness.facts.samples == 2)
    #expect(harness.holdEntries.isEmpty)
  }

  @Test func theInterpreterAndTheMachineAgreeOnTheWatchdogCode() {
    #expect(LiveInterpreter.unwatchedWriteCode == SelfTest.watchdogNotRunningCode)
  }

  @Test func theInterpreterTheBackendsAndTheMachineAgreeOnTheCodesThatAreNotMacOSErrors() {
    #expect(LiveInterpreter.unpersistedWriteCode == SelfTest.stateNotSavedCode)
    #expect(IOPMAssertionBackend.lockBusyCode == SelfTest.lockBusyCode)
    #expect(ClamshellBackend.lockBusyCode == SelfTest.lockBusyCode)
    #expect(Set([SelfTest.watchdogNotRunningCode, SelfTest.stateNotSavedCode, SelfTest.lockBusyCode]).count == 3)
  }
}
