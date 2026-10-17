import Foundation

public enum HelperPhase: Sendable, Equatable {
  case idle
  case engaging(EffectID)
  case engaged
  case releasing(EffectID)
  case failed(retryAt: Instant)
}

public enum HelperReleaseReason: String, Sendable, Equatable, CaseIterable {
  case lidOpen
  case battery
  case notWanted
  case sleepNow
  case stop
  case notReady
  case temperature
  case lidClosedHoldOff
}

public struct HelperIntentState: Sendable, Equatable {
  public var facts: HelperFacts?
  public var phase: HelperPhase
  public var lastContact: Instant?
  public var suppressedUntilWake: Bool
  public var heartbeat: EffectID?
  public var sleepRequest: EffectID?
  public var atOrBelowHelperFloor: Bool
  public var atOrAboveHelperCeiling: Bool
  public var sentLimits: HelperLimits?

  public init(
    facts: HelperFacts? = nil, phase: HelperPhase = .idle, lastContact: Instant? = nil,
    suppressedUntilWake: Bool = false, heartbeat: EffectID? = nil, sleepRequest: EffectID? = nil,
    atOrBelowHelperFloor: Bool = false, atOrAboveHelperCeiling: Bool = false, sentLimits: HelperLimits? = nil
  ) {
    self.facts = facts
    self.phase = phase
    self.lastContact = lastContact
    self.suppressedUntilWake = suppressedUntilWake
    self.heartbeat = heartbeat
    self.sleepRequest = sleepRequest
    self.atOrBelowHelperFloor = atOrBelowHelperFloor
    self.atOrAboveHelperCeiling = atOrAboveHelperCeiling
    self.sentLimits = sentLimits
  }
}

public enum HelperIntent {
  public static let heartbeatSeconds: Double = 20
  public static let retrySeconds: Double = 30
  public static let helperTemperatureCeilingCelsius = 60

  public static func desired(_ state: AppState, settings: Settings = Settings()) -> Bool {
    state.want.wanted == true && lidClosed(state) && !state.battery.blocked && state.helper.facts?.ready == true
      && !state.hold.stopping && !state.helper.suppressedUntilWake && !state.helper.atOrBelowHelperFloor
      && !state.temperature.blocked && !state.helper.atOrAboveHelperCeiling
      && Hold.lidClosedAllowed(state, settings: settings)
  }

  public static func step(
    _ state: inout AppState, event: Event, now: Instant, batch: [Effect], settings: Settings = Settings()
  ) -> (before: [Effect], after: [Effect]) {
    noteSleep(&state, event: event, batch: batch)
    notePower(&state, event: event, settings: settings)
    noteTemperature(&state, event: event, settings: settings)
    let wanted = desired(state, settings: settings)
    switch state.helper.phase {
    case .idle:
      guard wanted, state.lastFullWake == true else { return ([], []) }
      return ([], engage(&state, settings: settings))
    case .engaging:
      guard !wanted else { return ([], []) }
      return (release(&state, settings: settings), [])
    case .engaged:
      guard wanted else { return (release(&state, settings: settings), []) }
      if state.helper.sentLimits != HelperLimits(settings: settings) {
        return ([], engage(&state, settings: settings, reason: "limits"))
      }
      guard isTick(event), heartbeatDue(state.helper, now: now) else { return ([], []) }
      let id = Hold.allocate(&state)
      state.helper.heartbeat = id
      state.helper.lastContact = now
      return ([], [.helper(.heartbeat, id: id)])
    case .failed(let retryAt):
      guard wanted else { return (release(&state, settings: settings), []) }
      guard isTick(event), now >= retryAt, state.lastFullWake == true else { return ([], []) }
      return ([], engage(&state, settings: settings))
    case .releasing:
      return ([], [])
    }
  }

  public static func handleResult(
    _ id: EffectID, _ outcome: EffectOutcome, state: inout AppState, now: Instant
  ) -> [Effect]? {
    if state.helper.sleepRequest == id {
      state.helper.sleepRequest = nil
      if outcome != .succeeded {
        state.helper.suppressedUntilWake = false
      }
      return nil
    }
    if state.helper.heartbeat == id {
      state.helper.heartbeat = nil
      guard outcome == .succeeded else { return [fail(.heartbeat, outcome, state: &state, now: now)] }
      state.helper.lastContact = now
      return []
    }
    switch state.helper.phase {
    case .engaging(let current) where current == id:
      guard outcome == .succeeded else { return [fail(.engage, outcome, state: &state, now: now)] }
      state.helper.phase = .engaged
      state.helper.lastContact = now
      return []
    case .releasing(let current) where current == id:
      state.helper.phase = .idle
      guard outcome == .succeeded else { return [failure(.release, outcome, retry: false)] }
      return []
    default:
      return nil
    }
  }

  public static func deadlines(_ state: AppState) -> [Instant] {
    switch state.helper.phase {
    case .failed(let retryAt):
      return [retryAt]
    case .engaged:
      return state.helper.lastContact.map { [$0.adding(seconds: heartbeatSeconds)] } ?? []
    case .idle, .engaging, .releasing:
      return []
    }
  }

  static func lidClosed(_ state: AppState) -> Bool {
    (state.lid.closed ?? state.lastLidClosed) == true
  }

  static func isTick(_ event: Event) -> Bool {
    if case .tick = event { return true }
    return false
  }

  static func heartbeatDue(_ helper: HelperIntentState, now: Instant) -> Bool {
    guard let lastContact = helper.lastContact else { return true }
    return now.nanoseconds(since: lastContact) >= Instant.nanoseconds(forSeconds: heartbeatSeconds)
  }

  static func noteSleep(_ state: inout AppState, event: Event, batch: [Effect]) {
    switch event {
    case .command(.sleepNow):
      state.helper.suppressedUntilWake = true
      state.helper.sleepRequest = sleepRequest(in: batch)
    case .systemHasPoweredOn:
      state.helper.suppressedUntilWake = false
      state.helper.sleepRequest = nil
    default:
      break
    }
  }

  static func notePower(_ state: inout AppState, event: Event, settings: Settings) {
    guard case .power(let reading) = event else { return }
    state.helper.atOrBelowHelperFloor = atOrBelowHelperFloor(reading, floor: settings.helperBatteryFloorPercent)
  }

  static func atOrBelowHelperFloor(_ reading: PowerReading, floor: Int) -> Bool {
    switch reading {
    case .ac(let percent?), .battery(let percent?):
      percent <= floor
    case .ac(nil), .battery(nil), .noBattery:
      false
    }
  }

  static func noteTemperature(_ state: inout AppState, event: Event, settings: Settings) {
    guard case .batteryTemperature(let reading) = event else { return }
    let ceiling = HelperLimits(settings: settings).temperatureCeilingCelsius ?? helperTemperatureCeilingCelsius
    switch reading {
    case .celsius(let celsius):
      if celsius >= ceiling {
        state.helper.atOrAboveHelperCeiling = true
      } else if celsius < ceiling - Settings.temperatureResumeHysteresisCelsius {
        state.helper.atOrAboveHelperCeiling = false
      }
    case .unavailable:
      state.helper.atOrAboveHelperCeiling = false
    case .unreadable:
      break
    }
  }

  static func sleepRequest(in batch: [Effect]) -> EffectID? {
    for effect in batch.reversed() {
      if case .requestSleep(let id) = effect { return id }
    }
    return nil
  }

  static func releaseReason(_ state: AppState, settings: Settings) -> HelperReleaseReason {
    if state.hold.stopping { return .stop }
    if state.helper.suppressedUntilWake { return .sleepNow }
    if state.helper.facts?.ready != true { return .notReady }
    if state.battery.blocked || state.helper.atOrBelowHelperFloor { return .battery }
    if state.temperature.blocked || state.helper.atOrAboveHelperCeiling { return .temperature }
    if !Hold.lidClosedAllowed(state, settings: settings) { return .lidClosedHoldOff }
    if !lidClosed(state) { return .lidOpen }
    return .notWanted
  }

  static func engage(_ state: inout AppState, settings: Settings, reason: String? = nil) -> [Effect] {
    let id = Hold.allocate(&state)
    let limits = HelperLimits(settings: settings)
    state.helper.phase = .engaging(id)
    state.helper.sentLimits = limits
    let fields = reason.map { [DecisionField(key: "reason", value: $0)] } ?? []
    return [
      .log(Decision(keyword: .hold, verb: "helper engage", fields: fields)), .helper(.engage, id: id, limits: limits),
    ]
  }

  static func release(_ state: inout AppState, settings: Settings) -> [Effect] {
    let reason = DecisionField(key: "reason", value: releaseReason(state, settings: settings).rawValue)
    let id = Hold.allocate(&state)
    state.helper.phase = .releasing(id)
    state.helper.heartbeat = nil
    state.helper.lastContact = nil
    return [.helper(.release, id: id), .log(Decision(keyword: .hold, verb: "helper release", fields: [reason]))]
  }

  static func fail(_ action: HelperAction, _ outcome: EffectOutcome, state: inout AppState, now: Instant) -> Effect {
    state.helper.phase = .failed(retryAt: now.adding(seconds: retrySeconds))
    state.helper.lastContact = nil
    return failure(action, outcome, retry: true)
  }

  static func failure(_ action: HelperAction, _ outcome: EffectOutcome, retry: Bool) -> Effect {
    var fields: [DecisionField] = []
    switch outcome {
    case .failed(let code):
      fields.append(DecisionField(key: "code", value: String(code)))
    case .timedOut:
      fields.append(DecisionField(key: "reason", value: "timedOut"))
    case .succeeded:
      break
    }
    if retry {
      fields.append(DecisionField(key: "retryIn", value: String(Int(retrySeconds))))
    }
    return .log(Decision(keyword: .error, verb: "helper " + action.rawValue + " failed", fields: fields))
  }
}
