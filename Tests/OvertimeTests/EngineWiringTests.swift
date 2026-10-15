import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing

@testable import Overtime

@MainActor
struct EngineWiringTests {
  @Test func thePanelModelFollowsARealEngine() async throws {
    let folder = try TestFolder()
    let paths = Paths.resolve(environment: ["OVERTIME_HOME": folder.path], homeDirectory: "/Users/dev")
    try paths.createDirectories()
    let logger = try FileLogger(decisionLog: paths.decisionLog(.shadow), errorLog: paths.errorLog(.shadow))
    let clock = SystemClock()
    let engine = Engine(
      mode: .shadow,
      settings: Settings(),
      clock: clock,
      interpreter: RecordingInterpreter(logger: logger, timeZone: TimeZone(secondsFromGMT: 0)!),
      sources: EngineSources(transcriptSeed: { [] }, sampleTick: { TickFacts(agents: .none) })
    )
    let host = LiveEngineHost(engine: engine, clock: clock)
    let model = PanelModel()
    model.amphetamineLocator = .absent
    model.bind(to: host)
    #expect(model.presentation.accessibilityLabel == "Overtime, starting")

    await engine.tick()
    #expect(await waitUntil { model.presentation.accessibilityLabel == "Overtime, idle" })
    #expect(model.presentation.glyph == .idle)

    let response = await host.send(.force(.indefinite))
    #expect(response?.ok == true)
    #expect(await waitUntil { model.presentation.glyph == .forced })
    #expect(model.presentation.accessibilityLabel == "Overtime, keeping awake manually")
    #expect(model.presentation.title == "Keeping awake manually")
  }

  @Test func panelControlsDriveARealEngineAndComeBackAsANewGlyph() async throws {
    let folder = try TestFolder()
    let paths = Paths.resolve(environment: ["OVERTIME_HOME": folder.path], homeDirectory: "/Users/dev")
    try paths.createDirectories()
    let logger = try FileLogger(decisionLog: paths.decisionLog(.shadow), errorLog: paths.errorLog(.shadow))
    let clock = SystemClock()
    let engine = Engine(
      mode: .shadow,
      settings: Settings(),
      clock: clock,
      interpreter: RecordingInterpreter(logger: logger, timeZone: TimeZone(secondsFromGMT: 0)!),
      sources: EngineSources(transcriptSeed: { [] }, sampleTick: { TickFacts(agents: .none) })
    )
    let model = PanelModel()
    model.amphetamineLocator = .absent
    model.bind(to: LiveEngineHost(engine: engine, clock: clock))
    await engine.tick()
    #expect(await waitUntil { model.presentation.state == .idle })
    #expect(
      model.controls == ControlAvailability(pauseRow: .pauseMenu, keepAwakeRow: .keepAwakeMenu, releaseEnabled: false))

    #expect(await model.perform(.pause(.fifteenMinutes))?.ok == true)
    #expect(await waitUntil { model.presentation.glyph == .paused })
    #expect(model.presentation.title == "Paused")
    #expect(model.timingLine?.text.hasPrefix("Resumes in") == true)
    #expect(model.controls.pauseRow == .resume)

    #expect(await model.perform(.resume)?.ok == true)
    #expect(await waitUntil { model.presentation.state == .idle })
    #expect(model.presentation.glyph == .idle)
    #expect(model.controls.pauseRow == .pauseMenu)

    #expect(await model.perform(.keepAwake(.untilStopped))?.ok == true)
    #expect(await waitUntil { model.presentation.state == .override })
    #expect(model.presentation.glyph == .forced)
    #expect(model.controls.keepAwakeRow == .stopKeepingAwake)

    #expect(await model.perform(.stopKeepingAwake)?.ok == true)
    #expect(await waitUntil { model.presentation.state == .idle })
    #expect(model.controls.keepAwakeRow == .keepAwakeMenu)
  }
}
