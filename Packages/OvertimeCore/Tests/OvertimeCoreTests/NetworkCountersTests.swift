import Foundation
import Testing

@testable import OvertimeCore

@Suite("Network journal counters")
struct NetworkCountersTests {
  @Test func freshCountersStartAtZero() {
    let counters = EventCounters()
    #expect(counters.hotspotSwitches == 0)
    #expect(counters.wifiCycles == 0)
  }

  @Test func aJoinThatReachesTheHotspotCountsOneSwitch() {
    var driver = NetworkFailoverTests.joiningDriver()
    #expect(driver.harness.state.events.hotspotSwitches == 0)
    driver.onHotspot = true
    driver.tick(at: 26)
    #expect(driver.harness.state.persisted.switchedToHotspot)
    #expect(driver.harness.state.events.hotspotSwitches == 1)
    driver.run(from: 28, to: 60, answering: true)
    #expect(driver.harness.state.events.hotspotSwitches == 1)
    #expect(driver.harness.state.events.wifiCycles == 0)
  }

  @Test func aSecondConfirmedSwitchAfterALaterFailoverCountsAgain() {
    var driver = NetworkFailoverTests.joiningDriver()
    driver.onHotspot = true
    driver.tick(at: 26)
    driver.onHotspot = false
    driver.run(from: 28, to: 126, answering: false)
    #expect(driver.times(.joinHotspot(NetDriver.hotspot)).count == 2)
    #expect(driver.harness.state.events.hotspotSwitches == 1)
    driver.onHotspot = true
    driver.tick(at: 128)
    #expect(driver.harness.state.events.hotspotSwitches == 2)
  }

  @Test func aLaunchWithAPersistedSwitchCountsNothing() {
    var driver = NetDriver()
    _ = driver.harness.send(
      .launched(LaunchFacts(persisted: .state(PersistedState(switchedToHotspot: true)), bootSessionUUID: "boot")),
      at: -1)
    driver.onHotspot = true
    driver.startBusy(at: -0.5)
    driver.run(from: 0, to: 30, answering: true)
    #expect(driver.harness.state.persisted.switchedToHotspot)
    #expect(driver.harness.state.events.hotspotSwitches == 0)
    #expect(driver.harness.state.events.wifiCycles == 0)
  }

  @Test func aJoinThatDidNotLandCountsOneWifiCycle() {
    var driver = NetworkFailoverTests.joiningDriver()
    driver.run(from: 26, to: 70, answering: nil)
    #expect(driver.times(.cycleWifi).count == 1)
    #expect(driver.harness.state.events.wifiCycles == 0)
    driver.cycleDone(.succeeded, at: 71)
    #expect(driver.harness.state.events.wifiCycles == 1)
    #expect(driver.harness.state.events.hotspotSwitches == 0)
  }

  @Test func goingOfflineOnTheHotspotCountsOneWifiCycle() {
    var driver = NetworkScenarios.stableDriver()
    driver.onHotspot = true
    NetworkScenarios.offlineThreeTimes(&driver)
    #expect(driver.actions.map(\.effect) == [.cycleWifi])
    driver.cycleDone(.failed, at: 25)
    #expect(driver.harness.state.events.wifiCycles == 1)
  }

  @Test func theLidOpenReturnIsNotCounted() {
    var driver = NetworkFailoverTests.switchedAndOpened(onHotspot: true)
    driver.run(from: 10, to: 30, answering: nil)
    #expect(driver.actions.map(\.effect) == [.cycleWifi])
    #expect(driver.harness.state.events.wifiCycles == 0)
    #expect(driver.harness.state.events.hotspotSwitches == 0)
  }
}
