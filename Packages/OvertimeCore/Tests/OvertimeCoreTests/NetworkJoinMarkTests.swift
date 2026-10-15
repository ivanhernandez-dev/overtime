import Foundation
import Testing

@testable import OvertimeCore

@Suite("A join Overtime started is recorded from the facts")
struct NetworkJoinMarkTests {
  static func persistsMark(_ effects: [Effect], _ value: Bool) -> Bool {
    effects.contains { effect in
      if case .persist(let state) = effect { return state.hotspotJoinStarted == value }
      return false
    }
  }

  @Test func startingAJoinPersistsTheMark() {
    var driver = NetworkScenarios.stableDriver()
    NetworkScenarios.offlineThreeTimes(&driver)
    #expect(driver.actions.map(\.effect) == [.joinHotspot("Test iPhone")])
    #expect(driver.harness.state.persisted.hotspotJoinStarted)
    let joinBatch = driver.batches.first { $0.effects.contains(.net(.joinHotspot("Test iPhone"))) }
    #expect(Self.persistsMark(joinBatch?.effects ?? [], true))
    #expect(driver.harness.state.persisted.switchedToHotspot == false)
  }

  @Test func aJoinThatLandsAfterTheLidOpenedIsRecordedAndTheMacIsReturned() {
    var driver = NetworkFailoverTests.joiningDriver()
    driver.lidClosed = false
    driver.tick(at: 26)
    driver.tick(at: 28)
    #expect(driver.harness.state.network.phase == .idle)
    #expect(driver.harness.state.persisted.switchedToHotspot == false)
    driver.onHotspot = true
    let landed = driver.tick(at: 29)
    #expect(driver.harness.state.persisted.switchedToHotspot)
    #expect(ScenarioHarness.decisions(landed).contains(NetDriver.connected))
    #expect(driver.harness.state.persisted.hotspotJoinStarted == false)
    driver.tick(at: 30)
    #expect(driver.actions.map(\.effect) == [.joinHotspot("Test iPhone"), .cycleWifi])
    #expect(driver.times(.cycleWifi) == [30])
    #expect(driver.netLines.contains(NetDriver.lidOpened))
  }

  @Test func aJoinThatLandsAfterKeepAwakeDroppedIsRecordedForTheLidOpenReturn() {
    var driver = NetworkFailoverTests.joiningDriver()
    _ = driver.harness.send(.command(.pause(.indefinite)), at: 25)
    driver.busy = false
    driver.run(from: 26, to: 34, answering: nil)
    #expect(driver.harness.state.want.wanted == false)
    #expect(driver.harness.state.persisted.switchedToHotspot == false)
    driver.onHotspot = true
    driver.tick(at: 36)
    #expect(driver.harness.state.persisted.switchedToHotspot)
    driver.lidClosed = false
    driver.run(from: 38, to: 46, answering: nil)
    #expect(driver.actions.map(\.effect) == [.joinHotspot("Test iPhone"), .cycleWifi])
  }

  @Test func aMarkRestoredAtLaunchStillRecordsTheHotspotOnceTheFactsShowIt() {
    var driver = NetDriver()
    driver.busy = false
    _ = driver.harness.send(
      .launched(LaunchFacts(persisted: .state(PersistedState(hotspotJoinStarted: true)), bootSessionUUID: "boot")),
      at: -1)
    driver.tick(at: 0)
    #expect(driver.harness.state.persisted.switchedToHotspot == false)
    driver.onHotspot = true
    driver.tick(at: 2)
    #expect(driver.harness.state.persisted.switchedToHotspot)
    #expect(driver.harness.state.persisted.hotspotJoinStarted == false)
  }

  @Test func offTheHotspotWithTheLidOpenTheMarkClearsOnceTheJoinCanNoLongerLand() {
    var driver = NetworkFailoverTests.joiningDriver()
    let joinedAt = 24.01
    driver.lidClosed = false
    var clearedAt: Double?
    var at = 26.0
    while at <= 70 {
      driver.tick(at: at)
      if clearedAt == nil, !driver.harness.state.persisted.hotspotJoinStarted { clearedAt = at }
      at += 2
    }
    let cleared = clearedAt ?? 0
    #expect(cleared >= joinedAt + Timing.hotspotJoinLandSeconds)
    #expect(cleared < joinedAt + Timing.hotspotJoinLandSeconds + 2.1)
    driver.onHotspot = true
    driver.run(from: 72, to: 90, answering: nil)
    #expect(driver.harness.state.persisted.switchedToHotspot == false)
    #expect(driver.actions.map(\.effect) == [.joinHotspot("Test iPhone")])
  }

  @Test func withNoJoinStartedTheHotspotWithTheLidOpenIsLeftAlone() {
    var driver = NetDriver()
    driver.busy = false
    driver.lidClosed = false
    driver.onHotspot = true
    driver.run(from: 0, to: 40, answering: nil)
    #expect(driver.netEffects.isEmpty)
    #expect(driver.harness.state.persisted.switchedToHotspot == false)
  }

  @Test func theMarkRoundTripsAndAnOlderStateFileReadsWithoutIt() throws {
    let state = PersistedState(ownsHold: false, hotspotJoinStarted: true)
    #expect(StateCodec.decode(try StateCodec.encode(state)) == .state(state))
    #expect(StateCodec.decode(Data(#"{"ownsHold": false}"#.utf8)) == .state(PersistedState()))
    let garbage = #"{"ownsHold": false, "hotspotJoinStarted": "x"}"#
    #expect(StateCodec.decode(Data(garbage.utf8)) == .state(PersistedState()))
  }
}
