import Foundation
import Testing

@testable import OvertimeCore

@Suite("No network action once the engine is stopping")
struct NetworkStopGateTests {
  @Test func aThirdFailedProbeAfterTheStopJoinsNothing() {
    var driver = NetworkScenarios.stableDriver()
    driver.run(from: 2, to: 16, answering: false)
    #expect(driver.harness.state.network.fails == 2)
    _ = driver.record(driver.harness.send(.stop, at: 17), at: 17)
    #expect(driver.harness.state.hold.stopping)
    driver.probeResult(online: false, at: 18)
    driver.run(from: 20, to: 80, answering: false)
    #expect(driver.netEffects.filter { $0.at > 17 }.isEmpty)
    #expect(driver.netLines.isEmpty)
  }

  @Test func aJoinInProgressAtTheStopIsNeverFollowedByAPowerCycle() {
    var driver = NetworkFailoverTests.joiningDriver()
    #expect(driver.actions.map(\.effect) == [.joinHotspot("Test iPhone")])
    _ = driver.record(driver.harness.send(.stop, at: 25), at: 25)
    driver.run(from: 26, to: 80, answering: false)
    #expect(driver.actions.map(\.effect) == [.joinHotspot("Test iPhone")])
  }

  @Test func theLidOpenReturnIsNotStartedWhileStopping() {
    var driver = NetworkFailoverTests.switchedAndOpened(onHotspot: true)
    _ = driver.record(driver.harness.send(.stop, at: 9), at: 9)
    driver.run(from: 10, to: 40, answering: nil)
    #expect(driver.actions.isEmpty)
    #expect(driver.harness.state.persisted.switchedToHotspot)
  }
}
