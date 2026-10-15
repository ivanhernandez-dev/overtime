import Foundation
import OvertimeClamshell
import OvertimeCore
import OvertimeEngine
import OvertimeHelperClient
import OvertimeHelperCore
import OvertimeSystem
import os

public enum AppHostStart: Sendable {
  case running(LiveEngineHost)
  case blocked(HostFailure)
}

public struct AppHostLaunch: Sendable {
  public var paths: Paths
  public var settings: Settings
  public var environment: [String: String]
  public var homeDirectory: String
  public var lock: InstanceLock?
  public var helper: any HelperPort = NoHelperPort()
  public var network: any NetworkPort = NoNetworkPort()
}

public typealias AppHostLauncher = @Sendable (AppHostLaunch) throws -> RunningInstance

public final class AppHost: Sendable {
  public let paths: Paths
  public let version: String
  private let environment: [String: String]
  private let homeDirectory: String
  private let launcher: AppHostLauncher
  private let wifi: (any WiFiInfoPort)?
  private let helper: any HelperPort
  private let network: any NetworkPort
  private let recoveryRunner = DeadlineRunner()
  private let fallbackLog: @Sendable (Decision) -> Void
  private let restartStopBound: Double
  private let terminator = OSAllocatedUnfairLock<TerminationCoordinator?>(initialState: nil)
  private let running = OSAllocatedUnfairLock<LiveEngineHost?>(initialState: nil)
  private let hosted = OSAllocatedUnfairLock<Hosted?>(initialState: nil)
  private let retainedLocks = OSAllocatedUnfairLock<HeldLocks?>(initialState: nil)
  private let starting = OSAllocatedUnfairLock<Task<AppHostStart, Never>?>(initialState: nil)
  private let restarting = OSAllocatedUnfairLock<Task<AppHostStart, Never>?>(initialState: nil)
  private let terminating = OSAllocatedUnfairLock(initialState: false)

  public static let restartStopBoundSeconds = TerminationCoordinator.defaultOuterBoundSeconds
  public static let stopRecoverySeconds: Double = 6
  public static let stopRecoveryReserveSeconds: Double = 0.5

  private struct Hosted: Sendable {
    var instance: RunningInstance
    var locks: HeldLocks
  }

  public var runningHost: LiveEngineHost? {
    running.withLock { $0 }
  }

  public init(
    paths: Paths,
    version: String,
    environment: [String: String],
    homeDirectory: String,
    wifi: (any WiFiInfoPort)? = nil,
    helper: (any HelperPort)? = nil,
    network: (any NetworkPort)? = nil,
    restartStopBoundSeconds: Double = AppHost.restartStopBoundSeconds,
    fallbackLog: @escaping @Sendable (Decision) -> Void = AppHost.emergencyLog,
    launcher: @escaping AppHostLauncher = AppHost.liveLauncher
  ) {
    self.fallbackLog = fallbackLog
    self.wifi = wifi
    self.helper = helper ?? NoHelperPort()
    self.network = network ?? NoNetworkPort()
    self.restartStopBound = restartStopBoundSeconds
    self.paths = paths
    self.version = version
    self.environment = environment
    self.homeDirectory = homeDirectory
    self.launcher = launcher
    terminator.withLock { $0 = makeCoordinator() }
  }

  public static func relaunchConfiguration(appPath: String, paths: Paths) -> RelaunchConfiguration {
    RelaunchConfiguration(
      appPath: appPath, historyPath: paths.relaunchHistory.path(percentEncoded: false),
      suppressionPath: paths.relaunchSuppression.path(percentEncoded: false))
  }

  public static let liveLauncher: AppHostLauncher = { launch in
    let relaunch = relaunchConfiguration(appPath: Bundle.main.bundlePath, paths: launch.paths)
    return try Composition.launchLive(
      paths: launch.paths, settings: launch.settings,
      ports: LivePorts.system(
        paths: launch.paths, relaunch: relaunch, helper: launch.helper, network: launch.network),
      environment: launch.environment, homeDirectory: launch.homeDirectory, once: false, lock: launch.lock)
  }

  public func terminate() async -> Bool {
    guard let coordinator = terminator.withLock({ $0 }) else { return true }
    return await coordinator.terminate()
  }

  public func start(locks: HeldLocks) async -> AppHostStart {
    await beginStart(locks: locks).value
  }

  public func beginStart(locks: HeldLocks) -> Task<AppHostStart, Never> {
    let task = Task { await self.performStart(locks: locks) }
    starting.withLock { $0 = task }
    return task
  }

  private func performStart(locks: HeldLocks) async -> AppHostStart {
    guard !terminating.withLock({ $0 }) else {
      locks.release()
      return .blocked(.sentinelUnavailable)
    }
    let loaded = Self.loadSettings(from: paths.settingsFile)
    let instance: RunningInstance
    do {
      instance = try launcher(
        AppHostLaunch(
          paths: paths, settings: loaded.settings, environment: environment, homeDirectory: homeDirectory,
          lock: locks.primary, helper: helper, network: network))
    } catch {
      retainedLocks.withLock { $0 = locks }
      network.attachLog(fallbackLog)
      recoverInBackground(log: fallbackLog)
      return .blocked(Self.failure(for: error))
    }
    let engine = instance.engine
    let stampRemoval = terminating.withLock { terminating -> [Decision]? in
      guard !terminating else { return nil }
      hosted.withLock { $0 = Hosted(instance: instance, locks: locks) }
      var decisions: [Decision] = []
      RelaunchSuppression.consume(at: paths.relaunchSuppression) { decisions.append($0) }
      return decisions
    }
    guard let stampRemoval else {
      await discard(instance, keeping: locks)
      locks.release()
      return .blocked(.sentinelUnavailable)
    }
    for decision in stampRemoval {
      engine.logImmediately(decision)
    }
    network.attachLog { engine.logImmediately($0) }
    await logStart(engine)
    for adjustment in loaded.adjustments {
      await engine.logLine(adjustment.decision)
    }
    if let problem = loaded.problem {
      await engine.logLine(
        Decision(keyword: .error, verb: "settings invalid", fields: [DecisionField(key: "reason", value: problem)]))
    }
    Task.detached {
      await engine.run()
    }
    if let wifi {
      let hotspot = loaded.settings.hotspot
      Task.detached {
        let decisions = await StartupChecks.run(
          wifi: wifi, screenLock: { ScreenLockReader.read(tools: ToolRunner()) }, configuredHotspot: hotspot)
        for decision in decisions {
          await engine.logLine(decision)
        }
      }
    }
    let published = publish(engine)
    recoverInBackground(log: { engine.logImmediately($0) })
    return .running(published)
  }

  private func recoverInBackground(log: @escaping @Sendable (Decision) -> Void) {
    let network = network
    let runner = recoveryRunner
    Task.detached {
      let outcome = await runner.perform(timeout: LiveNetworkPort.recoveryTimeoutSeconds) {
        network.recoverIfLeftOff()
      }
      if case .timedOut = outcome {
        log(LiveNetworkPort.recoveryFailure(result: LiveNetworkPort.timedOutResult))
      }
    }
  }

  private func recoverAtStop(engine: Engine?, began: ContinuousClock.Instant) async {
    let budget = Self.stopRecoveryBudget(
      elapsed: Self.seconds(ContinuousClock.now - began), outerBound: TerminationCoordinator.defaultOuterBoundSeconds)
    let deadline = ContinuousClock.now + .seconds(budget)
    if let engine {
      _ = await Engine.bounded(seconds: budget) { await engine.networkLaneDrained() }
    }
    let left = max(0, Self.seconds(deadline - ContinuousClock.now))
    let wait = max(0, left - Self.stopRecoveryReserveSeconds)
    let network = network
    let outcome = await recoveryRunner.perform(timeout: left) { network.recoverIfLeftOff(waitSeconds: wait) }
    if case .timedOut = outcome {
      let failure = LiveNetworkPort.recoveryFailure(result: LiveNetworkPort.timedOutResult)
      if let engine {
        engine.logImmediately(failure)
      } else {
        fallbackLog(failure)
      }
    }
  }

  public static func stopRecoveryBudget(elapsed: Double, outerBound: Double) -> Double {
    max(0, min(stopRecoverySeconds, outerBound - elapsed - stopRecoveryReserveSeconds))
  }

  static func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
  }

  private func makeCoordinator() -> TerminationCoordinator {
    TerminationCoordinator(
      beforeStop: { [weak self] in
        guard let self else { return }
        terminating.withLock { $0 = true }
        RelaunchSuppression.stamp(at: paths.relaunchSuppression) { decision in
          self.hosted.withLock({ $0 })?.instance.engine.logImmediately(decision)
        }
      },
      stop: { [weak self] in
        guard let self else { return }
        let began = ContinuousClock.now
        if let start = starting.withLock({ $0 }) {
          _ = await start.value
        }
        if let restart = restarting.withLock({ $0 }) {
          _ = await restart.value
        }
        let engine = hosted.withLock({ $0 })?.instance.engine
        await engine?.stop()
        await recoverAtStop(engine: engine, began: began)
      },
      shutdown: { [weak self] in
        guard let self else { return }
        let current = hosted.withLock { current -> Hosted? in
          defer { current = nil }
          return current
        }
        running.withLock { $0 = nil }
        current?.instance.shutdown()
        current?.locks.release()
        let retained = retainedLocks.withLock { retained -> HeldLocks? in
          defer { retained = nil }
          return retained
        }
        retained?.release()
      }
    )
  }

  public func restart(with settings: Settings) async -> AppHostStart {
    let task = restarting.withLock { current -> Task<AppHostStart, Never> in
      if let current { return current }
      let created = Task { await self.performRestart(with: settings) }
      current = created
      return created
    }
    let result = await task.value
    restarting.withLock { current in
      if current == task { current = nil }
    }
    return result
  }

  private func performRestart(with settings: Settings) async -> AppHostStart {
    guard !terminating.withLock({ $0 }), let current = hosted.withLock({ $0 }) else {
      return .blocked(.sentinelUnavailable)
    }
    let oldEngine = current.instance.engine
    let stopped = await Engine.bounded(seconds: restartStopBound) { await oldEngine.stop() }
    running.withLock { $0 = nil }
    guard stopped else {
      oldEngine.logImmediately(Decision(keyword: .error, verb: "restart stop timedOut"))
      return .blocked(.sentinelUnavailable)
    }
    current.instance.stopServer()
    if current.instance.lock !== current.locks.primary {
      current.instance.releaseLock()
    }
    guard !terminating.withLock({ $0 }) else {
      return .blocked(.sentinelUnavailable)
    }
    let (validated, adjustments) = settings.validated()
    let instance: RunningInstance
    do {
      instance = try launcher(
        AppHostLaunch(
          paths: paths, settings: validated, environment: environment, homeDirectory: homeDirectory,
          lock: current.locks.primary, helper: helper, network: network))
    } catch {
      abandon(current)
      return .blocked(Self.failure(for: error))
    }
    let installed = terminating.withLock { terminating -> Bool in
      guard !terminating else { return false }
      hosted.withLock { $0 = Hosted(instance: instance, locks: current.locks) }
      return true
    }
    guard installed else {
      await discard(instance, keeping: current.locks)
      return .blocked(.sentinelUnavailable)
    }
    let engine = instance.engine
    network.attachLog { engine.logImmediately($0) }
    await logStart(engine)
    for adjustment in adjustments {
      await engine.logLine(adjustment.decision)
    }
    Task.detached {
      await engine.run()
    }
    return .running(publish(engine))
  }

  private func discard(_ instance: RunningInstance, keeping locks: HeldLocks) async {
    let engine = instance.engine
    _ = await Engine.bounded(seconds: restartStopBound) { await engine.stop() }
    instance.stopServer()
    if instance.lock !== locks.primary {
      instance.releaseLock()
    }
  }

  private func abandon(_ current: Hosted) {
    hosted.withLock { $0 = nil }
    retainedLocks.withLock { $0 = current.locks }
  }

  private func logStart(_ engine: Engine) async {
    await engine.logLine(
      Decision(
        keyword: .start, verb: RunMode.live.rawValue,
        fields: [DecisionField(key: "app", value: "true"), DecisionField(key: "version", value: version)]))
  }

  private func publish(_ engine: Engine) -> LiveEngineHost {
    let host = LiveEngineHost(engine: engine, clock: SystemClock())
    running.withLock { $0 = host }
    return host
  }

  public static let emergencyLogger = Logger(subsystem: FileLogger.logSubsystem, category: "emergency")

  public static let emergencyLog: @Sendable (Decision) -> Void = { decision in
    let line = DecisionFormatter.line(decision, wall: Date(), timeZone: .current)
    emergencyLogger.error("\(line, privacy: .public)")
  }

  public static func makeEmergencyCoordinator(
    host: @escaping @Sendable () -> LiveEngineHost?,
    fallbackSockets: [URL] = [],
    log: Logger = AppHost.emergencyLogger,
    helperClear: (@Sendable () -> Bool)? = nil,
    opener: @escaping @Sendable () throws -> any ClamshellSelector = { try ClamshellWriter.open() },
    registry: AssertionRegistry = .shared,
    release: @escaping @Sendable (UInt32) -> Int32 = { RealAssertionSyscalls().release($0) }
  ) -> EmergencyCoordinator {
    let reset = EmergencyReset(
      opener: opener,
      registry: registry,
      release: release,
      log: { decision in
        if let host = host() {
          host.engine.logImmediately(decision)
        } else {
          let line = DecisionFormatter.line(decision, wall: Date(), timeZone: .current)
          log.error("\(line, privacy: .public)")
        }
      },
      helperClear: helperClear
    )
    return EmergencyCoordinator(
      reset: reset,
      releaseUntilIdle: {
        if let host = host() {
          return await host.send(.releaseUntilIdle).map(\.ok)
        }
        return await releaseOverSockets(fallbackSockets)
      }
    )
  }

  public static func emergencyHelperClear(
    installer: any HelperInstallerService,
    makeClient: @escaping @Sendable () -> HelperXPCClient
  ) -> @Sendable () -> Bool {
    {
      guard installer.status == .enabled else { return true }
      let client = makeClient()
      defer { client.invalidate() }
      guard case .success(let reply) = client.set(false) else { return false }
      return reply.code == .cleared
    }
  }

  static let socketFollowUpSeconds: Double = 4

  static func releaseOverSockets(_ sockets: [URL]) async -> Bool {
    let paths = sockets.map { $0.path(percentEncoded: false) }
    let outcome = await DeadlineRunner().perform(timeout: socketFollowUpSeconds) { () -> Bool in
      paths.contains { path in
        (try? ControlClient.send(.releaseUntilIdle, socketPath: path))?.ok == true
      }
    }
    guard case .value(let sent) = outcome else { return false }
    return sent
  }

  public static func failure(for error: any Error) -> HostFailure {
    switch error {
    case CompositionError.alreadyRunning, InstanceLockError.alreadyRunning:
      .lockHeldElsewhere
    default:
      .sentinelUnavailable
    }
  }

  public static func loadSettings(from url: URL) -> (
    settings: Settings, adjustments: [SettingsAdjustment], problem: String?
  ) {
    var fileSettings = Settings()
    var problem: String?
    switch SettingsStore.load(from: url) {
    case .missing:
      break
    case .loaded(let loaded):
      fileSettings = loaded
    case .invalid(let reason):
      problem = reason
    }
    if let validation = SettingsStore.validationProblem(fileSettings) {
      problem = validation
      fileSettings = Settings()
    }
    let (settings, adjustments) = fileSettings.validated()
    return (settings, adjustments, problem)
  }
}
