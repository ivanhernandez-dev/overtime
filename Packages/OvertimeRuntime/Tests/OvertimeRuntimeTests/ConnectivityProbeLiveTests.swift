import Foundation
import OvertimeSystem
import Testing

struct ConnectivityProbeLiveTests {
  static let enabled = ProcessInfo.processInfo.environment["OVERTIME_LIVE_NETWORK"] == "1"

  @Test(.enabled(if: enabled, "real requests to api.anthropic.com and captive.apple.com run only when asked for"))
  func theDefaultProbeReadsAWorkingNetworkAsOnlineWithinTheBudget() async {
    let probe = ConnectivityProbe()
    let start = ContinuousClock.now
    let online = await OffPool.bounded(seconds: 10) { probe.probe() }
    #expect(online == true)
    #expect(ContinuousClock.now - start < .milliseconds(4_600))
  }
}
