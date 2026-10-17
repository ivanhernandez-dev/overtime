import Foundation
import Testing

@testable import OvertimeCore

struct TemperatureTests {
  static let release = 45

  static func block(_ celsius: Int) -> Decision {
    Decision(
      keyword: .temperature, verb: "block",
      fields: [
        DecisionField(key: "celsius", value: String(celsius)),
        DecisionField(key: "msg", value: "Battery at \(celsius) degrees Celsius: releasing the Mac so it can sleep"),
      ])
  }

  static func unblock(_ celsius: Int) -> Decision {
    Decision(
      keyword: .temperature, verb: "unblock",
      fields: [
        DecisionField(key: "celsius", value: String(celsius)),
        DecisionField(key: "msg", value: "Battery at \(celsius) degrees Celsius: resuming"),
      ])
  }

  static let unblockOff = Decision(
    keyword: .temperature, verb: "unblock",
    fields: [
      DecisionField(key: "reason", value: "off"),
      DecisionField(key: "msg", value: "Temperature protection off: resuming"),
    ])

  static let unblockUnavailable = Decision(
    keyword: .temperature, verb: "unblock",
    fields: [
      DecisionField(key: "reason", value: "unavailable"),
      DecisionField(key: "msg", value: "Battery temperature unavailable: resuming"),
    ])

  static let unavailable = Decision(
    keyword: .temperature, verb: "unavailable",
    fields: [
      DecisionField(key: "msg", value: "Battery temperature unavailable: temperature protection cannot act")
    ])

  static func unreadable(blocked: Bool) -> Decision {
    Decision(
      keyword: .temperature, verb: "unreadable",
      fields: [
        DecisionField(key: "blocked", value: blocked ? "true" : "false"),
        DecisionField(key: "msg", value: "Battery temperature unreadable: keeping the last state"),
      ])
  }

  static func step(
    _ state: inout TemperatureState, _ reading: BatteryTemperatureReading, enabled: Bool = true
  ) -> [Decision] {
    Temperature.step(&state, reading, enabled: enabled, release: release)
  }

  @Test func atOrAboveTheReleaseTemperatureTheBatteryBlocksWithTheBlockLine() {
    var state = TemperatureState()
    #expect(Self.step(&state, .celsius(45)) == [Self.block(45)])
    #expect(state.blocked)
    var hotter = TemperatureState()
    #expect(Self.step(&hotter, .celsius(60)) == [Self.block(60)])
    #expect(hotter.blocked)
  }

  @Test func belowTheReleaseTemperatureNothingBlocksOrLogs() {
    for celsius in [44, 0, -5] {
      var state = TemperatureState()
      #expect(Self.step(&state, .celsius(celsius)).isEmpty)
      #expect(!state.blocked)
    }
  }

  @Test(arguments: [(44, true), (41, true), (40, true), (39, false)])
  func aHotBatteryResumesOnlyBelowFiveDegreesUnderTheRelease(_ celsius: Int, _ stillBlocked: Bool) {
    var state = TemperatureState()
    _ = Self.step(&state, .celsius(Self.release))
    #expect(state.blocked)
    let decisions = Self.step(&state, .celsius(celsius))
    #expect(state.blocked == stillBlocked)
    #expect(decisions == (stillBlocked ? [] : [Self.unblock(celsius)]))
  }

  @Test func withTemperatureProtectionOffNothingBlocksAndABlockEndsWithTheOffLine() {
    var state = TemperatureState()
    #expect(Self.step(&state, .celsius(70), enabled: false).isEmpty)
    #expect(!state.blocked)
    for reading in [BatteryTemperatureReading.celsius(70), .unavailable, .unreadable] {
      var blocked = TemperatureState()
      _ = Self.step(&blocked, .celsius(50))
      #expect(blocked.blocked)
      #expect(Self.step(&blocked, reading, enabled: false) == [Self.unblockOff])
      #expect(!blocked.blocked)
      #expect(blocked.reading == reading)
    }
  }

  @Test func anUnavailableReadingNeverBlocksEndsABlockAndIsLoggedOnce() {
    var blocked = TemperatureState()
    _ = Self.step(&blocked, .celsius(50))
    #expect(Self.step(&blocked, .unavailable) == [Self.unblockUnavailable])
    #expect(!blocked.blocked)
    var fresh = TemperatureState()
    #expect(Self.step(&fresh, .unavailable) == [Self.unavailable])
    #expect(Self.step(&fresh, .unavailable).isEmpty)
    #expect(!fresh.blocked)
    #expect(fresh.reading == .unavailable)
  }

  @Test func anUnreadableReadingKeepsTheLastStateAndIsLoggedOncePerEpisode() {
    var state = TemperatureState()
    _ = Self.step(&state, .celsius(50))
    #expect(Self.step(&state, .unreadable) == [Self.unreadable(blocked: true)])
    #expect(state.blocked)
    #expect(Self.step(&state, .unreadable).isEmpty)
    #expect(state.blocked)
    #expect(Self.step(&state, .celsius(39)) == [Self.unblock(39)])
    #expect(!state.blocked)
    #expect(Self.step(&state, .unreadable) == [Self.unreadable(blocked: false)])
    #expect(!state.blocked)
  }

  @Test func theReducerReleasesForAHotBatteryAndHoldsAgainWhenItCools() {
    var harness = ScenarioHarness()
    harness.settings.temperatureProtectionEnabled = true
    _ = harness.activity(writtenAt: 0, seenAt: 0)
    _ = harness.tick(at: 0)
    #expect(harness.state.want.wanted == true)
    let hot = ScenarioHarness.decisions(harness.send(.batteryTemperature(.celsius(46)), at: 1))
    #expect(hot.contains(Self.block(46)))
    #expect(
      hot.contains(Decision(keyword: .want, verb: "off", fields: [DecisionField(key: "reason", value: "temperature")])))
    let warm = ScenarioHarness.decisions(harness.send(.batteryTemperature(.celsius(40)), at: 2))
    #expect(warm.isEmpty)
    #expect(harness.state.want.wanted == false)
    let cool = ScenarioHarness.decisions(harness.send(.batteryTemperature(.celsius(39)), at: 3))
    #expect(cool.contains(Self.unblock(39)))
    #expect(cool.contains(Decision(keyword: .want, verb: "on", fields: [DecisionField(key: "reason", value: "busy")])))
    #expect(harness.state.want.wanted == true)
  }

  @Test func theTemperatureLinesUseTheTemperatureKeyword() {
    let line = DecisionFormatter.line(
      Self.block(45), wall: Date(timeIntervalSince1970: 0), timeZone: TimeZone(secondsFromGMT: 0) ?? .gmt)
    #expect(
      line.hasSuffix(
        " TEMPERATURE block celsius=45 msg=\"Battery at 45 degrees Celsius: releasing the Mac so it can sleep\""))
  }
}
