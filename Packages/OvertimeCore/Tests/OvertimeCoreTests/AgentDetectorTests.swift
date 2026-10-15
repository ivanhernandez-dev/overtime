import Foundation
import Testing

@testable import OvertimeCore

struct AgentDetectorTests {
  struct FixedDetector: AgentDetector {
    let name = "fixed"
    let result: AgentSignals

    func signals(from processes: [ProcessRecord]) -> AgentSignals {
      result
    }
  }

  let settings = Settings()
  let t0 = Instant(nanoseconds: 50_000_000_000_000)

  func stamp(_ event: Event, at mono: Instant) -> Stamped<Event> {
    Stamped(mono: mono, wall: Date(timeIntervalSince1970: 1_800_000_000), event: event)
  }

  func decisions(_ effects: [Effect]) -> [Decision] {
    effects.compactMap { effect in
      switch effect {
      case .log(let decision): decision
      default: nil
      }
    }
  }

  func tick(_ state: inout AppState, caffeinate: Bool, at mono: Instant) -> [Decision] {
    let agents = AgentSignals(busyProcessCount: caffeinate ? 1 : 0, sessionCount: caffeinate ? 1 : 0)
    return decisions(Reducer.reduce(&state, stamp(.tick(TickFacts(agents: agents)), at: mono), settings))
  }

  func seed(_ state: inout AppState, activityAt at: Instant, stampedAt mono: Instant) {
    _ = Reducer.reduce(&state, stamp(.transcriptActivity(TranscriptActivity(at: at)), at: mono), settings)
  }

  @Test func aSecondDetectorOrsIntoBusyAndSessionsAreSummed() {
    let processes = [ProcessRecord(pid: 10, ppid: 9, uid: 501, comm: "agent", argv0: "agent")]
    let detectors: [any AgentDetector] = [
      ClaudeCodeDetector(userID: 501),
      FixedDetector(result: AgentSignals(busyProcessCount: 1, sessionCount: 2)),
    ]
    let merged = AgentSignals.merged(detectors.map { $0.signals(from: processes) })
    #expect(merged.busyProcessCount == 1)
    #expect(merged.sessionCount == 2)
    #expect(ClaudeCodeDetector(userID: 501).signals(from: processes) == .none)
    #expect(ClaudeCodeDetector(userID: 501).name == "claude-code")

    var withSecond = AppState(mode: .shadow)
    seed(&withSecond, activityAt: t0.adding(seconds: -600), stampedAt: t0)
    _ = Reducer.reduce(&withSecond, stamp(.tick(TickFacts(agents: merged)), at: t0), settings)
    #expect(withSecond.busy.busy == true)

    var claudeOnly = AppState(mode: .shadow)
    seed(&claudeOnly, activityAt: t0.adding(seconds: -600), stampedAt: t0)
    let alone = AgentSignals.merged([ClaudeCodeDetector(userID: 501).signals(from: processes)])
    _ = Reducer.reduce(&claudeOnly, stamp(.tick(TickFacts(agents: alone)), at: t0), settings)
    #expect(claudeOnly.busy.busy == false)
  }

  @Test func mergedSumsCountsAndConcatenatesStarts() {
    let merged = AgentSignals.merged([
      AgentSignals(busyProcessCount: 1, sessionCount: 1, terminalAgentStarts: [Instant(nanoseconds: 1)]),
      AgentSignals(busyProcessCount: 2, sessionCount: 3, terminalAgentStarts: [Instant(nanoseconds: 2)]),
    ])
    #expect(
      merged
        == AgentSignals(
          busyProcessCount: 3, sessionCount: 4, terminalAgentStarts: [.init(nanoseconds: 1), .init(nanoseconds: 2)]))
    #expect(AgentSignals.merged([]) == .none)
  }

  @Test func caffeinateKeepsBusyWithinTheStuckWindow() {
    var state = AppState(mode: .shadow)
    seed(&state, activityAt: t0.adding(seconds: -600), stampedAt: t0)
    let logged = tick(&state, caffeinate: true, at: t0)
    #expect(state.busy.busy == true)
    #expect(
      logged.first == Decision(keyword: .busy, verb: "on", fields: [DecisionField(key: "source", value: "caffeinate")]))
    #expect(state.busy.caffeinateSince == t0)
    _ = tick(&state, caffeinate: false, at: t0.adding(seconds: 2))
    #expect(state.busy.caffeinateSince == nil)
  }

  @Test func caffeinateWithoutRecentTranscriptsIsStuckAndLoggedOnce() {
    var state = AppState(mode: .shadow)
    seed(&state, activityAt: t0.adding(seconds: -2400), stampedAt: t0)
    let first = tick(&state, caffeinate: true, at: t0)
    let second = tick(&state, caffeinate: true, at: t0.adding(seconds: 2))
    let stuck = (first + second).filter { $0.keyword == .stuck }
    #expect(state.busy.busy == false)
    #expect(
      stuck == [Decision(keyword: .stuck, verb: "ignored", fields: [DecisionField(key: "window", value: "1800")])])
    #expect(state.busy.stuckLogged)

    seed(&state, activityAt: t0.adding(seconds: 3), stampedAt: t0.adding(seconds: 4))
    _ = tick(&state, caffeinate: true, at: t0.adding(seconds: 4))
    #expect(state.busy.busy == true)
    #expect(!state.busy.stuckLogged)
  }

  @Test func stuckBoundaryIsStrict() {
    var state = AppState(mode: .shadow)
    seed(&state, activityAt: t0, stampedAt: t0)
    _ = tick(&state, caffeinate: true, at: t0.adding(seconds: 1790))
    _ = tick(&state, caffeinate: true, at: t0.adding(seconds: 1799.999))
    #expect(state.busy.busy == true)
    _ = tick(&state, caffeinate: true, at: t0.adding(seconds: 1800))
    #expect(state.busy.busy == false)
    #expect(state.busy.stuckLogged)
  }
}
