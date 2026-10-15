import Foundation
import OvertimeClamshell
import OvertimeCore
import OvertimeSystem
import os

public enum CompositionError: Error, Equatable {
  case alreadyRunning(RunMode)
  case sentinelUnavailable(String)
}

public struct RunningInstance: Sendable {
  public let engine: Engine
  public let lock: InstanceLock
  public let server: ControlServer?

  public func shutdown() {
    stopServer()
    releaseLock()
  }

  public func stopServer() {
    server?.stop()
  }

  public func releaseLock() {
    lock.release()
  }

  public func runOnceAndFinish() async {
    await engine.runOnce()
    if await engine.state.mode == .live {
      await engine.stop()
    }
    shutdown()
  }
}

public enum Composition {
  public static func launchShadow(
    paths: Paths,
    settings: Settings,
    environment: [String: String],
    homeDirectory: String,
    once: Bool
  ) throws -> RunningInstance {
    try launch(mode: .shadow, paths: paths, once: once) {
      try makeShadowEngine(
        paths: paths, settings: settings, environment: environment, homeDirectory: homeDirectory, once: once)
    }
  }

  public static func launchLive(
    paths: Paths,
    settings: Settings,
    ports: LivePorts,
    environment: [String: String],
    homeDirectory: String,
    once: Bool,
    lock: InstanceLock? = nil
  ) throws -> RunningInstance {
    try launch(mode: .live, paths: paths, once: once, lock: lock) {
      try makeLiveEngine(
        paths: paths, settings: settings, ports: ports, environment: environment, homeDirectory: homeDirectory,
        once: once)
    }
  }

  static func launch(
    mode: RunMode, paths: Paths, once: Bool, lock heldLock: InstanceLock? = nil, makeEngine: () throws -> Engine
  ) throws -> RunningInstance {
    try paths.createDirectories()
    let lock: InstanceLock
    if let heldLock {
      lock = heldLock
    } else {
      do {
        lock = try InstanceLock.acquire(at: paths.lockFile(mode))
      } catch InstanceLockError.alreadyRunning {
        throw CompositionError.alreadyRunning(mode)
      }
    }
    let engine = try makeEngine()
    guard !once else { return RunningInstance(engine: engine, lock: lock, server: nil) }
    let server = ControlServer(socketPath: paths.controlSocket(mode).path(percentEncoded: false)) { request in
      await engine.handle(request)
    }
    try server.start()
    return RunningInstance(engine: engine, lock: lock, server: server)
  }

  public static func makeShadowEngine(
    paths: Paths,
    settings: Settings,
    environment: [String: String],
    homeDirectory: String,
    once: Bool,
    externalDisplays: (@Sendable () -> Int?)? = nil,
    tools: any ToolPort = ToolRunner()
  ) throws -> Engine {
    try paths.createDirectories()
    let logger = try makeLogger(paths: paths, mode: .shadow)
    let interpreter = RecordingInterpreter(logger: logger, timeZone: .current, paths: paths)
    return makeEngine(
      mode: .shadow, paths: paths, settings: settings, interpreter: interpreter, clock: SystemClock(),
      environment: environment, homeDirectory: homeDirectory, once: once, tools: tools,
      externalDisplays: externalDisplays)
  }

  public static func makeLiveEngine(
    paths: Paths,
    settings: Settings,
    ports: LivePorts,
    environment: [String: String],
    homeDirectory: String,
    once: Bool,
    clock: any ClockPort = SystemClock(),
    callTimeoutSeconds: Double = Timing.systemCallTimeoutSeconds,
    externalDisplays: (@Sendable () -> Int?)? = nil,
    coexistence: (@Sendable () -> CoexistenceFacts)? = nil,
    sleepDisabled: (@Sendable () -> Bool?)? = nil,
    osBuild: (@Sendable () -> String?)? = nil,
    stopWaitSeconds: Double = Engine.stopWaitSeconds
  ) throws -> Engine {
    try paths.createDirectories()
    let logger = try makeLogger(paths: paths, mode: .live)
    let launch = LaunchFacts(persisted: StateStore.read(at: ports.stateFile), bootSessionUUID: BootSession.current())
    let sentinel = ports.makeSentinel()
    do {
      try sentinel.start()
    } catch {
      if launchMayFindTheBitSet(launch) {
        clearWithoutSentinel(
          ports.clamshell, logger: logger, wall: clock.wall(), timeoutSeconds: callTimeoutSeconds)
      }
      throw CompositionError.sentinelUnavailable(String(describing: error))
    }
    if launchMayFindTheBitSet(launch) {
      _ = sentinel.send(.arm)
    }
    let interpreter = LiveInterpreter(
      ports: ports, logger: logger, sentinel: sentinel, timeZone: .current, callTimeoutSeconds: callTimeoutSeconds)
    let network = ports.network
    network.autoDetectInUse(autoDetectInUse(settings))
    return makeEngine(
      mode: .live, paths: paths, settings: settings, interpreter: interpreter, clock: clock,
      environment: environment, homeDirectory: homeDirectory, once: once, tools: ports.tools,
      heartbeat: { await interpreter.heartbeat() },
      closeSentinel: { interpreter.closeSentinel() }, externalDisplays: externalDisplays, coexistence: coexistence,
      sleepDisabled: sleepDisabled, osBuild: osBuild, stopWaitSeconds: stopWaitSeconds,
      networkFacts: { lidClosed in network.facts(lidClosed: lidClosed) },
      networkSettings: { network.autoDetectInUse(autoDetectInUse($0)) })
  }

  public static func autoDetectInUse(_ settings: Settings) -> Bool {
    settings.hotspot.isEmpty && settings.hotspotAutoDetect
  }

  static func launchMayFindTheBitSet(_ facts: LaunchFacts) -> Bool {
    LidCloseHold.launchAction(facts) != nil
  }

  static func clearWithoutSentinel(
    _ clamshell: any ClamshellPort, logger: FileLogger, wall: Date, timeoutSeconds: Double
  ) {
    let fields: [DecisionField]
    switch DeadlineRunner().run(timeout: timeoutSeconds, { clamshell.write(on: false) }) {
    case .value(.succeeded):
      fields = [DecisionField(key: "clearStale", value: "succeeded")]
    case .value(.failed(let code)):
      fields = [DecisionField(key: "clearStale", value: "failed"), DecisionField(key: "code", value: String(code))]
    case .value(.timedOut), .timedOut:
      fields = [DecisionField(key: "clearStale", value: "timedOut")]
    }
    logger.log(Decision(keyword: .error, verb: "sentinel unavailable", fields: fields), wall: wall, timeZone: .current)
  }

  static func makeLogger(paths: Paths, mode: RunMode) throws -> FileLogger {
    try FileLogger(
      decisionLog: paths.decisionLog(mode),
      errorLog: paths.errorLog(mode),
      rotateAtBytes: Timing.logRotateBytes
    )
  }

  static func makeEngine(
    mode: RunMode,
    paths: Paths,
    settings: Settings,
    interpreter: any EffectInterpreter,
    clock: any ClockPort,
    environment: [String: String],
    homeDirectory: String,
    once: Bool,
    tools: any ToolPort,
    heartbeat: (@Sendable () async -> SentinelSendResult)? = nil,
    closeSentinel: (@Sendable () -> Void)? = nil,
    externalDisplays: (@Sendable () -> Int?)? = nil,
    coexistence: (@Sendable () -> CoexistenceFacts)? = nil,
    sleepDisabled: (@Sendable () -> Bool?)? = nil,
    osBuild: (@Sendable () -> String?)? = nil,
    stopWaitSeconds: Double = Engine.stopWaitSeconds,
    networkFacts: (@Sendable (Bool?) -> NetworkFacts?)? = nil,
    networkSettings: (@Sendable (Settings) -> Void)? = nil
  ) -> Engine {
    let roots = settings.transcriptRootSet(environment: environment, homeDirectory: homeDirectory)
    let stuckWindow = StuckWindowBox(seconds: settings.stuckWindowSeconds)
    let headers = TranscriptHeaderReader(clock: clock, stuckWindow: stuckWindow)
    let scanner = TranscriptScanner(roots: roots.map(\.path), headers: headers)
    let userID = getuid()
    let processScanner = ProcessScanner(userID: userID)
    let detectors: [any AgentDetector] = [ClaudeCodeDetector(userID: userID)]
    let powerMonitor = PowerSourceMonitor()
    let registry = RegistryReader()
    let displayCount: @Sendable () -> Int? = externalDisplays ?? { registry.externalDisplayCount() }
    let latestProcesses = OSAllocatedUnfairLock<[ProcessRecord]>(initialState: [])
    let sessionReader = SessionReader()
    let latestSessions = OSAllocatedUnfairLock<[SessionSummary]>(initialState: [])
    let probe = CoexistenceProbe()
    let ownPID = getpid()
    let coexistenceSource: @Sendable () -> CoexistenceFacts =
      coexistence ?? {
        let processes = latestProcesses.withLock { $0 }
        return probe.read(
          processes: processes,
          excludingPIDs: CoexistenceProbe.claudeCaffeinatePIDs(in: processes).union([ownPID]))
      }
    var transcriptStream: (@Sendable () -> AsyncStream<Event>)?
    var powerStream: (@Sendable () -> AsyncStream<PowerReading?>)?
    var systemPowerStream: (@Sendable () -> AsyncStream<Event>)?
    var rebuildTranscripts: (@Sendable ([TranscriptRoot]) -> TranscriptSource)?
    if !once {
      let notifications = PowerNotifications()
      systemPowerStream = { notifications.start() }
      let watcher = TranscriptWatcher(roots: roots, clock: clock, stuckWindow: stuckWindow, headers: headers)
      transcriptStream = { watcher.start() }
      powerStream = { powerMonitor.startReporting() }
      if mode == .live {
        rebuildTranscripts = { roots in
          makeTranscriptSource(roots: roots, clock: clock, stuckWindow: stuckWindow, headers: headers)
        }
      }
    }
    let stateFile = paths.stateFile(mode)
    let sources = EngineSources(
      transcriptSeed: { scanner.recentActivity(withinSeconds: stuckWindow.seconds, clock: clock) },
      sampleTick: {
        let processes = processScanner.sample(clock: clock, extraCandidates: [])
        latestProcesses.withLock { $0 = processes }
        let sessions = sessionReader.sessions(from: processes, at: clock.mono())
        latestSessions.withLock { $0 = sessions }
        let lidClosed = registry.lidClosed()
        let closed = lidClosed == true
        return TickFacts(
          agents: .merged(detectors.map { $0.signals(from: processes) }), lidClosed: lidClosed,
          externalDisplays: closed ? displayCount() : nil,
          fullWake: RegistryReader.isFullWake(capabilities: registry.systemCapabilities()),
          hidIdleSeconds: closed ? registry.hidIdleSeconds() : nil, network: networkFacts?(lidClosed))
      },
      transcriptStream: transcriptStream,
      rootHealth: { TranscriptWatcher.health(ofRoots: roots) },
      powerRead: { powerMonitor.read() },
      powerStream: powerStream,
      launchFacts: {
        LaunchFacts(persisted: StateStore.read(at: stateFile), bootSessionUUID: BootSession.current())
      },
      systemPowerStream: systemPowerStream,
      samplesFullWake: true,
      externalDisplays: displayCount,
      coexistence: coexistenceSource,
      screenLock: { ScreenLockReader.read(tools: tools) },
      sessions: { latestSessions.withLock { $0 } },
      rebuildTranscripts: rebuildTranscripts,
      resolveRoots: { $0.transcriptRootSet(environment: environment, homeDirectory: homeDirectory) },
      stuckWindow: stuckWindow,
      sleepDisabled: sleepDisabled ?? { registry.sleepDisabled() },
      osBuild: osBuild ?? { SystemInfo.osBuild() },
      networkSettings: networkSettings
    )
    return Engine(
      mode: mode, settings: settings, clock: clock, interpreter: interpreter, sources: sources, heartbeat: heartbeat,
      closeSentinel: closeSentinel, stopWaitSeconds: stopWaitSeconds)
  }

  static func makeTranscriptSource(
    roots: [TranscriptRoot], clock: any ClockPort, stuckWindow: StuckWindowBox, headers: TranscriptHeaderReader
  ) -> TranscriptSource {
    let scanner = TranscriptScanner(roots: roots.map(\.path), headers: headers)
    let watcher = TranscriptWatcher(roots: roots, clock: clock, stuckWindow: stuckWindow, headers: headers)
    return TranscriptSource(
      seed: { scanner.recentActivity(withinSeconds: stuckWindow.seconds, clock: clock) },
      stream: { watcher.start() },
      health: { TranscriptWatcher.health(ofRoots: roots) }
    )
  }
}
