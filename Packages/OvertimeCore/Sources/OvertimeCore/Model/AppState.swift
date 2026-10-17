import Foundation

public enum RunMode: String, Sendable, Codable, Equatable {
  case shadow
  case live
}

public struct AppState: Sendable, Equatable {
  public var mode: RunMode
  public var busy: BusyState
  public var want: WantState
  public var battery: BatteryState
  public var health: HealthState
  public var startedAt: Instant?
  public var lastEventAt: Instant?
  public var lastEventWall: Date?
  public var persisted: PersistedState
  public var bootSessionUUID: String?
  public var hold: HoldState
  public var nextEffectID: UInt64
  public var lastLidClosed: Bool?
  public var lastExternalDisplays: Int?
  public var lastFullWake: Bool?
  public var lid: LidState
  public var verification: VerificationState
  public var coexistence: CoexistenceState
  public var screenLockWarned: Bool
  public var network: NetworkState
  public var events: EventCounters
  public var selfTest: SelfTestState
  public var helper: HelperIntentState
  public var temperature: TemperatureState
  public var lastPower: PowerReading?

  public init(mode: RunMode) {
    self.lastPower = nil
    self.helper = HelperIntentState()
    self.temperature = TemperatureState()
    self.selfTest = SelfTestState()
    self.lid = LidState()
    self.verification = .idle
    self.coexistence = CoexistenceState()
    self.screenLockWarned = false
    self.network = NetworkState()
    self.events = EventCounters()
    self.lastFullWake = nil
    self.hold = HoldState()
    self.nextEffectID = 1
    self.lastLidClosed = nil
    self.lastExternalDisplays = nil
    self.mode = mode
    self.busy = BusyState()
    self.want = WantState()
    self.battery = BatteryState()
    self.health = HealthState()
    self.startedAt = nil
    self.lastEventAt = nil
    self.lastEventWall = nil
    self.persisted = PersistedState()
    self.bootSessionUUID = nil
  }
}
