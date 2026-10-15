import Foundation
import Testing

@testable import OvertimeCore

struct WantedSinceTests {
  @Test func theRisingEdgeOfWantedStampsTheInstant() {
    var harness = ScenarioHarness()
    _ = harness.tick(at: 0)
    #expect(harness.state.want.wanted == false)
    #expect(harness.state.want.wantedSince == nil)
    _ = harness.activity(writtenAt: 10, seenAt: 10)
    #expect(harness.state.want.wanted == true)
    #expect(harness.state.want.wantedSince == harness.instant(10))
  }

  @Test func furtherTicksWhileWantedKeepTheInstant() {
    var harness = ScenarioHarness()
    _ = harness.tick(at: 0)
    _ = harness.activity(writtenAt: 0, seenAt: 0)
    _ = harness.tick(at: 2)
    _ = harness.tick(at: 100)
    _ = harness.tick(at: 130)
    #expect(harness.state.busy.busy == false)
    #expect(harness.state.want.wanted == true)
    #expect(harness.state.want.wantedSince == harness.instant(0))
  }

  @Test func wantedFallingClearsItAndALaterRiseStampsAgain() {
    var harness = ScenarioHarness()
    _ = harness.tick(at: 0)
    _ = harness.activity(writtenAt: 0, seenAt: 0)
    #expect(harness.state.want.wanted == true)
    _ = harness.tick(at: 300)
    #expect(harness.state.want.wanted == false)
    #expect(harness.state.want.wantedSince == nil)
    _ = harness.activity(writtenAt: 400, seenAt: 400)
    #expect(harness.state.want.wantedSince == harness.instant(400))
  }

  @Test func aForceStampsTheCommandInstant() {
    var harness = ScenarioHarness()
    _ = harness.tick(at: 0)
    _ = harness.send(.command(.force(.indefinite)), at: 42)
    #expect(harness.state.want.reason == "forced")
    #expect(harness.state.want.wantedSince == harness.instant(42))
  }

  @Test func aPauseWhileWantedClearsIt() {
    var harness = ScenarioHarness()
    _ = harness.tick(at: 0)
    _ = harness.activity(writtenAt: 0, seenAt: 0)
    #expect(harness.state.want.wantedSince == harness.instant(0))
    _ = harness.send(.command(.pause(.indefinite)), at: 5)
    #expect(harness.state.want.wanted == false)
    #expect(harness.state.want.wantedSince == nil)
  }

  @Test func withWantedNeverSetItStaysNil() {
    var harness = ScenarioHarness()
    _ = harness.send(.command(.pause(.forSeconds(60))), at: 0)
    #expect(harness.state.want.wantedSince == nil)
    #expect(WantState().wantedSince == nil)
  }
}
