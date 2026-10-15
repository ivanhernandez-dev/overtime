import Foundation
import Testing

@testable import OvertimeCore

@Suite("Network failover backoff and gating")
struct NetworkFailoverTests {
  @Test func theRetryWaitDoublesFrom90To300AndCaps() {
    var driver = NetworkScenarios.stableDriver()
    var tries: [(at: Double, nextTry: Instant?, wait: Double)] = []
    var at = 2.0
    while at <= 1400 {
      let effects = driver.tick(at: at)
      if effects.contains(.net(.probe)) {
        let result = driver.probeResult(online: false, at: at + 0.01)
        if result.contains(.net(.joinHotspot("Test iPhone"))) {
          tries.append((at + 0.01, driver.harness.state.network.nextTry, driver.harness.state.network.waitSeconds))
        }
      }
      at += 2
    }
    #expect(tries.count >= 5)
    let waits = zip(tries.dropFirst(), tries).map { next, previous in
      driver.harness.seconds(previous.nextTry ?? driver.harness.t0) - previous.at
    }
    #expect(Array(waits.prefix(4)).map { ($0 * 1000).rounded() / 1000 } == [90, 180, 300, 300])
    #expect(tries.map(\.wait).prefix(4) == [180, 300, 300, 300])
    for (next, previous) in zip(tries.dropFirst(), tries) {
      let nextTry = driver.harness.seconds(previous.nextTry ?? driver.harness.t0)
      #expect(next.at >= nextTry && next.at < nextTry + 12)
    }
  }

  @Test func anOnlineResultResetsTheWaitAndLogsRestoredAfterThreeFailures() {
    var driver = NetworkScenarios.stableDriver()
    NetworkScenarios.offlineThreeTimes(&driver)
    driver.run(from: 26, to: 70, answering: nil)
    #expect(driver.harness.state.network.waitSeconds == 180)
    driver.run(from: 72, to: 80, answering: true)
    #expect(driver.harness.state.network.waitSeconds == 90)
    #expect(driver.harness.state.network.fails == 0)
    #expect(driver.netLines.filter { $0 == NetDriver.restored }.count == 1)
  }

  @Test func anOnlineResultAfterFewerThanThreeFailuresLogsNothing() {
    var driver = NetworkScenarios.stableDriver()
    driver.run(from: 2, to: 16, answering: false)
    driver.run(from: 18, to: 26, answering: true)
    #expect(driver.harness.state.network.fails == 0)
    #expect(driver.netLines.isEmpty)
  }

  @Test func alreadyOnTheHotspotAFailoverPowerCyclesInsteadOfJoining() {
    var driver = NetworkScenarios.stableDriver()
    driver.onHotspot = true
    NetworkScenarios.offlineThreeTimes(&driver)
    #expect(driver.actions.map(\.effect) == [.cycleWifi])
    #expect(driver.netLines == [NetDriver.offlineOnHotspot])
  }

  @Test func aLidOpenResetsTheFailuresAndTheWait() {
    var driver = NetworkScenarios.stableDriver()
    NetworkScenarios.offlineThreeTimes(&driver)
    driver.run(from: 26, to: 70, answering: nil)
    driver.run(from: 72, to: 90, answering: false)
    #expect(driver.harness.state.network.fails > 0)
    #expect(driver.harness.state.network.nextTry != nil)
    driver.lidClosed = false
    driver.tick(at: 92)
    #expect(driver.harness.state.network.fails == 0)
    #expect(driver.harness.state.network.nextTry == nil)
    #expect(driver.harness.state.network.waitSeconds == 90)
  }

  @Test func probingWaitsForTheLidToBeClosedForFourSeconds() {
    var driver = NetDriver()
    driver.startBusy(at: -1)
    driver.tick(at: 0)
    driver.tick(at: 2)
    #expect(driver.netEffects.isEmpty)
    driver.tick(at: 4)
    #expect(driver.times(.probe) == [4])
  }

  @Test func nothingIsProbedWhileNotWanted() {
    var driver = NetDriver()
    driver.busy = false
    driver.run(from: 0, to: 60, answering: false)
    #expect(driver.netEffects.isEmpty)
  }

  @Test func withoutNetworkFactsNoNetEffectIsEverEmitted() {
    var closed = NetworkScenarios.stableDriver()
    closed.network = false
    closed.run(from: 2, to: 200, answering: false)
    for second in stride(from: 201.0, through: 206.0, by: 1.0) {
      closed.probeResult(online: false, at: second)
    }
    #expect(closed.netEffects.isEmpty)
    #expect(closed.harness.state.persisted.switchedToHotspot == false)

    var opened = NetDriver()
    opened.network = false
    opened.busy = false
    _ = opened.harness.send(
      .launched(LaunchFacts(persisted: .state(PersistedState(switchedToHotspot: true)), bootSessionUUID: "boot")),
      at: -1)
    opened.tick(at: 0)
    opened.lidClosed = false
    opened.run(from: 10, to: 30, answering: nil)
    #expect(opened.netEffects.isEmpty)
    #expect(opened.harness.state.persisted.switchedToHotspot)
  }

  static func switchedAndOpened(onHotspot: Bool?) -> NetDriver {
    var driver = NetDriver()
    driver.busy = false
    driver.onHotspot = onHotspot ?? false
    _ = driver.harness.send(
      .launched(LaunchFacts(persisted: .state(PersistedState(switchedToHotspot: true)), bootSessionUUID: "boot")),
      at: -1)
    driver.tick(at: 0)
    driver.lidClosed = false
    return driver
  }

  @Test func anUnknownHotspotStateKeepsTheSwitchFlagUntilItIsKnown() {
    var driver = NetworkFailoverTests.switchedAndOpened(onHotspot: nil)
    for second in stride(from: 10.0, through: 30.0, by: 2.0) {
      _ = driver.record(
        driver.harness.send(
          .tick(TickFacts(lidClosed: false, network: NetworkFacts(wifiInterface: "en0", onHotspot: nil))), at: second),
        at: second)
    }
    #expect(driver.actions.isEmpty)
    #expect(driver.harness.state.persisted.switchedToHotspot)
    driver.onHotspot = true
    driver.tick(at: 32)
    #expect(driver.actions.map(\.effect) == [.cycleWifi])
    #expect(driver.harness.state.persisted.switchedToHotspot)
    driver.onHotspot = false
    driver.tick(at: 34)
    #expect(driver.harness.state.persisted.switchedToHotspot == false)
  }

  @Test func offTheHotspotAfterALidOpenTheFlagIsForgottenWithoutPowerCycling() {
    var driver = NetworkFailoverTests.switchedAndOpened(onHotspot: false)
    driver.run(from: 10, to: 30, answering: nil)
    #expect(driver.actions.isEmpty)
    #expect(driver.harness.state.persisted.switchedToHotspot == false)
  }

  static func joiningDriver() -> NetDriver {
    var driver = NetworkScenarios.stableDriver()
    NetworkScenarios.offlineThreeTimes(&driver)
    return driver
  }

  @Test func aLidOpenDuringTheJoinStopsItWithoutPowerCyclingWifi() {
    var driver = Self.joiningDriver()
    #expect(driver.actions.map(\.effect) == [.joinHotspot("Test iPhone")])
    driver.lidClosed = false
    driver.run(from: 26, to: 80, answering: nil)
    #expect(driver.harness.state.network.phase == .idle)
    #expect(driver.actions.map(\.effect) == [.joinHotspot("Test iPhone")])
    #expect(driver.harness.state.persisted.switchedToHotspot == false)
  }

  @Test func aLidOpenNotificationDuringTheJoinStopsItToo() {
    var driver = Self.joiningDriver()
    driver.lidClosed = false
    let effects = driver.record(
      driver.harness.send(.lidChanged(closed: false, sleepBit: nil, externalDisplays: nil), at: 26), at: 26)
    #expect(!effects.contains(.net(.cycleWifi)))
    #expect(driver.harness.state.network.phase == .idle)
  }

  @Test func wantDroppingDuringTheJoinStopsItWithoutPowerCyclingWifi() {
    var driver = Self.joiningDriver()
    _ = driver.harness.send(.command(.pause(.indefinite)), at: 25)
    driver.run(from: 26, to: 80, answering: nil)
    #expect(driver.harness.state.want.wanted == false)
    #expect(driver.harness.state.network.phase == .idle)
    #expect(driver.actions.map(\.effect) == [.joinHotspot("Test iPhone")])
  }

  @Test func aJoinThatReachedTheHotspotBeforeTheLidOpenedIsStillRemembered() {
    var driver = Self.joiningDriver()
    driver.onHotspot = true
    driver.lidClosed = false
    let opened = driver.tick(at: 26)
    #expect(driver.harness.state.persisted.switchedToHotspot)
    #expect(ScenarioHarness.decisions(opened).contains(NetDriver.connected))
    #expect(!opened.contains(.net(.cycleWifi)))
  }

  @Test func theNextDeadlineIncludesTheProbeAndTheJoinDeadline() {
    var driver = NetworkScenarios.stableDriver()
    driver.tick(at: 4)
    #expect(NetworkFailover.deadlines(driver.harness.state, driver.harness.settings) == [driver.harness.instant(14)])
    #expect(
      Reducer.nextDeadline(driver.harness.state, driver.harness.settings).map { $0 <= driver.harness.instant(14) }
        == true)
    driver.probeResult(online: false, at: 4.01)
    driver.run(from: 6, to: 24, answering: false)
    guard case .joining(let until) = driver.harness.state.network.phase else {
      Issue.record("expected joining, got \(driver.harness.state.network.phase)")
      return
    }
    #expect(until == driver.harness.instant(40.01))
    #expect(NetworkFailover.deadlines(driver.harness.state, driver.harness.settings) == [until])
    #expect(Reducer.nextDeadline(driver.harness.state, driver.harness.settings).map { $0 <= until } == true)
  }
}
