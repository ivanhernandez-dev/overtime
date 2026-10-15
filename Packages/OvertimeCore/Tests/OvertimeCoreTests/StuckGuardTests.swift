import Foundation
import Testing

@testable import OvertimeCore

struct StuckGuardTests {
  typealias H = ScenarioHarness

  @Test func freshCaffeinateDefersTheStuckVerdictForTwoSeconds() {
    var harness = H()
    #expect(harness.activity(writtenAt: -2400, seenAt: 0) == [])
    #expect(harness.tick(at: 0, caffeinate: true) == [H.busy(false, source: "caffeinate"), H.want(false)])
    #expect(Reducer.nextDeadline(harness.state, harness.settings) == harness.instant(2))
    #expect(harness.tick(at: 1, caffeinate: true) == [])
    #expect(harness.tick(at: 1.999, caffeinate: true) == [])
    #expect(harness.tick(at: 2, caffeinate: true) == [H.stuck])
    #expect(harness.tick(at: 4, caffeinate: true) == [])
    #expect(harness.state.busy.busy == false)
  }

  @Test func caffeinateRotationRestartsTheFreshWindow() {
    var harness = H()
    #expect(harness.tick(at: 0, caffeinate: true) == [H.busy(false, source: "caffeinate"), H.want(false)])
    #expect(harness.tick(at: 1, caffeinate: false) == [])
    #expect(harness.tick(at: 2, caffeinate: true) == [])
    #expect(harness.tick(at: 3.5, caffeinate: true) == [])
    #expect(harness.tick(at: 4, caffeinate: true) == [H.stuck])
  }

  @Test func caffeinateAloneNeverMakesBusyTrue() {
    var harness = H()
    let results = harness.ticks(from: 0, to: 600, every: 0.5, facts: H.claudeCaffeinate)
    let effects = results.flatMap(\.effects)
    #expect(results.first?.effects == [H.busy(false, source: "caffeinate"), H.want(false)])
    #expect(effects.filter { $0 == H.stuck }.count == 1)
    #expect(!effects.contains(H.busy(true, source: "caffeinate")))
    #expect(!effects.contains(H.busy(true, source: "transcript")))
    #expect(!effects.contains(H.want(true)))
    #expect(harness.state.busy.busy == false)
  }

  @Test func freshCaffeinateWithARecentTranscriptIsBusyByTheCaffeinateRule() {
    var harness = H()
    #expect(harness.activity(writtenAt: -600, seenAt: 0) == [])
    #expect(harness.tick(at: 0, caffeinate: true) == [H.busy(true, source: "caffeinate"), H.want(true)])
  }

  @Test func anActivityResetsTheOnceFlagSoALaterEpisodeLogsAgain() {
    var harness = H()
    _ = harness.tick(at: 0, caffeinate: true)
    #expect(harness.tick(at: 2, caffeinate: true) == [H.stuck])
    #expect(harness.activity(writtenAt: 10, seenAt: 10) == [H.busy(true, source: "transcript"), H.want(true)])
    #expect(harness.tick(at: 10, caffeinate: true) == [])
    #expect(harness.tick(at: 1809.999, caffeinate: true) == [])
    #expect(harness.tick(at: 1810, caffeinate: true) == [H.stuck, H.busy(false, source: "caffeinate")])
    #expect(harness.tick(at: 1812, caffeinate: true) == [])
    #expect(harness.tick(at: 1869.998, caffeinate: true) == [])
    #expect(harness.tick(at: 1869.999, caffeinate: true) == [H.want(false)])
  }

  @Test func exactlyTheStuckWindowOldIsStuck() {
    var harness = H()
    _ = harness.tick(at: -10, caffeinate: true)
    #expect(harness.activity(writtenAt: -1800, seenAt: 0) == [])
    #expect(harness.tick(at: 0, caffeinate: true) == [H.stuck])
    #expect(harness.state.busy.busy == false)
  }

  @Test func justInsideTheStuckWindowIsBusy() {
    var harness = H()
    _ = harness.tick(at: -10, caffeinate: true)
    #expect(harness.activity(writtenAt: -1799.999, seenAt: 0) == [])
    #expect(harness.tick(at: 0, caffeinate: true) == [H.busy(true, source: "caffeinate"), H.want(true)])
  }

  @Test func ignoredEntrypointsNeverFeedTheStuckWindow() {
    var harness = H()
    _ = harness.tick(at: -10, caffeinate: true)
    #expect(
      harness.activity(writtenAt: -600, entrypoint: "sdk-py", seenAt: 0) == [H.entrypoint("sdk-py", ignored: true)])
    #expect(harness.tick(at: 0, caffeinate: true) == [H.stuck])
    #expect(harness.state.busy.busy == false)
  }
}
