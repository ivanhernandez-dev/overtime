import Foundation
import Testing

@testable import OvertimeCore

struct SleepNowCommandTests {
  enum Setup: String, Sendable, CaseIterable, CustomTestStringConvertible {
    case idle
    case holdingForBusyClaude
    case paused
    case forced
    case releasedUntilIdle

    var testDescription: String { rawValue }

    func prepare(_ harness: inout ScenarioHarness) {
      _ = harness.tick(at: 0)
      switch self {
      case .idle:
        break
      case .holdingForBusyClaude:
        _ = harness.activity(writtenAt: 1, seenAt: 1)
      case .paused:
        _ = harness.send(.command(.pause(.indefinite)), at: 1)
      case .forced:
        _ = harness.send(.command(.force(.indefinite)), at: 1)
      case .releasedUntilIdle:
        _ = harness.activity(writtenAt: 1, seenAt: 1)
        _ = harness.send(.command(.releaseUntilIdle), at: 2)
      }
    }
  }

  static let logLine = Effect.log(Decision(keyword: .command, verb: "sleepNow"))

  @Test(arguments: Setup.allCases)
  func sleepNowRequestsSleepAndLeavesTheHoldAndOverridesAlone(_ setup: Setup) throws {
    var harness = ScenarioHarness()
    harness.includeActuators = true
    setup.prepare(&harness)
    let want = harness.state.want
    let hold = harness.state.hold
    let busy = harness.state.busy
    let effects = harness.send(.command(.sleepNow), at: 5)
    try #require(effects.count == 2)
    #expect(effects[0] == Self.logLine)
    guard case .requestSleep(let id) = effects[1] else {
      Issue.record("expected requestSleep, got \(effects[1])")
      return
    }
    #expect(harness.state.want == want)
    #expect(harness.state.hold == hold)
    #expect(harness.state.busy == busy)

    for outcome in [EffectOutcome.succeeded, .failed(code: 1), .timedOut] {
      _ = harness.send(.effectResult(id, outcome), at: 6)
      #expect(harness.state.want == want)
      #expect(harness.state.hold == hold)
    }
  }

  @Test func holdingSetupReallyHolds() {
    var harness = ScenarioHarness()
    Setup.holdingForBusyClaude.prepare(&harness)
    #expect(harness.state.want.wanted == true)
    #expect(harness.state.want.reason == "busy")
  }

  @Test func sleepNowBeforeTheFirstTickStillRequestsSleep() {
    var harness = ScenarioHarness()
    harness.includeActuators = true
    let effects = harness.send(.command(.sleepNow), at: 0)
    #expect(effects.first == Self.logLine)
    #expect(effects.contains { if case .requestSleep = $0 { true } else { false } })
    #expect(harness.state.want.wanted == nil)
  }

  @Test func eachSleepNowGetsItsOwnEffectID() {
    var harness = ScenarioHarness()
    harness.includeActuators = true
    _ = harness.tick(at: 0)
    let ids = [1.0, 2.0].compactMap { at -> EffectID? in
      harness.send(.command(.sleepNow), at: at).compactMap { effect -> EffectID? in
        if case .requestSleep(let id) = effect { id } else { nil }
      }.first
    }
    #expect(ids.count == 2)
    #expect(Set(ids.map(\.value)).count == 2)
  }

  @Test func theDecisionKeywordsAreTheLogVocabulary() {
    #expect(
      DecisionKeyword.allCases.map(\.rawValue) == [
        "START", "STOP", "BUSY", "WANT", "STUCK", "ENTRYPOINT", "BATTERY", "OVERRIDE", "HOLD", "LID", "DISPLAY",
        "VERIFY", "WARN", "NET", "SENTINEL", "CHECK", "ERROR", "COMMAND", "SETTINGS", "SELFTEST", "UNINSTALL",
        "TEMPERATURE",
      ])
  }

  @Test func theDecisionLineReadsCommandSleepNow() {
    #expect(DecisionKeyword.command.rawValue == "COMMAND")
  }

  @Test func wantApplyIgnoresSleepNow() {
    var state = WantState(lastBusy: Instant(nanoseconds: 5), wanted: true)
    let before = state
    let decisions = Want.apply(.sleepNow, to: &state, now: Instant(nanoseconds: 10), wall: Date())
    #expect(decisions.isEmpty)
    #expect(state == before)
  }
}
