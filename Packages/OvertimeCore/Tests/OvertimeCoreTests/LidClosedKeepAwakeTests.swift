import Foundation
import Testing

@testable import OvertimeCore

struct LidClosedKeepAwakeTests {
  static let readings: [PowerReading?] = [
    .ac(percent: 80), .ac(percent: nil), .battery(percent: 50), .battery(percent: nil), .noBattery, nil,
  ]
  static let powerWords = ["ac", "ac", "battery", "battery", "noBattery", "unknown"]
  static let onPowerAdapterAllows = [true, true, false, false, true, false]

  static func lidClosedLine(allowed: Bool, setting: LidClosedKeepAwake, power: String) -> Decision {
    Decision(
      keyword: .hold, verb: "lidClosed",
      fields: [
        DecisionField(key: "allowed", value: allowed ? "true" : "false"),
        DecisionField(key: "setting", value: setting.rawValue),
        DecisionField(key: "power", value: power),
      ])
  }

  static let helperReleaseLine = HelperIntentTests.releaseLine(.lidClosedHoldOff)

  static func driver(_ setting: LidClosedKeepAwake) -> HoldDriver {
    var driver = HoldDriver()
    driver.harness.settings = Settings(lidClosedKeepAwake: setting)
    return driver
  }

  static func busy(_ driver: inout HoldDriver, at seconds: Double) {
    driver.send(.transcriptActivity(TranscriptActivity(at: driver.harness.instant(seconds))), at: seconds)
  }

  static func clamshells(_ batches: ArraySlice<[Effect]>) -> [StopSequenceTests.Step] {
    StopSequenceTests.steps(batches).filter {
      if case .clamshell = $0 { return true }
      return false
    }
  }

  static func writesOfOne(_ effects: some Sequence<Effect>) -> Int {
    effects.filter { effect in
      if case .clamshell(on: true, _, _) = effect { return true }
      return false
    }.count
  }

  static func lidClosedLines(_ batches: ArraySlice<[Effect]>) -> [Decision] {
    StopSequenceTests.decisions(batches).filter { $0.verb == "lidClosed" }
  }

  @Test(arguments: LidClosedKeepAwake.allCases, Array(readings.indices))
  func theThreeSettingsAllowTheLidClosedHoldAsDocumented(_ setting: LidClosedKeepAwake, _ index: Int) {
    let reading = Self.readings[index]
    let expected: Bool
    switch setting {
    case .always: expected = true
    case .never: expected = false
    case .onPowerAdapter: expected = Self.onPowerAdapterAllows[index]
    }
    #expect(setting.allows(power: reading) == expected)
    #expect(LidClosedKeepAwake.powerWord(reading) == Self.powerWords[index])
  }

  @Test func withNeverClaudeWorkKeepsTheLidOpenHoldAndNeverSetsTheClamshell() {
    var driver = Self.driver(.never)
    driver.tick(at: -2, fullWake: true)
    Self.busy(&driver, at: 0)
    for second in stride(from: 2.0, through: 30.0, by: 2.0) {
      driver.send(HelperIntentTests.tick(closed: second > 14), at: second)
    }
    let effects = driver.batches.flatMap { $0 }
    #expect(Self.writesOfOne(effects) == 0)
    #expect(driver.writes.isEmpty)
    #expect(driver.harness.state.hold.lidClose == .released)
    #expect(driver.harness.state.want.wanted == true)
    let idle = effects.contains { effect in
      if case .idleAssertion(.acquireOrRenew, _) = effect { return true }
      return false
    }
    #expect(idle)
  }

  @Test func withOnPowerAdapterTheClamshellIsSetOnlyOnPower() {
    var driver = Self.driver(.onPowerAdapter)
    driver.send(.power(.battery(percent: 50)), at: -3)
    driver.tick(at: -2, fullWake: true)
    Self.busy(&driver, at: 0)
    #expect(Self.writesOfOne(driver.batches.flatMap { $0 }) == 0)
    #expect(driver.harness.state.want.wanted == true)
    let plugged = StopSequenceTests.send(&driver, .power(.ac(percent: 50)), at: 1)
    #expect(Self.clamshells(plugged) == [.clamshell(on: true, why: .engage)])
    #expect(driver.harness.state.hold.lidClose == .held)
    let unplugged = StopSequenceTests.send(&driver, .power(.battery(percent: 49)), at: 2)
    #expect(Self.clamshells(unplugged) == [.clamshell(on: false, why: .release)])
    #expect(driver.harness.state.hold.lidClose == .released)
    let again = StopSequenceTests.send(&driver, .power(.battery(percent: 48)), at: 3)
    #expect(Self.clamshells(again).isEmpty)
    let replugged = StopSequenceTests.send(&driver, .power(.ac(percent: 48)), at: 4)
    #expect(Self.clamshells(replugged) == [.clamshell(on: true, why: .engage)])
    #expect(driver.harness.state.hold.lidClose == .held)
  }

  @Test func withOnPowerAdapterAndNoPowerReadingTheClamshellIsNotSet() {
    var driver = Self.driver(.onPowerAdapter)
    driver.tick(at: -2, fullWake: true)
    Self.busy(&driver, at: 0)
    for second in stride(from: 2.0, through: 20.0, by: 2.0) {
      driver.tick(at: second, fullWake: true)
    }
    #expect(Self.writesOfOne(driver.batches.flatMap { $0 }) == 0)
    #expect(driver.harness.state.want.wanted == true)
    let power = StopSequenceTests.send(&driver, .power(.noBattery), at: 21)
    #expect(Self.clamshells(power) == [.clamshell(on: true, why: .engage)])
    #expect(driver.harness.state.hold.lidClose == .held)
  }

  @Test func anUnplugWhileTheEngageIsInFlightClearsIt() throws {
    var harness = ScenarioHarness(settings: Settings(lidClosedKeepAwake: .onPowerAdapter), mode: .live)
    harness.includeActuators = true
    _ = harness.send(.tick(TickFacts(agents: HoldDriver.busyAgents, fullWake: true)), at: -2)
    _ = harness.send(.power(.ac(percent: 50)), at: -1)
    let busy = harness.send(.transcriptActivity(TranscriptActivity(at: harness.instant(0))), at: 0)
    let engage = try #require(
      busy.compactMap { effect -> EffectID? in
        if case .clamshell(on: true, let id, .engage) = effect { return id }
        return nil
      }.first)
    #expect(harness.state.hold.lidClose == .acquiring(engage))
    let unplugged = harness.send(.power(.battery(percent: 50)), at: 1)
    let clear = try #require(
      unplugged.compactMap { effect -> EffectID? in
        if case .clamshell(on: false, let id, .release) = effect { return id }
        return nil
      }.first)
    #expect(Self.writesOfOne(unplugged) == 0)
    let late = harness.send(.effectResult(engage, .succeeded), at: 2)
    #expect(Self.writesOfOne(late) == 0)
    #expect(harness.state.hold.lidClose == .releasing(clear))
    _ = harness.send(.effectResult(clear, .succeeded), at: 3)
    #expect(harness.state.hold.lidClose == .released)
  }

  @Test func aChangeOfTheSettingWhileHeldReleasesAtTheNextEvent() {
    var driver = HoldDriver.engaged()
    driver.tick(at: 2, fullWake: true)
    #expect(driver.harness.state.hold.lidClose == .held)
    driver.harness.settings.lidClosedKeepAwake = .never
    let effects = driver.harness.send(.tick(TickFacts(agents: HoldDriver.busyAgents, fullWake: true)), at: 4)
    #expect(
      ScenarioHarness.decisions(effects).filter { $0.verb == "lidClosed" } == [
        Self.lidClosedLine(allowed: false, setting: .never, power: "unknown")
      ])
    let clears = effects.filter { effect in
      if case .clamshell(on: false, _, .release) = effect { return true }
      return false
    }
    #expect(clears.count == 1)
    #expect(!effects.contains { if case .idleAssertion(.release, _) = $0 { true } else { false } })
  }

  @Test func theLidClosedLineIsLoggedOnlyWhenTheAnswerChanges() throws {
    var driver = Self.driver(.onPowerAdapter)
    let first = StopSequenceTests.send(&driver, .power(.battery(percent: 50)), at: 0)
    let refused = Self.lidClosedLine(allowed: false, setting: .onPowerAdapter, power: "battery")
    #expect(Self.lidClosedLines(first) == [refused])
    var quiet = StopSequenceTests.send(&driver, .power(.battery(percent: 49)), at: 1)
    quiet += StopSequenceTests.send(&driver, .tick(TickFacts(fullWake: true)), at: 2)
    #expect(Self.lidClosedLines(quiet).isEmpty)
    let plugged = StopSequenceTests.send(&driver, .power(.ac(percent: 49)), at: 3)
    let allowed = Self.lidClosedLine(allowed: true, setting: .onPowerAdapter, power: "ac")
    #expect(Self.lidClosedLines(plugged) == [allowed])
    let decision = try #require(Self.lidClosedLines(plugged).first)
    let line = DecisionFormatter.line(
      decision, wall: Date(timeIntervalSince1970: 0), timeZone: TimeZone(secondsFromGMT: 0) ?? .gmt)
    #expect(line.hasSuffix(" HOLD lidClosed allowed=true setting=onPowerAdapter power=ac"))
  }

  @Test func withTheDefaultSettingNoLidClosedLineIsEverLogged() {
    var driver = HoldDriver()
    driver.tick(at: -2, fullWake: true)
    Self.busy(&driver, at: 0)
    for second in stride(from: 2.0, through: 20.0, by: 2.0) {
      driver.send(HelperIntentTests.tick(closed: second > 10), at: second)
    }
    driver.send(.power(.battery(percent: 50)), at: 21)
    driver.send(.power(.ac(percent: nil)), at: 22)
    driver.send(.power(.noBattery), at: 23)
    driver.send(HelperIntentTests.tick(closed: true), at: 24)
    driver.send(.sentinelLost, at: 25)
    driver.send(HelperIntentTests.tick(closed: false), at: 26)
    driver.send(.stop, at: 27)
    #expect(driver.decisions.count > 0)
    #expect(!driver.decisions.contains { $0.decision.verb == "lidClosed" })
  }

  @Test func aLostWatchdogClearsAndDoesNotReengageWhenTheSettingForbidsTheHold() {
    var driver = HoldDriver.engaged()
    #expect(driver.harness.state.hold.lidClose == .held)
    driver.harness.settings.lidClosedKeepAwake = .never
    let start = driver.writes.count
    let lost = driver.harness.send(.sentinelLost, at: 1)
    let clears = lost.compactMap { effect -> ClamshellWhy? in
      if case .clamshell(on: false, _, let why) = effect { return why }
      return nil
    }
    #expect(clears == [.watchdogLost])
    #expect(Self.writesOfOne(lost) == 0)
    #expect(driver.writes.count == start)

    var control = HoldDriver.engaged()
    let controlLost = control.harness.send(.sentinelLost, at: 1)
    let controlClears = controlLost.compactMap { effect -> ClamshellWhy? in
      if case .clamshell(on: false, _, let why) = effect { return why }
      return nil
    }
    #expect(controlClears == [.watchdogLost])
    #expect(controlLost.contains { if case .clamshell(on: true, _, .reassert) = $0 { true } else { false } })
  }

  @Test func aStaleHoldAtLaunchIsClearedWhenTheSettingForbidsTheHold() {
    let forbidden: [(LidClosedKeepAwake, PowerReading?)] = [(.never, nil), (.onPowerAdapter, .battery(percent: 50))]
    for (setting, reading) in forbidden {
      var driver = LaunchReclaimTests.launched(LaunchReclaimTests.owned())
      driver.harness.settings.lidClosedKeepAwake = setting
      if let reading {
        driver.send(.power(reading), at: 0.2)
      }
      LaunchReclaimTests.busyAt(&driver, 0.5)
      driver.tick(at: 1, fullWake: true)
      let steps = LaunchReclaimTests.steps(driver)
      #expect(steps.contains(.clamshell(on: false, why: .clearStale)), "\(setting)")
      #expect(driver.writes.isEmpty, "\(setting)")
      #expect(driver.harness.state.hold.lidClose == .released, "\(setting)")
    }
    var driver = LaunchReclaimTests.launched(LaunchReclaimTests.owned())
    driver.harness.settings.lidClosedKeepAwake = .onPowerAdapter
    driver.send(.power(.ac(percent: 50)), at: 0.2)
    LaunchReclaimTests.busyAt(&driver, 0.5)
    driver.tick(at: 1, fullWake: true)
    #expect(driver.writeTimes(.reclaim) == [1])
    #expect(LaunchReclaimTests.clears(driver).isEmpty)
    #expect(driver.harness.state.hold.lidClose == .held)
  }

  @Test func stopReleasesTheLidClosedHoldUnderEverySetting() throws {
    for setting in LidClosedKeepAwake.allCases {
      var driver = HoldDriver.engaged()
      try #require(driver.harness.state.hold.lidClose == .held)
      driver.harness.settings.lidClosedKeepAwake = setting
      let steps = StopSequenceTests.steps(StopSequenceTests.send(&driver, .stop, at: 5))
      let clear = try #require(steps.firstIndex(of: .clamshell(on: false, why: .release)), "\(setting)")
      let bye = try #require(steps.firstIndex(of: .sentinel(.bye)), "\(setting)")
      #expect(clear < bye, "\(setting)")
      #expect(driver.harness.state.hold.lidClose == .released, "\(setting)")
    }
  }

  @Test func theHelperIsNotDesiredWhenTheLidClosedSettingForbidsTheHold() {
    let never = HelperIntentTests.working(lidClosed: true, settings: Settings(lidClosedKeepAwake: .never))
    #expect(!HelperIntent.desired(never.harness.state, settings: never.harness.settings))
    #expect(never.harness.state.helper.phase == .idle)

    var adapter = HelperIntentTests.working(lidClosed: true, settings: Settings(lidClosedKeepAwake: .onPowerAdapter))
    #expect(!HelperIntent.desired(adapter.harness.state, settings: adapter.harness.settings))
    adapter.send(.power(.battery(percent: 80)), at: 2)
    #expect(!HelperIntent.desired(adapter.harness.state, settings: adapter.harness.settings))
    adapter.send(.power(.ac(percent: 80)), at: 3)
    #expect(HelperIntent.desired(adapter.harness.state, settings: adapter.harness.settings))

    let always = HelperIntentTests.working(lidClosed: true, settings: Settings(lidClosedKeepAwake: .always))
    #expect(HelperIntent.desired(always.harness.state, settings: always.harness.settings))
    #expect(always.harness.state.helper.phase == .engaged)
  }

  @Test func unpluggingWithOnPowerAdapterReleasesAnEngagedHelperFirst() throws {
    var driver = Self.driver(.onPowerAdapter)
    driver.send(.helperFacts(HelperIntentTests.ready), at: -6)
    driver.send(.power(.ac(percent: 80)), at: -5)
    driver.send(HelperIntentTests.tick(closed: true), at: -2)
    Self.busy(&driver, at: 0)
    try #require(driver.harness.state.helper.phase == .engaged)
    try #require(driver.harness.state.hold.lidClose == .held)
    let effects = driver.harness.send(.power(.battery(percent: 80)), at: 5)
    guard case .helper(.release, let id, _)? = effects.first else {
      Issue.record("the batch does not start with a helper release: \(effects)")
      return
    }
    let decisions = ScenarioHarness.decisions(effects)
    #expect(decisions.contains(Self.helperReleaseLine))
    #expect(decisions.contains(Self.lidClosedLine(allowed: false, setting: .onPowerAdapter, power: "battery")))
    let own = try #require(HelperIntentTests.ownClear(in: effects))
    #expect(own > 0)
    #expect(HelperIntentTests.helperActions(effects) == [.release])
    #expect(driver.harness.state.helper.phase == .releasing(id))
  }
}
