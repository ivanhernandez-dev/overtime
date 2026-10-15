import Foundation
import Testing

@testable import OvertimeCore

struct ReadinessCase: Sendable, CustomTestStringConvertible {
  var label: String
  var settings: Settings
  var facts: NetworkFacts?
  var expected: NetReadiness?

  var testDescription: String { label }

  static let good = NetworkFacts(wifiInterface: "en0", onHotspot: false, wired: false, wifiPowered: true)
  static let configured = Settings(hotspot: "Test iPhone")

  static func facts(_ change: (inout NetworkFacts) -> Void) -> NetworkFacts {
    var facts = good
    change(&facts)
    return facts
  }

  static let all: [ReadinessCase] = [
    ReadinessCase(label: "facts unknown", settings: configured, facts: nil, expected: nil),
    ReadinessCase(label: "no effective hotspot", settings: Settings(), facts: good, expected: .off(.noHotspot)),
    ReadinessCase(
      label: "no Wi-Fi interface", settings: configured, facts: facts { $0.wifiInterface = nil },
      expected: .off(.noWifi)),
    ReadinessCase(label: "wired", settings: configured, facts: facts { $0.wired = true }, expected: .off(.wired)),
    ReadinessCase(
      label: "Wi-Fi off", settings: configured, facts: facts { $0.wifiPowered = false }, expected: .off(.wifiOff)),
    ReadinessCase(label: "armed, configured", settings: configured, facts: good, expected: .armed(.configured)),
    ReadinessCase(
      label: "armed, auto", settings: Settings(hotspot: "", hotspotAutoDetect: true),
      facts: facts { $0.autoHotspot = "Test iPhone" }, expected: .armed(.auto)),
    ReadinessCase(
      label: "wired and power unknown still armed", settings: configured,
      facts: facts {
        $0.wired = nil
        $0.wifiPowered = nil
      }, expected: .armed(.configured)),
    ReadinessCase(
      label: "no hotspot before no Wi-Fi", settings: Settings(),
      facts: NetworkFacts(wifiInterface: nil, wired: true, wifiPowered: false), expected: .off(.noHotspot)),
    ReadinessCase(
      label: "no Wi-Fi before wired", settings: configured,
      facts: NetworkFacts(wifiInterface: nil, wired: true, wifiPowered: false), expected: .off(.noWifi)),
    ReadinessCase(
      label: "wired before Wi-Fi off", settings: configured,
      facts: NetworkFacts(wifiInterface: "en0", wired: true, wifiPowered: false), expected: .off(.wired)),
  ]
}

struct EpisodeOffCase: Sendable, CustomTestStringConvertible {
  var reason: NetOffReason
  var settings: Settings
  var change: @Sendable (inout NetDriver) -> Void

  var testDescription: String { reason.rawValue }

  static let all: [EpisodeOffCase] = [
    EpisodeOffCase(reason: .wired, settings: ReadinessCase.configured) { $0.wired = true },
    EpisodeOffCase(reason: .noHotspot, settings: Settings(hotspot: "", hotspotAutoDetect: true)) {
      $0.autoHotspot = nil
    },
    EpisodeOffCase(reason: .noWifi, settings: ReadinessCase.configured) { $0.wifiInterface = nil },
    EpisodeOffCase(reason: .wifiOff, settings: ReadinessCase.configured) { $0.wifiPowered = false },
  ]
}

@Suite("Network failover gates")
struct NetworkGateTests {
  @Test(arguments: ReadinessCase.all)
  func readinessNamesTheFirstReasonFailoverIsOff(_ example: ReadinessCase) {
    var state = AppState(mode: .shadow)
    state.network.facts = example.facts
    #expect(NetworkFailover.readiness(state, settings: example.settings) == example.expected)
  }

  @Test func theOffReasonsAreOnlyTheOnesOvertimeDecides() {
    #expect(NetOffReason.allCases.map(\.rawValue) == ["noHotspot", "noWifi", "wired", "wifiOff"])
  }

  static func probes(_ change: (inout NetDriver) -> Void) -> [Double] {
    var driver = NetDriver()
    change(&driver)
    driver.startBusy(at: -1)
    driver.run(from: 0, to: 60, answering: nil)
    return driver.times(.probe)
  }

  static let usualProbes: [Double] = [4, 14, 24, 34, 44, 54]

  @Test func aCableWithARouterKeepsProbingOff() {
    #expect(Self.probes { $0.wired = true }.isEmpty)
  }

  @Test func noWifiInterfaceKeepsProbingOff() {
    #expect(Self.probes { $0.wifiInterface = nil }.isEmpty)
  }

  @Test func wifiTurnedOffStillProbes() {
    #expect(Self.probes { $0.wifiPowered = false } == Self.usualProbes)
  }

  @Test func anUnknownWiredStateDoesNotBlockProbing() {
    #expect(Self.probes { $0.wired = nil } == Self.usualProbes)
  }

  @Test func ticksThatDidNotReadAFullWakeNeverProbe() {
    #expect(Self.probes { $0.fullWake = nil }.isEmpty)
    #expect(Self.probes { $0.fullWake = false }.isEmpty)
    #expect(Self.probes { $0.fullWake = true } == Self.usualProbes)
  }

  @Test func aProbeResultReducedAfterSleepEntryCountsNeitherWay() {
    var control = NetworkScenarios.stableDriver()
    control.run(from: 2, to: 4, answering: nil)
    control.probeResult(online: false, at: 4.5)
    #expect(control.harness.state.network.fails == 1)

    var driver = NetworkScenarios.stableDriver()
    driver.run(from: 2, to: 4, answering: nil)
    #expect(driver.times(.probe) == [4])
    _ = driver.record(driver.harness.send(.systemWillSleep, at: 4.2), at: 4.2)
    driver.probeResult(online: false, at: 4.5)
    #expect(driver.harness.state.network.fails == 0)
  }

  @Test func afterPowerOnADarkWakeTickDoesNotProbeAndTheNextFullWakeTickDoes() {
    var driver = NetworkScenarios.stableDriver()
    driver.run(from: 2, to: 14, answering: true)
    #expect(driver.times(.probe) == [4, 14])
    _ = driver.record(driver.harness.send(.systemWillSleep, at: 15), at: 15)
    _ = driver.record(driver.harness.send(.systemHasPoweredOn, at: 40), at: 40)
    driver.fullWake = false
    driver.tick(at: 40)
    driver.tick(at: 42)
    #expect(driver.times(.probe) == [4, 14])
    driver.fullWake = true
    driver.tick(at: 44)
    #expect(driver.times(.probe) == [4, 14, 44])
  }

  @Test func aJoinDeadlinePassedDuringADarkWakeWaitsForAFullWakeToPowerCycle() {
    var driver = NetworkFailoverTests.joiningDriver()
    #expect(driver.actions.map(\.effect) == [.joinHotspot(NetDriver.hotspot)])
    driver.fullWake = false
    driver.run(from: 26, to: 60, answering: nil)
    #expect(driver.actions.map(\.effect) == [.joinHotspot(NetDriver.hotspot)])
    guard case .joining = driver.harness.state.network.phase else {
      Issue.record("expected joining, got \(driver.harness.state.network.phase)")
      return
    }
    driver.fullWake = true
    let cycled = driver.tick(at: 62)
    #expect(driver.actions.map(\.effect) == [.joinHotspot(NetDriver.hotspot), .cycleWifi])
    #expect(ScenarioHarness.decisions(cycled).contains(NetDriver.couldNotJoin))
  }

  @Test func reachingTheHotspotDuringADarkWakeStillConnects() {
    var driver = NetworkFailoverTests.joiningDriver()
    driver.fullWake = false
    driver.onHotspot = true
    let connected = driver.tick(at: 30)
    #expect(ScenarioHarness.decisions(connected).contains(NetDriver.connected))
    #expect(driver.harness.state.persisted.switchedToHotspot)
    #expect(driver.harness.state.network.phase == .idle)
  }

  static func returned(fullWake: Bool?, change: (inout NetDriver) -> Void = { _ in }) -> NetDriver {
    var driver = NetworkFailoverTests.switchedAndOpened(onHotspot: true)
    driver.fullWake = fullWake
    change(&driver)
    driver.run(from: 10, to: 30, answering: nil)
    return driver
  }

  @Test func theLidOpenReturnWaitsWhileTheLastTickReadADarkWake() {
    let driver = Self.returned(fullWake: false)
    #expect(driver.actions.isEmpty)
    #expect(driver.harness.state.persisted.switchedToHotspot)
  }

  @Test func theLidOpenReturnRunsWhenTheWakeStateIsUnknownOrFull() {
    for fullWake in [nil, true] as [Bool?] {
      var driver = Self.returned(fullWake: fullWake)
      #expect(driver.actions.map(\.effect) == [.cycleWifi])
      #expect(driver.harness.state.persisted.switchedToHotspot)
      driver.onHotspot = false
      driver.tick(at: 32)
      #expect(driver.harness.state.persisted.switchedToHotspot == false)
    }
  }

  @Test func theLidOpenReturnRunsWithACableAndWithoutKeepAwake() {
    var driver = Self.returned(fullWake: true) { $0.wired = true }
    #expect(driver.harness.state.want.wanted != true)
    #expect(driver.actions.map(\.effect) == [.cycleWifi])
    #expect(driver.netLines == [NetDriver.lidOpened])
    driver.onHotspot = false
    driver.tick(at: 32)
    #expect(driver.harness.state.persisted.switchedToHotspot == false)
  }

  @Test func aLidCloseAloneNeverJoinsTheHotspot() {
    var driver = NetworkScenarios.stableDriver()
    driver.run(from: 2, to: 60, answering: nil)
    #expect(driver.times(.probe) == [4, 14, 24, 34, 44, 54])
    #expect(driver.actions.isEmpty)
  }

  @Test func oneArmedLineIsLoggedPerLidCloseAndNonePerTick() {
    var driver = NetworkScenarios.stableDriver()
    driver.run(from: 2, to: 64, answering: true)
    #expect(driver.episodeLines == [NetDriver.armed(.configured)])
    #expect(driver.episodeTimes == [4])
    driver.lidClosed = false
    driver.tick(at: 66)
    driver.tick(at: 68)
    driver.lidClosed = true
    driver.run(from: 70, to: 100, answering: true)
    #expect(driver.episodeLines == [NetDriver.armed(.configured), NetDriver.armed(.configured)])
    #expect(driver.episodeTimes == [4, 74])
  }

  @Test func aClosedLidThatIsNotWantedLogsNothingUntilKeepAwakeIsWanted() {
    var driver = NetDriver()
    driver.busy = false
    driver.run(from: 0, to: 20, answering: nil)
    #expect(driver.episodeLines.isEmpty)
    driver.startBusy(at: 21)
    driver.run(from: 22, to: 60, answering: nil)
    #expect(driver.episodeLines == [NetDriver.armed(.configured)])
  }

  @Test(arguments: EpisodeOffCase.all)
  func eachOffReasonIsLoggedOncePerLidClose(_ example: EpisodeOffCase) {
    var driver = NetDriver(settings: example.settings)
    example.change(&driver)
    driver.startBusy(at: -1)
    driver.run(from: 0, to: 60, answering: nil)
    #expect(driver.episodeLines == [NetDriver.off(example.reason)])
  }

  @Test func nothingIsLoggedWhileTheNetworkFactsAreUnknown() {
    var driver = NetDriver()
    driver.network = false
    driver.startBusy(at: -1)
    driver.run(from: 0, to: 60, answering: nil)
    #expect(driver.episodeLines.isEmpty)
  }
}
