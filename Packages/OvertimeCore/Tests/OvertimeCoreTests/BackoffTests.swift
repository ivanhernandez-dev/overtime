import Foundation
import Testing

@testable import OvertimeCore

@Suite("HOLD-08 failure backoff and error state")
struct BackoffTests {
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

  static func busyTick(_ harness: inout ScenarioHarness, at seconds: Double) -> [Effect] {
    _ = harness.activity(writtenAt: seconds, seenAt: seconds)
    return harness.tick(at: seconds)
  }

  static func failed(attempt: Int, retryIn: Int) -> Effect {
    .log(
      Decision(
        keyword: .hold, verb: "failed",
        fields: [
          DecisionField(key: "backend", value: "idle"), DecisionField(key: "attempt", value: String(attempt)),
          DecisionField(key: "retryIn", value: String(retryIn)),
        ]))
  }

  static func retry(attempt: Int) -> Effect {
    .log(
      Decision(
        keyword: .hold, verb: "retry",
        fields: [DecisionField(key: "backend", value: "idle"), DecisionField(key: "attempt", value: String(attempt))]
      ))
  }

  static let errorHold = Effect.log(
    Decision(keyword: .error, verb: "hold", fields: [DecisionField(key: "backend", value: "idle")]))
  static let recovered = Effect.log(Decision(keyword: .hold, verb: "recovered"))

  static func acquireID(_ harness: inout ScenarioHarness, at seconds: Double) -> EffectID? {
    idle(busyTick(&harness, at: seconds)).first?.1
  }

  @Test func aFailedAcquireBacksOffTwentySecondsAndRaisesTheErrorOnce() throws {
    var harness = Self.harness()
    let id = try #require(Self.acquireID(&harness, at: 0))
    let effects = harness.send(.effectResult(id, .failed(code: -536_870_199)), at: 0)
    #expect(effects == [Self.failed(attempt: 1, retryIn: 20), Self.errorHold])
    #expect(harness.state.hold.idle == .failed(attempts: 1, retryAt: harness.instant(20)))
    #expect(harness.state.hold.errorActive)
    #expect(Reducer.nextDeadline(harness.state, harness.settings) == harness.instant(20))
    for second in stride(from: 2.0, through: 18.0, by: 2.0) {
      #expect(Self.idle(Self.busyTick(&harness, at: second)).isEmpty)
    }
    #expect(Self.idle(Self.busyTick(&harness, at: 19.999)).isEmpty)
    let retry = Self.busyTick(&harness, at: 20)
    let retries = Self.idle(retry)
    #expect(retries.count == 1)
    #expect(retries.first?.0 == .acquireOrRenew(timeoutSeconds: 300))
    #expect(retry.contains(Self.retry(attempt: 2)))
    if let retryID = retries.first?.1 {
      #expect(harness.state.hold.idle == .acquiring(retryID))
    }
  }

  @Test func consecutiveFailuresRetryAfter20_40_80_160_300_300() throws {
    var harness = Self.harness()
    var id = try #require(Self.acquireID(&harness, at: 0))
    var now = 0.0
    var errorLines = 0
    for (index, delay) in [20, 40, 80, 160, 300, 300].enumerated() {
      let outcome: EffectOutcome = index.isMultiple(of: 2) ? .failed(code: 1) : .timedOut
      let effects = harness.send(.effectResult(id, outcome), at: now)
      errorLines += effects.filter { $0 == Self.errorHold }.count
      #expect(effects.contains(Self.failed(attempt: index + 1, retryIn: delay)))
      #expect(harness.state.hold.idle == .failed(attempts: index + 1, retryAt: harness.instant(now + Double(delay))))
      #expect(Self.idle(Self.busyTick(&harness, at: now + Double(delay) - 0.5)).isEmpty)
      now += Double(delay)
      let retry = Self.busyTick(&harness, at: now)
      #expect(retry.contains(Self.retry(attempt: index + 2)))
      id = try #require(Self.idle(retry).first?.1)
    }
    #expect(errorLines == 1)
    #expect(harness.state.hold.errorActive)
  }

  @Test func oneSuccessResetsTheStreakAndClearsTheError() throws {
    var harness = Self.harness()
    let first = try #require(Self.acquireID(&harness, at: 0))
    _ = harness.send(.effectResult(first, .timedOut), at: 0)
    let second = try #require(Self.idle(Self.busyTick(&harness, at: 20)).first?.1)
    _ = harness.send(.effectResult(second, .failed(code: 1)), at: 20)
    let third = try #require(Self.idle(Self.busyTick(&harness, at: 60)).first?.1)
    let success = harness.send(.effectResult(third, .succeeded), at: 60)
    #expect(success == [.log(Decision(keyword: .hold, verb: "idle acquired")), Self.recovered])
    #expect(harness.state.hold.idle == .held)
    #expect(!harness.state.hold.errorActive)
    let renewal = try #require(Self.idle(Self.busyTick(&harness, at: 62)).first?.1)
    let failed = harness.send(.effectResult(renewal, .failed(code: 1)), at: 62)
    #expect(failed == [Self.failed(attempt: 1, retryIn: 20), Self.errorHold])
    #expect(harness.state.hold.idle == .failed(attempts: 1, retryAt: harness.instant(82)))
  }

  @Test func aStaleResultIsIgnoredAndNeverLeavesFailed() throws {
    var harness = Self.harness()
    let first = try #require(Self.acquireID(&harness, at: 0))
    _ = harness.send(.effectResult(first, .timedOut), at: 0)
    #expect(harness.send(.effectResult(first, .succeeded), at: 5).isEmpty)
    #expect(harness.state.hold.idle == .failed(attempts: 1, retryAt: harness.instant(20)))
    #expect(harness.state.hold.errorActive)
    let second = try #require(Self.idle(Self.busyTick(&harness, at: 20)).first?.1)
    #expect(harness.send(.effectResult(first, .succeeded), at: 21).isEmpty)
    #expect(harness.state.hold.idle == .acquiring(second))
    #expect(harness.send(.effectResult(EffectID(value: 9_999), .failed(code: 1)), at: 21).isEmpty)
    #expect(harness.state.hold.idle == .acquiring(second))
  }

  @Test func wantOffWhileFailedCleansUpWithAReleaseAndNeverRetriesTheAcquire() throws {
    var harness = Self.harness()
    let first = try #require(Self.acquireID(&harness, at: 0))
    _ = harness.send(.effectResult(first, .timedOut), at: 0)
    let paused = harness.send(.command(.pause(.indefinite)), at: 5)
    let actions = Self.idle(paused)
    #expect(actions.map(\.0) == [.release])
    let releaseID = try #require(actions.first?.1)
    #expect(harness.state.hold.idle == .releasing(releaseID))
    let released = harness.send(.effectResult(releaseID, .succeeded), at: 5)
    #expect(released == [.log(Decision(keyword: .hold, verb: "idle released")), Self.recovered])
    #expect(harness.state.hold.idle == .released)
    #expect(!harness.state.hold.errorActive)
    #expect(Self.idle(Self.busyTick(&harness, at: 20)).isEmpty)
    #expect(Self.idle(Self.busyTick(&harness, at: 40)).isEmpty)
  }

  @Test func aFailedReleaseKeepsRetryingTheReleaseWithTheSameBackoff() throws {
    var harness = Self.harness()
    let first = try #require(Self.acquireID(&harness, at: 0))
    _ = harness.send(.effectResult(first, .succeeded), at: 0)
    let off = harness.tick(at: 200)
    let release = try #require(Self.idle(off).first)
    #expect(release.0 == .release)
    _ = harness.send(.effectResult(release.1, .failed(code: 1)), at: 200)
    #expect(harness.state.hold.idle == .failed(attempts: 1, retryAt: harness.instant(220)))
    #expect(Self.idle(harness.tick(at: 219)).isEmpty)
    let retry = harness.tick(at: 220)
    let again = try #require(Self.idle(retry).first)
    #expect(again.0 == .release)
    _ = harness.send(.effectResult(again.1, .timedOut), at: 220)
    #expect(harness.state.hold.idle == .failed(attempts: 2, retryAt: harness.instant(260)))
    let last = try #require(Self.idle(harness.tick(at: 260)).first)
    #expect(harness.send(.effectResult(last.1, .succeeded), at: 260).contains(Self.recovered))
    #expect(harness.state.hold.idle == .released)
  }

  @Test func backoffDelayIsCappedAtFiveMinutes() {
    #expect((1...8).map(Hold.backoffSeconds) == [20, 40, 80, 160, 300, 300, 300, 300])
  }
}
