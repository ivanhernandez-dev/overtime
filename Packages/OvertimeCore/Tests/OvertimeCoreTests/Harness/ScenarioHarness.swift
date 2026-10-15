import Foundation

@testable import OvertimeCore

struct ScenarioHarness {
  static let claudeCaffeinate = TickFacts(agents: AgentSignals(busyProcessCount: 1, sessionCount: 1))
  static let noAgents = TickFacts()

  var state: AppState
  var settings: Settings
  var includeActuators = false
  let t0 = Instant(nanoseconds: 1_000_000 * 1_000_000_000)
  let wall0 = Date(timeIntervalSince1970: 1_800_000_000)

  init(settings: Settings = Settings(), mode: RunMode = .shadow) {
    self.state = AppState(mode: mode)
    self.settings = settings
  }

  func instant(_ seconds: Double) -> Instant {
    t0.adding(seconds: seconds)
  }

  func seconds(_ instant: Instant) -> Double {
    instant >= t0 ? instant.seconds(since: t0) : -t0.seconds(since: instant)
  }

  mutating func send(_ event: Event, at seconds: Double) -> [Effect] {
    let stamped = Stamped(mono: instant(seconds), wall: wall0.addingTimeInterval(seconds), event: event)
    let effects = Reducer.reduce(&state, stamped, settings)
    return includeActuators ? effects : effects.filter { !Self.isActuator($0) }
  }

  static func isActuator(_ effect: Effect) -> Bool {
    switch effect {
    case .idleAssertion, .displayAssertion, .sentinel, .clamshell, .displaySleepNow, .requestSleep, .net, .helper: true
    case .log, .persist: false
    }
  }

  mutating func activity(writtenAt written: Double, entrypoint: String? = nil, seenAt seen: Double) -> [Effect] {
    send(.transcriptActivity(TranscriptActivity(at: instant(written), entrypoint: entrypoint)), at: seen)
  }

  mutating func tick(at seconds: Double, caffeinate: Bool = false) -> [Effect] {
    send(.tick(caffeinate ? Self.claudeCaffeinate : Self.noAgents), at: seconds)
  }

  mutating func ticks(from start: Double, to end: Double, every step: Double, facts: TickFacts) -> [(
    at: Double, effects: [Effect]
  )] {
    var results: [(at: Double, effects: [Effect])] = []
    var index = 0
    while true {
      let at = start + Double(index) * step
      guard at <= end else { break }
      results.append((at: at, effects: send(.tick(facts), at: at)))
      index += 1
    }
    return results
  }

  static func decisions(_ effects: [Effect]) -> [Decision] {
    effects.compactMap { effect in
      switch effect {
      case .log(let decision): decision
      default: nil
      }
    }
  }

  static func wantLines(_ effects: [Effect]) -> [Decision] {
    decisions(effects).filter { $0.keyword == .want }
  }

  static func busy(_ on: Bool, source: String) -> Effect {
    .log(Decision(keyword: .busy, verb: on ? "on" : "off", fields: [DecisionField(key: "source", value: source)]))
  }

  static func want(_ on: Bool) -> Effect {
    .log(
      Decision(
        keyword: .want, verb: on ? "on" : "off", fields: [DecisionField(key: "reason", value: on ? "busy" : "idle")]))
  }

  static let stuck = Effect.log(
    Decision(keyword: .stuck, verb: "ignored", fields: [DecisionField(key: "window", value: "1800")]))

  static func entrypoint(_ value: String, ignored: Bool) -> Effect {
    .log(
      Decision(
        keyword: .entrypoint,
        verb: "new",
        fields: [
          DecisionField(key: "value", value: value),
          DecisionField(key: "ignored", value: ignored ? "true" : "false"),
        ]
      ))
  }

  static func header(_ line: String) -> String? {
    TranscriptHeader.entrypoint(in: Array((line + "\n").utf8))
  }
}
