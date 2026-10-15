import Foundation
import Testing

@testable import OvertimeCore

struct NetDriver {
  static let hotspot = "Test iPhone"

  var harness: ScenarioHarness
  var batches: [(at: Double, effects: [Effect])] = []
  var busy = true
  var lidClosed = true
  var onHotspot = false
  var network: Bool = true
  var autoHotspot: String?
  var fullWake: Bool? = true
  var wifiInterface: String? = "en0"
  var wired: Bool?
  var wifiPowered: Bool?

  init(hotspot: String = NetDriver.hotspot) {
    self.init(settings: Settings(hotspot: hotspot))
  }

  init(settings: Settings) {
    harness = ScenarioHarness(settings: settings)
    harness.includeActuators = true
  }

  var facts: TickFacts {
    TickFacts(
      agents: busy ? ScenarioHarness.claudeCaffeinate.agents : .none, lidClosed: lidClosed, fullWake: fullWake,
      network: network ? networkFacts : nil)
  }

  var networkFacts: NetworkFacts {
    NetworkFacts(
      wifiInterface: wifiInterface, onHotspot: onHotspot, wired: wired, wifiPowered: wifiPowered,
      autoHotspot: autoHotspot)
  }

  mutating func startBusy(at seconds: Double) {
    busy = true
    _ = harness.send(.transcriptActivity(TranscriptActivity(at: harness.instant(seconds))), at: seconds)
  }

  @discardableResult
  mutating func tick(at seconds: Double) -> [Effect] {
    record(harness.send(.tick(facts), at: seconds), at: seconds)
  }

  @discardableResult
  mutating func probeResult(online: Bool, at seconds: Double) -> [Effect] {
    record(harness.send(.netProbeResult(online: online), at: seconds), at: seconds)
  }

  @discardableResult
  mutating func cycleDone(_ outcome: NetCycleOutcome, at seconds: Double) -> [Effect] {
    record(harness.send(.netCycleDone(outcome), at: seconds), at: seconds)
  }

  mutating func record(_ effects: [Effect], at seconds: Double) -> [Effect] {
    batches.append((seconds, effects))
    return effects
  }

  mutating func run(from start: Double, to end: Double, answering online: Bool?) {
    var at = start
    while at <= end {
      let effects = tick(at: at)
      if let online, effects.contains(.net(.probe)) {
        probeResult(online: online, at: at + 0.01)
      }
      at += 2
    }
  }

  var netEffects: [(at: Double, effect: NetEffect)] {
    batches.flatMap { batch in
      batch.effects.compactMap { effect -> (at: Double, effect: NetEffect)? in
        if case .net(let net) = effect { return (batch.at, net) }
        return nil
      }
    }
  }

  var actions: [(at: Double, effect: NetEffect)] {
    netEffects.filter { $0.effect != .probe }
  }

  func times(_ effect: NetEffect) -> [Double] {
    netEffects.filter { $0.effect == effect }.map(\.at)
  }

  static let episodeVerbs: Set<String> = ["armed", "off"]

  var netLines: [Decision] {
    batches.flatMap { ScenarioHarness.decisions($0.effects) }.filter {
      $0.keyword == .net && !Self.episodeVerbs.contains($0.verb)
    }
  }

  var episodeLines: [Decision] {
    batches.flatMap { ScenarioHarness.decisions($0.effects) }.filter {
      $0.keyword == .net && Self.episodeVerbs.contains($0.verb)
    }
  }

  var episodeTimes: [Double] {
    batches.filter { batch in
      ScenarioHarness.decisions(batch.effects).contains { $0.keyword == .net && Self.episodeVerbs.contains($0.verb) }
    }.map(\.at)
  }

  static func armed(_ source: HotspotSource) -> Decision {
    Decision(keyword: .net, verb: "armed", fields: [DecisionField(key: "hotspot", value: source.rawValue)])
  }

  static func off(_ reason: NetOffReason) -> Decision {
    Decision(keyword: .net, verb: "off", fields: [DecisionField(key: "reason", value: reason.rawValue)])
  }

  static func line(_ verb: String, _ message: String) -> Decision {
    Decision(keyword: .net, verb: verb, fields: [DecisionField(key: "msg", value: message)])
  }

  static let joining = joinLine(.configured)

  static func joinLine(_ source: HotspotSource) -> Decision {
    Decision(
      keyword: .net, verb: "join",
      fields: [
        DecisionField(key: "msg", value: "Offline with lid closed: joining the hotspot"),
        DecisionField(key: "hotspot", value: source.rawValue),
      ])
  }
  static let connected = line("connected", "Connected to hotspot")
  static let couldNotJoin = line("cycleWifi", "Could not join hotspot: power-cycling Wi-Fi so macOS picks a network")
  static let lidOpened = line(
    "cycleWifi", "Lid opened after switching to hotspot: power-cycling Wi-Fi to return to the best network")
  static let offlineOnHotspot = line(
    "cycleWifi", "Offline while on hotspot: power-cycling Wi-Fi in case another network is available")
  static let restored = line("restored", "Connection restored")

  static func persistsSwitched(_ effects: [Effect], _ value: Bool) -> Bool {
    effects.contains { effect in
      if case .persist(let state) = effect { return state.switchedToHotspot == value }
      return false
    }
  }
}

@Suite("Network scenarios #29-#34")
struct NetworkScenarios {
  static func stableDriver(hotspot: String = NetDriver.hotspot) -> NetDriver {
    stableDriver(settings: Settings(hotspot: hotspot))
  }

  static func stableDriver(settings: Settings, autoHotspot: String? = nil) -> NetDriver {
    var driver = NetDriver(settings: settings)
    driver.autoHotspot = autoHotspot
    driver.startBusy(at: -1)
    driver.tick(at: 0)
    return driver
  }

  static func offlineThreeTimes(_ driver: inout NetDriver) {
    driver.run(from: 2, to: 24, answering: false)
  }

  @Test("#29 two failed connectivity checks change nothing")
  func scenario29TwoFailedChecksChangeNothing() {
    var driver = Self.stableDriver()
    driver.run(from: 2, to: 16, answering: false)
    #expect(driver.times(.probe) == [4, 14])
    #expect(driver.harness.state.network.fails == 2)
    #expect(driver.actions.isEmpty)
    #expect(driver.netLines.isEmpty)
  }

  @Test("#30 a third failed check joins the hotspot and remembers the switch")
  func scenario30ThirdFailureJoinsTheHotspot() {
    var driver = Self.stableDriver()
    Self.offlineThreeTimes(&driver)
    #expect(driver.times(.probe) == [4, 14, 24])
    #expect(driver.actions.map(\.effect) == [.joinHotspot("Test iPhone")])
    #expect(driver.netLines == [NetDriver.joining])
    #expect(driver.harness.state.persisted.switchedToHotspot == false)
    driver.onHotspot = true
    let connected = driver.tick(at: 26)
    #expect(driver.harness.state.persisted.switchedToHotspot)
    #expect(NetDriver.persistsSwitched(connected, true))
    #expect(ScenarioHarness.decisions(connected).contains(NetDriver.connected))
    #expect(driver.harness.state.network.phase == .idle)
  }

  @Test("#31 a join that does not reach the hotspot power-cycles Wi-Fi and keeps the flag off")
  func scenario31FailedJoinCyclesWifi() {
    var driver = Self.stableDriver()
    Self.offlineThreeTimes(&driver)
    let joinedAt = 24.01
    driver.run(from: 26, to: 70, answering: false)
    #expect(driver.actions.map(\.effect) == [.joinHotspot("Test iPhone"), .cycleWifi])
    let cycledAt = driver.times(.cycleWifi).first ?? 0
    #expect(cycledAt >= joinedAt + 16 && cycledAt < joinedAt + 18)
    #expect(driver.netLines == [NetDriver.joining, NetDriver.couldNotJoin])
    #expect(driver.harness.state.persisted.switchedToHotspot == false)
    #expect(driver.harness.state.network.phase == .idle)
  }

  @Test("#32 connectivity checks that keep succeeding never touch the network")
  func scenario32OnlineLeavesTheNetworkAlone() {
    var driver = Self.stableDriver()
    driver.run(from: 2, to: 36, answering: true)
    #expect(driver.times(.probe) == [4, 14, 24, 34])
    #expect(driver.actions.isEmpty)
    #expect(driver.netLines.isEmpty)
  }

  @Test("#33 an empty hotspot setting disables failover entirely")
  func scenario33EmptyHotspotDisablesFailover() {
    var driver = Self.stableDriver(hotspot: "")
    driver.run(from: 2, to: 60, answering: false)
    for second in stride(from: 61.0, through: 63.0, by: 1.0) {
      driver.probeResult(online: false, at: second)
    }
    #expect(driver.netEffects.isEmpty)
    #expect(driver.netLines.isEmpty)
  }

  @Test("#34 opening the lid after a hotspot switch power-cycles Wi-Fi and forgets the switch")
  func scenario34LidOpenAfterSwitchCyclesWifi() {
    var driver = NetDriver()
    driver.busy = false
    driver.onHotspot = true
    _ = driver.harness.send(
      .launched(LaunchFacts(persisted: .state(PersistedState(switchedToHotspot: true)), bootSessionUUID: "boot")),
      at: -1)
    #expect(driver.harness.state.persisted.switchedToHotspot)
    driver.tick(at: 0)
    driver.lidClosed = false
    driver.tick(at: 10)
    driver.tick(at: 12)
    #expect(driver.actions.isEmpty)
    driver.tick(at: 14)
    #expect(driver.actions.map(\.effect) == [.cycleWifi])
    #expect(driver.times(.cycleWifi) == [14])
    #expect(driver.netLines == [NetDriver.lidOpened])
    driver.cycleDone(.succeeded, at: 15)
    driver.run(from: 16, to: 40, answering: nil)
    #expect(driver.actions.count == 1)
    driver.onHotspot = false
    let left = driver.tick(at: 42)
    #expect(driver.harness.state.persisted.switchedToHotspot == false)
    #expect(NetDriver.persistsSwitched(left, false))
    #expect(driver.actions.count == 1)
  }
}
