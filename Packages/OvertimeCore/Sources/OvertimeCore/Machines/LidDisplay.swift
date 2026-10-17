import Foundation

public struct LidState: Sendable, Equatable {
  public var closed: Bool?
  public var since: Instant?
  public var externalDisplays: Int
  public var nextDisplayCheck: Instant?
  public var nextResleep: Instant?

  public init(
    closed: Bool? = nil, since: Instant? = nil, externalDisplays: Int = 0, nextDisplayCheck: Instant? = nil,
    nextResleep: Instant? = nil
  ) {
    self.closed = closed
    self.since = since
    self.externalDisplays = externalDisplays
    self.nextDisplayCheck = nextDisplayCheck
    self.nextResleep = nextResleep
  }
}

public enum LidDisplay {
  public static func gateOn(_ state: AppState, settings: Settings = Settings()) -> Bool {
    Hold.lidCloseDesired(state, settings: settings) || state.persisted.ownsHold || state.persisted.switchedToHotspot
      || state.persisted.hotspotJoinStarted
  }

  public static func step(
    _ state: inout AppState, event: Event, now: Instant, settings: Settings = Settings()
  ) -> [Effect] {
    guard gateOn(state, settings: settings) else {
      state.lid = LidState()
      return []
    }
    let effects = transition(&state, event: event, now: now)
    guard case .tick(let facts) = event, state.lid.closed == true else { return effects }
    return effects + closedTick(&state, facts: facts, now: now)
  }

  public static func deadlines(_ state: AppState, settings: Settings = Settings()) -> [Instant] {
    guard gateOn(state, settings: settings), state.lid.closed == true else { return [] }
    var deadlines = state.lid.nextDisplayCheck.map { [$0] } ?? []
    if state.lid.externalDisplays == 0, let resleep = state.lid.nextResleep {
      deadlines.append(resleep)
    }
    return deadlines
  }

  static func closedTick(_ state: inout AppState, facts: TickFacts, now: Instant) -> [Effect] {
    if let check = state.lid.nextDisplayCheck, now >= check {
      if let count = facts.externalDisplays {
        state.lid.externalDisplays = max(0, count)
      }
      state.lid.nextDisplayCheck = now.adding(seconds: Timing.displayRecheckSeconds)
    }
    guard state.lid.externalDisplays == 0, let resleep = state.lid.nextResleep, now >= resleep else { return [] }
    state.lid.nextResleep = now.adding(seconds: Timing.resleepEverySeconds)
    guard (facts.hidIdleSeconds ?? 0) >= Timing.hidIdleResleepSeconds else { return [] }
    return [.displaySleepNow(id: Hold.allocate(&state))]
  }

  static func transition(_ state: inout AppState, event: Event, now: Instant) -> [Effect] {
    guard let observed = observation(event), observed != state.lid.closed else { return [] }
    let previous = state.lid.closed
    state.lid.closed = observed
    state.lid.since = now
    guard observed else {
      state.lid.nextDisplayCheck = nil
      state.lid.nextResleep = nil
      return previous == true ? [.log(Decision(keyword: .lid, verb: "opened"))] : []
    }
    let count = closeDisplayCount(event, state: state)
    state.lid.externalDisplays = count
    state.lid.nextDisplayCheck = now.adding(seconds: Timing.displayRecheckSeconds)
    if previous == nil, case .tick = event {
      state.lid.nextResleep = now
      return []
    }
    state.lid.nextResleep = now.adding(seconds: Timing.resleepEverySeconds)
    var effects: [Effect] = []
    if count == 0 {
      effects.append(.displaySleepNow(id: Hold.allocate(&state)))
    }
    effects.append(
      .log(Decision(keyword: .lid, verb: "closed", fields: [DecisionField(key: "ext", value: String(count))])))
    return effects
  }

  public static func isClosedStable(_ lid: LidState, now: Instant) -> Bool {
    guard lid.closed == true, let since = lid.since else { return false }
    return now.nanoseconds(since: since) >= Instant.nanoseconds(forSeconds: Timing.lidStableSeconds)
  }

  static func observation(_ event: Event) -> Bool? {
    switch event {
    case .lidChanged(let closed, _, _): closed
    case .tick(let facts): facts.lidClosed
    default: nil
    }
  }

  static func closeDisplayCount(_ event: Event, state: AppState) -> Int {
    let reported: Int?
    switch event {
    case .lidChanged(_, _, let externalDisplays): reported = externalDisplays
    case .tick(let facts): reported = facts.externalDisplays
    default: reported = nil
    }
    return max(0, reported ?? state.lastExternalDisplays ?? 0)
  }
}
