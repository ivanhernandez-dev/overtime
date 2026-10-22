import Foundation

public struct BusyState: Sendable, Equatable {
  public var lastEligibleTranscript: Instant?
  public var claudeCaffeinate: Bool
  public var caffeinateSince: Instant?
  public var stuckLogged: Bool
  public var busy: Bool?
  public var seenEntrypoints: Set<String> = []
  public var lastTranscriptEventAt: Instant?
  public var backgroundCommandSessions: Int = 0
  public var printRunStarts: [Instant] = []
  public var backgroundSince: Instant?
  public var lastCountedCaffeinate: Instant?
  public var source: String?
  public var limitLogged: Set<String> = []
  public var backgroundHolding: Bool = false
  public var printHolding: Bool = false

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
  public static let printSource = "print"
  public static let backgroundSource = "background"

  public static func evaluate(_ state: inout BusyState, now: Instant, settings: Settings) -> [Decision] {
    var decisions: [Decision] = []
    if state.claudeCaffeinate && eligibleTranscript(state, within: settings.stuckWindowSeconds, now: now) {
      state.lastCountedCaffeinate = now
    }
    let limit = settings.longRunningLimitSeconds
    state.printHolding = printHolds(state, now: now, settings: settings, limit: limit)
    state.backgroundHolding = backgroundHolds(state, now: now, settings: settings, limit: limit)
    decisions += limitDecisions(&state, settings: settings, limit: limit)
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
    } else if state.printHolding {
      isBusy = true
      source = printSource
    } else if state.backgroundHolding {
      isBusy = true
      source = backgroundSource
    } else {
      isBusy = false
      source = offSource(state)
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
    let previousSource = state.source
    state.source = isBusy ? source : nil
    guard state.busy != isBusy else {
      if isBusy, previousSource != source, source == printSource || source == backgroundSource {
        decisions.append(
          Decision(keyword: .busy, verb: "continues", fields: [DecisionField(key: "source", value: source)]))
      }
      return decisions
    }
    state.busy = isBusy
    decisions.append(
      Decision(
        keyword: .busy,
        verb: isBusy ? "on" : "off",
        fields: [DecisionField(key: "source", value: source)]
      ))
    return decisions
  }

  static func offSource(_ state: BusyState) -> String {
    if state.claudeCaffeinate {
      return "caffeinate"
    }
    if !state.printRunStarts.isEmpty {
      return printSource
    }
    if state.backgroundCommandSessions > 0 {
      return backgroundSource
    }
    return "transcript"
  }

  public static func backgroundAnchor(_ state: BusyState) -> Instant? {
    [state.lastEligibleTranscript, state.lastCountedCaffeinate, state.backgroundSince].compactMap { $0 }.max()
  }

  static func within(_ limit: Double?, from start: Instant, now: Instant) -> Bool {
    guard let limit else { return true }
    return now.nanoseconds(since: start) < Instant.nanoseconds(forSeconds: limit)
  }

  static func printHolds(_ state: BusyState, now: Instant, settings: Settings, limit: Double?) -> Bool {
    guard settings.printRunsKeepAwake else { return false }
    return state.printRunStarts.contains { within(limit, from: $0, now: now) }
  }

  static func backgroundHolds(_ state: BusyState, now: Instant, settings: Settings, limit: Double?) -> Bool {
    guard settings.backgroundCommandsKeepAwake, state.backgroundCommandSessions > 0 else { return false }
    guard limit != nil else { return true }
    guard let anchor = backgroundAnchor(state) else { return false }
    return within(limit, from: anchor, now: now)
  }

  static func limitDecisions(_ state: inout BusyState, settings: Settings, limit: Double?) -> [Decision] {
    let stopped = [
      (
        printSource,
        limit != nil && settings.printRunsKeepAwake && !state.printRunStarts.isEmpty && !state.printHolding
      ),
      (
        backgroundSource,
        limit != nil && settings.backgroundCommandsKeepAwake && state.backgroundCommandSessions > 0
          && !state.backgroundHolding
      ),
    ]
    var decisions: [Decision] = []
    for (source, isStopped) in stopped {
      guard isStopped else {
        state.limitLogged.remove(source)
        continue
      }
      guard state.limitLogged.insert(source).inserted else { continue }
      decisions.append(
        Decision(
          keyword: .busy, verb: "limit",
          fields: [
            DecisionField(key: "source", value: source),
            DecisionField(key: "minutes", value: String(settings.longRunningLimitMinutes)),
          ]))
    }
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
