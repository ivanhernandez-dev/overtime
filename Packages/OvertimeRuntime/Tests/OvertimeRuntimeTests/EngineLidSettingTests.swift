import Foundation
import OvertimeCore
import OvertimeSystem
import Testing

@testable import OvertimeEngine

@Suite(.serialized)
struct EngineLidSettingTests {
  typealias Harness = EngineApplySettingsTests.Harness

  static func held(_ harness: Harness, power: PowerReading?) async throws -> Engine {
    let engine = try harness.engine()
    await engine.step(.tick(TickFacts(fullWake: true)))
    if let power {
      await engine.stepPower(power)
    }
    await engine.step(.transcriptActivity(TranscriptActivity(at: harness.clock.mono())))
    return engine
  }

  static func clears(_ recorder: HoldRecorder) -> Int {
    recorder.all.filter { entry in
      if case .clamshell(on: false, _) = entry { return true }
      return false
    }.count
  }

  static func writesOfOne(_ recorder: HoldRecorder) -> Int {
    recorder.all.filter { entry in
      if case .clamshell(on: true, _) = entry { return true }
      return false
    }.count
  }

  static func settings(_ harness: Harness, _ change: (inout Settings) -> Void) -> Settings {
    var settings = harness.settings
    change(&settings)
    return settings
  }

  @Test func switchingToNeverWhileHeldReleasesTheClamshellWithoutAnotherEvent() async throws {
    let harness = try Harness()
    let engine = try await Self.held(harness, power: .ac(percent: 80))
    #expect(await engine.state.hold.lidClose == .held)
    harness.recorder.reset()
    let never = Self.settings(harness) { $0.lidClosedKeepAwake = .never }
    #expect(await engine.apply(settings: never))
    #expect(Self.clears(harness.recorder) == 1)
    #expect(await engine.state.hold.lidClose == .released)
    #expect(await engine.snapshot().holdIdle == "held")
    #expect(harness.lines().contains { $0.hasSuffix(" HOLD lidClosed allowed=false setting=never power=ac") })
    #expect(harness.settingsLines().last?.hasSuffix(" SETTINGS applied keys=lidClosedKeepAwake") == true)
  }

  @Test func switchingBackToAlwaysEngagesTheClamshellAgain() async throws {
    let harness = try Harness()
    let engine = try await Self.held(harness, power: .ac(percent: 80))
    let never = Self.settings(harness) { $0.lidClosedKeepAwake = .never }
    #expect(await engine.apply(settings: never))
    try #require(await engine.state.hold.lidClose == .released)
    harness.recorder.reset()
    #expect(await engine.apply(settings: harness.settings))
    #expect(Self.writesOfOne(harness.recorder) == 1)
    #expect(await engine.state.hold.lidClose == .held)
    #expect(harness.lines().contains { $0.hasSuffix(" HOLD lidClosed allowed=true setting=always power=ac") })
  }

  @Test func withoutAPowerReadingTheNextTickAppliesTheSetting() async throws {
    let harness = try Harness()
    let engine = try await Self.held(harness, power: nil)
    #expect(await engine.state.hold.lidClose == .held)
    let never = Self.settings(harness) { $0.lidClosedKeepAwake = .never }
    #expect(await engine.apply(settings: never))
    #expect(await engine.state.hold.lidClose == .held)
    await engine.step(.tick(TickFacts(fullWake: true)))
    #expect(await engine.state.hold.lidClose == .released)
    #expect(harness.lines().contains { $0.hasSuffix(" HOLD lidClosed allowed=false setting=never power=unknown") })
  }

  @Test func theChangedKeysNameTheLidAndDurationSettings() {
    let changed = Settings(
      lidClosedKeepAwake: .never, pauseFirstMinutes: 45, pauseSecondMinutes: 90, keepAwakeFirstMinutes: 10,
      keepAwakeSecondMinutes: 1440)
    #expect(
      Engine.changedKeys(from: Settings(), to: changed) == [
        "keepAwakeFirstMinutes", "keepAwakeSecondMinutes", "lidClosedKeepAwake", "pauseFirstMinutes",
        "pauseSecondMinutes",
      ])
  }

  @Test func aDurationChangeAppliesWithoutTouchingTheHold() async throws {
    let harness = try Harness()
    let engine = try await Self.held(harness, power: .ac(percent: 80))
    #expect(await engine.state.hold.lidClose == .held)
    harness.recorder.reset()
    let longer = Self.settings(harness) { $0.pauseFirstMinutes = 45 }
    #expect(await engine.apply(settings: longer))
    #expect(Self.clears(harness.recorder) == 0)
    #expect(await engine.state.hold.lidClose == .held)
    #expect(await engine.snapshot().holdIdle == "held")
    #expect(harness.settingsLines().count == 1)
    #expect(harness.settingsLines().first?.hasSuffix(" SETTINGS applied keys=pauseFirstMinutes") == true)
    #expect(await engine.currentSnapshot().pauseFirstMinutes == 45)
  }

  @Test func theSnapshotCarriesTheLidSettingAndTheDurations() {
    var state = AppState(mode: .live)
    state.lastPower = .battery(percent: 50)
    let settings = Settings(
      lidClosedKeepAwake: .onPowerAdapter, pauseFirstMinutes: 45, pauseSecondMinutes: 90, keepAwakeFirstMinutes: 10,
      keepAwakeSecondMinutes: 1440)
    let onBattery = EngineSnapshot(state: state, settings: settings)
    #expect(onBattery.lidClosedKeepAwake == .onPowerAdapter)
    #expect(onBattery.lidClosedHoldAllowed == false)
    #expect(onBattery.pauseFirstMinutes == 45)
    #expect(onBattery.pauseSecondMinutes == 90)
    #expect(onBattery.keepAwakeFirstMinutes == 10)
    #expect(onBattery.keepAwakeSecondMinutes == 1440)
    state.lastPower = .ac(percent: 50)
    #expect(EngineSnapshot(state: state, settings: settings).lidClosedHoldAllowed == true)
    let defaults = EngineSnapshot()
    #expect(defaults.lidClosedKeepAwake == .always)
    #expect(defaults.lidClosedHoldAllowed == true)
    #expect(defaults.pauseFirstMinutes == 15)
    #expect(defaults.pauseSecondMinutes == 60)
    #expect(defaults.keepAwakeFirstMinutes == 30)
    #expect(defaults.keepAwakeSecondMinutes == 120)
  }
}
