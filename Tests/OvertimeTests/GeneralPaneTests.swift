import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing

@testable import Overtime

@MainActor
struct GeneralPaneTests {
  @MainActor struct Fixture {
    let folder: TestFolder
    let host = FakeEngineHost()
    let panel = PanelModel()
    let model: SettingsModel

    init() throws {
      folder = try TestFolder()
      panel.homeDirectory = SettingsWindowTests.testHome
      panel.amphetamineLocator = .absent
      panel.bind(to: host)
      model = SettingsModel(
        settingsFile: folder.url.appendingPathComponent("settings.json"), host: host, panel: panel,
        environment: [:], homeDirectory: SettingsWindowTests.testHome)
    }

    var fileSettings: Settings? {
      guard case .loaded(let settings) = SettingsStore.load(from: model.settingsFile) else { return nil }
      return settings
    }
  }

  static let durationMessage = "Enter a whole number of minutes from 1 to 1440."
  static let durationFields: [SettingsField] = [
    .pauseFirstMinutes, .pauseSecondMinutes, .keepAwakeFirstMinutes, .keepAwakeSecondMinutes,
  ]

  @Test func theLidClosedSettingSavesAndApplies() async throws {
    let fixture = try Fixture()
    for value in [LidClosedKeepAwake.onPowerAdapter, .never, .always] {
      #expect(await fixture.model.setLidClosedKeepAwake(value) == .applied)
      #expect(fixture.fileSettings?.lidClosedKeepAwake == value)
      #expect(fixture.host.appliedSettings.last?.lidClosedKeepAwake == value)
      #expect(fixture.model.lidClosedKeepAwake == value)
    }
    #expect(await fixture.model.setLidClosedKeepAwake(.always) == nil)
    #expect(fixture.host.appliedSettings.count == 3)
  }

  @Test func aNewSettingsFileShowsAlways() throws {
    let fixture = try Fixture()
    #expect(fixture.fileSettings == nil)
    #expect(fixture.model.lidClosedKeepAwake == .always)
    #expect(fixture.model.settings == Settings())
  }

  @Test func theDurationRowsCommitOneToFourteenFortyAndRejectTheRest() async throws {
    let fixture = try Fixture()
    #expect(fixture.model.text(for: .pauseFirstMinutes) == "15")
    #expect(await fixture.model.commit(.pauseFirstMinutes, text: "45") == .applied)
    #expect(fixture.model.settings.pauseFirstMinutes == 45)
    #expect(fixture.fileSettings?.pauseFirstMinutes == 45)
    let rejected = await fixture.model.commit(.pauseFirstMinutes, text: "1441")
    #expect(rejected == .invalid(SettingsValidationError(message: Self.durationMessage)))
    #expect(fixture.model.message(for: .pauseFirstMinutes) == Self.durationMessage)
    #expect(fixture.model.settings.pauseFirstMinutes == 45)
    #expect(fixture.fileSettings?.pauseFirstMinutes == 45)
  }

  @Test func theDurationSteppersMoveByFiveInsideTheRange() async throws {
    let fixture = try Fixture()
    #expect(await fixture.model.step(.pauseFirstMinutes, by: 5) == .applied)
    #expect(fixture.model.settings.pauseFirstMinutes == 20)
    #expect(fixture.fileSettings?.pauseFirstMinutes == 20)
    #expect(await fixture.model.commit(.keepAwakeSecondMinutes, text: "1440") == .applied)
    let saved = fixture.host.appliedSettings.count
    #expect(await fixture.model.step(.keepAwakeSecondMinutes, by: 5) == nil)
    #expect(fixture.host.appliedSettings.count == saved)
    #expect(fixture.model.settings.keepAwakeSecondMinutes == 1440)
    for field in Self.durationFields {
      #expect(SettingsModel.stepSize(for: field) == 5)
      #expect(SettingsModel.stepBounds(for: field, in: Settings()) == 1...1440)
    }
  }

  @Test func theDurationsCaptionListsTheMenusInOrder() async throws {
    let fixture = try Fixture()
    let model = fixture.model
    #expect(
      GeneralPane.durationsCaption(pause: model.pauseChoices, keepAwake: model.keepAwakeChoices)
        == "The panel's Pause menu offers 15 Minutes, 1 Hour, Until Tomorrow and Until Resumed, and its Keep Awake menu offers 30 Minutes, 2 Hours and Until Stopped."
    )
    #expect(await model.commit(.pauseFirstMinutes, text: "120") == .applied)
    #expect(await model.commit(.pauseSecondMinutes, text: "30") == .applied)
    let caption = GeneralPane.durationsCaption(pause: model.pauseChoices, keepAwake: model.keepAwakeChoices)
    #expect(caption.contains("Pause menu offers 30 Minutes, 2 Hours, Until Tomorrow and Until Resumed,"))
  }

  @Test func theGeneralPaneCopyIsTheContractCopy() {
    #expect(GeneralPane.durationsTitle == "Pause and Keep Awake")
    #expect(
      Self.durationFields.map(GeneralPane.durationLabel) == [
        "Pause, first choice", "Pause, second choice", "Keep Awake, first choice", "Keep Awake, second choice",
      ])
    #expect(GeneralPane.durationFields == Self.durationFields)
  }

  @Test func theUnplugProtectionPaneShowsTheSettingNote() async throws {
    let fixture = try Fixture()
    #expect(UnplugProtectionPane.settingNote(for: fixture.model) == nil)
    #expect(await fixture.model.setLidClosedKeepAwake(.never) == .applied)
    #expect(
      UnplugProtectionPane.settingNote(for: fixture.model)
        == "In Settings > General, Keep awake with the lid closed is set to Never, so unplug protection isn't used. It stays installed until you remove it."
    )
  }
}
