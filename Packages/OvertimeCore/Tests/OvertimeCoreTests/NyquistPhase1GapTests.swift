import Foundation
import Testing

@testable import OvertimeCore

@Suite("Nyquist phase 1 gap coverage")
struct NyquistPhase1GapTests {
  typealias H = ScenarioHarness

  static let lidOpen = TickFacts(lidClosed: false)

  static func harness() -> ScenarioHarness {
    var harness = ScenarioHarness()
    harness.includeActuators = true
    return harness
  }

  static func idle(_ effects: [Effect]) -> [(AssertionAction, EffectID)] {
    effects.compactMap { effect in
      if case .idleAssertion(let action, let id) = effect { return (action, id) }
      return nil
    }
  }

  static func answer(_ harness: inout ScenarioHarness, _ effects: [Effect], at seconds: Double) {
    for (_, id) in idle(effects) {
      _ = harness.send(.effectResult(id, .succeeded), at: seconds + 0.001)
    }
  }

  static func step(_ harness: inout ScenarioHarness, at seconds: Double) -> [Effect] {
    let effects = harness.send(.tick(lidOpen), at: seconds)
    answer(&harness, effects, at: seconds)
    return effects
  }

  @Test func theIdleAssertionIsRenewedThroughTheReleaseGraceAfterBusyEnds() {
    var harness = Self.harness()
    _ = harness.activity(writtenAt: 0, seenAt: 0)
    _ = Self.step(&harness, at: 0)
    var busyOff = false
    for second in stride(from: 2.0, through: 170.0, by: 2.0) {
      let effects = Self.step(&harness, at: second)
      if H.decisions(effects).contains(where: { $0.keyword == .busy && $0.verb == "off" }) { busyOff = true }
      let actions = Self.idle(effects).map(\.0)
      #expect(actions == [.acquireOrRenew(timeoutSeconds: 300)], "at \(second)")
      #expect(H.wantLines(effects).isEmpty, "at \(second)")
    }
    #expect(busyOff)
    #expect(harness.state.hold.idle == .held)
    let after = Self.step(&harness, at: 200)
    #expect(H.wantLines(after).map(\.verb) == ["off"])
    #expect(Self.idle(after).map(\.0) == [.release])
  }

  @Test func onBatteryAboveTheFloorATranscriptOnlyBusyTakesTheIdleAssertion() {
    var harness = Self.harness()
    #expect(harness.send(.power(.battery(percent: 50)), at: 0).isEmpty)
    _ = harness.activity(writtenAt: 1, seenAt: 1)
    let effects = harness.send(.tick(Self.lidOpen), at: 2)
    #expect(H.wantLines(effects).map(\.verb) == ["on"])
    #expect(Self.idle(effects).map(\.0) == [.acquireOrRenew(timeoutSeconds: 300)])
  }

  @Test func sparseLoopWakeupsDoNotKeepWantOnBetweenThem() {
    var harness = Self.harness()
    var wants: [(Double, String)] = []
    var released = false
    for wakeup in [0.0, 600.0, 1200.0] {
      let seen = harness.activity(writtenAt: wakeup, seenAt: wakeup)
      wants += H.wantLines(seen).map { (wakeup, $0.verb) }
      for second in stride(from: wakeup, to: wakeup + 600, by: 2.0) {
        let effects = Self.step(&harness, at: second)
        wants += H.wantLines(effects).map { (second, $0.verb) }
        if Self.idle(effects).contains(where: { $0.0 == .release }) { released = true }
      }
    }
    #expect(wants.map(\.1) == ["on", "off", "on", "off", "on", "off"])
    for (at, verb) in wants where verb == "off" {
      let offset = at.truncatingRemainder(dividingBy: 600)
      #expect(offset >= 176 && offset <= 182, "want off at \(at)")
    }
    #expect(released)
    #expect(harness.state.hold.idle == .released)
  }

  @Test func aLongRunningBackgroundChildWithoutTranscriptsNeverTurnsWantOn() {
    var harness = Self.harness()
    let devServer = TickFacts(agents: AgentSignals(busyProcessCount: 0, sessionCount: 1), lidClosed: false)
    var all: [Effect] = []
    for second in stride(from: 0.0, through: 3600.0, by: 2.0) {
      all += harness.send(.tick(devServer), at: second)
    }
    #expect(!H.wantLines(all).contains { $0.verb == "on" })
    #expect(Self.idle(all).isEmpty)
  }
}
