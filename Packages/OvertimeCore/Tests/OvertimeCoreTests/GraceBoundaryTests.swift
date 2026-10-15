import Foundation
import Testing

@testable import OvertimeCore

struct GraceBoundaryTests {
  typealias H = ScenarioHarness

  @Test func wantStaysOnUntilExactlyTheGraceAfterTheLastBusyStep() {
    var harness = H()
    #expect(harness.activity(writtenAt: -119, seenAt: 0) == [])
    #expect(harness.tick(at: 0) == [H.busy(true, source: "transcript"), H.want(true)])
    #expect(harness.state.want.lastBusy == harness.instant(0))
    #expect(harness.tick(at: 59.999) == [H.busy(false, source: "transcript")])
    #expect(harness.state.want.wanted == true)
    #expect(harness.tick(at: 60) == [H.want(false)])
  }

  @Test func transcriptExactlyTheWindowOldIsNotBusy() {
    var harness = H()
    #expect(harness.activity(writtenAt: -120, seenAt: 0) == [])
    #expect(harness.tick(at: 0) == [H.busy(false, source: "transcript"), H.want(false)])
  }

  @Test func transcriptJustInsideTheWindowIsBusy() {
    var harness = H()
    #expect(harness.activity(writtenAt: -119.999, seenAt: 0) == [])
    #expect(harness.tick(at: 0) == [H.busy(true, source: "transcript"), H.want(true)])
  }

  @Test func futureDatedActivityCountsAsBusyFromTheMomentItWasSeen() {
    var harness = H()
    #expect(harness.activity(writtenAt: 30, seenAt: 0) == [])
    #expect(harness.tick(at: 0) == [H.busy(true, source: "transcript"), H.want(true)])
    #expect(harness.state.busy.lastEligibleTranscript == harness.instant(0))
    #expect(harness.state.busy.lastTranscriptEventAt == harness.instant(0))
    #expect(harness.tick(at: 119.999) == [])
    #expect(harness.tick(at: 120) == [H.busy(false, source: "transcript")])
  }

  @Test func aFarFutureTimestampCannotPinBusy() {
    var harness = H()
    #expect(harness.activity(writtenAt: 1e9, seenAt: 0) == [])
    #expect(harness.tick(at: 0) == [H.busy(true, source: "transcript"), H.want(true)])
    #expect(harness.tick(at: 120) == [H.busy(false, source: "transcript"), H.want(false)])
  }

  @Test func busyStaysTrueWhileAnySessionOrSubagentTranscriptIsBusy() {
    var harness = H()
    #expect(harness.activity(writtenAt: 0, seenAt: 0) == [])
    #expect(harness.tick(at: 0) == [H.busy(true, source: "transcript"), H.want(true)])
    #expect(harness.activity(writtenAt: 100, seenAt: 100) == [])
    #expect(harness.activity(writtenAt: 50, seenAt: 101) == [])
    #expect(harness.tick(at: 200) == [])
    #expect(harness.tick(at: 219.999) == [])
    #expect(harness.tick(at: 220) == [H.busy(false, source: "transcript")])
  }
}
