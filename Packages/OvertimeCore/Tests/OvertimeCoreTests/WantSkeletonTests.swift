import Foundation
import Testing

@testable import OvertimeCore

struct WantSkeletonTests {
  let settings = Settings()
  let t0 = Instant(nanoseconds: 10_000_000_000_000)

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

  func wantDecisions(_ effects: [Effect]) -> [Decision] {
    decisions(effects).filter { $0.keyword == .want }
  }

  @Test func eligibleActivityThenTickLogsWantOnBusy() {
    var state = AppState(mode: .shadow)
    let seeded = Reducer.reduce(&state, stamp(.transcriptActivity(TranscriptActivity(at: t0)), at: t0), settings)
    #expect(seeded.isEmpty)
    let effects = Reducer.reduce(&state, stamp(.tick(TickFacts()), at: t0), settings)
    #expect(
      wantDecisions(effects) == [
        Decision(keyword: .want, verb: "on", fields: [DecisionField(key: "reason", value: "busy")])
      ])
    #expect(
      decisions(effects).first
        == Decision(keyword: .busy, verb: "on", fields: [DecisionField(key: "source", value: "transcript")]))
  }

  @Test func firstEvaluationWithoutActivityLogsWantOffIdle() {
    var state = AppState(mode: .shadow)
    let effects = Reducer.reduce(&state, stamp(.tick(TickFacts()), at: t0), settings)
    #expect(
      wantDecisions(effects) == [
        Decision(keyword: .want, verb: "off", fields: [DecisionField(key: "reason", value: "idle")])
      ])
    #expect(state.want.wanted == false)
  }

  @Test func activityOutsideTheWindowIsNotBusy() {
    var state = AppState(mode: .shadow)
    let old = t0.adding(seconds: -600)
    _ = Reducer.reduce(&state, stamp(.transcriptActivity(TranscriptActivity(at: old)), at: t0), settings)
    _ = Reducer.reduce(&state, stamp(.tick(TickFacts()), at: t0), settings)
    #expect(state.busy.busy == false)
    #expect(state.want.wanted == false)
  }

  @Test func transcriptWindowIsStrict() {
    var state = AppState(mode: .shadow)
    _ = Reducer.reduce(&state, stamp(.transcriptActivity(TranscriptActivity(at: t0)), at: t0), settings)
    _ = Reducer.reduce(&state, stamp(.tick(TickFacts()), at: t0.adding(seconds: 119.999)), settings)
    #expect(state.busy.busy == true)
    _ = Reducer.reduce(&state, stamp(.tick(TickFacts()), at: t0.adding(seconds: 120)), settings)
    #expect(state.busy.busy == false)
  }

  @Test func releaseGraceIsStrict() {
    var want = WantState()
    _ = Want.evaluate(&want, busy: true, now: t0, wall: Date(), settings: settings)
    #expect(want.wanted == true)
    let stillOn = Want.evaluate(&want, busy: false, now: t0.adding(seconds: 59.999), wall: Date(), settings: settings)
    #expect(stillOn.isEmpty)
    #expect(want.wanted == true)
    let off = Want.evaluate(&want, busy: false, now: t0.adding(seconds: 60), wall: Date(), settings: settings)
    #expect(off == [Decision(keyword: .want, verb: "off", fields: [DecisionField(key: "reason", value: "idle")])])
  }

  @Test func ignoredEntrypointIsNotEligible() {
    var state = AppState(mode: .shadow)
    let activity = TranscriptActivity(at: t0, entrypoint: "sdk-cli")
    _ = Reducer.reduce(&state, stamp(.transcriptActivity(activity), at: t0), settings)
    #expect(state.busy.lastEligibleTranscript == nil)
  }

  @Test func nextDeadlineIsTheEarliestUpcomingBoundary() {
    var state = AppState(mode: .shadow)
    _ = Reducer.reduce(&state, stamp(.transcriptActivity(TranscriptActivity(at: t0)), at: t0), settings)
    _ = Reducer.reduce(&state, stamp(.tick(TickFacts()), at: t0), settings)
    #expect(Reducer.nextDeadline(state, settings) == t0.adding(seconds: 60))
    _ = Reducer.reduce(&state, stamp(.tick(TickFacts()), at: t0.adding(seconds: 70)), settings)
    #expect(Reducer.nextDeadline(state, settings) == Instant(nanoseconds: t0.adding(seconds: 120).nanoseconds - 1))
  }

  @Test func instantArithmeticSaturates() {
    #expect(Instant(nanoseconds: 5).adding(seconds: -1).nanoseconds == 0)
    #expect(Instant(nanoseconds: UInt64.max - 1).adding(seconds: 1).nanoseconds == UInt64.max)
    #expect(Instant(nanoseconds: 1).nanoseconds(since: Instant(nanoseconds: 9)) == 0)
    #expect(Instant(nanoseconds: 0).adding(seconds: 0.0000000016).nanoseconds == 2)
  }

  @Test func decisionLineFormat() {
    let decision = Decision(
      keyword: .start, verb: "shadow",
      fields: [DecisionField(key: "once", value: "true"), DecisionField(key: "note", value: "say \"hi\" now")])
    let line = DecisionFormatter.line(
      decision, wall: Date(timeIntervalSince1970: 1_790_000_000.123), timeZone: TimeZone(secondsFromGMT: 7200)!)
    #expect(line == "2026-09-21T16:13:20.123+02:00 START shadow once=true note=\"say \\\"hi\\\" now\"")
  }

  @Test func settingsDecodeLenientlyAndResolveRoots() throws {
    let json = Data(#"{"releaseGraceSeconds": 30, "unknown": 1}"#.utf8)
    let decoded = try JSONDecoder().decode(Settings.self, from: json)
    #expect(decoded.releaseGraceSeconds == 30)
    #expect(decoded.transcriptWindowSeconds == 120)
    #expect(decoded.ignoredEntrypoints == ["sdk-*"])
    #expect(
      Settings.defaultTranscriptRoots(environment: [:], homeDirectory: "/Users/dev") == ["/Users/dev/.claude/projects"])
    #expect(
      Settings.defaultTranscriptRoots(environment: ["CLAUDE_CONFIG_DIR": "/cfg"], homeDirectory: "/Users/dev") == [
        "/Users/dev/.claude/projects", "/cfg/projects",
      ])
    #expect(
      Settings(transcriptRoots: []).resolvedTranscriptRoots(environment: [:], homeDirectory: "/h") == [
        "/h/.claude/projects"
      ])
    #expect(Settings(transcriptRoots: ["/r"]).resolvedTranscriptRoots(environment: [:], homeDirectory: "/h") == ["/r"])
  }
}
