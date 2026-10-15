import Foundation

public struct WantState: Sendable, Equatable {
  public var lastBusy: Instant?
  public var wanted: Bool?
  public var override: Bool
  public var pause: PauseState?
  public var force: ForceState?
  public var reason: String?
  public var wantedSince: Instant?

  public init(lastBusy: Instant? = nil, wanted: Bool? = nil, override: Bool = false, pause: PauseState? = nil) {
    self.lastBusy = lastBusy
    self.wanted = wanted
    self.override = override
    self.pause = pause
    self.force = nil
    self.reason = nil
    self.wantedSince = nil
  }
}

public enum Want {
  public static func apply(_ command: UserCommand, to state: inout WantState, now: Instant, wall: Date) -> [Decision] {
    switch command {
    case .pause(let spec):
      let pause: PauseState
      switch spec {
      case .forSeconds(let seconds):
        pause = .untilMono(now.adding(seconds: seconds), wall: wall.addingTimeInterval(seconds))
      case .until(let date):
        pause = .untilWall(date)
      case .indefinite:
        pause = .indefinite
      }
      state.pause = pause
      state.force = nil
      return [Decision(keyword: .override, verb: "pause", fields: [DecisionField(key: "until", value: until(pause))])]
    case .force(let spec):
      let force: ForceState
      let until: String
      switch spec {
      case .forSeconds(let seconds):
        force = .untilMono(now.adding(seconds: seconds))
        until = iso8601(wall.addingTimeInterval(seconds))
      case .indefinite:
        force = .indefinite
        until = "indefinite"
      }
      state.force = force
      state.pause = nil
      return [Decision(keyword: .override, verb: "force", fields: [DecisionField(key: "until", value: until)])]
    case .releaseUntilIdle:
      let cancelled = state.force != nil ? [DecisionField(key: "cancelled", value: "force")] : []
      state.force = nil
      state.override = true
      return [Decision(keyword: .override, verb: "releaseUntilIdle", fields: cancelled)]
    case .resume:
      state.pause = nil
      state.force = nil
      state.override = false
      return [Decision(keyword: .override, verb: "resume")]
    case .sleepNow:
      return []
    }
  }

  public static func evaluate(
    _ state: inout WantState, busy: Bool, batteryBlocked: Bool = false, now: Instant, wall: Date, settings: Settings
  ) -> [Decision] {
    var decisions: [Decision] = []
    if let pause = state.pause, isExpired(pause, now: now, wall: wall) {
      state.pause = nil
      decisions.append(Decision(keyword: .override, verb: "pauseExpired"))
    }
    if case .untilMono(let deadline)? = state.force, now >= deadline {
      state.force = nil
      decisions.append(Decision(keyword: .override, verb: "forceExpired"))
    }
    if busy {
      state.lastBusy = now
    }
    let grace = withinGrace(state, now: now, settings: settings)
    if !grace && state.override {
      state.override = false
      decisions.append(
        Decision(
          keyword: .override, verb: "cleared",
          fields: [DecisionField(key: "msg", value: "Claude idle: automatic management resumed")]))
    }
    let wanted: Bool
    let reason: String
    if batteryBlocked {
      wanted = false
      reason = "battery"
    } else if state.pause != nil {
      wanted = false
      reason = "paused"
    } else if state.force != nil {
      wanted = true
      reason = "forced"
    } else if state.override {
      wanted = false
      reason = "override"
    } else {
      wanted = grace
      reason = grace ? "busy" : "idle"
    }
    state.reason = reason
    guard state.wanted != wanted else { return decisions }
    state.wanted = wanted
    state.wantedSince = wanted ? now : nil
    decisions.append(
      Decision(
        keyword: .want,
        verb: wanted ? "on" : "off",
        fields: [DecisionField(key: "reason", value: reason)]
      ))
    return decisions
  }

  public static func isExpired(_ pause: PauseState, now: Instant, wall: Date) -> Bool {
    switch pause {
    case .untilMono(let deadline, _):
      return now >= deadline
    case .untilWall(let date):
      return wall >= date
    case .indefinite:
      return false
    }
  }

  public static func until(_ pause: PauseState) -> String {
    switch pause {
    case .untilMono(_, let wall):
      return iso8601(wall)
    case .untilWall(let date):
      return iso8601(date)
    case .indefinite:
      return "indefinite"
    }
  }

  public static func iso8601(_ date: Date) -> String {
    date.formatted(Date.ISO8601FormatStyle(timeZone: TimeZone(secondsFromGMT: 0) ?? .gmt))
  }

  static func withinGrace(_ state: WantState, now: Instant, settings: Settings) -> Bool {
    guard let lastBusy = state.lastBusy else { return false }
    return now.nanoseconds(since: lastBusy) < Instant.nanoseconds(forSeconds: settings.releaseGraceSeconds)
  }
}
