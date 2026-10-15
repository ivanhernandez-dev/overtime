import Foundation
import Testing

@testable import OvertimeCore

struct DetectionHealthTests {
  typealias H = ScenarioHarness

  static let rootA = "/Users/dev/.claude/projects"
  static let rootB = "/Volumes/Work/claude projects"

  static func warning(_ reason: String, root: String) -> Decision {
    Decision(
      keyword: .warn,
      verb: "detectionHealth",
      fields: [DecisionField(key: "reason", value: reason), DecisionField(key: "root", value: root)]
    )
  }

  static func cleared(_ root: String) -> Decision {
    Decision(keyword: .warn, verb: "detectionHealth cleared", fields: [DecisionField(key: "root", value: root)])
  }

  static let silence = Decision(
    keyword: .warn,
    verb: "detectionHealth",
    fields: [
      DecisionField(key: "reason", value: "terminalClaudeSilent"),
      DecisionField(key: "after", value: "600"),
    ]
  )

  static func warnings(_ effects: [Effect]) -> [Decision] {
    H.decisions(effects).filter { $0.keyword == .warn }
  }

  func roots(_ harness: inout H, _ statuses: [(String, RootStatus)], at seconds: Double) -> [Decision] {
    Self.warnings(
      harness.send(.transcriptRoots(statuses.map { RootHealth(path: $0.0, status: $0.1) }), at: seconds))
  }

  static func terminal(_ starts: [Instant]) -> Event {
    .tick(TickFacts(agents: AgentSignals(terminalAgentStarts: starts)))
  }

  static func absent(_ root: String) -> Decision {
    Decision(keyword: .check, verb: "transcriptRoot absent", fields: [DecisionField(key: "root", value: root)])
  }

  func report(_ harness: inout H, _ roots: [RootHealth], at seconds: Double) -> [Decision] {
    H.decisions(harness.send(.transcriptRoots(roots), at: seconds))
  }

  @Test func aMissingInferredRootIsLoggedOnceAndNeverWarns() {
    var harness = H()
    let missing = [RootHealth(path: Self.rootA, status: .missing, origin: .inferred)]
    #expect(report(&harness, missing, at: 0) == [Self.absent(Self.rootA)])
    #expect(harness.state.health.rootIssues.isEmpty)
    #expect(harness.state.health.warnedRoots.isEmpty)
    #expect(harness.state.health.quietRoots == [Self.rootA])
    #expect(report(&harness, missing, at: 30).isEmpty)
    #expect(harness.state.health.rootIssues.isEmpty)
  }

  @Test func aMissingInferredRootThatReturnsIsLoggedAgain() {
    var harness = H()
    let missing = [RootHealth(path: Self.rootA, status: .missing, origin: .inferred)]
    let present = [RootHealth(path: Self.rootA, status: .ok, origin: .inferred)]
    #expect(report(&harness, missing, at: 0) == [Self.absent(Self.rootA)])
    #expect(report(&harness, present, at: 30).isEmpty)
    #expect(harness.state.health.quietRoots.isEmpty)
    #expect(report(&harness, missing, at: 60) == [Self.absent(Self.rootA)])
  }

  @Test func anUnreadableInferredRootStillWarns() {
    var harness = H()
    let unreadable = [RootHealth(path: Self.rootA, status: .unreadable, origin: .inferred)]
    #expect(report(&harness, unreadable, at: 0) == [Self.warning("rootUnreadable", root: Self.rootA)])
    #expect(harness.state.health.rootIssues == [Self.rootA: .unreadable])
  }

  @Test func aConfiguredRootBesideAMissingInferredOneStillWarnsAlone() {
    var harness = H()
    let decisions = report(
      &harness,
      [
        RootHealth(path: Self.rootA, status: .missing, origin: .inferred),
        RootHealth(path: Self.rootB, status: .missing, origin: .configured),
      ], at: 0)
    #expect(decisions.filter { $0.keyword == .warn } == [Self.warning("rootMissing", root: Self.rootB)])
    #expect(decisions.filter { $0.keyword == .check } == [Self.absent(Self.rootA)])
    #expect(decisions.count == 2)
    #expect(harness.state.health.rootIssues == [Self.rootB: .missing])
  }

  @Test func aRootHealthWithoutAnOriginIsConfigured() {
    #expect(RootHealth(path: Self.rootA, status: .missing).origin == .configured)
  }

  @Test func missingRootWarnsOncePerEpisode() {
    var harness = H()
    #expect(
      roots(&harness, [(Self.rootA, .ok), (Self.rootB, .missing)], at: 0) == [
        Self.warning("rootMissing", root: Self.rootB)
      ])
    #expect(roots(&harness, [(Self.rootA, .ok), (Self.rootB, .missing)], at: 30).isEmpty)
    #expect(roots(&harness, [(Self.rootA, .ok), (Self.rootB, .ok)], at: 60) == [Self.cleared(Self.rootB)])
    #expect(roots(&harness, [(Self.rootA, .ok), (Self.rootB, .ok)], at: 90).isEmpty)
    #expect(
      roots(&harness, [(Self.rootA, .ok), (Self.rootB, .missing)], at: 120) == [
        Self.warning("rootMissing", root: Self.rootB)
      ])
  }

  @Test func unreadableRootWarnsWithItsOwnReason() {
    var harness = H()
    #expect(roots(&harness, [(Self.rootA, .unreadable)], at: 0) == [Self.warning("rootUnreadable", root: Self.rootA)])
    #expect(roots(&harness, [(Self.rootA, .missing)], at: 30).isEmpty)
    #expect(roots(&harness, [(Self.rootA, .ok)], at: 60) == [Self.cleared(Self.rootA)])
  }

  @Test func missingAndUnreadableRootsAreKeptWithTheirOwnReason() {
    var harness = H()
    #expect(
      roots(&harness, [(Self.rootA, .unreadable), (Self.rootB, .missing)], at: 0) == [
        Self.warning("rootUnreadable", root: Self.rootA), Self.warning("rootMissing", root: Self.rootB),
      ])
    #expect(harness.state.health.rootIssues == [Self.rootA: .unreadable, Self.rootB: .missing])
    #expect(roots(&harness, [(Self.rootA, .missing), (Self.rootB, .missing)], at: 30).isEmpty)
    #expect(harness.state.health.rootIssues == [Self.rootA: .missing, Self.rootB: .missing])
  }

  @Test func aRecoveredRootIsRemovedAndTheLogLinesAreUnchanged() {
    var harness = H()
    #expect(
      roots(&harness, [(Self.rootA, .ok), (Self.rootB, .missing)], at: 0) == [
        Self.warning("rootMissing", root: Self.rootB)
      ])
    #expect(harness.state.health.rootIssues == [Self.rootB: .missing])
    #expect(roots(&harness, [(Self.rootA, .ok), (Self.rootB, .ok)], at: 60) == [Self.cleared(Self.rootB)])
    #expect(harness.state.health.rootIssues.isEmpty)
    #expect(harness.state.health.warnedRoots.isEmpty)
  }

  @Test func aRootNoLongerReportedLeavesTheIssuesButKeepsItsLogEpisode() {
    var harness = H()
    _ = roots(&harness, [(Self.rootA, .ok), (Self.rootB, .missing)], at: 0)
    #expect(roots(&harness, [(Self.rootA, .ok)], at: 30).isEmpty)
    #expect(harness.state.health.rootIssues.isEmpty)
    #expect(harness.state.health.warnedRoots == [Self.rootB])
    #expect(roots(&harness, [(Self.rootA, .ok), (Self.rootB, .missing)], at: 60).isEmpty)
    #expect(harness.state.health.rootIssues == [Self.rootB: .missing])
  }

  @Test func rootIssuesKeepTheFullPathWhileTheLogKeepsItsBoundedField() {
    var harness = H()
    let long = "/Users/dev/" + String(repeating: "a", count: Health.maxLoggedRootLength + 40)
    let effects = harness.send(.transcriptRoots([RootHealth(path: long, status: .missing)]), at: 0)
    let logged = Reducer.loggable(long, limit: Health.maxLoggedRootLength)
    #expect(logged != long)
    #expect(Self.warnings(effects) == [Self.warning("rootMissing", root: logged)])
    #expect(harness.state.health.rootIssues == [long: .missing])
  }

  @Test func silenceStaysInSilenceWarnedAndNeverInRootIssues() {
    var harness = H()
    let start = harness.instant(-3600)
    _ = harness.send(Self.terminal([start]), at: 0)
    #expect(Self.warnings(harness.send(Self.terminal([start]), at: 600)) == [Self.silence])
    #expect(harness.state.health.silenceWarned)
    #expect(harness.state.health.rootIssues.isEmpty)
  }

  @Test func healthyRootsLogNothing() {
    var harness = H()
    #expect(roots(&harness, [(Self.rootA, .ok), (Self.rootB, .ok)], at: 0).isEmpty)
    #expect(harness.state.health.warnedRoots.isEmpty)
    #expect(harness.state.health.rootIssues.isEmpty)
  }

  @Test func rootPathsAreSanitizedBeforeLogging() {
    var harness = H()
    let effects = harness.send(.transcriptRoots([RootHealth(path: "/tmp/evil\nWANT on", status: .missing)]), at: 0)
    #expect(Self.warnings(effects) == [Self.warning("rootMissing", root: "/tmp/evil?WANT on")])
  }

  @Test func silenceWarnsAtExactlySixHundredSecondsAfterTheEngineStarted() {
    var harness = H()
    let start = harness.instant(-3600)
    _ = harness.send(Self.terminal([start]), at: 0)
    #expect(harness.state.startedAt == harness.instant(0))
    #expect(Self.warnings(harness.send(Self.terminal([start]), at: 599.999)).isEmpty)
    #expect(Self.warnings(harness.send(Self.terminal([start]), at: 600)) == [Self.silence])
    #expect(Self.warnings(harness.send(Self.terminal([start]), at: 602)).isEmpty)
    #expect(harness.state.health.silenceWarned)
  }

  @Test func silenceIsMeasuredFromTheProcessStartWhenItIsLater() {
    var harness = H()
    _ = harness.tick(at: 0)
    let start = harness.instant(100)
    #expect(Self.warnings(harness.send(Self.terminal([start]), at: 699.999)).isEmpty)
    #expect(Self.warnings(harness.send(Self.terminal([start]), at: 700)) == [Self.silence])
  }

  @Test func anyTranscriptEventSinceTheStartPreventsTheWarning() {
    for entrypoint in [nil, "cli", "sdk-cli"] as [String?] {
      var harness = H()
      let start = harness.instant(-3600)
      _ = harness.send(Self.terminal([start]), at: 0)
      _ = harness.activity(writtenAt: 5, entrypoint: entrypoint, seenAt: 5)
      #expect(Self.warnings(harness.send(Self.terminal([start]), at: 900)).isEmpty)
    }
  }

  @Test func aTranscriptEventBeforeTheStartDoesNotPreventTheWarning() {
    var harness = H()
    _ = harness.activity(writtenAt: -30, seenAt: 0)
    let start = harness.instant(-10)
    _ = harness.send(Self.terminal([start]), at: 0)
    #expect(Self.warnings(harness.send(Self.terminal([start]), at: 600)) == [Self.silence])
  }

  @Test func theWarningRearmsAfterTheConditionClears() {
    var harness = H()
    let start = harness.instant(-3600)
    _ = harness.send(Self.terminal([start]), at: 0)
    #expect(Self.warnings(harness.send(Self.terminal([start]), at: 600)) == [Self.silence])
    #expect(Self.warnings(harness.send(Self.terminal([]), at: 602)).isEmpty)
    #expect(!harness.state.health.silenceWarned)
    #expect(Self.warnings(harness.send(Self.terminal([start]), at: 604)) == [Self.silence])
    _ = harness.activity(writtenAt: 606, seenAt: 606)
    #expect(Self.warnings(harness.send(Self.terminal([start]), at: 608)).isEmpty)
    #expect(!harness.state.health.silenceWarned)
    let later = harness.instant(610)
    #expect(Self.warnings(harness.send(Self.terminal([start, later]), at: 1209)).isEmpty)
    #expect(Self.warnings(harness.send(Self.terminal([start, later]), at: 1210)) == [Self.silence])
  }

  @Test func noTerminalClaudeNeverWarns() {
    var harness = H()
    _ = harness.tick(at: 0)
    #expect(Self.warnings(harness.tick(at: 5000)).isEmpty)
  }

  @Test func healthOnlyEmitsDecisionsAndLeavesWantAlone() {
    var harness = H()
    let start = harness.instant(-3600)
    #expect(harness.send(Self.terminal([start]), at: 0) == [H.busy(false, source: "transcript"), H.want(false)])
    let effects = harness.send(Self.terminal([start]), at: 600)
    #expect(effects == [.log(Self.silence)])
    #expect(harness.state.want.wanted == false)
  }
}
