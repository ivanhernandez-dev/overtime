import Foundation
import Testing

@testable import OvertimeCore

@Suite("LID-04 screen lock status")
struct ScreenLockStatusTests {
  static let prefix = "2026-09-27 01:00:16.163 sysadminctl[53534:12172306] "

  @Test func theImmediateFormIsImmediate() {
    #expect(
      ScreenLockStatus.parse(output: Self.prefix + "screenLock delay is immediate\n", exitCode: 0, timedOut: false)
        == .immediate)
  }

  @Test func aDelayInSecondsIsDelayed() {
    #expect(
      ScreenLockStatus.parse(output: Self.prefix + "screenLock delay is 5 seconds\n", exitCode: 0, timedOut: false)
        == .delayed(seconds: 5))
    #expect(
      ScreenLockStatus.parse(output: "screenLock delay is 300 seconds", exitCode: 0, timedOut: false)
        == .delayed(seconds: 300))
  }

  @Test func theOffFormIsOff() {
    #expect(ScreenLockStatus.parse(output: Self.prefix + "screenLock is off\n", exitCode: 0, timedOut: false) == .off)
  }

  @Test(arguments: [
    Self.prefix + "Unknown state for screenLock (0)\n",
    "",
    "garbage",
    "screenLock delay is soon",
    "screenLock delay is 5",
    "screenLock delay is  seconds",
  ])
  func everyOtherOutputIsUnknown(_ output: String) {
    #expect(ScreenLockStatus.parse(output: output, exitCode: 0, timedOut: false) == .unknown)
  }

  @Test func aFailedOrTimedOutRunIsUnknown() {
    let immediate = "screenLock delay is immediate"
    #expect(ScreenLockStatus.parse(output: immediate, exitCode: 1, timedOut: false) == .unknown)
    #expect(ScreenLockStatus.parse(output: immediate, exitCode: nil, timedOut: false) == .unknown)
    #expect(ScreenLockStatus.parse(output: immediate, exitCode: 0, timedOut: true) == .unknown)
  }

  static func warning(_ fields: [DecisionField]) -> Effect {
    .log(Decision(keyword: .warn, verb: "screenLock", fields: fields))
  }

  @Test func theReducerWarnsForEveryNonImmediateStatus() {
    let cases: [(ScreenLockStatus, [Effect])] = [
      (.immediate, []),
      (
        .delayed(seconds: 5),
        [Self.warning([DecisionField(key: "reason", value: "delay"), DecisionField(key: "seconds", value: "5")])]
      ),
      (.off, [Self.warning([DecisionField(key: "reason", value: "off")])]),
      (.unknown, [Self.warning([DecisionField(key: "reason", value: "unverified")])]),
    ]
    for (status, expected) in cases {
      var harness = ScenarioHarness()
      #expect(harness.send(.screenLock(status), at: 0) == expected, "status \(status)")
    }
  }

  @Test func theWarningIsLoggedAtMostOncePerLaunch() {
    var harness = ScenarioHarness()
    #expect(harness.send(.screenLock(.off), at: 0).count == 1)
    #expect(harness.state.screenLockWarned)
    #expect(harness.send(.screenLock(.off), at: 1).isEmpty)
    #expect(harness.send(.screenLock(.unknown), at: 2).isEmpty)
  }
}
