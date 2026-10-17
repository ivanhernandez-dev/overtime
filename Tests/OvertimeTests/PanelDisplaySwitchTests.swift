import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing

@testable import Overtime

@MainActor
struct PanelDisplaySwitchTests {
  @MainActor final class CommitRecorder {
    var values: [Bool] = []
    var result: SettingsCommitResult? = .applied

    func commit(_ enabled: Bool) async -> SettingsCommitResult? {
      values.append(enabled)
      return result
    }
  }

  static func bound(recorder: CommitRecorder) -> PanelModelTests.Bound {
    let bound = PanelModelTests.Bound()
    bound.model.onSetKeepDisplayOn = { await recorder.commit($0) }
    return bound
  }

  static let idle = EngineSnapshot(busy: false, wanted: false, reason: "idle")

  static func fileSettings(_ url: URL) -> Settings? {
    guard case .loaded(let settings) = SettingsStore.load(from: url) else { return nil }
    return settings
  }

  @Test func theSwitchCommitsThroughTheSettingsModelAndFollowsTheEngine() async throws {
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
    let panel = PanelModel()
    panel.amphetamineLocator = .absent
    panel.bind(to: host)
    let settingsFile = folder.url.appendingPathComponent("settings.json")
    let settings = SettingsModel(settingsFile: settingsFile, host: host, panel: panel)
    panel.onSetKeepDisplayOn = { await settings.setKeepDisplayOn($0) }

    await engine.tick()
    #expect(await waitUntil(timeout: 10) { panel.presentation.state == .idle })
    let row = KeepDisplayOnRow(model: panel)
    #expect(row.isEnabled)
    #expect(!row.isOn)

    #expect(await panel.setKeepDisplayOn(true) == .applied)
    #expect(await waitUntil(timeout: 10) { panel.keepDisplayOn })
    #expect(settings.keepDisplayOn)
    #expect(Self.fileSettings(settingsFile)?.keepDisplayOn == true)
    #expect(await engine.currentSnapshot().keepDisplayOn)
    #expect(KeepDisplayOnRow(model: panel).isOn)

    #expect(await settings.setKeepDisplayOn(false) == .applied)
    #expect(await waitUntil(timeout: 10) { !panel.keepDisplayOn })
    #expect(!KeepDisplayOnRow(model: panel).isOn)
    #expect(panel.presentation.reason != ControlFeedback.keepDisplayOnFailure)
  }

  @Test func theRowFollowsTheSnapshotAndTheEngine() async {
    let recorder = CommitRecorder()
    let bound = Self.bound(recorder: recorder)
    var on = Self.idle
    on.keepDisplayOn = true
    bound.host.publish(on)
    #expect(await waitUntil(timeout: 10) { bound.model.keepDisplayOn })
    let enabled = KeepDisplayOnRow(model: bound.model)
    #expect(enabled.isOn)
    #expect(enabled.isEnabled)
    #expect(enabled.help == ControlMapping.keepDisplayOnHelp)

    bound.host.publish(Self.idle)
    #expect(await waitUntil(timeout: 10) { !bound.model.keepDisplayOn })
    #expect(!KeepDisplayOnRow(model: bound.model).isOn)

    bound.model.engineUnresponsive = true
    let unresponsive = KeepDisplayOnRow(model: bound.model)
    #expect(!unresponsive.isEnabled)
    #expect(unresponsive.help == ControlMapping.engineUnavailableHelp)

    bound.model.engineUnresponsive = false
    bound.model.uninstalling = true
    let uninstalling = KeepDisplayOnRow(model: bound.model)
    #expect(!uninstalling.isEnabled)
    #expect(uninstalling.help == ControlMapping.uninstallingHelp)
  }

  @Test func theRowSendsItsSwitchToThePanelModel() async {
    let recorder = CommitRecorder()
    let bound = Self.bound(recorder: recorder)
    bound.host.publish(Self.idle)
    #expect(await waitUntil(timeout: 10) { bound.model.snapshot != nil })
    KeepDisplayOnRow(model: bound.model).setKeepDisplayOn(true)
    #expect(await waitUntil(timeout: 10) { recorder.values == [true] })
  }

  struct FailedResult: Sendable, CustomTestStringConvertible {
    let name: String
    let result: SettingsCommitResult

    var testDescription: String { name }
  }

  nonisolated static let failedResults: [FailedResult] = [
    FailedResult(name: "save failed", result: .saveFailed),
    FailedResult(name: "apply timed out", result: .applyTimedOut),
    FailedResult(name: "invalid", result: .invalid(SettingsValidationError(message: "Rejected."))),
  ]

  @Test(arguments: failedResults)
  func aFailedChangeShowsTheFailureCopyAndKeepsTheEngineValue(_ item: FailedResult) async {
    let recorder = CommitRecorder()
    recorder.result = item.result
    let bound = Self.bound(recorder: recorder)
    bound.host.publish(Self.idle)
    #expect(await waitUntil(timeout: 10) { bound.model.snapshot != nil })
    #expect(await bound.model.setKeepDisplayOn(true) == item.result)
    #expect(recorder.values == [true])
    #expect(bound.model.presentation.reason == ControlFeedback.keepDisplayOnFailure)
    #expect(!bound.model.keepDisplayOn)
  }

  struct QuietResult: Sendable, CustomTestStringConvertible {
    let name: String
    let result: SettingsCommitResult?

    var testDescription: String { name }
  }

  nonisolated static let quietResults: [QuietResult] = [
    QuietResult(name: "applied", result: .applied),
    QuietResult(name: "nothing to change", result: nil),
  ]

  @Test(arguments: quietResults)
  func anAppliedOrUnneededChangeShowsNoFailure(_ item: QuietResult) async {
    let recorder = CommitRecorder()
    recorder.result = item.result
    let bound = Self.bound(recorder: recorder)
    bound.host.publish(Self.idle)
    #expect(await waitUntil(timeout: 10) { bound.model.snapshot != nil })
    #expect(await bound.model.setKeepDisplayOn(true) == item.result)
    #expect(recorder.values == [true])
    #expect(bound.model.presentation.reason != ControlFeedback.keepDisplayOnFailure)
  }

  @Test func anUnboundModelShowsTheFailureWithoutCommitting() async {
    let recorder = CommitRecorder()
    let model = PanelModel()
    model.amphetamineLocator = .absent
    model.onSetKeepDisplayOn = { await recorder.commit($0) }
    #expect(model.controls.engineControlsEnabled)
    #expect(await model.setKeepDisplayOn(true) == nil)
    #expect(recorder.values.isEmpty)
    #expect(model.presentation.reason == ControlFeedback.keepDisplayOnFailure)
  }

  @Test func theSameValueOrAnUnresponsiveEngineSendsNothing() async {
    let recorder = CommitRecorder()
    let bound = Self.bound(recorder: recorder)
    bound.host.publish(Self.idle)
    #expect(await waitUntil(timeout: 10) { bound.model.snapshot != nil })
    #expect(await bound.model.setKeepDisplayOn(false) == nil)
    #expect(recorder.values.isEmpty)

    bound.model.engineUnresponsive = true
    #expect(await bound.model.setKeepDisplayOn(true) == nil)
    #expect(recorder.values.isEmpty)
  }

  @Test func thePanelCopyMatchesTheGeneralPane() {
    #expect(GeneralPane.keepDisplayOnLabel.hasPrefix(ControlMapping.keepDisplayOnLabel + " "))
    let help = "Keeps the display on while Claude works. " + GeneralPane.keepDisplayOnCaption
    #expect(ControlMapping.keepDisplayOnHelp == help)
  }
}
