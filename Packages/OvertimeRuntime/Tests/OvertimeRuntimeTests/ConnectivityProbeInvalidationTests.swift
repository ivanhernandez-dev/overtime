import Foundation
import Testing

@testable import OvertimeSystem

struct ConnectivityProbeInvalidationTests {
  @Test func aFactsChangeWhileThePrimaryIsInFlightNeverTrapsAndTheCaptiveCheckStillAnswers() async {
    await #expect(processExitsWith: .success) {
      let stubbed = StubbedProbe(
        primary: .hang, captive: .respond(status: 200, body: ConnectivityProbe.successMarker), staggerSeconds: 0.3,
        budgetSeconds: 2)
      let probe = stubbed.probe
      let running = Task { await OffPool.bounded(seconds: 5) { probe.probe() } }
      try? await Task.sleep(for: .milliseconds(100))
      probe.invalidate()
      let online = await running.value
      exit(online == true ? 0 : 2)
    }
  }

  static let staggerSeconds: Double = 3.3

  @Test func theCaptiveTaskIsCancelledWhenThePrimaryAnswersFirst() async {
    let stubbed = StubbedProbe(
      primary: .respond(status: 204, body: ""), captive: .hang, staggerSeconds: Self.staggerSeconds,
      budgetSeconds: 10)
    let started = ContinuousClock.now
    #expect(await stubbed.run() == true)
    let pastTheStagger = started + .milliseconds(Int((Self.staggerSeconds + 1) * 1000))
    try? await Task.sleep(until: pastTheStagger, clock: .continuous)
    #expect(StubURLProtocol.requests(to: stubbed.captiveHost).isEmpty)
  }
}
