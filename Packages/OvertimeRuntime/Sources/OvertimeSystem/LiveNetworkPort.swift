import Foundation
import OvertimeCore
import os

public final class LocationGrant: Sendable {
  private let state: OSAllocatedUnfairLock<Bool>

  public init(authorized: Bool = false) {
    state = OSAllocatedUnfairLock(initialState: authorized)
  }

  public func set(_ authorized: Bool) {
    state.withLock { $0 = authorized }
  }

  public var isAuthorized: Bool {
    state.withLock { $0 }
  }
}

public final class LiveNetworkPort: NetworkPort, Sendable {
  public static let recoveryTimeoutSeconds: Double = 15
  public static let recoveryRunnerKey = "wifi.recover"
  public static let recoveryAction = "wifiOn"
  public static let timedOutResult = "timedOut"
  public static let recoveryRetrySeconds: Double = 30
  public static let monitorAction = "monitor"
  public static let monitorRunnerKey = "net.monitor"
  public static let startFailedResult = "failed"

  private struct Recovery: Sendable {
    var checkedAt: Instant?
    var checkedFacts: NetworkFacts?
    var failing = false
    var retry = false
  }

  private struct Monitoring: Sendable {
    var started = false
    var starting = false
    var failed = false
    var unlogged: Decision?
  }

  private struct State: Sendable {
    var log: (@Sendable (Decision) -> Void)?
    var lastLidClosed: Bool?
    var recovery = Recovery()
    var monitoring = Monitoring()
  }

  private let monitor: NetworkMonitor
  private let connectivity: ConnectivityProbe
  private let wifi: WiFiController
  private let recovery: DeadlineRunner
  private let clock: any ClockPort
  private let recoveryWait: Double
  private let startTimeout: Double
  private let state = OSAllocatedUnfairLock(initialState: State())

  public init(
    monitor: NetworkMonitor, probe: ConnectivityProbe, wifi: WiFiController,
    recovery: DeadlineRunner = DeadlineRunner(), clock: any ClockPort = SystemClock(),
    recoveryWaitSeconds: Double = WiFiController.actuationWaitSeconds,
    startTimeoutSeconds: Double = Timing.systemCallTimeoutSeconds
  ) {
    self.monitor = monitor
    connectivity = probe
    self.wifi = wifi
    self.recovery = recovery
    self.clock = clock
    recoveryWait = recoveryWaitSeconds
    startTimeout = startTimeoutSeconds
  }

  public static func system(paths: Paths, location: LocationGrant) -> LiveNetworkPort {
    compose(
      paths: paths, location: location, source: SystemNetworkStore(), knownNetworks: KnownNetworks.names,
      probe: ConnectivityProbe(), radio: CoreWLANRadio())
  }

  public static func compose(
    paths: Paths,
    location: LocationGrant,
    source: any NetworkStoreSource,
    knownNetworks: @escaping @Sendable () -> [String]?,
    probe: ConnectivityProbe,
    radio: any WiFiRadio,
    clock: any ClockPort = SystemClock(),
    makeTools: @escaping @Sendable (Double) -> any ToolPort = { ToolRunner(timeoutSeconds: $0) },
    sleep: @escaping @Sendable (Double) -> Void = { Thread.sleep(forTimeInterval: $0) },
    recovery: DeadlineRunner = DeadlineRunner(),
    recoveryWaitSeconds: Double = WiFiController.actuationWaitSeconds,
    startTimeoutSeconds: Double = Timing.systemCallTimeoutSeconds
  ) -> LiveNetworkPort {
    let monitor = NetworkMonitor(
      source: source, knownNetworks: knownNetworks, onFactsChange: { probe.invalidate() })
    let wifi = WiFiController(
      radio: radio, knownNetworks: knownNetworks, locationAuthorized: { location.isAuthorized }, clock: clock,
      makeTools: makeTools, marker: WiFiCycleMarker(url: paths.wifiCycleMarker), sleep: sleep)
    return LiveNetworkPort(
      monitor: monitor, probe: probe, wifi: wifi, recovery: recovery, clock: clock,
      recoveryWaitSeconds: recoveryWaitSeconds, startTimeoutSeconds: startTimeoutSeconds)
  }

  public static func recoveryFailure(result: String) -> Decision {
    Decision(
      keyword: .error, verb: "net failed",
      fields: [DecisionField(key: "action", value: recoveryAction), DecisionField(key: "result", value: result)])
  }

  public static func monitorFailure(result: String) -> Decision {
    Decision(
      keyword: .error, verb: "net failed",
      fields: [DecisionField(key: "action", value: monitorAction), DecisionField(key: "result", value: result)])
  }

  @discardableResult
  public func start() -> Task<Bool, Never> {
    let (begin, started) = state.withLock { state -> (Bool, Bool) in
      guard !state.monitoring.started, !state.monitoring.starting else { return (false, state.monitoring.started) }
      state.monitoring.starting = true
      return (true, false)
    }
    guard begin else { return Task { started } }
    let runner = recovery
    let monitor = monitor
    let timeout = startTimeout
    return Task.detached { [self] in
      let outcome = await runner.performIfAdmitted(timeout: timeout, key: Self.monitorRunnerKey) { monitor.start() }
      return settleStart(outcome)
    }
  }

  private func settleStart(_ outcome: DeadlineRunner.Admission<Bool>) -> Bool {
    let result: String?
    switch outcome {
    case .value(true):
      result = nil
    case .value(false):
      result = Self.startFailedResult
    case .timedOut, .notAdmitted:
      result = Self.timedOutResult
    }
    let line = state.withLock { state -> Decision? in
      state.monitoring.starting = false
      guard let result else {
        state.monitoring.started = true
        state.monitoring.failed = false
        return nil
      }
      defer { state.monitoring.failed = true }
      guard !state.monitoring.failed else { return nil }
      let decision = Self.monitorFailure(result: result)
      guard state.log != nil else {
        state.monitoring.unlogged = decision
        return nil
      }
      return decision
    }
    if let line {
      log(line)
    }
    return result == nil
  }

  private func retryStartIfFailed() {
    let retry = state.withLock { state in
      state.monitoring.failed && !state.monitoring.starting && !state.monitoring.started
    }
    if retry {
      _ = start()
    }
  }

  public func attachLog(_ log: @escaping @Sendable (Decision) -> Void) {
    let unlogged = state.withLock { state -> Decision? in
      state.log = log
      defer { state.monitoring.unlogged = nil }
      return state.monitoring.unlogged
    }
    wifi.attachLog(log)
    if let unlogged {
      log(unlogged)
    }
  }

  public func facts(lidClosed: Bool?) -> NetworkFacts? {
    let (opened, closed, monitoring) = state.withLock { state -> (Bool, Bool, Bool) in
      let previous = state.lastLidClosed
      if let lidClosed {
        state.lastLidClosed = lidClosed
      }
      return (previous == true && lidClosed == false, lidClosed == true && previous != true, state.monitoring.started)
    }
    if closed {
      retryStartIfFailed()
    }
    let read = monitor.facts(lidClosed: lidClosed)
    let facts = monitoring ? read : nil
    if opened || recoveryDue(facts) {
      recoverInBackground()
    }
    return facts
  }

  private func recoveryDue(_ facts: NetworkFacts?) -> Bool {
    let now = clock.mono()
    let powered = facts?.wifiPowered == true
    let kept = powered && wifi.markerKept
    let check = state.withLock { state -> Bool in
      if state.recovery.retry {
        state.recovery.retry = false
        return true
      }
      guard !powered || kept else {
        state.recovery.checkedAt = nil
        state.recovery.checkedFacts = nil
        return false
      }
      if let checkedAt = state.recovery.checkedAt, state.recovery.checkedFacts == facts,
        now < checkedAt.adding(seconds: Self.recoveryRetrySeconds)
      {
        return false
      }
      state.recovery.checkedAt = now
      state.recovery.checkedFacts = facts
      return true
    }
    return check && (kept || wifi.markerPresent)
  }

  private func recoverInBackground() {
    let runner = recovery
    let wifi = wifi
    let wait = recoveryWait
    Task.detached { [self] in
      let admission = await runner.performIfAdmitted(
        timeout: Self.recoveryTimeoutSeconds, key: Self.recoveryRunnerKey
      ) {
        wifi.recoverIfLeftOff(waitSeconds: wait)
      }
      settleRecovery(admission)
    }
  }

  private func settleRecovery(_ admission: DeadlineRunner.Admission<EffectOutcome>) {
    let result: String
    switch admission {
    case .notAdmitted, .value(WiFiController.Code.busy.outcome):
      state.withLock { $0.recovery.retry = true }
      return
    case .value(.succeeded):
      state.withLock { $0.recovery.failing = false }
      return
    case .value(.failed(let code)):
      result = String(code)
    case .value(.timedOut), .timedOut:
      result = Self.timedOutResult
    }
    let first = state.withLock { state -> Bool in
      defer { state.recovery.failing = true }
      return !state.recovery.failing
    }
    if first {
      log(Self.recoveryFailure(result: result))
    }
  }

  public func autoDetectInUse(_ inUse: Bool) {
    retryStartIfFailed()
    monitor.autoDetectInUse(inUse)
  }

  public func probe() -> Bool {
    connectivity.probe()
  }

  public func joinHotspot(_ name: String) -> EffectOutcome {
    wifi.joinHotspot(name)
  }

  public func cycleWifi() -> EffectOutcome {
    wifi.cycleWifi()
  }

  public func recoverIfLeftOff() -> EffectOutcome {
    recoverIfLeftOff(waitSeconds: WiFiController.actuationWaitSeconds)
  }

  public func recoverIfLeftOff(waitSeconds: Double) -> EffectOutcome {
    let outcome = wifi.recoverIfLeftOff(waitSeconds: waitSeconds)
    switch outcome {
    case .succeeded:
      break
    case .failed(let code):
      log(Self.recoveryFailure(result: String(code)))
    case .timedOut:
      log(Self.recoveryFailure(result: Self.timedOutResult))
    }
    return outcome
  }

  private func log(_ decision: Decision) {
    state.withLock { $0.log }?(decision)
  }
}
