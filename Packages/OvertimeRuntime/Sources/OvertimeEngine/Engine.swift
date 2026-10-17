import Foundation
import OvertimeCore
import OvertimeSystem
import os

public struct TranscriptSource: Sendable {
  public var seed: @Sendable () -> [TranscriptActivity]
  public var stream: @Sendable () -> AsyncStream<Event>
  public var health: @Sendable () -> [RootHealth]

  public init(
    seed: @escaping @Sendable () -> [TranscriptActivity],
    stream: @escaping @Sendable () -> AsyncStream<Event>,
    health: @escaping @Sendable () -> [RootHealth]
  ) {
    self.seed = seed
    self.stream = stream
    self.health = health
  }
}

public struct EngineSources: Sendable {
  public var transcriptSeed: @Sendable () -> [TranscriptActivity]
  public var sampleTick: @Sendable () -> TickFacts
  public var transcriptStream: (@Sendable () -> AsyncStream<Event>)?
  public var rootHealth: (@Sendable () -> [RootHealth])?
  public var powerRead: (@Sendable () -> PowerReading?)?
  public var powerStream: (@Sendable () -> AsyncStream<PowerReading?>)?
  public var launchFacts: (@Sendable () -> LaunchFacts)?
  public var systemPowerStream: (@Sendable () -> AsyncStream<Event>)?
  public var samplesFullWake: Bool
  public var externalDisplays: (@Sendable () -> Int?)?
  public var coexistence: (@Sendable () -> CoexistenceFacts)?
  public var screenLock: (@Sendable () -> ScreenLockStatus)?
  public var sessions: (@Sendable () -> [SessionSummary])?
  public var rebuildTranscripts: (@Sendable ([TranscriptRoot]) -> TranscriptSource)?
  public var resolveRoots: (@Sendable (Settings) -> [TranscriptRoot])?
  public var stuckWindow: StuckWindowBox?
  public var sleepDisabled: (@Sendable () -> Bool?)?
  public var osBuild: (@Sendable () -> String?)?
  public var networkSettings: (@Sendable (Settings) -> Void)?
  public var temperatureRead: (@Sendable () -> BatteryTemperatureReading)?
  public var temperatureStream: (@Sendable () -> AsyncStream<BatteryTemperatureReading>)?

  public init(
    transcriptSeed: @escaping @Sendable () -> [TranscriptActivity],
    sampleTick: @escaping @Sendable () -> TickFacts,
    transcriptStream: (@Sendable () -> AsyncStream<Event>)? = nil,
    rootHealth: (@Sendable () -> [RootHealth])? = nil,
    powerRead: (@Sendable () -> PowerReading?)? = nil,
    powerStream: (@Sendable () -> AsyncStream<PowerReading?>)? = nil,
    launchFacts: (@Sendable () -> LaunchFacts)? = nil,
    systemPowerStream: (@Sendable () -> AsyncStream<Event>)? = nil,
    samplesFullWake: Bool = false,
    externalDisplays: (@Sendable () -> Int?)? = nil,
    coexistence: (@Sendable () -> CoexistenceFacts)? = nil,
    screenLock: (@Sendable () -> ScreenLockStatus)? = nil,
    sessions: (@Sendable () -> [SessionSummary])? = nil,
    rebuildTranscripts: (@Sendable ([TranscriptRoot]) -> TranscriptSource)? = nil,
    resolveRoots: (@Sendable (Settings) -> [TranscriptRoot])? = nil,
    stuckWindow: StuckWindowBox? = nil,
    sleepDisabled: (@Sendable () -> Bool?)? = nil,
    osBuild: (@Sendable () -> String?)? = nil,
    networkSettings: (@Sendable (Settings) -> Void)? = nil,
    temperatureRead: (@Sendable () -> BatteryTemperatureReading)? = nil,
    temperatureStream: (@Sendable () -> AsyncStream<BatteryTemperatureReading>)? = nil
  ) {
    self.temperatureRead = temperatureRead
    self.temperatureStream = temperatureStream
    self.networkSettings = networkSettings
    self.sleepDisabled = sleepDisabled
    self.osBuild = osBuild
    self.stuckWindow = stuckWindow
    self.rebuildTranscripts = rebuildTranscripts
    self.resolveRoots = resolveRoots
    self.sessions = sessions
    self.screenLock = screenLock
    self.coexistence = coexistence
    self.externalDisplays = externalDisplays
    self.transcriptSeed = transcriptSeed
    self.sampleTick = sampleTick
    self.transcriptStream = transcriptStream
    self.rootHealth = rootHealth
    self.powerRead = powerRead
    self.powerStream = powerStream
    self.launchFacts = launchFacts
    self.systemPowerStream = systemPowerStream
    self.samplesFullWake = samplesFullWake
  }
}

struct SelfTestSample: Sendable {
  var coexistence: CoexistenceFacts?
  var sleepDisabled: Bool?
  var osBuild: String?
}

public actor Engine {
  public static let maxChainedSteps = 16
  public static let stopWaitSeconds: Double = 6
  public static let selfTestRunnerKey = "selfTest"
  public static let selfTestSampleRetrySeconds: Double = 30
  public static let transcriptRebuildRunnerKey = "transcriptRebuild"
  public static let transcriptStartRunnerKey = "transcriptStart"
  public static let transcriptRetryBaseSeconds: Double = 10
  public static let transcriptRetryCapSeconds: Double = 300

  public private(set) var state: AppState
  private(set) var settings: Settings
  private let clock: any ClockPort
  private let interpreter: any EffectInterpreter
  private let sources: EngineSources
  private let heartbeat: (@Sendable () async -> SentinelSendResult)?
  private let closeSentinel: (@Sendable () -> Void)?
  public static let sampleRunnerKey = "sample"

  private let deadlineRunner: DeadlineRunner
  private let sampleTimeoutSeconds: Double
  private let stopWaitSeconds: Double
  private var samplerFailureLogged = false
  private var powerFailureLogged = false
  private var capabilitiesFailureLogged = false
  private var sentinelLoss: (reports: Int, retryAt: Instant)?
  private var lastCoexistenceSample: Instant?
  private var stopRequested = false
  private var runTask: Task<Void, Never>?
  private var stopTask: Task<Void, Never>?
  private var transcriptTask: Task<Void, Never>?
  private var transcriptGeneration = 0
  private var transcriptRetry: (failures: Int, at: Instant)?
  private var transcriptRetryTask: Task<Void, Never>?
  private var learnedDirectories = LearnedConfigDirectories()
  private var learningTask: Task<Void, Never>?
  private var learnedChangePending = false
  private var rebuildsRunning = 0
  private var watchedRoots: [TranscriptRoot]?
  private var watchedHealth: (@Sendable () -> [RootHealth])?
  private var snapshotContinuation: AsyncStream<EngineSnapshot>.Continuation?
  private var lastPublished: EngineSnapshot?
  private var lastPower: PowerReading?
  private var lastCoexistence: CoexistenceFacts?
  private var tickReduced = false
  private var selfTestDeferred = false
  private var selfTestSampling = false
  private var selfTestSampleRetryAt: Instant?
  private var selfTestSampleFailureLogged = false

  public init(
    mode: RunMode,
    settings: Settings,
    clock: any ClockPort,
    interpreter: any EffectInterpreter,
    sources: EngineSources,
    sampleTimeoutSeconds: Double = Timing.systemCallTimeoutSeconds,
    heartbeat: (@Sendable () async -> SentinelSendResult)? = nil,
    closeSentinel: (@Sendable () -> Void)? = nil,
    deadlineRunner: DeadlineRunner = DeadlineRunner(),
    stopWaitSeconds: Double = Engine.stopWaitSeconds
  ) {
    self.deadlineRunner = deadlineRunner
    self.stopWaitSeconds = stopWaitSeconds
    self.heartbeat = heartbeat
    self.closeSentinel = closeSentinel
    self.state = AppState(mode: mode)
    self.settings = settings
    self.clock = clock
    self.interpreter = interpreter
    self.sources = sources
    self.sampleTimeoutSeconds = sampleTimeoutSeconds
  }

  public func runOnce() async {
    await launch()
    await seedTranscripts(sources.transcriptSeed)
    if let rootHealth = sources.rootHealth {
      await reportRootHealth(rootHealth)
    }
    await readPowerOnce()
    await readTemperatureOnce()
    await step(.tick(await withCoexistence(sources.sampleTick())))
  }

  public func run() async {
    if !stopRequested {
      await launch()
      await seedTranscripts(sources.transcriptSeed)
      await readPowerOnce()
      await readTemperatureOnce()
      await startTranscripts()
      let task = Task { await self.runLoops() }
      runTask = task
      if stopRequested {
        task.cancel()
        transcriptTask?.cancel()
      }
      await task.value
      runTask = nil
      transcriptTask?.cancel()
      transcriptTask = nil
    }
    if let stopTask {
      await stopTask.value
    } else {
      await logLine(Decision(keyword: .stop, verb: state.mode.rawValue))
    }
  }

  private func startTranscripts() async {
    guard !stopRequested, transcriptTask == nil, let start = sources.transcriptStream else { return }
    let started = await deadlineRunner.perform(
      timeout: sampleTimeoutSeconds, key: Self.transcriptStartRunnerKey, start)
    guard !stopRequested, transcriptTask == nil else { return }
    guard case .value(let stream) = started else {
      if transcriptRetry == nil {
        _ = await rootsNotApplied(resolvedRoots(settings), generation: transcriptGeneration)
      }
      return
    }
    transcriptTask = consumeTranscripts(stream)
  }

  private func seedTranscripts(_ seed: @escaping @Sendable () -> [TranscriptActivity]) async {
    switch await deadlineRunner.perform(timeout: sampleTimeoutSeconds, key: "transcriptSeed", seed) {
    case .value(let activities):
      for activity in activities {
        await step(.transcriptActivity(activity))
      }
    case .timedOut:
      await logLine(Decision(keyword: .error, verb: "transcript seed timedOut"))
    }
  }

  private func reportRootHealth(_ health: @escaping @Sendable () -> [RootHealth]) async {
    if case .value(let roots) = await deadlineRunner.perform(timeout: sampleTimeoutSeconds, key: "rootHealth", health) {
      await step(.transcriptRoots(roots))
    } else {
      await logLine(Decision(keyword: .error, verb: "transcript roots timedOut"))
    }
  }

  private func consumeTranscripts(_ stream: AsyncStream<Event>) -> Task<Void, Never> {
    Task {
      for await event in stream {
        await self.step(event)
      }
    }
  }

  private func rootsChanged(from old: Settings, to new: Settings) -> Bool {
    guard let resolveRoots = sources.resolveRoots else { return old.transcriptRoots != new.transcriptRoots }
    return resolveRoots(old) != resolveRoots(new)
  }

  private func baseRoots(_ settings: Settings) -> [TranscriptRoot] {
    sources.resolveRoots?(settings)
      ?? (settings.transcriptRoots ?? []).map { TranscriptRoot(path: $0, origin: .configured) }
  }

  private func resolvedRoots(_ settings: Settings) -> [TranscriptRoot] {
    TranscriptRoots.adding(learnedConfigDirectories: learnedDirectories.active(), to: baseRoots(settings))
  }

  private func learnConfigDirectories(_ directories: [String]) async {
    guard sources.rebuildTranscripts != nil else { return }
    let known = Set(learnedDirectories.lastSeen.keys)
    let decisions = learnedDirectories.observe(directories, at: clock.mono())
    let forgotten = known.subtracting(learnedDirectories.lastSeen.keys).subtracting(baseRoots(settings).map(\.path))
    state.health.quietRoots.subtract(forgotten)
    if !decisions.isEmpty {
      learnedChangePending = true
    }
    for decision in decisions {
      await logLine(decision)
    }
    guard learnedChangePending, !stopRequested, transcriptRetry == nil, transcriptRetryTask == nil,
      learningTask == nil, rebuildsRunning == 0
    else { return }
    learnedChangePending = false
    guard resolvedRoots(settings) != (watchedRoots ?? baseRoots(settings)) else { return }
    learningTask = Task {
      _ = await self.rebuildTranscripts()
      self.learningTask = nil
    }
  }

  private func applyRoots(replacing old: Settings) async -> Bool {
    let watched = watchedRoots ?? baseRoots(old)
    watchedRoots = watched
    guard resolvedRoots(settings) != watched || transcriptTask == nil else {
      transcriptGeneration += 1
      transcriptRetry = nil
      if let health = watchedHealth ?? sources.rootHealth {
        await reportRootHealth(health)
      }
      return true
    }
    transcriptRetry = nil
    return await rebuildTranscripts()
  }

  private func rebuildTranscripts() async -> Bool {
    guard let rebuild = sources.rebuildTranscripts else {
      transcriptRetry = nil
      await logLine(Decision(keyword: .error, verb: "settings roots notRebuilt"))
      return true
    }
    guard !stopRequested else { return true }
    rebuildsRunning += 1
    defer { rebuildsRunning -= 1 }
    let roots = resolvedRoots(settings)
    transcriptGeneration += 1
    let generation = transcriptGeneration
    guard
      case .value(let source) = await deadlineRunner.perform(
        timeout: sampleTimeoutSeconds, key: Self.transcriptRebuildRunnerKey, { rebuild(roots) })
    else {
      return await rootsNotApplied(roots, generation: generation)
    }
    guard isCurrentTranscripts(generation) else { return true }
    await seedTranscripts(source.seed)
    guard isCurrentTranscripts(generation) else { return true }
    await reportRootHealth(source.health)
    guard isCurrentTranscripts(generation) else { return true }
    guard
      case .value(let stream) = await deadlineRunner.perform(
        timeout: sampleTimeoutSeconds, key: Self.transcriptStartRunnerKey, source.stream)
    else {
      return await rootsNotApplied(roots, generation: generation)
    }
    guard isCurrentTranscripts(generation) else { return true }
    let previous = transcriptTask
    transcriptTask = consumeTranscripts(stream)
    transcriptRetry = nil
    watchedRoots = roots
    watchedHealth = source.health
    previous?.cancel()
    await previous?.value
    return true
  }

  private func rootsNotApplied(_ roots: [TranscriptRoot], generation: Int) async -> Bool {
    guard isCurrentTranscripts(generation) else { return true }
    let failures = (transcriptRetry?.failures ?? 0) + 1
    let wait = Self.transcriptRetrySeconds(afterFailures: failures)
    transcriptRetry = (failures, clock.mono().adding(seconds: wait))
    await logLine(
      Decision(
        keyword: .error, verb: "settings roots notRebuilt",
        fields: [
          DecisionField(key: "reason", value: "timedOut"), DecisionField(key: "retryIn", value: String(Int(wait))),
        ]))
    guard isCurrentTranscripts(generation) else { return false }
    let watched = transcriptTask == nil ? [] : Set((watchedRoots ?? []).map(\.path))
    let known = state.health.rootIssues
    await step(
      .transcriptRoots(
        roots.map { root in
          RootHealth(
            path: root.path, status: watched.contains(root.path) ? known[root.path] ?? .ok : .unreadable,
            origin: root.origin)
        }))
    return false
  }

  private func retryRootsIfDue() {
    guard let retry = transcriptRetry, transcriptRetryTask == nil, !stopRequested, clock.mono() >= retry.at else {
      return
    }
    transcriptRetryTask = Task {
      _ = await self.rebuildTranscripts()
      self.transcriptRetryTask = nil
    }
  }

  private func isCurrentTranscripts(_ generation: Int) -> Bool {
    generation == transcriptGeneration && !stopRequested
  }

  public static func transcriptRetrySeconds(afterFailures failures: Int) -> Double {
    let exponent = min(max(failures - 1, 0), 16)
    return min(transcriptRetryBaseSeconds * Double(1 << exponent), transcriptRetryCapSeconds)
  }

  public func stop() async {
    if stopTask == nil {
      stopRequested = true
      runTask?.cancel()
      transcriptTask?.cancel()
      stopTask = Task { await self.finishStop() }
    }
    await stopTask?.value
  }

  private func finishStop() async {
    interpreter.closeNetwork()
    if state.mode == .live {
      _ = await Self.bounded(seconds: stopWaitSeconds) { await self.chain(.stop) }
      closeSentinel?()
    }
    interpreter.logNow(Decision(keyword: .stop, verb: state.mode.rawValue), wall: clock.wall())
  }

  public static func bounded(seconds: Double, _ body: @escaping @Sendable () async -> Void) async -> Bool {
    let gate = OSAllocatedUnfairLock<CheckedContinuation<Bool, Never>?>(initialState: nil)
    let finish: @Sendable (Bool) -> Void = { finished in
      let continuation = gate.withLock { current -> CheckedContinuation<Bool, Never>? in
        defer { current = nil }
        return current
      }
      continuation?.resume(returning: finished)
    }
    let sleeper = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    let finished = await withCheckedContinuation { continuation in
      gate.withLock { $0 = continuation }
      Task {
        await body()
        finish(true)
      }
      let timer = Task {
        try? await Task.sleep(for: .seconds(seconds))
        finish(false)
      }
      sleeper.withLock { $0 = timer }
    }
    sleeper.withLock { $0 }?.cancel()
    return finished
  }

  public nonisolated func networkLaneDrained() async {
    await interpreter.drainNetwork()
  }

  public nonisolated func logImmediately(_ decision: Decision) {
    interpreter.logNow(decision, wall: clock.wall())
  }

  public func logLine(_ decision: Decision) async {
    _ = await interpreter.enqueue([.log(decision)], wall: clock.wall()).value
  }

  public func step(_ event: Event) async {
    await chain(event)
    await sendHeartbeat()
    guard case .tick(let facts) = event else { return }
    tickReduced = true
    await learnConfigDirectories(facts.agents.claudeConfigDirectories)
    retryRootsIfDue()
    await retrySelfTest()
  }

  public func updateHelper(_ facts: HelperFacts) async {
    await step(.helperFacts(facts))
  }

  public func requestSelfTest() async {
    guard state.mode == .live, !stopRequested, state.selfTest.pending == nil else { return }
    guard tickReduced else {
      deferSelfTest()
      return
    }
    guard !selfTestSampling else { return }
    selfTestSampling = true
    let sources = sources
    let sampled = await deadlineRunner.perform(timeout: sampleTimeoutSeconds, key: Self.selfTestRunnerKey) {
      SelfTestSample(
        coexistence: sources.coexistence?(), sleepDisabled: sources.sleepDisabled?(), osBuild: sources.osBuild?())
    }
    selfTestSampling = false
    guard !stopRequested else { return }
    guard case .value(let sample) = sampled else {
      await selfTestSampleTimedOut()
      return
    }
    selfTestDeferred = false
    selfTestSampleRetryAt = nil
    selfTestSampleFailureLogged = false
    await step(.selfTest(Self.selfTestFacts(sample)))
  }

  static func selfTestFacts(_ sample: SelfTestSample) -> SelfTestFacts {
    let foreign = (sample.coexistence?.foreignAssertions ?? []).filter { !CoexistenceProbe.isIdleOnly($0) }
    return SelfTestFacts(
      amphetamineRunning: sample.coexistence?.amphetamineRunning ?? false,
      otherTool: EngineSnapshot.toolNames(foreign).first,
      sleepDisabled: sample.sleepDisabled,
      osBuild: sample.osBuild)
  }

  private func retrySelfTest() async {
    guard selfTestDeferred || (state.selfTest.status == .waiting && SelfTest.runnable(state)) else { return }
    if let retryAt = selfTestSampleRetryAt, clock.mono() < retryAt { return }
    await requestSelfTest()
  }

  private func deferSelfTest() {
    selfTestDeferred = true
    publishSnapshot()
  }

  private func selfTestSampleTimedOut() async {
    selfTestSampleRetryAt = clock.mono().adding(seconds: Self.selfTestSampleRetrySeconds)
    deferSelfTest()
    guard !selfTestSampleFailureLogged else { return }
    selfTestSampleFailureLogged = true
    await logLine(Decision(keyword: .error, verb: "selftest sample timedOut"))
  }

  private func sendHeartbeat() async {
    guard let heartbeat, !stopRequested else { return }
    guard await heartbeat() != .sent else {
      sentinelLoss = nil
      return
    }
    let now = clock.mono()
    if let sentinelLoss, now < sentinelLoss.retryAt { return }
    let reports = (sentinelLoss?.reports ?? 0) + 1
    sentinelLoss = (reports, now.adding(seconds: Self.sentinelRetrySeconds(afterReports: reports)))
    await chain(.sentinelLost)
  }

  public static func sentinelRetrySeconds(afterReports reports: Int) -> Double {
    let exponent = min(max(reports - 1, 0), 16)
    return min(Timing.sentinelRespawnRetryBaseSeconds * Double(1 << exponent), Timing.sentinelRespawnRetryCapSeconds)
  }

  private func chain(_ event: Event) async {
    await continueChain(await apply(await enriched(event)))
  }

  private func continueChain(_ first: [Event]) async {
    var pending = first
    var chained = 0
    while !pending.isEmpty {
      guard chained < Self.maxChainedSteps else {
        await logLine(
          Decision(
            keyword: .error, verb: "effect chain",
            fields: [DecisionField(key: "dropped", value: String(pending.count))]))
        return
      }
      chained += 1
      let next = pending.removeFirst()
      pending += await apply(next)
    }
  }

  private func enriched(_ event: Event) async -> Event {
    guard case .lidChanged(true, let sleepBit, nil) = event, let source = sources.externalDisplays else { return event }
    guard case .value(let count?) = await deadlineRunner.perform(timeout: sampleTimeoutSeconds, key: "displays", source)
    else {
      return event
    }
    return .lidChanged(closed: true, sleepBit: sleepBit, externalDisplays: count)
  }

  private func apply(_ event: Event) async -> [Event] {
    guard let batch = submit(event) else { return [] }
    return await batch.value
  }

  private func submit(_ event: Event) -> Task<[Event], Never>? {
    let stamped = Stamped(mono: clock.mono(), wall: clock.wall(), event: event)
    let effects = Reducer.reduce(&state, stamped, settings)
    publishSnapshot()
    guard !effects.isEmpty else { return nil }
    return interpreter.enqueue(effects, wall: stamped.wall)
  }

  public func handle(_ request: CtlRequest) async -> CtlResponse {
    let command: UserCommand
    switch request {
    case .pause(let spec):
      command = .pause(spec)
    case .force(let spec):
      command = .force(spec)
    case .releaseUntilIdle:
      command = .releaseUntilIdle
    case .resume:
      command = .resume
    case .sleepNow:
      command = .sleepNow
    case .status:
      return CtlResponse(ok: true, status: snapshot())
    }
    let batch = submit(.command(command))
    let status = snapshot()
    Task { await self.finishCommand(batch) }
    return CtlResponse(ok: true, status: status)
  }

  private func finishCommand(_ batch: Task<[Event], Never>?) async {
    await continueChain(await batch?.value ?? [])
    await sendHeartbeat()
  }

  public func snapshots() -> AsyncStream<EngineSnapshot> {
    snapshotContinuation?.finish()
    let (stream, continuation) = AsyncStream.makeStream(
      of: EngineSnapshot.self, bufferingPolicy: .bufferingNewest(1))
    snapshotContinuation = continuation
    let current = currentSnapshot()
    lastPublished = current
    continuation.yield(current)
    return stream
  }

  public func currentSnapshot() -> EngineSnapshot {
    var snapshot = EngineSnapshot(
      state: state, settings: settings, sessions: sources.sessions?() ?? [], power: lastPower,
      coexistence: lastCoexistence)
    if selfTestDeferred {
      snapshot.selfTest = .waiting
    }
    return snapshot
  }

  private func publishSnapshot() {
    guard let snapshotContinuation else { return }
    let current = currentSnapshot()
    guard current != lastPublished else { return }
    lastPublished = current
    snapshotContinuation.yield(current)
  }

  public func snapshot() -> StatusSnapshot {
    var snapshot = StatusSnapshot(
      mode: state.mode.rawValue,
      busy: state.busy.busy,
      wanted: state.want.wanted,
      reason: state.want.reason,
      override: state.want.override,
      batteryBlocked: state.battery.blocked,
      holdIdle: Self.describe(state.hold.idle),
      holdDisplay: Self.describe(state.hold.display),
      holdError: state.hold.errorActive
    )
    switch state.want.pause {
    case .untilMono(_, let wall):
      snapshot.pause = "timed"
      snapshot.pauseUntil = Want.iso8601(wall)
    case .untilWall(let date):
      snapshot.pause = "until"
      snapshot.pauseUntil = Want.iso8601(date)
    case .indefinite:
      snapshot.pause = "indefinite"
    case nil:
      break
    }
    switch state.want.force {
    case .untilMono(let deadline):
      snapshot.force = "timed"
      let remaining = deadline.seconds(since: clock.mono())
      snapshot.forceUntil = Want.iso8601(clock.wall().addingTimeInterval(remaining))
    case .indefinite:
      snapshot.force = "indefinite"
    case nil:
      break
    }
    return snapshot
  }

  static func describe(_ phase: BackendPhase) -> String {
    switch phase {
    case .released: "released"
    case .acquiring: "acquiring"
    case .held: "held"
    case .releasing: "releasing"
    case .failed(let attempts, _): "failed attempts=\(attempts)"
    }
  }

  public func stepPower(_ reading: PowerReading?) async {
    guard let reading else {
      guard !powerFailureLogged else { return }
      powerFailureLogged = true
      await logLine(Decision(keyword: .error, verb: "power unreadable"))
      return
    }
    powerFailureLogged = false
    lastPower = reading
    await step(.power(reading))
  }

  public func stepTemperature(_ reading: BatteryTemperatureReading) async {
    await step(.batteryTemperature(reading))
  }

  public func apply(settings new: Settings) async -> Bool {
    guard SettingsStore.validationProblem(new) == nil, new.validated().adjustments.isEmpty else { return false }
    let old = settings
    guard new != old else { return transcriptRetry == nil }
    settings = new
    if old.stuckWindowSeconds != new.stuckWindowSeconds {
      sources.stuckWindow?.seconds = new.stuckWindowSeconds
    }
    publishSnapshot()
    let keys = Self.changedKeys(from: old, to: new)
    if keys.contains("hotspot") || keys.contains("hotspotAutoDetect") {
      sources.networkSettings?(new)
    }
    await logLine(
      Decision(
        keyword: .settings, verb: "applied", fields: [DecisionField(key: "keys", value: keys.joined(separator: ","))])
    )
    let powerRulesChanged =
      old.batteryLowPercent != new.batteryLowPercent || old.batteryResumePercent != new.batteryResumePercent
      || old.batteryProtectionEnabled != new.batteryProtectionEnabled
      || old.helperBatteryFloorPercent != new.helperBatteryFloorPercent
      || old.lidClosedKeepAwake != new.lidClosedKeepAwake
    if powerRulesChanged, let lastPower {
      await step(.power(lastPower))
    }
    let temperatureChanged =
      old.temperatureProtectionEnabled != new.temperatureProtectionEnabled
      || old.temperatureReleaseCelsius != new.temperatureReleaseCelsius
    if temperatureChanged, let reading = state.temperature.reading {
      await step(.batteryTemperature(reading))
    }
    if rootsChanged(from: old, to: new) {
      return await applyRoots(replacing: old)
    }
    return transcriptRetry == nil
  }

  static func changedKeys(from old: Settings, to new: Settings) -> [String] {
    var keys: [String] = []
    if old.batteryLowPercent != new.batteryLowPercent { keys.append("batteryLowPercent") }
    if old.batteryResumePercent != new.batteryResumePercent { keys.append("batteryResumePercent") }
    if old.transcriptWindowSeconds != new.transcriptWindowSeconds { keys.append("transcriptWindowSeconds") }
    if old.releaseGraceSeconds != new.releaseGraceSeconds { keys.append("releaseGraceSeconds") }
    if old.stuckWindowSeconds != new.stuckWindowSeconds { keys.append("stuckWindowSeconds") }
    if old.transcriptRoots != new.transcriptRoots { keys.append("transcriptRoots") }
    if old.ignoredEntrypoints != new.ignoredEntrypoints { keys.append("ignoredEntrypoints") }
    if old.keepDisplayOn != new.keepDisplayOn { keys.append("keepDisplayOn") }
    if old.hotspot != new.hotspot { keys.append("hotspot") }
    if old.hotspotAutoDetect != new.hotspotAutoDetect { keys.append("hotspotAutoDetect") }
    if old.batteryProtectionEnabled != new.batteryProtectionEnabled { keys.append("batteryProtectionEnabled") }
    if old.helperBatteryFloorPercent != new.helperBatteryFloorPercent { keys.append("helperBatteryFloorPercent") }
    if old.temperatureProtectionEnabled != new.temperatureProtectionEnabled {
      keys.append("temperatureProtectionEnabled")
    }
    if old.temperatureReleaseCelsius != new.temperatureReleaseCelsius { keys.append("temperatureReleaseCelsius") }
    if old.lidClosedKeepAwake != new.lidClosedKeepAwake { keys.append("lidClosedKeepAwake") }
    if old.pauseFirstMinutes != new.pauseFirstMinutes { keys.append("pauseFirstMinutes") }
    if old.pauseSecondMinutes != new.pauseSecondMinutes { keys.append("pauseSecondMinutes") }
    if old.keepAwakeFirstMinutes != new.keepAwakeFirstMinutes { keys.append("keepAwakeFirstMinutes") }
    if old.keepAwakeSecondMinutes != new.keepAwakeSecondMinutes { keys.append("keepAwakeSecondMinutes") }
    return keys.sorted()
  }

  private func launch() async {
    if let launchFacts = sources.launchFacts {
      await step(.launched(launchFacts()))
    }
    guard let screenLock = sources.screenLock else { return }
    let bound = sampleTimeoutSeconds + ToolRunner.terminateGraceSeconds + ToolRunner.reapWaitSeconds
    switch await deadlineRunner.perform(timeout: bound, key: "screenLock", screenLock) {
    case .value(let status):
      await step(.screenLock(status))
    case .timedOut:
      await step(.screenLock(.unknown))
    }
  }

  private func readPowerOnce() async {
    guard let powerRead = sources.powerRead else { return }
    switch await deadlineRunner.perform(timeout: sampleTimeoutSeconds, key: "power", powerRead) {
    case .value(let reading):
      await stepPower(reading)
    case .timedOut:
      await stepPower(nil)
    }
  }

  private func readTemperatureOnce() async {
    guard let temperatureRead = sources.temperatureRead else { return }
    switch await deadlineRunner.perform(timeout: sampleTimeoutSeconds, key: "temperature", temperatureRead) {
    case .value(let reading):
      await stepTemperature(reading)
    case .timedOut:
      await stepTemperature(.unreadable)
    }
  }

  private func runLoops() async {
    let power = sources.powerStream?()
    let temperature = sources.temperatureStream?()
    let systemPower = sources.systemPowerStream?()
    let network = interpreter.networkEvents
    await withTaskGroup(of: Void.self) { group in
      if let network {
        group.addTask {
          for await event in network {
            await self.step(event)
          }
        }
      }
      if let systemPower {
        group.addTask {
          for await event in systemPower {
            await self.step(event)
          }
        }
      }
      if let power {
        group.addTask {
          for await reading in power {
            await self.stepPower(reading)
          }
        }
      }
      if let temperature {
        group.addTask {
          for await reading in temperature {
            await self.stepTemperature(reading)
          }
        }
      }
      group.addTask {
        await self.timerLoop()
      }
    }
  }

  private func timerLoop() async {
    var lastTick: Instant?
    while !Task.isCancelled {
      let now = clock.mono()
      var wake = lastTick?.adding(seconds: Timing.tickSeconds) ?? now
      if let deadline = Reducer.nextDeadline(state, settings), deadline < wake {
        wake = deadline
      }
      let delay = wake.nanoseconds(since: now)
      if delay > 0 {
        do {
          try await Task.sleep(
            until: ContinuousClock.now.advanced(by: .nanoseconds(Int64(clamping: delay))),
            tolerance: .milliseconds(50),
            clock: .continuous
          )
        } catch {
          return
        }
      }
      guard !Task.isCancelled else { return }
      lastTick = clock.mono()
      await tick()
    }
  }

  public func tick() async {
    var facts = TickFacts(agents: .none)
    switch await deadlineRunner.perform(timeout: sampleTimeoutSeconds, key: Self.sampleRunnerKey, sources.sampleTick) {
    case .value(let sampled):
      facts = sampled
      samplerFailureLogged = false
      await noteCapabilities(sampled.fullWake)
    case .timedOut:
      await logSamplerFailure()
    }
    await step(.tick(await withCoexistence(facts)))
  }

  private func withCoexistence(_ facts: TickFacts) async -> TickFacts {
    guard state.want.wanted != false, let source = sources.coexistence else { return facts }
    let now = clock.mono()
    if let last = lastCoexistenceSample, now < last.adding(seconds: Timing.coexistenceCheckSeconds) {
      return facts
    }
    lastCoexistenceSample = now
    guard
      case .value(let sampled) = await deadlineRunner.perform(timeout: sampleTimeoutSeconds, key: "coexistence", source)
    else {
      return facts
    }
    lastCoexistence = sampled
    var enriched = facts
    enriched.coexistence = sampled
    return enriched
  }

  private func noteCapabilities(_ fullWake: Bool?) async {
    guard sources.samplesFullWake else { return }
    guard fullWake == nil else {
      capabilitiesFailureLogged = false
      return
    }
    guard !capabilitiesFailureLogged else { return }
    capabilitiesFailureLogged = true
    await logLine(Decision(keyword: .error, verb: "capabilities unreadable"))
  }

  private func logSamplerFailure() async {
    guard !samplerFailureLogged else { return }
    samplerFailureLogged = true
    await logLine(Decision(keyword: .error, verb: "sampler timedOut"))
  }
}
