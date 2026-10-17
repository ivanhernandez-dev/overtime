import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import Testing

struct KeepDisplayOnSwitchTests {
  static func engine(_ harness: EngineSnapshotTests.Harness, keepDisplayOn: Bool) -> Engine {
    Engine(
      mode: .shadow,
      settings: Settings(keepDisplayOn: keepDisplayOn),
      clock: harness.clock,
      interpreter: RecordingInterpreter(logger: harness.logger, timeZone: TimeZone(secondsFromGMT: 0)!),
      sources: EngineSources(transcriptSeed: { [] }, sampleTick: { TickFacts(agents: .none) }))
  }

  @Test func theSnapshotCarriesKeepDisplayOnFromSettings() async throws {
    let harness = try EngineSnapshotTests.Harness()
    let on = Self.engine(harness, keepDisplayOn: true)
    #expect(await on.currentSnapshot().keepDisplayOn)
    let defaults = harness.engine()
    #expect(await !defaults.currentSnapshot().keepDisplayOn)
    #expect(!EngineSnapshot().keepDisplayOn)
  }

  @Test func applyingTheSettingChangesTheNextSnapshot() async throws {
    let harness = try EngineSnapshotTests.Harness()
    let engine = harness.engine()
    let before = await engine.currentSnapshot()
    var settings = Settings()
    settings.keepDisplayOn = true
    #expect(await engine.apply(settings: settings))
    let after = await engine.currentSnapshot()
    #expect(after.keepDisplayOn)
    #expect(after != before)
    settings.keepDisplayOn = false
    #expect(await engine.apply(settings: settings))
    #expect(await !engine.currentSnapshot().keepDisplayOn)
  }

  @Test func theSwitchCopyIsPinned() {
    #expect(ControlMapping.keepDisplayOnLabel == "Keep display on")
    #expect(ControlMapping.keepDisplayOnSymbol == "display")
    #expect(
      ControlMapping.keepDisplayOnHelp
        == "Keeps the display on while Claude works. With the lid closed and no external display, the display still turns off so the screen locks."
    )
    #expect(ControlFeedback.keepDisplayOnFailure == "Couldn't change the display setting. Try again.")
  }

  struct HelpCase: Sendable, CustomTestStringConvertible {
    let name: String
    let snapshot: EngineSnapshot?
    let engineUnresponsive: Bool
    let hostFailure: HostFailure?
    let uninstalling: Bool
    let help: String

    init(
      _ name: String, _ snapshot: EngineSnapshot?, engineUnresponsive: Bool = false, hostFailure: HostFailure? = nil,
      uninstalling: Bool = false, help: String
    ) {
      self.name = name
      self.snapshot = snapshot
      self.engineUnresponsive = engineUnresponsive
      self.hostFailure = hostFailure
      self.uninstalling = uninstalling
      self.help = help
    }

    var testDescription: String { name }
  }

  static let helpCases: [HelpCase] = [
    HelpCase(
      "idle", EngineSnapshot(busy: false, wanted: false, reason: "idle"), help: ControlMapping.keepDisplayOnHelp),
    HelpCase(
      "holding", EngineSnapshot(busy: true, wanted: true, reason: "busy", lidClosed: false),
      help: ControlMapping.keepDisplayOnHelp),
    HelpCase(
      "hold failed", EngineSnapshot(busy: true, wanted: true, reason: "busy", holdError: true),
      help: ControlMapping.keepDisplayOnHelp),
    HelpCase(
      "not responding", EngineSnapshot(busy: true, wanted: true, reason: "busy"), engineUnresponsive: true,
      help: ControlMapping.engineUnavailableHelp),
    HelpCase("could not start", nil, hostFailure: .lockHeldElsewhere, help: ControlMapping.engineUnavailableHelp),
    HelpCase(
      "uninstalling", EngineSnapshot(busy: false, wanted: false, reason: "idle"), uninstalling: true,
      help: ControlMapping.uninstallingHelp),
  ]

  @Test(arguments: helpCases)
  func theSwitchHelpFollowsTheEngine(_ item: HelpCase) {
    let presentation = StatusPresentation.derive(
      snapshot: item.snapshot, hostFailure: item.hostFailure, engineUnresponsive: item.engineUnresponsive,
      uninstalling: item.uninstalling)
    let availability = ControlAvailability.from(presentation, snapshot: item.snapshot)
    #expect(availability.displaySwitchHelp == item.help)
  }

  struct ResultCase: Sendable, CustomTestStringConvertible {
    let name: String
    let result: SettingsCommitResult?
    let failed: Bool

    var testDescription: String { name }
  }

  static let resultCases: [ResultCase] = [
    ResultCase(name: "nothing to change", result: nil, failed: false),
    ResultCase(name: "applied", result: .applied, failed: false),
    ResultCase(name: "apply timed out", result: .applyTimedOut, failed: true),
    ResultCase(name: "save failed", result: .saveFailed, failed: true),
    ResultCase(name: "invalid", result: .invalid(SettingsValidationError(message: "Rejected.")), failed: true),
  ]

  @Test(arguments: resultCases)
  func aSettingChangeFailsUnlessItAppliesOrHasNothingToDo(_ item: ResultCase) {
    #expect(ControlFeedback.settingFailed(item.result) == item.failed)
  }
}
