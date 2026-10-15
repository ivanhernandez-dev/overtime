import Foundation
import Testing

@testable import OvertimeCore

struct ReleaseTimingTests {
  typealias H = ScenarioHarness

  @Test(arguments: [0.0, 0.5, 1.0, 1.999])
  func twoSecondTicksReleaseBetween178And180SecondsAfterTheWrite(phase: Double) {
    var harness = H()
    var releasedAt: Double?
    var sawWantOn = false
    var sent = false
    var index = 0
    while releasedAt == nil && index < 200 {
      let at = Double(index) * 2
      var wants: [Decision] = []
      if !sent && at >= phase {
        let activity = harness.activity(writtenAt: phase, seenAt: phase)
        #expect(activity == (at == phase ? [] : [H.busy(true, source: "transcript"), H.want(true)]))
        wants = H.wantLines(activity)
        sent = true
      }
      wants += H.wantLines(harness.tick(at: at))
      if wants.contains(where: { $0.verb == "on" }) {
        sawWantOn = true
      } else if sawWantOn && wants.contains(where: { $0.verb == "off" }) {
        releasedAt = at
      }
      index += 1
    }
    #expect(sawWantOn)
    guard let releasedAt else {
      Issue.record("WANT off never logged")
      return
    }
    #expect(releasedAt >= phase + 178)
    #expect(releasedAt <= phase + 180)
  }

  @Test func steppingOnlyAtReducerDeadlinesReleasesWithinTheSameBounds() {
    var harness = H()
    #expect(harness.activity(writtenAt: 0, seenAt: 0) == [])
    #expect(harness.tick(at: 0) == [H.busy(true, source: "transcript"), H.want(true)])
    var releasedAt: Double?
    var steps = 0
    while releasedAt == nil && steps < 50, let deadline = Reducer.nextDeadline(harness.state, harness.settings) {
      let at = harness.seconds(deadline)
      if H.wantLines(harness.tick(at: at)).contains(where: { $0.verb == "off" }) {
        releasedAt = at
      }
      steps += 1
    }
    guard let releasedAt else {
      Issue.record("WANT off never reached through deadlines")
      return
    }
    #expect(releasedAt >= 178)
    #expect(releasedAt <= 180)
    #expect(steps <= 6)
  }

  @Test func nextDeadlineIncludesTheLastBusyInstantOfTheWindow() {
    var harness = H()
    _ = harness.activity(writtenAt: 0, seenAt: 0)
    _ = harness.tick(at: 100)
    let lastInside = Instant(nanoseconds: harness.instant(120).nanoseconds - 1)
    #expect(Reducer.nextDeadline(harness.state, harness.settings) == lastInside)
  }

  @Test func nothingPendingMeansNoDeadline() {
    var harness = H()
    _ = harness.tick(at: 0)
    #expect(Reducer.nextDeadline(harness.state, harness.settings) == nil)
  }
}
