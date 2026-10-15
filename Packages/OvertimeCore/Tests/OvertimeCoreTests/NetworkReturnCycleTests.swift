import Foundation
import Testing

@testable import OvertimeCore

@Suite("The lid-open return follows the cycle's outcome")
struct NetworkReturnCycleTests {
  static func stopped(_ reason: String) -> Decision {
    let message =
      reason == "backOnHotspot"
      ? "Still on the hotspot: macOS rejoined it, choose your usual network in the Wi-Fi menu"
      : "Still on the hotspot: turn Wi-Fi off and on to return to your usual network"
    return Decision(
      keyword: .net, verb: "return stopped",
      fields: [DecisionField(key: "reason", value: reason), DecisionField(key: "msg", value: message)])
  }

  static let stopped = stopped("adminRequired")

  static func openedOnHotspot() -> NetDriver {
    var driver = NetworkFailoverTests.switchedAndOpened(onHotspot: true)
    driver.tick(at: 10)
    driver.tick(at: 12)
    driver.tick(at: 14)
    return driver
  }

  @Test func theSwitchIsForgottenOnlyOnceTheFactsShowTheMacOffTheHotspot() {
    var driver = Self.openedOnHotspot()
    #expect(driver.times(.cycleWifi) == [14])
    #expect(driver.harness.state.persisted.switchedToHotspot)
    driver.cycleDone(.succeeded, at: 20)
    driver.run(from: 22, to: 600, answering: nil)
    #expect(driver.times(.cycleWifi) == [14])
    #expect(driver.harness.state.persisted.switchedToHotspot)
    driver.onHotspot = false
    let left = driver.tick(at: 602)
    #expect(driver.harness.state.persisted.switchedToHotspot == false)
    #expect(NetDriver.persistsSwitched(left, false))
  }

  @Test(arguments: [NetCycleOutcome.failed, .refused])
  func aReturnThatDidNotGetThroughRetriesWithTheBackOff(_ outcome: NetCycleOutcome) {
    var driver = Self.openedOnHotspot()
    var answers = [15.0]
    var at = 15.0
    driver.cycleDone(outcome, at: at)
    while at < 1200 {
      at += 2
      let effects = driver.tick(at: at)
      if effects.contains(.net(.cycleWifi)) {
        answers.append(at + 0.5)
        driver.cycleDone(outcome, at: at + 0.5)
      }
    }
    let retries = Array(driver.times(.cycleWifi).dropFirst())
    #expect(retries.count >= 4)
    let waits: [Double] = [90, 180, 300, 300]
    for (index, wait) in waits.enumerated() where index < retries.count {
      #expect(retries[index] >= answers[index] + wait)
      #expect(retries[index] < answers[index] + wait + 2.1)
    }
    #expect(driver.harness.state.persisted.switchedToHotspot)
  }

  @Test func anAdministratorRefusalStopsTheRetriesAndIsLoggedOnce() {
    var driver = Self.openedOnHotspot()
    let refused = driver.cycleDone(.adminRequired, at: 15)
    #expect(ScenarioHarness.decisions(refused) == [Self.stopped])
    #expect(driver.harness.state.network.returnCycle == .stopped(.adminRequired))
    driver.run(from: 16, to: 900, answering: nil)
    #expect(driver.times(.cycleWifi) == [14])
    #expect(driver.netLines.filter { $0 == Self.stopped }.count == 1)
    #expect(driver.harness.state.persisted.switchedToHotspot)
    driver.onHotspot = false
    driver.tick(at: 902)
    #expect(driver.harness.state.persisted.switchedToHotspot == false)
  }

  static func answerEachCycle(
    _ driver: inout NetDriver, with outcomes: [NetCycleOutcome], from start: Double, to end: Double
  ) -> [Double] {
    var outcomes = outcomes
    var answered: [Double] = []
    var at = start
    while at < end {
      at += 2
      let effects = driver.tick(at: at)
      if effects.contains(.net(.cycleWifi)), !outcomes.isEmpty {
        answered.append(at + 0.5)
        driver.cycleDone(outcomes.removeFirst(), at: at + 0.5)
      }
    }
    return answered
  }

  @Test func aSingleUnreadablePowerStateRetriesOnTheBackOffAndARetryThatGetsThroughReturns() {
    var driver = Self.openedOnHotspot()
    #expect(ScenarioHarness.decisions(driver.cycleDone(.powerUnknown, at: 15)).isEmpty)
    guard case .retryAt = driver.harness.state.network.returnCycle else {
      Issue.record("expected a retry, got \(driver.harness.state.network.returnCycle)")
      return
    }
    let answered = Self.answerEachCycle(&driver, with: [.succeeded], from: 15, to: 105)
    let retries = Array(driver.times(.cycleWifi).dropFirst())
    #expect(retries.count == 1)
    #expect(retries.first.map { $0 >= 15 + 90 && $0 < 15 + 90 + 2.1 } == true)
    #expect(answered.count == 1)
    #expect(driver.harness.state.network.returnCycle == .done)
    #expect(!driver.netLines.contains { $0.verb == "return stopped" })
    driver.onHotspot = false
    driver.tick(at: 108)
    #expect(driver.harness.state.persisted.switchedToHotspot == false)
  }

  @Test func threeUnreadablePowerStatesInARowStopTheReturnAndAreLoggedOnce() {
    var driver = Self.openedOnHotspot()
    #expect(ScenarioHarness.decisions(driver.cycleDone(.powerUnknown, at: 15)).isEmpty)
    let answered = Self.answerEachCycle(&driver, with: [.powerUnknown, .powerUnknown], from: 15, to: 1200)
    #expect(answered.count == 2)
    #expect(driver.times(.cycleWifi).count == 3)
    #expect(driver.harness.state.network.returnCycle == .stopped(.powerUnknown))
    #expect(driver.netLines.filter { $0.verb == "return stopped" } == [Self.stopped("powerUnknown")])
    #expect(driver.harness.state.persisted.switchedToHotspot)
  }

  @Test func anotherOutcomeBetweenUnreadablePowerStatesStartsTheCountAgain() {
    var driver = Self.openedOnHotspot()
    driver.cycleDone(.powerUnknown, at: 15)
    let outcomes: [NetCycleOutcome] = [.powerUnknown, .failed, .powerUnknown, .powerUnknown]
    let answered = Self.answerEachCycle(&driver, with: outcomes, from: 15, to: 1500)
    #expect(answered.count == 4)
    #expect(driver.times(.cycleWifi).count == 6)
    #expect(driver.harness.state.network.returnCycle == .inFlight)
    #expect(!driver.netLines.contains { $0.verb == "return stopped" })
  }

  @Test func aNewLidOpenStartsTheUnreadableCountAgain() {
    var driver = Self.openedOnHotspot()
    driver.cycleDone(.powerUnknown, at: 15)
    _ = Self.answerEachCycle(&driver, with: [.powerUnknown], from: 15, to: 200)
    driver.lidClosed = true
    driver.run(from: 202, to: 220, answering: nil)
    driver.lidClosed = false
    let before = driver.times(.cycleWifi).count
    let answered = Self.answerEachCycle(&driver, with: [.powerUnknown, .powerUnknown], from: 220, to: 900)
    #expect(answered.count == 2)
    #expect(driver.times(.cycleWifi).count == before + 3)
    #expect(driver.harness.state.network.returnCycle == .inFlight)
    #expect(!driver.netLines.contains { $0.verb == "return stopped" })
  }

  @Test func aReturnThatSucceededButLandedBackOnTheHotspotStopsAndIsLoggedOnce() {
    var driver = Self.openedOnHotspot()
    #expect(ScenarioHarness.decisions(driver.cycleDone(.succeeded, at: 15)).isEmpty)
    #expect(driver.harness.state.network.returnCycle == .done)
    driver.run(from: 16, to: 900, answering: nil)
    #expect(driver.times(.cycleWifi) == [14])
    #expect(driver.netLines.filter { $0.verb == "return stopped" } == [Self.stopped("backOnHotspot")])
    #expect(driver.harness.state.network.returnCycle == .stopped(.backOnHotspot))
    #expect(driver.harness.state.persisted.switchedToHotspot)
    driver.onHotspot = false
    driver.tick(at: 902)
    #expect(driver.harness.state.persisted.switchedToHotspot == false)
    #expect(driver.harness.state.network.returnCycle == .idle)
  }

  @Test func aReturnStillRetryingOrInFlightIsNotStopped() {
    var driver = Self.openedOnHotspot()
    #expect(driver.harness.state.network.returnCycle == .inFlight)
    driver.cycleDone(.failed, at: 15)
    driver.run(from: 16, to: 60, answering: nil)
    guard case .retryAt = driver.harness.state.network.returnCycle else {
      Issue.record("expected a retry, got \(driver.harness.state.network.returnCycle)")
      return
    }
    #expect(!driver.netLines.contains { $0.verb == "return stopped" })
  }

  @Test func aNewLidOpenStartsTheReturnAfresh() {
    var driver = Self.openedOnHotspot()
    driver.cycleDone(.adminRequired, at: 15)
    driver.lidClosed = true
    driver.run(from: 16, to: 30, answering: nil)
    driver.lidClosed = false
    driver.run(from: 32, to: 40, answering: nil)
    #expect(driver.times(.cycleWifi) == [14, 36])
  }

  @Test func theOutcomeOfAnEarlierLidClosedCycleIsNotTakenForTheReturns() {
    var driver = NetworkScenarios.stableDriver()
    NetworkScenarios.offlineThreeTimes(&driver)
    driver.onHotspot = true
    driver.tick(at: 26)
    #expect(driver.harness.state.persisted.switchedToHotspot)
    driver.run(from: 28, to: 130, answering: false)
    let closedCycle = driver.times(.cycleWifi)
    #expect(closedCycle.count == 1)
    driver.lidClosed = false
    driver.run(from: 132, to: 136, answering: nil)
    #expect(driver.times(.cycleWifi).count == 2)
    driver.cycleDone(.succeeded, at: 137)
    driver.cycleDone(.refused, at: 138)
    driver.run(from: 140, to: 240, answering: nil)
    #expect(driver.times(.cycleWifi).count == 3)
  }

  @Test func onlyLidClosedCyclesThatRanAreCounted() {
    var driver = NetworkScenarios.stableDriver()
    driver.onHotspot = true
    NetworkScenarios.offlineThreeTimes(&driver)
    #expect(driver.actions.map(\.effect) == [.cycleWifi])
    #expect(driver.harness.state.events.wifiCycles == 0)
    driver.cycleDone(.refused, at: 25)
    #expect(driver.harness.state.events.wifiCycles == 0)
    driver.cycleDone(.adminRequired, at: 25.5)
    #expect(driver.harness.state.events.wifiCycles == 0)
    driver.cycleDone(.powerUnknown, at: 25.7)
    #expect(driver.harness.state.events.wifiCycles == 0)
    driver.cycleDone(.succeeded, at: 26)
    #expect(driver.harness.state.events.wifiCycles == 1)
    driver.cycleDone(.failed, at: 27)
    #expect(driver.harness.state.events.wifiCycles == 2)
  }

  @Test func theReturnCycleIsNeverCounted() {
    var driver = Self.openedOnHotspot()
    driver.cycleDone(.succeeded, at: 15)
    #expect(driver.harness.state.events.wifiCycles == 0)
  }

  @Test func aReturnOutcomeThatArrivesAfterTheMacLeftTheHotspotIsStillTheReturns() {
    var driver = Self.openedOnHotspot()
    driver.onHotspot = false
    driver.tick(at: 16)
    #expect(driver.harness.state.persisted.switchedToHotspot == false)
    driver.cycleDone(.refused, at: 17)
    #expect(driver.harness.state.events.wifiCycles == 0)
    driver.run(from: 18, to: 400, answering: nil)
    #expect(driver.times(.cycleWifi) == [14])
  }
}
