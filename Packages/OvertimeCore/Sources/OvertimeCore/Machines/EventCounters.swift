import Foundation

public struct EventCounters: Sendable, Equatable {
  public var holdErrorEpisodes: UInt64
  public var holdErrorsWhileBusy: UInt64
  public var batteryReleases: UInt64
  public var busyStartsBelowFloor: UInt64
  public var stuckReleases: UInt64
  public var unexpectedSleeps: UInt64
  public var forceSince: Instant?
  public var busyEndedAt: Instant?
  public var sleepRequested: Bool
  public var sleepRequest: EffectID?
  public var hotspotSwitches: UInt64
  public var wifiCycles: UInt64

  public init(
    holdErrorEpisodes: UInt64 = 0,
    holdErrorsWhileBusy: UInt64 = 0,
    batteryReleases: UInt64 = 0,
    busyStartsBelowFloor: UInt64 = 0,
    stuckReleases: UInt64 = 0,
    unexpectedSleeps: UInt64 = 0,
    forceSince: Instant? = nil,
    busyEndedAt: Instant? = nil,
    sleepRequested: Bool = false,
    sleepRequest: EffectID? = nil,
    hotspotSwitches: UInt64 = 0,
    wifiCycles: UInt64 = 0
  ) {
    self.holdErrorEpisodes = holdErrorEpisodes
    self.holdErrorsWhileBusy = holdErrorsWhileBusy
    self.batteryReleases = batteryReleases
    self.busyStartsBelowFloor = busyStartsBelowFloor
    self.stuckReleases = stuckReleases
    self.unexpectedSleeps = unexpectedSleeps
    self.forceSince = forceSince
    self.busyEndedAt = busyEndedAt
    self.sleepRequested = sleepRequested
    self.sleepRequest = sleepRequest
    self.hotspotSwitches = hotspotSwitches
    self.wifiCycles = wifiCycles
  }

  public static func observe(_ state: inout AppState, before: AppState, event: Event, effects: [Effect], now: Instant) {
    var counters = state.events
    if !before.hold.errorActive && state.hold.errorActive {
      bump(&counters.holdErrorEpisodes)
      if state.busy.busy == true {
        bump(&counters.holdErrorsWhileBusy)
      }
    }
    if before.want.wanted == true, state.want.wanted == false, state.want.reason == "battery" {
      bump(&counters.batteryReleases)
    }
    if before.busy.busy == true, state.busy.busy != true {
      counters.busyEndedAt = state.want.lastBusy ?? now
    }
    if before.busy.busy != true, state.busy.busy == true, state.battery.blocked {
      bump(&counters.busyStartsBelowFloor)
    }
    for effect in effects where isStuckRelease(effect) {
      bump(&counters.stuckReleases)
    }
    for effect in effects where isHotspotSwitch(effect) {
      bump(&counters.hotspotSwitches)
    }
    if case .netCycleDone(let outcome) = event, outcome.ran, !NetworkFailover.completesReturnCycle(before) {
      bump(&counters.wifiCycles)
    }
    switch event {
    case .systemHasPoweredOn:
      counters.sleepRequested = false
      counters.sleepRequest = nil
    case .systemWillSleep:
      if before.want.wanted == true && !counters.sleepRequested {
        bump(&counters.unexpectedSleeps)
      }
    case .effectResult(let id, let outcome) where id == counters.sleepRequest:
      counters.sleepRequest = nil
      if outcome != .succeeded {
        counters.sleepRequested = false
      }
    default:
      break
    }
    if let id = sleepRequest(in: effects) {
      counters.sleepRequested = true
      counters.sleepRequest = id
    }
    counters.forceSince = forceSince(counters.forceSince, before: before, after: state, event: event, now: now)
    state.events = counters
  }

  static func forceSince(_ current: Instant?, before: AppState, after: AppState, event: Event, now: Instant)
    -> Instant?
  {
    guard after.want.force != nil else { return nil }
    if case .command(.force) = event { return now }
    if before.want.force == nil || current == nil { return now }
    return current
  }

  static func bump(_ value: inout UInt64) {
    if value < UInt64.max {
      value += 1
    }
  }

  static func isStuckRelease(_ effect: Effect) -> Bool {
    guard case .log(let decision) = effect else { return false }
    return decision.keyword == .stuck && decision.verb == "ignored"
  }

  static func isHotspotSwitch(_ effect: Effect) -> Bool {
    guard case .log(let decision) = effect else { return false }
    return decision.keyword == .net && decision.verb == "connected"
  }

  static func sleepRequest(in effects: [Effect]) -> EffectID? {
    for effect in effects.reversed() {
      if case .requestSleep(let id) = effect { return id }
    }
    return nil
  }
}
