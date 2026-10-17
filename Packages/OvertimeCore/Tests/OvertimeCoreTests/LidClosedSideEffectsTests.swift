import Foundation
import Testing

@testable import OvertimeCore

struct LidClosedSideEffectsTests {
  static let sleepFailed = Decision(
    keyword: .verify, verb: "sleep failed", fields: [DecisionField(key: "action", value: "requestSleep")])
  static let sleepNotObserved = Decision(keyword: .error, verb: "sleep not observed")
  static let sleepOK = Decision(keyword: .verify, verb: "sleep ok")
  static let cancelledWanted = Decision(
    keyword: .verify, verb: "cancelled", fields: [DecisionField(key: "reason", value: "wanted")])

  static func closedTick(hidIdleSeconds: Double? = nil) -> Event {
    .tick(
      TickFacts(
        agents: HoldDriver.busyAgents, lidClosed: true, externalDisplays: 0, fullWake: true,
        hidIdleSeconds: hidIdleSeconds))
  }

  static func isDisplayOff(_ effect: Effect) -> Bool {
    if case .displaySleepNow = effect { return true }
    return false
  }

  static func isSleepRequest(_ effect: Effect) -> Bool {
    if case .requestSleep = effect { return true }
    return false
  }

  static func verifyLines(_ batches: ArraySlice<[Effect]>) -> [Decision] {
    StopSequenceTests.decisions(batches).filter { $0.keyword == .verify }
  }

  static func displayOffTimes(_ setting: LidClosedKeepAwake, power: PowerReading? = nil) -> [Double] {
    var driver = HoldDriver()
    driver.harness.settings = Settings(lidClosedKeepAwake: setting)
    if let power {
      driver.send(.power(power), at: -3)
    }
    driver.send(HelperIntentTests.tick(closed: false), at: -2)
    LidClosedKeepAwakeTests.busy(&driver, at: 0)
    var times: [Double] = []
    if driver.send(.lidChanged(closed: true, sleepBit: nil, externalDisplays: 0), at: 1).contains(where: isDisplayOff) {
      times.append(1)
    }
    for second in stride(from: 2.0, through: 30.0, by: 2.0) {
      if driver.send(closedTick(hidIdleSeconds: 120), at: second).contains(where: isDisplayOff) {
        times.append(second)
      }
    }
    return times
  }

  static func heldWithTheLidClosed(_ setting: LidClosedKeepAwake) -> HoldDriver {
    var driver = HoldDriver()
    driver.harness.settings = Settings(lidClosedKeepAwake: setting)
    driver.send(.power(.ac(percent: 80)), at: -5)
    driver.send(HelperIntentTests.tick(closed: true), at: -2)
    LidClosedKeepAwakeTests.busy(&driver, at: 0)
    driver.send(closedTick(), at: 2)
    driver.send(closedTick(), at: 4)
    return driver
  }

  static func closedTicks(_ driver: inout HoldDriver, from start: Double, to end: Double) -> ArraySlice<[Effect]> {
    let first = driver.batches.count
    var at = start
    while at <= end {
      driver.send(closedTick(), at: at)
      at += 2
    }
    return driver.batches[first...]
  }

  @Test func withNeverClosingTheLidWhileClaudeWorksTurnsNoDisplayOff() {
    #expect(Self.displayOffTimes(.never).isEmpty)
    #expect(Self.displayOffTimes(.always) == [1, 12, 22])
  }

  @Test func withOnPowerAdapterOnBatteryClosingTheLidTurnsNoDisplayOff() {
    #expect(Self.displayOffTimes(.onPowerAdapter, power: .battery(percent: 50)).isEmpty)
    #expect(Self.displayOffTimes(.onPowerAdapter, power: .ac(percent: 50)) == [1, 12, 22])
  }

  @Test func aReleaseForTheSettingWithTheLidClosedIsVerified() throws {
    var driver = Self.heldWithTheLidClosed(.onPowerAdapter)
    try #require(driver.harness.state.hold.lidClose == .held)
    let unplugged = StopSequenceTests.send(&driver, .power(.battery(percent: 80)), at: 10)
    #expect(LidClosedKeepAwakeTests.clamshells(unplugged) == [.clamshell(on: false, why: .release)])
    #expect(driver.harness.state.want.wanted == true)
    var later = Self.closedTicks(&driver, from: 12, to: 40)
    later += StopSequenceTests.send(&driver, Self.closedTick(), at: 41)
    let decisions = StopSequenceTests.decisions(later)
    #expect(decisions.filter { $0 == Self.sleepFailed }.count == 1)
    #expect(decisions.filter { $0 == Self.sleepNotObserved }.count == 1)
    #expect(later.flatMap { $0 }.filter(Self.isSleepRequest).count == 1)

    var observed = Self.heldWithTheLidClosed(.onPowerAdapter)
    _ = StopSequenceTests.send(&observed, .power(.battery(percent: 80)), at: 10)
    var slept = StopSequenceTests.send(&observed, .systemWillSleep, at: 12)
    slept += Self.closedTicks(&observed, from: 14, to: 40)
    slept += StopSequenceTests.send(&observed, Self.closedTick(), at: 41)
    #expect(Self.verifyLines(slept) == [Self.sleepOK])
    #expect(!slept.flatMap { $0 }.contains(where: Self.isSleepRequest))

    var control = Self.heldWithTheLidClosed(.always)
    var unchanged = StopSequenceTests.send(&control, .power(.battery(percent: 80)), at: 10)
    #expect(!LidClosedKeepAwakeTests.clamshells(unchanged).contains(.clamshell(on: false, why: .release)))
    unchanged += Self.closedTicks(&control, from: 12, to: 40)
    unchanged += StopSequenceTests.send(&control, Self.closedTick(), at: 41)
    #expect(Self.verifyLines(unchanged).isEmpty)
    #expect(!StopSequenceTests.steps(unchanged).contains(.clamshell(on: false, why: .release)))
    #expect(control.harness.state.hold.lidClose == .held)
  }

  @Test func pluggingBackInDuringTheCheckCancelsIt() throws {
    var driver = Self.heldWithTheLidClosed(.onPowerAdapter)
    try #require(driver.harness.state.hold.lidClose == .held)
    let unplugged = StopSequenceTests.send(&driver, .power(.battery(percent: 80)), at: 10)
    #expect(LidClosedKeepAwakeTests.clamshells(unplugged) == [.clamshell(on: false, why: .release)])
    let plugged = StopSequenceTests.send(&driver, .power(.ac(percent: 80)), at: 15)
    #expect(Self.verifyLines(plugged) == [Self.cancelledWanted])
    #expect(LidClosedKeepAwakeTests.clamshells(plugged) == [.clamshell(on: true, why: .engage)])
    #expect(driver.harness.state.verification == .idle)
  }

  @Test func failoverNeverProbesWhileTheLidClosedHoldIsOff() {
    let settings = Settings(hotspot: NetDriver.hotspot, lidClosedKeepAwake: .never)
    var never = NetworkScenarios.stableDriver(settings: settings)
    never.run(from: 2, to: 30, answering: nil)
    #expect(never.times(.probe).isEmpty)
    #expect(never.episodeLines.isEmpty)

    var control = NetworkScenarios.stableDriver(settings: Settings(hotspot: NetDriver.hotspot))
    control.run(from: 2, to: 30, answering: nil)
    #expect(control.times(.probe) == [4, 14, 24])
    #expect(control.episodeLines == [NetDriver.armed(.configured)])
  }

  @Test func aSleepWithTheLidClosedIsNotUnexpectedWhileTheHoldIsOff() {
    let cases: [(LidClosedKeepAwake, PowerReading?, UInt64)] = [
      (.never, nil, 0), (.onPowerAdapter, .battery(percent: 50), 0), (.always, nil, 1),
    ]
    for (setting, power, expected) in cases {
      var driver = HoldDriver()
      driver.harness.settings = Settings(lidClosedKeepAwake: setting)
      if let power {
        driver.send(.power(power), at: -3)
      }
      driver.send(HelperIntentTests.tick(closed: true), at: -2)
      LidClosedKeepAwakeTests.busy(&driver, at: 0)
      #expect(driver.harness.state.want.wanted == true, "\(setting)")
      driver.send(.systemWillSleep, at: 1)
      #expect(driver.harness.state.events.unexpectedSleeps == expected, "\(setting)")
    }
  }
}
