import Foundation
import Testing

@testable import OvertimeCore

@Suite("Battery scenarios #9-#15")
struct BatteryScenarios {
  static let low = 10
  static let resume = 20

  static let sequence: [(reading: PowerReading, blocked: Bool, decisions: [Decision])] = [
    (.battery(percent: 50), false, []),
    (.battery(percent: 10), true, [block(10)]),
    (.battery(percent: 19), true, []),
    (.battery(percent: 20), false, [unblock(20)]),
    (.battery(percent: 8), true, [block(8)]),
    (.ac(percent: 8), false, [chargerConnected]),
  ]

  static func block(_ percent: Int) -> Decision {
    Decision(
      keyword: .battery,
      verb: "block",
      fields: [
        DecisionField(key: "source", value: "battery"),
        DecisionField(key: "percent", value: String(percent)),
        DecisionField(key: "msg", value: "Battery at \(percent)%: releasing the Mac so it can sleep"),
      ]
    )
  }

  static func unblock(_ percent: Int) -> Decision {
    Decision(
      keyword: .battery,
      verb: "unblock",
      fields: [
        DecisionField(key: "source", value: "battery"),
        DecisionField(key: "percent", value: String(percent)),
        DecisionField(key: "msg", value: "Battery at \(percent)%: resuming"),
      ]
    )
  }

  static let chargerConnected = Decision(
    keyword: .battery,
    verb: "unblock",
    fields: [
      DecisionField(key: "source", value: "ac"),
      DecisionField(key: "msg", value: "Charger connected: resuming"),
    ]
  )

  static func replay(through number: Int) -> (state: BatteryState, last: [Decision]) {
    var state = BatteryState()
    var last: [Decision] = []
    for step in sequence.prefix(number - 8) {
      last = Battery.step(&state, step.reading, low: low, resume: resume)
      #expect(state.blocked == step.blocked)
      #expect(last == step.decisions)
    }
    return (state, last)
  }

  @Test("#9 battery 50% is not blocked")
  func scenario09FiftyPercentNotBlocked() {
    let result = Self.replay(through: 9)
    #expect(result.state.blocked == false)
    #expect(result.last.isEmpty)
  }

  @Test("#10 battery 10% blocks")
  func scenario10TenPercentBlocks() {
    let result = Self.replay(through: 10)
    #expect(result.state.blocked == true)
    #expect(result.last == [Self.block(10)])
  }

  @Test("#11 battery 19% stays blocked (hysteresis)")
  func scenario11NineteenPercentStaysBlocked() {
    let result = Self.replay(through: 11)
    #expect(result.state.blocked == true)
    #expect(result.last.isEmpty)
  }

  @Test("#12 battery 20% unblocks")
  func scenario12TwentyPercentUnblocks() {
    let result = Self.replay(through: 12)
    #expect(result.state.blocked == false)
    #expect(result.last == [Self.unblock(20)])
  }

  @Test("#13 battery 8% blocks again")
  func scenario13EightPercentBlocks() {
    let result = Self.replay(through: 13)
    #expect(result.state.blocked == true)
    #expect(result.last == [Self.block(8)])
  }

  @Test("#14 AC power at 8% unblocks")
  func scenario14ACAtEightPercentUnblocks() {
    let result = Self.replay(through: 14)
    #expect(result.state.blocked == false)
    #expect(result.last == [Self.chargerConnected])
  }

  @Test("#15 a Mac without a battery never blocks")
  func scenario15NoBatteryUnblocks() {
    var state = BatteryState(blocked: true)
    #expect(Battery.step(&state, .noBattery, low: Self.low, resume: Self.resume) == [Self.chargerConnected])
    #expect(state.blocked == false)
    #expect(Battery.step(&state, .noBattery, low: Self.low, resume: Self.resume).isEmpty)
    #expect(state.blocked == false)
  }
}

struct BatteryFloorTests {
  typealias H = ScenarioHarness
  typealias L = BatteryScenarios

  static let wantBattery = Effect.log(
    Decision(keyword: .want, verb: "off", fields: [DecisionField(key: "reason", value: "battery")]))

  static let unknownBlock = Decision(
    keyword: .battery, verb: "block",
    fields: [
      DecisionField(key: "source", value: "battery"),
      DecisionField(key: "percent", value: "unknown"),
      DecisionField(key: "msg", value: Battery.unknownPercentMessage),
    ])

  @Test func anEmptyPercentageIsANoBatteryMacAndUnblocks() {
    var state = BatteryState(blocked: true)
    #expect(Battery.step(&state, .noBattery, low: 10, resume: 20) == [L.chargerConnected])
    #expect(state.blocked == false)
  }

  @Test func unknownPercentageOnBatteryKeepsABlockedMacBlocked() {
    var state = BatteryState(blocked: true)
    #expect(Battery.step(&state, .battery(percent: nil), low: 10, resume: 20).isEmpty)
    #expect(state.blocked == true)
  }

  @Test func unknownPercentageOnBatteryBlocksAndNeverSaysChargerConnected() {
    var state = BatteryState()
    #expect(Battery.step(&state, .battery(percent: nil), low: 10, resume: 20) == [Self.unknownBlock])
    #expect(state.blocked == true)
    #expect(Battery.step(&state, .battery(percent: nil), low: 10, resume: 20).isEmpty)
    #expect(Battery.step(&state, .battery(percent: 15), low: 10, resume: 20).isEmpty)
    #expect(state.blocked == true)
    #expect(Battery.step(&state, .battery(percent: 20), low: 10, resume: 20) == [L.unblock(20)])
  }

  @Test func unknownPercentageOnBatteryTurnsWantOffAtTheFloor() {
    var harness = H()
    _ = harness.activity(writtenAt: 0, seenAt: 0)
    #expect(harness.tick(at: 0) == [H.busy(true, source: "transcript"), H.want(true)])
    #expect(harness.send(.power(.battery(percent: nil)), at: 1) == [.log(Self.unknownBlock), Self.wantBattery])
    #expect(harness.state.want.wanted == false)
    #expect(harness.send(.power(.battery(percent: nil)), at: 2).isEmpty)
    #expect(harness.state.want.wanted == false)
  }

  @Test func acNeverBlocksAndUnblockedChangesLogNothing() {
    var state = BatteryState()
    #expect(Battery.step(&state, .ac(percent: 3), low: 10, resume: 20).isEmpty)
    #expect(Battery.step(&state, .ac(percent: nil), low: 10, resume: 20).isEmpty)
    #expect(Battery.step(&state, .battery(percent: 11), low: 10, resume: 20).isEmpty)
    #expect(state.blocked == false)
  }

  @Test func thresholdsComeFromTheArguments() {
    var state = BatteryState()
    #expect(Battery.step(&state, .battery(percent: 15), low: 15, resume: 25) == [L.block(15)])
    #expect(Battery.step(&state, .battery(percent: 24), low: 15, resume: 25).isEmpty)
    #expect(Battery.step(&state, .battery(percent: 25), low: 15, resume: 25) == [L.unblock(25)])
  }

  @Test func blockedBatteryTurnsWantOffEvenWhileBusy() {
    var harness = H()
    _ = harness.activity(writtenAt: 0, seenAt: 0)
    #expect(harness.tick(at: 0) == [H.busy(true, source: "transcript"), H.want(true)])
    #expect(harness.send(.power(.battery(percent: 9)), at: 1) == [.log(L.block(9)), Self.wantBattery])
    #expect(harness.state.want.wanted == false)
    #expect(harness.tick(at: 2).isEmpty)
    #expect(harness.send(.power(.ac(percent: 9)), at: 3) == [.log(L.chargerConnected), H.want(true)])
    #expect(harness.state.want.wanted == true)
  }

  @Test func unblockingAfterBusyEndedStaysOffOnceGraceHasPassed() {
    var harness = H()
    _ = harness.activity(writtenAt: 0, seenAt: 0)
    _ = harness.tick(at: 0)
    #expect(harness.send(.power(.battery(percent: 5)), at: 1) == [.log(L.block(5)), Self.wantBattery])
    #expect(harness.tick(at: 200) == [H.busy(false, source: "transcript")])
    #expect(harness.send(.power(.ac(percent: 5)), at: 300) == [.log(L.chargerConnected)])
    #expect(harness.state.want.wanted == false)
  }

  @Test func powerBeforeTheFirstTickOnlyUpdatesTheBattery() {
    var harness = H()
    _ = harness.activity(writtenAt: 0, seenAt: 0)
    #expect(harness.send(.power(.battery(percent: 4)), at: 0) == [.log(L.block(4))])
    #expect(harness.state.busy.busy == nil)
    #expect(harness.tick(at: 0) == [H.busy(true, source: "transcript"), Self.wantBattery])
  }

  @Test func blockedWhileIdleLogsNoWantChange() {
    var harness = H()
    #expect(harness.tick(at: 0) == [H.busy(false, source: "transcript"), H.want(false)])
    #expect(harness.send(.power(.battery(percent: 10)), at: 1) == [.log(L.block(10))])
    #expect(harness.state.battery.blocked)
  }
}
