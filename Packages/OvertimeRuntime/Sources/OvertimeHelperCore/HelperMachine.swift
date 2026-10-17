import Foundation

public final class HelperMachine {
  public static let heartbeatTimeoutSeconds: Double = 55
  public static let watchPeriodSeconds: Double = 5
  public static let thermalTrappingLevel = 3
  public static let verifyPollMilliseconds = 50
  public static let verifyWindowSeconds: Double = 2
  public static let retrySeconds: Double = 5

  private enum Stage {
    case clear
    case edge
    case record
  }

  private enum Released {
    case done
    case notOwned
    case failed(String)
  }

  private let system: any HelperSystemPort
  private let recordPort: any HelperRecordPort
  private let log: any HelperLogPort
  private let clock: any HelperClock
  private let version: Int

  private var record: HelperRecord?
  private var limits = HelperSafetyLimits.compiled
  private var engaged = false
  private var holder: HelperConnectionID?
  private var stage = Stage.clear
  private var edge = "skipped"
  private var retry: (reason: String, at: Double)?
  private var lastContact: Double = 0
  private var lastReleaseReason: String?
  private var exitWhenReleased = false
  private var terminating = false

  public private(set) var shouldExit = false
  public private(set) var connections = 0

  public init(
    system: any HelperSystemPort, record: any HelperRecordPort, log: any HelperLogPort, clock: any HelperClock,
    version: Int = HelperIdentity.version
  ) {
    self.system = system
    self.recordPort = record
    self.log = log
    self.clock = clock
    self.version = version
  }

  public var needsWatch: Bool { engaged || owns }

  private var owns: Bool { record?.owns == true }

  public func launched() {
    engaged = false
    holder = nil
    stage = .clear
    retry = nil
    switch recordPort.read() {
    case .missing:
      record = nil
      log.record("reconcile none")
    case .loaded(let loaded):
      record = loaded
      log.record(loaded.owns ? "reconcile owned" : "reconcile none")
    case .unreadable:
      record = HelperRecord(owns: true, prior: false, at: clock.now())
      log.record("reconcile ambiguous")
    }
    if owns {
      release("reconcile")
    } else if !store(HelperRecord(owns: false, prior: false, at: clock.now())) {
      log.record("ERROR reconcile record write failed")
    }
  }

  public func set(from caller: HelperConnectionID, limits requested: HelperSafetyLimits = .compiled) -> HelperReply {
    let asked = clock.now()
    guard !shouldExit, !terminating else { return refused("exiting") }
    if let reason = unsafeReason(requested) { return refuse(reason) }
    guard let current = system.readSleepDisabled() else { return refuse("unreadable") }
    if current && !(owns && stage == .clear) {
      guard store(HelperRecord(owns: false, prior: true, at: clock.now())) else { return refuse("recordWrite") }
      engage(caller, at: asked, limits: requested)
      log.record("set alreadyOn prior=1 " + Self.describe(requested))
      return HelperReply(code: .alreadyOn, message: "alreadyOn")
    }
    guard store(HelperRecord(owns: true, prior: false, at: clock.now())) else { return refuse("recordWrite") }
    stage = .clear
    if !current {
      guard system.writeSleepDisabled(true) else { return refuse("pmset", releaseAs: "setFailed") }
      guard confirm(true) else { return refuse("verify", releaseAs: "setFailed") }
    }
    engage(caller, at: asked, limits: requested)
    log.record("set owned prior=0 " + Self.describe(requested))
    return HelperReply(code: .owned, message: "owned")
  }

  public func clear() -> HelperReply {
    switch release("clear") {
    case .done, .notOwned:
      return HelperReply(code: .cleared, message: "cleared")
    case .failed(let step):
      return HelperReply(code: .refused, message: step)
    }
  }

  public func status(
    appVersion: Int, from caller: HelperConnectionID?
  ) -> (status: HelperStatus, exitAfterReply: Bool) {
    if engaged, let caller, caller == holder {
      lastContact = clock.now()
    }
    if appVersion != version {
      noteStale()
    }
    let sleepDisabled = system.readSleepDisabled()
    let power = system.power()
    let thermal = system.thermal()
    let batteryTemperature = system.batteryTemperature()
    let status = HelperStatus(
      helperVersion: version, sleepDisabled: sleepDisabled, owns: owns, prior: record?.prior, engaged: engaged,
      batteryPercent: power?.percent, onBattery: power?.onBattery, warningLevel: power?.warningLevel,
      thermalLevel: thermal?.pressureLevel, thermalCritical: thermal?.critical,
      lastReleaseReason: lastReleaseReason, exiting: shouldExit, batteryFloorPercent: limits.batteryFloorPercent,
      temperatureCeilingCelsius: limits.temperatureCeilingCelsius, batteryTemperature: batteryTemperature)
    return (status, shouldExit)
  }

  public func connectionOpened() {
    connections += 1
  }

  public func connectionEnded(_ caller: HelperConnectionID, remaining: Int) {
    connections = max(0, remaining)
    guard engaged, caller == holder || connections == 0 else { return }
    release("connection")
  }

  public func signal(_ number: Int32) {
    let name = Self.signalName(number)
    terminating = true
    exitWhenReleased = true
    log.record("received \(name)")
    if engaged || owns {
      release(name)
    } else {
      shouldExit = true
    }
  }

  public func power(_ facts: HelperPowerFacts?) {
    guard engaged, let reason = Self.powerReason(facts, floor: limits.batteryFloorPercent) else { return }
    release(reason)
  }

  public func thermal(_ facts: HelperThermalFacts?) {
    guard engaged, let reason = Self.thermalReason(facts) else { return }
    release(reason)
  }

  public func watch() {
    let now = clock.now()
    guard engaged else {
      if owns, now >= (retry?.at ?? now) {
        release(retry?.reason ?? "retry")
      }
      return
    }
    if now - lastContact >= Self.heartbeatTimeoutSeconds {
      release("heartbeat")
    } else if let reason = unsafeReason(limits) {
      release(reason)
    }
  }

  private static func signalName(_ number: Int32) -> String {
    switch number {
    case SIGTERM: return "sigterm"
    case SIGINT: return "sigint"
    case SIGHUP: return "sighup"
    default: return "signal"
    }
  }

  private static func powerReason(_ facts: HelperPowerFacts?, floor: Int) -> String? {
    guard let facts else { return "powerUnreadable" }
    if facts.warningLevel != HelperPowerFacts.warningNone { return "lowBatteryWarning" }
    if facts.percent <= floor { return "battery" }
    return nil
  }

  private static func describe(_ limits: HelperSafetyLimits) -> String {
    "floor=\(limits.batteryFloorPercent) ceiling=\(limits.temperatureCeilingCelsius)"
  }

  private static func thermalReason(_ facts: HelperThermalFacts?) -> String? {
    guard let facts else { return "thermalUnreadable" }
    if facts.pressureLevel >= thermalTrappingLevel || facts.critical { return "thermal" }
    return nil
  }

  private func unsafeReason(_ limits: HelperSafetyLimits) -> String? {
    guard let closed = system.lidClosed() else { return "lidUnreadable" }
    guard closed else { return "lidOpen" }
    if let reason = Self.powerReason(system.power(), floor: limits.batteryFloorPercent) { return reason }
    if let reason = Self.thermalReason(system.thermal()) { return reason }
    if let celsius = system.batteryTemperature(), celsius >= limits.temperatureCeilingCelsius { return "temperature" }
    return nil
  }

  private func noteStale() {
    guard !shouldExit else { return }
    if engaged || owns {
      guard !exitWhenReleased else { return }
      exitWhenReleased = true
      log.record("status stale exit=deferred")
    } else {
      shouldExit = true
      log.record("status stale exit=now")
    }
  }

  private func engage(_ caller: HelperConnectionID, at asked: Double, limits requested: HelperSafetyLimits) {
    limits = requested
    engaged = true
    holder = caller
    lastContact = asked
    stage = .clear
    retry = nil
  }

  private func refuse(_ reason: String, releaseAs: String? = nil) -> HelperReply {
    if engaged || owns {
      release(releaseAs ?? reason)
    }
    return refused(reason)
  }

  private func refused(_ reason: String) -> HelperReply {
    log.record("set refused reason=\(reason)")
    return HelperReply(code: .refused, message: reason)
  }

  @discardableResult
  private func release(_ reason: String) -> Released {
    engaged = false
    holder = nil
    limits = .compiled
    lastReleaseReason = reason
    guard owns else {
      retry = nil
      log.record("release skipped reason=notOwned")
      finishExit()
      return .notOwned
    }
    if let step = advance() {
      retry = (reason, clock.now() + Self.retrySeconds)
      log.record("ERROR release failed step=\(step) retryIn=\(Int(Self.retrySeconds))")
      return .failed(step)
    }
    retry = nil
    log.record("release reason=\(reason) sleepDisabled=0 edge=\(edge)")
    finishExit()
    return .done
  }

  private func advance() -> String? {
    if stage == .clear {
      guard system.writeSleepDisabled(false) else { return "pmset" }
      guard confirm(false) else { return "verify" }
      stage = .edge
    }
    if stage == .edge {
      if system.lidClosed() == false {
        edge = "skipped"
      } else {
        guard system.clamshellEdge() else { return "edge" }
        edge = "done"
      }
      stage = .record
    }
    guard store(HelperRecord(owns: false, prior: false, at: clock.now())) else { return "record" }
    stage = .clear
    return nil
  }

  private func finishExit() {
    if exitWhenReleased {
      shouldExit = true
    }
  }

  private func confirm(_ expected: Bool) -> Bool {
    let deadline = clock.now() + Self.verifyWindowSeconds
    let polls = Int(Self.verifyWindowSeconds * 1_000) / Self.verifyPollMilliseconds
    for _ in 0..<polls {
      if system.readSleepDisabled() == expected { return true }
      guard clock.now() < deadline else { return false }
      system.pause(milliseconds: Self.verifyPollMilliseconds)
    }
    return system.readSleepDisabled() == expected
  }

  private func store(_ next: HelperRecord) -> Bool {
    guard recordPort.write(next) else { return false }
    record = next
    return true
  }
}
