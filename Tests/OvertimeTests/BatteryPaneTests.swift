import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing

@testable import Overtime

@MainActor
struct BatteryPaneTests {
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

    func publish(_ snapshot: EngineSnapshot) async -> Bool {
      host.publish(snapshot)
      return await waitUntil { panel.snapshot == snapshot }
    }
  }

  @Test func theBatteryProtectionSwitchSavesAndApplies() async throws {
    let fixture = try Fixture()
    #expect(fixture.model.batteryProtectionEnabled)
    #expect(await fixture.model.setBatteryProtectionEnabled(false) == .applied)
    #expect(fixture.fileSettings?.batteryProtectionEnabled == false)
    #expect(fixture.host.appliedSettings.map(\.batteryProtectionEnabled) == [false])
    #expect(!fixture.model.batteryProtectionEnabled)
    #expect(await fixture.model.setBatteryProtectionEnabled(false) == nil)
    #expect(fixture.host.appliedSettings.count == 1)
  }

  @Test func theTemperatureProtectionSwitchSavesAndApplies() async throws {
    let fixture = try Fixture()
    #expect(fixture.model.temperatureProtectionEnabled)
    #expect(await fixture.model.setTemperatureProtectionEnabled(false) == .applied)
    #expect(fixture.fileSettings?.temperatureProtectionEnabled == false)
    #expect(fixture.host.appliedSettings.map(\.temperatureProtectionEnabled) == [false])
    #expect(!fixture.model.temperatureProtectionEnabled)
    #expect(await fixture.model.setTemperatureProtectionEnabled(true) == .applied)
    #expect(fixture.model.temperatureProtectionEnabled)
  }

  @Test func theLevelRowsStayEditableWithBatteryProtectionOff() async throws {
    let fixture = try Fixture()
    #expect(await fixture.model.setBatteryProtectionEnabled(false) == .applied)
    #expect(fixture.model.canEdit)
    #expect(await fixture.model.commit(.batteryLowPercent, text: "15") == .applied)
    #expect(fixture.model.settings.batteryLowPercent == 15)
    #expect(fixture.fileSettings?.batteryLowPercent == 15)
    #expect(fixture.fileSettings?.batteryProtectionEnabled == false)
  }

  @Test func theHelperFloorCommitsFiveToFiftyAndRejectsTheRest() async throws {
    let fixture = try Fixture()
    #expect(fixture.model.text(for: .helperBatteryFloorPercent) == "10")
    #expect(await fixture.model.commit(.helperBatteryFloorPercent, text: "25") == .applied)
    #expect(fixture.model.settings.helperBatteryFloorPercent == 25)
    #expect(fixture.fileSettings?.helperBatteryFloorPercent == 25)
    let message = "Enter a whole percentage from 5 to 50."
    let rejected = await fixture.model.commit(.helperBatteryFloorPercent, text: "4")
    #expect(rejected == .invalid(SettingsValidationError(message: message)))
    #expect(fixture.model.message(for: .helperBatteryFloorPercent) == message)
    #expect(fixture.model.settings.helperBatteryFloorPercent == 25)
    #expect(SettingsModel.stepBounds(for: .helperBatteryFloorPercent, in: Settings()) == 5...50)
    #expect(SettingsModel.stepSize(for: .helperBatteryFloorPercent) == 1)
  }

  @Test func theReleaseTemperatureCommitsThirtyFiveToSixtyAndRejectsTheRest() async throws {
    let fixture = try Fixture()
    #expect(fixture.model.text(for: .temperatureReleaseCelsius) == "45")
    #expect(await fixture.model.commit(.temperatureReleaseCelsius, text: "50") == .applied)
    #expect(fixture.model.settings.temperatureReleaseCelsius == 50)
    #expect(fixture.fileSettings?.temperatureReleaseCelsius == 50)
    let message = "Enter a whole number of degrees from 35 to 60."
    let rejected = await fixture.model.commit(.temperatureReleaseCelsius, text: "61")
    #expect(rejected == .invalid(SettingsValidationError(message: message)))
    #expect(fixture.model.settings.temperatureReleaseCelsius == 50)
    #expect(SettingsModel.stepBounds(for: .temperatureReleaseCelsius, in: Settings()) == 35...60)
    #expect(SettingsModel.stepSize(for: .temperatureReleaseCelsius) == 1)
  }

  @Test func theReadingShowsTheSnapshotTemperature() async throws {
    let fixture = try Fixture()
    #expect(fixture.model.batteryTemperatureText == "Not read yet")
    let readings: [(BatteryTemperatureReading, String)] = [
      (.celsius(33), "33°C"), (.unavailable, "Unavailable"), (.unreadable, "Can't be read"),
    ]
    for (reading, text) in readings {
      #expect(await fixture.publish(EngineSnapshot(wanted: false, reason: "idle", batteryTemperature: reading)))
      #expect(fixture.model.batteryTemperatureText == text)
      #expect(SettingsModel.batteryTemperatureText(reading) == text)
    }
    #expect(SettingsModel.batteryTemperatureText(nil) == "Not read yet")
  }

  @Test func theBatteryPaneCopyIsTheContractCopy() {
    #expect(BatteryPane.batteryProtectionLabel == "Battery protection")
    #expect(
      BatteryPane.batteryProtectionOnCaption
        == "On battery, Overtime lets the Mac sleep at the Release at level, and holds again on power or at the Resume at level."
    )
    #expect(
      BatteryPane.batteryProtectionOffCaption
        == "Off: Overtime keeps the Mac awake at any battery level, and macOS still puts it to sleep when the battery is almost empty. The levels below apply when you turn it back on."
    )
    #expect(BatteryPane.helperFloorLabel == "Unplug protection floor")
    #expect(
      BatteryPane.helperFloorCaption
        == "Unplug protection lets the Mac sleep at this level on battery or on power, and also when macOS warns that the battery is low. It applies even with battery protection off, and it can't be turned off."
    )
    #expect(BatteryPane.temperatureTitle == "Temperature")
    #expect(BatteryPane.temperatureProtectionLabel == "Temperature protection")
    #expect(
      BatteryPane.temperatureOnCaption(resumeCelsius: 40)
        == "When the battery reaches the Release at temperature, Overtime lets the Mac sleep so it can cool down, and holds again below 40°C."
    )
    #expect(
      BatteryPane.temperatureOffCaption
        == "Off: Overtime keeps the Mac awake at any battery temperature. The temperature below applies when you turn it back on."
    )
    #expect(
      BatteryPane.temperatureReleaseCaption == "Overtime lets the Mac sleep when the battery reaches this temperature.")
    #expect(BatteryPane.temperatureReadingLabel == "Battery temperature")
    #expect(
      BatteryPane.temperatureUnavailableCaption
        == "This Mac doesn't report a battery temperature, so temperature protection can't act.")
    #expect(
      BatteryPane.helperCeilingCaption(enabled: true)
        == "Unplug protection also lets the Mac sleep at the Release at temperature.")
    #expect(
      BatteryPane.helperCeilingCaption(enabled: false)
        == "With temperature protection off, unplug protection still lets the Mac sleep at 60°C.")
  }
}
