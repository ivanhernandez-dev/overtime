import Foundation
import Testing

@testable import OvertimeCore

@Suite("HOLD-07 coexistence warning")
struct CoexistenceTests {
  static let amphetamine = CoexistenceFacts(amphetamineRunning: true, sleepDisabled: false)
  static let quiet = CoexistenceFacts(amphetamineRunning: false, sleepDisabled: false)
  static let foreign = ForeignAssertion(pid: 4242, type: "PreventUserIdleSystemSleep", processName: "Keeper")

  static func warning(amphetamine: Bool, sleepDisabled: String, foreign: Int, names: String) -> Decision {
    Decision(
      keyword: .warn, verb: "coexistence",
      fields: [
        DecisionField(key: "amphetamine", value: amphetamine ? "true" : "false"),
        DecisionField(key: "sleepDisabled", value: sleepDisabled),
        DecisionField(key: "foreign", value: String(foreign)),
        DecisionField(key: "names", value: names),
      ])
  }

  static let cleared = Decision(keyword: .warn, verb: "coexistence cleared")

  static func wantedHarness() -> ScenarioHarness {
    var harness = ScenarioHarness()
    _ = harness.tick(at: -2)
    _ = harness.activity(writtenAt: 0, seenAt: 0)
    return harness
  }

  static func coexistenceLines(_ effects: [Effect]) -> [Decision] {
    ScenarioHarness.decisions(effects).filter { $0.verb.hasPrefix("coexistence") }
  }

  static func sample(_ harness: inout ScenarioHarness, _ facts: CoexistenceFacts?, at seconds: Double) -> [Decision] {
    Self.coexistenceLines(harness.send(.tick(TickFacts(coexistence: facts)), at: seconds))
  }

  @Test func amphetamineWarnsOncePerEpisodeAndClears() {
    var harness = Self.wantedHarness()
    #expect(harness.state.want.wanted == true)
    #expect(
      Self.sample(&harness, Self.amphetamine, at: 2) == [
        Self.warning(amphetamine: true, sleepDisabled: "false", foreign: 0, names: "none")
      ])
    #expect(Self.sample(&harness, nil, at: 4).isEmpty)
    #expect(Self.sample(&harness, Self.amphetamine, at: 32).isEmpty)
    #expect(Self.sample(&harness, Self.quiet, at: 62) == [Self.cleared])
    #expect(Self.sample(&harness, Self.quiet, at: 92).isEmpty)
  }

  @Test func sleepDisabledAloneWarns() {
    var harness = Self.wantedHarness()
    let facts = CoexistenceFacts(amphetamineRunning: false, sleepDisabled: true)
    #expect(
      Self.sample(&harness, facts, at: 2) == [
        Self.warning(amphetamine: false, sleepDisabled: "true", foreign: 0, names: "none")
      ])
  }

  @Test func anUnreadableSleepDisabledIsReportedAsUnknownAndDoesNotWarnAlone() {
    var harness = Self.wantedHarness()
    #expect(Self.sample(&harness, CoexistenceFacts(sleepDisabled: nil), at: 2).isEmpty)
    #expect(
      Self.sample(&harness, CoexistenceFacts(amphetamineRunning: true, sleepDisabled: nil), at: 32) == [
        Self.warning(amphetamine: true, sleepDisabled: "unknown", foreign: 0, names: "none")
      ])
  }

  @Test func aForeignAssertionCountsOnlyInTwoConsecutiveSamples() {
    var harness = Self.wantedHarness()
    let seen = CoexistenceFacts(sleepDisabled: false, foreignAssertions: [Self.foreign])
    #expect(Self.sample(&harness, seen, at: 2).isEmpty)
    #expect(
      Self.sample(&harness, seen, at: 32) == [
        Self.warning(amphetamine: false, sleepDisabled: "false", foreign: 1, names: "Keeper")
      ])
  }

  @Test func theWarningNamesTheProcessAndNeverTheProcessThatStartedIt() {
    var harness = Self.wantedHarness()
    let started = ForeignAssertion(
      pid: 4242, type: "PreventUserIdleSystemSleep", processName: "caffeinate", parentName: "python3")
    let seen = CoexistenceFacts(amphetamineRunning: false, sleepDisabled: false, foreignAssertions: [started])
    #expect(Self.sample(&harness, seen, at: 2).isEmpty)
    #expect(
      Self.sample(&harness, seen, at: 32) == [
        Self.warning(amphetamine: false, sleepDisabled: "false", foreign: 1, names: "caffeinate")
      ])
  }

  @Test func aTransientForeignAssertionNeverWarns() {
    var harness = Self.wantedHarness()
    let other = ForeignAssertion(pid: 5151, type: "PreventUserIdleSystemSleep", processName: "Other")
    #expect(Self.sample(&harness, CoexistenceFacts(foreignAssertions: [Self.foreign]), at: 2).isEmpty)
    #expect(Self.sample(&harness, CoexistenceFacts(foreignAssertions: [other]), at: 32).isEmpty)
    #expect(Self.sample(&harness, Self.quiet, at: 62).isEmpty)
    let retyped = ForeignAssertion(pid: 4242, type: "PreventSystemSleep", processName: "Keeper")
    #expect(Self.sample(&harness, CoexistenceFacts(foreignAssertions: [Self.foreign]), at: 92).isEmpty)
    #expect(Self.sample(&harness, CoexistenceFacts(foreignAssertions: [retyped]), at: 122).isEmpty)
  }

  @Test func nothingIsEvaluatedWhileNotWanted() {
    var harness = ScenarioHarness()
    #expect(Self.sample(&harness, Self.amphetamine, at: 0).isEmpty)
    #expect(Self.sample(&harness, Self.amphetamine, at: 30).isEmpty)
    #expect(harness.state.coexistence == CoexistenceState())
  }

  @Test func consecutivenessIsBrokenByAnUnwantedStretch() {
    var harness = Self.wantedHarness()
    let seen = CoexistenceFacts(foreignAssertions: [Self.foreign])
    #expect(Self.sample(&harness, seen, at: 2).isEmpty)
    #expect(Self.sample(&harness, seen, at: 200).isEmpty)
    #expect(harness.state.want.wanted == false)
    _ = harness.activity(writtenAt: 300, seenAt: 300)
    #expect(Self.sample(&harness, seen, at: 302).isEmpty)
    #expect(Self.sample(&harness, seen, at: 332).count == 1)
  }

  @Test func processNamesAreSanitizedDeduplicatedAndSorted() {
    var harness = Self.wantedHarness()
    let facts = CoexistenceFacts(
      foreignAssertions: [
        ForeignAssertion(pid: 7, type: "PreventSystemSleep", processName: "Zed\u{7}"),
        ForeignAssertion(pid: 8, type: "PreventUserIdleSystemSleep", processName: "Alpha"),
        ForeignAssertion(pid: 9, type: "PreventUserIdleSystemSleep", processName: "Alpha"),
      ])
    _ = Self.sample(&harness, facts, at: 2)
    #expect(
      Self.sample(&harness, facts, at: 32) == [
        Self.warning(amphetamine: false, sleepDisabled: "unknown", foreign: 3, names: "Alpha,Zed?")
      ])
  }

  @Test func theMachineEmitsOnlyLogEffects() {
    var state = AppState(mode: .live)
    state.want.wanted = true
    let facts = CoexistenceFacts(amphetamineRunning: true, sleepDisabled: true, foreignAssertions: [Self.foreign])
    var effects = Coexistence.step(&state, facts: facts, now: Instant(nanoseconds: 1))
    effects += Coexistence.step(&state, facts: facts, now: Instant(nanoseconds: 2))
    effects += Coexistence.step(&state, facts: CoexistenceFacts(), now: Instant(nanoseconds: 3))
    #expect(effects.count == 2)
    #expect(
      effects.allSatisfy { effect in
        if case .log = effect { return true }
        return false
      })
  }
}
