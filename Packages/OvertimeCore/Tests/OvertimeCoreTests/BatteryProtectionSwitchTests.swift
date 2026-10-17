import Foundation
import Testing

@testable import OvertimeCore

struct BatteryProtectionSwitchTests {
  static let unblockOff = Decision(
    keyword: .battery, verb: "unblock",
    fields: [
      DecisionField(key: "reason", value: "off"),
      DecisionField(key: "msg", value: "Battery protection off: resuming"),
    ])

  static let unknownBlock = Decision(
    keyword: .battery, verb: "block",
    fields: [
      DecisionField(key: "source", value: "battery"),
      DecisionField(key: "percent", value: "unknown"),
      DecisionField(key: "msg", value: Battery.unknownPercentMessage),
    ])

  @Test func withBatteryProtectionOffAKnownLowChargeNeverBlocks() {
    for percent in [5, 1] {
      var state = BatteryState()
      #expect(Battery.step(&state, .battery(percent: percent), low: 10, resume: 20, enabled: false).isEmpty)
      #expect(!state.blocked)
    }
  }

  @Test func turningBatteryProtectionOffEndsABlockWithTheOffLine() {
    var state = BatteryState(blocked: true)
    #expect(Battery.step(&state, .battery(percent: 5), low: 10, resume: 20, enabled: false) == [Self.unblockOff])
    #expect(!state.blocked)
  }

  @Test func withBatteryProtectionOffAnUnknownChargeStillBlocks() {
    var state = BatteryState()
    #expect(Battery.step(&state, .battery(percent: nil), low: 10, resume: 20, enabled: false) == [Self.unknownBlock])
    #expect(state.blocked)
  }

  @Test func withBatteryProtectionOffTheReducerKeepsHoldingOnALowBattery() {
    var harness = ScenarioHarness(settings: Settings(batteryProtectionEnabled: false))
    _ = harness.activity(writtenAt: 0, seenAt: 0)
    _ = harness.tick(at: 0)
    #expect(harness.state.want.wanted == true)
    let decisions = ScenarioHarness.decisions(harness.send(.power(.battery(percent: 5)), at: 1))
    #expect(
      !decisions.contains(
        Decision(keyword: .want, verb: "off", fields: [DecisionField(key: "reason", value: "battery")])))
    #expect(harness.state.want.wanted == true)
    #expect(!harness.state.battery.blocked)
  }
}
