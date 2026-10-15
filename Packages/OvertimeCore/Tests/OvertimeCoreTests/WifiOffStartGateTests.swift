import Foundation
import Testing

@testable import OvertimeCore

@Suite("Wi-Fi off blocks only the start of a failover")
struct WifiOffStartGateTests {
  @Test func wifiTurnedOffBlocksTheJoinAndThePowerCycleButKeepsCounting() {
    var driver = NetworkScenarios.stableDriver()
    driver.wifiPowered = false
    NetworkScenarios.offlineThreeTimes(&driver)
    #expect(driver.times(.probe) == [4, 14, 24])
    #expect(driver.actions.isEmpty)
    #expect(driver.harness.state.network.fails == 3)
    #expect(driver.harness.state.network.nextTry == nil)
    #expect(driver.harness.state.network.waitSeconds == Timing.netWaitMinSeconds)
  }

  @Test func wifiTurnedOffWhileOnTheHotspotDoesNotPowerCycleEither() {
    var driver = NetworkScenarios.stableDriver()
    driver.onHotspot = true
    driver.wifiPowered = false
    NetworkScenarios.offlineThreeTimes(&driver)
    #expect(driver.actions.isEmpty)
    #expect(driver.harness.state.network.fails == 3)
  }

  @Test func wifiBackOnLetsTheNextFailedProbeJoinAtOnce() {
    var driver = NetworkScenarios.stableDriver()
    driver.wifiPowered = false
    NetworkScenarios.offlineThreeTimes(&driver)
    driver.wifiPowered = true
    driver.run(from: 26, to: 34, answering: false)
    #expect(driver.times(.probe) == [4, 14, 24, 34])
    #expect(driver.actions.map(\.effect) == [.joinHotspot(NetDriver.hotspot)])
    #expect(driver.times(.joinHotspot(NetDriver.hotspot)) == [34.01])
    #expect(driver.harness.state.network.fails == 4)
  }

  static func cycledDriver() -> NetDriver {
    var driver = NetworkFailoverTests.joiningDriver()
    driver.run(from: 26, to: 42, answering: nil)
    return driver
  }

  @Test func overtimesOwnPowerCycleKeepsItsWaitWhileWifiReadsOff() {
    var driver = Self.cycledDriver()
    #expect(driver.actions.map(\.effect) == [.joinHotspot(NetDriver.hotspot), .cycleWifi])
    guard case .waitingAfterCycle(let until) = driver.harness.state.network.phase else {
      Issue.record("expected waitingAfterCycle, got \(driver.harness.state.network.phase)")
      return
    }
    #expect(until == driver.harness.instant(58))
    driver.wifiPowered = false
    driver.run(from: 44, to: 56, answering: nil)
    #expect(driver.harness.state.network.phase == .waitingAfterCycle(until: until))
    driver.tick(at: 58)
    #expect(driver.harness.state.network.phase == .idle)
    #expect(driver.actions.count == 2)
  }

  @Test func reachingTheHotspotDuringThatWaitStillConnects() {
    var driver = Self.cycledDriver()
    driver.wifiPowered = false
    driver.tick(at: 44)
    driver.onHotspot = true
    let connected = driver.tick(at: 46)
    #expect(ScenarioHarness.decisions(connected).contains(NetDriver.connected))
    #expect(driver.harness.state.persisted.switchedToHotspot)
  }

  @Test func wifiReadingOffDoesNotAbandonAJoinInFlight() {
    var driver = NetworkFailoverTests.joiningDriver()
    driver.wifiPowered = false
    driver.run(from: 26, to: 38, answering: nil)
    #expect(driver.harness.state.network.phase == .joining(until: driver.harness.instant(40.01)))
  }
}
