import Foundation
import Testing

@testable import OvertimeCore

@Suite("Pause, force and the battery floor")
struct PauseForceBatteryTests {
  static func want(_ on: Bool, _ reason: String) -> Decision {
    Decision(keyword: .want, verb: on ? "on" : "off", fields: [DecisionField(key: "reason", value: reason)])
  }

  static func override(_ verb: String, _ fields: [DecisionField] = []) -> Decision {
    Decision(keyword: .override, verb: verb, fields: fields)
  }

  static func busyHarness() -> ScenarioHarness {
    var harness = ScenarioHarness()
    _ = harness.activity(writtenAt: 0, entrypoint: "cli", seenAt: 0)
    _ = harness.tick(at: 0)
    return harness
  }

  static func keepBusy(_ harness: inout ScenarioHarness, at seconds: Double) -> [Decision] {
    _ = harness.activity(writtenAt: seconds, seenAt: seconds)
    return ScenarioHarness.decisions(harness.tick(at: seconds))
  }

  @Test func pauseWhileBusyLogsTheOverrideAndTurnsWantOff() {
    var harness = Self.busyHarness()
    #expect(harness.state.want.wanted == true)
    let effects = harness.send(.command(.pause(.forSeconds(900))), at: 1)
    let until = Want.iso8601(harness.wall0.addingTimeInterval(901))
    #expect(
      ScenarioHarness.decisions(effects) == [
        Self.override("pause", [DecisionField(key: "until", value: until)]),
        Self.want(false, "paused"),
      ])
    #expect(harness.state.want.pause == .untilMono(harness.instant(901), wall: harness.wall0.addingTimeInterval(901)))
    #expect(harness.state.want.reason == "paused")
  }

  @Test func pauseEndsAtItsDeadlineAndWantReturnsWhileStillBusy() {
    var harness = Self.busyHarness()
    _ = harness.send(.command(.pause(.forSeconds(900))), at: 1)
    #expect(Self.keepBusy(&harness, at: 900).filter { $0.keyword == .want }.isEmpty)
    #expect(harness.state.want.pause != nil)
    #expect(Reducer.nextDeadline(harness.state, harness.settings) == harness.instant(901))
    let atDeadline = Self.keepBusy(&harness, at: 901)
    #expect(atDeadline == [Self.override("pauseExpired"), Self.want(true, "busy")])
    #expect(harness.state.want.pause == nil)
  }

  @Test func pauseBeforeTheFirstTickOnlyRecordsThePause() {
    var harness = ScenarioHarness()
    let effects = harness.send(.command(.pause(.indefinite)), at: 0)
    #expect(
      ScenarioHarness.decisions(effects) == [
        Self.override("pause", [DecisionField(key: "until", value: "indefinite")])
      ])
    #expect(harness.state.want.wanted == nil)
    _ = harness.activity(writtenAt: 1, entrypoint: "cli", seenAt: 1)
    #expect(ScenarioHarness.wantLines(harness.tick(at: 1)) == [Self.want(false, "paused")])
  }

  static func idleHarness() -> ScenarioHarness {
    var harness = ScenarioHarness()
    _ = harness.tick(at: 0)
    return harness
  }

  static func forceLine(_ until: String) -> Decision {
    override("force", [DecisionField(key: "until", value: until)])
  }

  @Test func forceWhileIdleTurnsWantOn() {
    var harness = Self.idleHarness()
    #expect(harness.state.want.wanted == false)
    let effects = harness.send(.command(.force(.forSeconds(1800))), at: 1)
    #expect(
      ScenarioHarness.decisions(effects) == [
        Self.forceLine(Want.iso8601(harness.wall0.addingTimeInterval(1801))), Self.want(true, "forced"),
      ])
    #expect(harness.state.want.force == .untilMono(harness.instant(1801)))
  }

  @Test func forceNeverWinsOverTheBatteryFloor() {
    var harness = Self.idleHarness()
    _ = harness.send(.power(.battery(percent: 5)), at: 1)
    #expect(harness.state.battery.blocked)
    let effects = harness.send(.command(.force(.indefinite)), at: 2)
    #expect(ScenarioHarness.decisions(effects) == [Self.forceLine("indefinite")])
    #expect(harness.state.want.wanted == false)
    #expect(harness.state.want.reason == "battery")
    _ = harness.activity(writtenAt: 3, entrypoint: "cli", seenAt: 3)
    #expect(ScenarioHarness.wantLines(harness.tick(at: 3)).isEmpty)
    #expect(harness.state.want.wanted == false)
  }

  @Test func forceNeverWinsOverTheTemperatureLimit() {
    var harness = Self.idleHarness()
    harness.settings.temperatureProtectionEnabled = true
    _ = harness.send(.batteryTemperature(.celsius(50)), at: 1)
    #expect(harness.state.temperature.blocked)
    let effects = harness.send(.command(.force(.indefinite)), at: 2)
    #expect(ScenarioHarness.decisions(effects) == [Self.forceLine("indefinite")])
    #expect(harness.state.want.wanted == false)
    #expect(harness.state.want.reason == "temperature")
    _ = harness.activity(writtenAt: 3, entrypoint: "cli", seenAt: 3)
    #expect(ScenarioHarness.wantLines(harness.tick(at: 3)).isEmpty)
    #expect(harness.state.want.wanted == false)
  }

  @Test func theBatteryFloorReleasesAnActiveForce() {
    var harness = Self.idleHarness()
    _ = harness.send(.command(.force(.indefinite)), at: 1)
    #expect(harness.state.want.wanted == true)
    let effects = harness.send(.power(.battery(percent: 10)), at: 2)
    #expect(ScenarioHarness.wantLines(effects) == [Self.want(false, "battery")])
    let charged = harness.send(.power(.ac(percent: 10)), at: 3)
    #expect(ScenarioHarness.wantLines(charged) == [Self.want(true, "forced")])
  }

  @Test func pauseWhileForcedReplacesTheForce() {
    var harness = Self.idleHarness()
    _ = harness.send(.command(.force(.indefinite)), at: 1)
    let effects = harness.send(.command(.pause(.indefinite)), at: 2)
    #expect(harness.state.want.force == nil)
    #expect(harness.state.want.pause == .indefinite)
    #expect(ScenarioHarness.wantLines(effects) == [Self.want(false, "paused")])
  }

  @Test func releaseUntilIdleWhileForcedAndBusyCancelsTheForceAndReleases() {
    var harness = Self.busyHarness()
    _ = harness.send(.command(.force(.indefinite)), at: 1)
    #expect(harness.state.want.wanted == true)
    let effects = harness.send(.command(.releaseUntilIdle), at: 2)
    #expect(harness.state.want.force == nil)
    #expect(harness.state.want.override)
    #expect(
      ScenarioHarness.decisions(effects) == [
        Self.override("releaseUntilIdle", [DecisionField(key: "cancelled", value: "force")]),
        Self.want(false, "override"),
      ])
    #expect(harness.state.persisted.forceActive == false)
  }

  @Test func releaseUntilIdleWhileForcedAndIdleCancelsTheForceAndLetsTheMacSleep() {
    var harness = Self.idleHarness()
    _ = harness.send(.command(.force(.indefinite)), at: 1)
    let effects = harness.send(.command(.releaseUntilIdle), at: 2)
    #expect(harness.state.want.force == nil)
    #expect(harness.state.want.wanted == false)
    #expect(
      ScenarioHarness.decisions(effects).first
        == Self.override("releaseUntilIdle", [DecisionField(key: "cancelled", value: "force")]))
    #expect(ScenarioHarness.wantLines(effects) == [Self.want(false, "idle")])
  }

  @Test func releaseUntilIdleWithoutAForceLogsNoCancellation() {
    var harness = Self.busyHarness()
    let effects = harness.send(.command(.releaseUntilIdle), at: 1)
    #expect(ScenarioHarness.decisions(effects).first == Self.override("releaseUntilIdle", []))
  }

  @Test func forceWhilePausedReplacesThePause() {
    var harness = Self.idleHarness()
    _ = harness.send(.command(.pause(.indefinite)), at: 1)
    let effects = harness.send(.command(.force(.indefinite)), at: 2)
    #expect(harness.state.want.pause == nil)
    #expect(harness.state.want.force == .indefinite)
    #expect(ScenarioHarness.wantLines(effects) == [Self.want(true, "forced")])
  }

  @Test func resumeClearsPauseForceAndReleaseUntilIdle() {
    var harness = Self.busyHarness()
    _ = harness.send(.command(.releaseUntilIdle), at: 1)
    _ = harness.send(.command(.pause(.indefinite)), at: 2)
    #expect(harness.state.want.override)
    let resumed = harness.send(.command(.resume), at: 3)
    #expect(ScenarioHarness.decisions(resumed) == [Self.override("resume"), Self.want(true, "busy")])
    #expect(harness.state.want.pause == nil)
    #expect(harness.state.want.force == nil)
    #expect(harness.state.want.override == false)
    _ = harness.send(.command(.force(.indefinite)), at: 4)
    _ = harness.send(.command(.resume), at: 5)
    #expect(harness.state.want.force == nil)
  }

  @Test func aTimedForceExpiresAtItsInstant() {
    var harness = Self.idleHarness()
    _ = harness.send(.command(.force(.forSeconds(1800))), at: 1)
    #expect(Reducer.nextDeadline(harness.state, harness.settings) == harness.instant(1801))
    #expect(ScenarioHarness.decisions(harness.tick(at: 1800.5)).isEmpty)
    #expect(harness.state.want.wanted == true)
    let expired = ScenarioHarness.decisions(harness.tick(at: 1801))
    #expect(expired == [Self.override("forceExpired"), Self.want(false, "idle")])
    #expect(harness.state.want.force == nil)
  }

  @Test func anIndefinitePauseNeverExpires() {
    var harness = Self.idleHarness()
    _ = harness.send(.command(.pause(.indefinite)), at: 1)
    #expect(Reducer.nextDeadline(harness.state, harness.settings) == nil)
    _ = harness.activity(writtenAt: 400 * 86_400, entrypoint: "cli", seenAt: 400 * 86_400)
    #expect(ScenarioHarness.wantLines(harness.tick(at: 400 * 86_400)).isEmpty)
    #expect(harness.state.want.pause == .indefinite)
    #expect(harness.state.want.wanted == false)
  }

  @Test func aPauseUntilADateExpiresWhenTheWallClockReachesIt() {
    var harness = Self.idleHarness()
    let until = harness.wall0.addingTimeInterval(100)
    let effects = harness.send(.command(.pause(.until(until))), at: 1)
    #expect(
      ScenarioHarness.decisions(effects) == [
        Self.override("pause", [DecisionField(key: "until", value: Want.iso8601(until))])
      ])
    #expect(harness.state.want.pause == .untilWall(until))
    #expect(ScenarioHarness.decisions(harness.tick(at: 99)).isEmpty)
    #expect(Reducer.nextDeadline(harness.state, harness.settings) == harness.instant(100))
    #expect(ScenarioHarness.decisions(harness.tick(at: 100)) == [Self.override("pauseExpired")])
    #expect(harness.state.want.pause == nil)
  }
}
