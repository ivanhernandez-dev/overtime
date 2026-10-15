import Foundation
import Testing

@testable import OvertimeCore

struct DeterminismTests {
  static func stream() -> [Stamped<Event>] {
    let base = Instant(nanoseconds: 90_000_000_000_000)
    let wallBase = Date(timeIntervalSince1970: 1_800_000_000)
    var events: [Stamped<Event>] = []
    for index in 0..<30 {
      let seconds = Double(index) * 37.5
      let mono = base.adding(seconds: seconds)
      let wall = wallBase.addingTimeInterval(seconds)
      let event: Event
      switch index % 5 {
      case 0:
        event = .transcriptActivity(TranscriptActivity(at: mono.adding(seconds: -Double(index % 3) * 50)))
      case 1:
        event = .tick(TickFacts(agents: AgentSignals(busyProcessCount: 1, sessionCount: 1)))
      case 2:
        event = .tick(TickFacts())
      case 3:
        event = .transcriptActivity(TranscriptActivity(at: mono.adding(seconds: -2400), entrypoint: "sdk-ts"))
      default:
        event = .tick(
          TickFacts(
            agents: AgentSignals(
              busyProcessCount: index % 2, sessionCount: 1, terminalAgentStarts: [base.adding(seconds: 1)])))
      }
      events.append(Stamped(mono: mono, wall: wall, event: event))
    }
    return events
  }

  static func replay(_ events: [Stamped<Event>]) -> ([Effect], AppState) {
    var state = AppState(mode: .shadow)
    var effects: [Effect] = []
    for event in events {
      effects += Reducer.reduce(&state, event, Settings())
    }
    return (effects, state)
  }

  @Test func replayingTheSameStreamTwiceIsIdentical() {
    let events = DeterminismTests.stream()
    #expect(events.count == 30)
    let first = DeterminismTests.replay(events)
    let second = DeterminismTests.replay(events)
    #expect(first.0 == second.0)
    #expect(first.1 == second.1)
    #expect(!first.0.isEmpty)
  }
}
