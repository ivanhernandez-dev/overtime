import Foundation
import OvertimeCore
import OvertimeSystem
import Testing

@testable import OvertimeEngine

struct EngineTemperatureTests {
  typealias Harness = EngineLoopTests.Harness

  static let lineSeconds: Double = 10
  static let protected = Settings(temperatureProtectionEnabled: true)

  @Test func theFirstTemperatureReadingIsSteppedBeforeTheFirstTick() async throws {
    let harness = try Harness()
    let recent = harness.clock.mono()
    let engine = harness.engine(
      EngineSources(
        transcriptSeed: { [TranscriptActivity(at: recent)] },
        sampleTick: { TickFacts() },
        temperatureRead: { .celsius(50) }
      ), settings: Self.protected)
    await engine.runOnce()
    let lines = harness.lines()
    #expect(lines.contains { $0.contains(" TEMPERATURE block celsius=50 ") })
    #expect(lines.filter { $0.contains(" WANT ") }.count == 1)
    #expect(lines.contains { $0.hasSuffix(" WANT off reason=temperature") })
    #expect(!lines.contains { $0.contains(" WANT on ") })
  }

  @Test func streamedReadingsReleaseAndResumeTheHold() async throws {
    let harness = try Harness()
    let recent = harness.clock.mono()
    let (stream, continuation) = AsyncStream.makeStream(of: BatteryTemperatureReading.self)
    let engine = harness.engine(
      EngineSources(
        transcriptSeed: { [TranscriptActivity(at: recent)] },
        sampleTick: { TickFacts() },
        temperatureStream: { stream }
      ), settings: Self.protected)
    let running = Task { await engine.run() }
    #expect(await harness.waitForLine(containing: " WANT on reason=busy", timeout: Self.lineSeconds))
    continuation.yield(.celsius(47))
    #expect(await harness.waitForLine(containing: " TEMPERATURE block celsius=47 ", timeout: Self.lineSeconds))
    continuation.yield(.celsius(39))
    #expect(await harness.waitForLine(containing: " TEMPERATURE unblock celsius=39 ", timeout: Self.lineSeconds))
    await engine.stop()
    await running.value
    continuation.finish()
  }

  @Test func raisingTheReleaseTemperatureReevaluatesTheLastReading() async throws {
    let harness = try Harness()
    let engine = harness.engine(
      EngineSources(transcriptSeed: { [] }, sampleTick: { TickFacts() }), settings: Self.protected)
    await engine.stepTemperature(.celsius(46))
    #expect(await engine.state.temperature.blocked)
    #expect(await engine.apply(settings: Settings(temperatureProtectionEnabled: true, temperatureReleaseCelsius: 55)))
    #expect(await harness.waitForLine(containing: " TEMPERATURE unblock celsius=46 ", timeout: Self.lineSeconds))
    #expect(await engine.state.temperature.blocked == false)
  }

  @Test func turningTemperatureProtectionOffEndsATemperatureBlock() async throws {
    let harness = try Harness()
    let engine = harness.engine(
      EngineSources(transcriptSeed: { [] }, sampleTick: { TickFacts() }), settings: Self.protected)
    await engine.stepTemperature(.celsius(50))
    #expect(await engine.state.temperature.blocked)
    #expect(await engine.apply(settings: Settings(temperatureProtectionEnabled: false)))
    #expect(await harness.waitForLine(containing: " TEMPERATURE unblock reason=off ", timeout: Self.lineSeconds))
  }

  @Test func turningBatteryProtectionOffEndsABatteryBlock() async throws {
    let harness = try Harness()
    let engine = harness.engine(
      EngineSources(transcriptSeed: { [] }, sampleTick: { TickFacts() }, powerRead: { .battery(percent: 5) }))
    await engine.runOnce()
    #expect(await engine.state.battery.blocked)
    #expect(await engine.apply(settings: Settings(batteryProtectionEnabled: false)))
    #expect(await harness.waitForLine(containing: " BATTERY unblock reason=off ", timeout: Self.lineSeconds))
  }

  @Test func theChangedKeysNameTheProtectionSettings() {
    let changed = Settings(
      batteryProtectionEnabled: false, helperBatteryFloorPercent: 25, temperatureProtectionEnabled: true,
      temperatureReleaseCelsius: 50)
    #expect(
      Engine.changedKeys(from: Settings(), to: changed) == [
        "batteryProtectionEnabled", "helperBatteryFloorPercent", "temperatureProtectionEnabled",
        "temperatureReleaseCelsius",
      ])
  }

  @Test func theSnapshotCarriesTheTemperatureAndTheProtectionSettings() {
    var state = AppState(mode: .live)
    state.temperature = TemperatureState(blocked: true, reading: .celsius(47))
    let settings = Settings(
      batteryProtectionEnabled: false, helperBatteryFloorPercent: 25, temperatureProtectionEnabled: false,
      temperatureReleaseCelsius: 50)
    let snapshot = EngineSnapshot(state: state, settings: settings)
    #expect(snapshot.temperatureBlocked)
    #expect(snapshot.batteryTemperature == .celsius(47))
    #expect(snapshot.batteryProtectionEnabled == false)
    #expect(snapshot.helperBatteryFloorPercent == 25)
    #expect(snapshot.temperatureProtectionEnabled == false)
    #expect(snapshot.temperatureReleaseCelsius == 50)
    #expect(snapshot.temperatureResumeCelsius == 45)
  }
}
