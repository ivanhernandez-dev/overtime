import Foundation
import Testing

@testable import OvertimeCore

@Suite("Release until idle (HOLD-06)")
struct ReleaseUntilIdleTests {
  static let cleared = Decision(
    keyword: .override, verb: "cleared",
    fields: [DecisionField(key: "msg", value: "Claude idle: automatic management resumed")])
  static let released = Decision(keyword: .override, verb: "releaseUntilIdle")

  static func want(_ on: Bool, _ reason: String) -> Decision {
    Decision(keyword: .want, verb: on ? "on" : "off", fields: [DecisionField(key: "reason", value: reason)])
  }

  static func overrideLines(_ effects: [Effect]) -> [Decision] {
    ScenarioHarness.decisions(effects).filter { $0.keyword == .override }
  }

  @Test func releaseWhileBusyKeepsWantOffUntilTheGraceRunsOut() {
    var harness = ScenarioHarness()
    _ = harness.activity(writtenAt: 0, entrypoint: "cli", seenAt: 0)
    _ = harness.tick(at: 0)
    #expect(harness.state.want.wanted == true)
    let released = harness.send(.command(.releaseUntilIdle), at: 1)
    #expect(ScenarioHarness.decisions(released) == [Self.released, Self.want(false, "override")])
    #expect(harness.state.want.override)
    for (at, effects) in harness.ticks(from: 2, to: 118, every: 2, facts: ScenarioHarness.noAgents) {
      #expect(ScenarioHarness.wantLines(effects).isEmpty, "tick at \(at)")
      #expect(Self.overrideLines(effects).isEmpty, "tick at \(at)")
    }
    #expect(harness.state.busy.busy == true)
    #expect(harness.state.want.override)
    #expect(harness.state.want.reason == "override")
    #expect(harness.state.want.lastBusy == harness.instant(118))
    let idle = harness.tick(at: 120)
    #expect(Self.overrideLines(idle).isEmpty)
    #expect(ScenarioHarness.wantLines(idle).isEmpty)
    #expect(harness.state.busy.busy == false)
    #expect(harness.state.want.override)
    #expect(Self.overrideLines(harness.tick(at: 177.999)).isEmpty)
    #expect(harness.state.want.override)
    let atGrace = harness.tick(at: 178)
    #expect(Self.overrideLines(atGrace) == [Self.cleared])
    #expect(ScenarioHarness.wantLines(atGrace).isEmpty)
    #expect(harness.state.want.override == false)
    let activity = harness.activity(writtenAt: 200, entrypoint: "cli", seenAt: 200)
    #expect(ScenarioHarness.wantLines(activity) == [Self.want(true, "busy")])
    #expect(ScenarioHarness.wantLines(harness.tick(at: 200)).isEmpty)
  }

  @Test func releaseWhileIdleClearsOnTheSameStep() {
    var harness = ScenarioHarness()
    _ = harness.tick(at: 0)
    let effects = harness.send(.command(.releaseUntilIdle), at: 1)
    #expect(ScenarioHarness.decisions(effects) == [Self.released, Self.cleared])
    #expect(harness.state.want.override == false)
    #expect(harness.state.want.wanted == false)
  }

  @Test func theReleaseStaysInForceWhileBusyEvenAfterItsGraceWouldHaveEnded() {
    var harness = ScenarioHarness()
    _ = harness.activity(writtenAt: 0, entrypoint: "cli", seenAt: 0)
    _ = harness.tick(at: 0)
    _ = harness.send(.command(.releaseUntilIdle), at: 1)
    for at in stride(from: 100.0, through: 1000, by: 100) {
      _ = harness.activity(writtenAt: at, seenAt: at)
      #expect(ScenarioHarness.decisions(harness.tick(at: at)).isEmpty, "tick at \(at)")
    }
    #expect(harness.state.want.override)
    #expect(harness.state.want.wanted == false)
  }
}
