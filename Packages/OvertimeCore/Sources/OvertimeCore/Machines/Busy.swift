import Foundation

public struct BusyState: Sendable, Equatable {
  public var lastEligibleTranscript: Instant?
  public var claudeCaffeinate: Bool
  public var caffeinateSince: Instant?
  public var stuckLogged: Bool
  public var busy: Bool?
  public var seenEntrypoints: Set<String> = []
  public var lastTranscriptEventAt: Instant?

  public init(
    lastEligibleTranscript: Instant? = nil,
    claudeCaffeinate: Bool = false,
    caffeinateSince: Instant? = nil,
    stuckLogged: Bool = false,
    busy: Bool? = nil
  ) {
    self.lastEligibleTranscript = lastEligibleTranscript
    self.claudeCaffeinate = claudeCaffeinate
    self.caffeinateSince = caffeinateSince
    self.stuckLogged = stuckLogged
    self.busy = busy
  }
}

public enum Busy {
  public static func evaluate(_ state: inout BusyState, now: Instant, settings: Settings) -> [Decision] {
    var decisions: [Decision] = []
    let isBusy: Bool
    let source: String
    if eligibleTranscript(state, within: settings.transcriptWindowSeconds, now: now) {
      isBusy = true
      source = "transcript"
      state.stuckLogged = false
    } else if state.claudeCaffeinate && eligibleTranscript(state, within: settings.stuckWindowSeconds, now: now) {
      isBusy = true
      source = "caffeinate"
      state.stuckLogged = false
    } else {
      isBusy = false
      source = state.claudeCaffeinate ? "caffeinate" : "transcript"
      if state.claudeCaffeinate && !state.stuckLogged && !freshCaffeinate(state, now: now) {
        state.stuckLogged = true
        decisions.append(
          Decision(
            keyword: .stuck,
            verb: "ignored",
            fields: [DecisionField(key: "window", value: seconds(settings.stuckWindowSeconds))]
          ))
      }
    }
    guard state.busy != isBusy else { return decisions }
    state.busy = isBusy
    decisions.append(
      Decision(
        keyword: .busy,
        verb: isBusy ? "on" : "off",
        fields: [DecisionField(key: "source", value: source)]
      ))
    return decisions
  }

  static func freshCaffeinate(_ state: BusyState, now: Instant) -> Bool {
    guard state.claudeCaffeinate, let since = state.caffeinateSince else { return false }
    return now.nanoseconds(since: since) < Instant.nanoseconds(forSeconds: Timing.freshCaffeinateSeconds)
  }

  static func eligibleTranscript(_ state: BusyState, within seconds: Double, now: Instant) -> Bool {
    guard let last = state.lastEligibleTranscript else { return false }
    return now.nanoseconds(since: last) < Instant.nanoseconds(forSeconds: seconds)
  }

  static func seconds(_ value: Double) -> String {
    if value.isFinite, value.rounded() == value, abs(value) < 1e15 {
      return String(Int64(value))
    }
    return String(value)
  }
}
