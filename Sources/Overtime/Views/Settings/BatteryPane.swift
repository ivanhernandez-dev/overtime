import OvertimeAppSupport
import OvertimeCore
import SwiftUI

struct BatteryPane: View {
  static let batteryProtectionLabel = "Battery protection"
  static let batteryProtectionOnCaption =
    "On battery, Overtime lets the Mac sleep at the Release at level, and holds again on power or at the Resume at level."
  static let batteryProtectionOffCaption =
    "Off: Overtime keeps the Mac awake at any battery level, and macOS still puts it to sleep when the battery is almost empty. The levels below apply when you turn it back on."
  static let releaseCaption =
    "On battery at or below this level, Overtime stops keeping the Mac awake so it can sleep."
  static let resumeCaption = "Overtime resumes on power, or when the battery reaches this level."
  static let helperFloorLabel = "Unplug protection floor"
  static let helperFloorCaption =
    "Unplug protection lets the Mac sleep at this level on battery or on power, and also when macOS warns that the battery is low. It applies even with battery protection off, and it can't be turned off."
  static let temperatureTitle = "Temperature"
  static let temperatureProtectionLabel = "Temperature protection"
  static let temperatureOffCaption =
    "Off: Overtime keeps the Mac awake at any battery temperature. The temperature below applies when you turn it back on."
  static let temperatureReleaseCaption = "Overtime lets the Mac sleep when the battery reaches this temperature."
  static let temperatureReadingLabel = "Battery temperature"
  static let temperatureUnavailableCaption =
    "This Mac doesn't report a battery temperature, so temperature protection can't act."

  static func temperatureOnCaption(resumeCelsius: Int) -> String {
    "When the battery reaches the Release at temperature, Overtime lets the Mac sleep so it can cool down, and holds again below \(resumeCelsius)°C."
  }

  static func helperCeilingCaption(enabled: Bool) -> String {
    enabled
      ? "Unplug protection also lets the Mac sleep at the Release at temperature."
      : "With temperature protection off, unplug protection still lets the Mac sleep at \(HelperIntent.helperTemperatureCeilingCelsius)°C."
  }

  let model: SettingsModel

  var body: some View {
    Form {
      SaveErrorSection(model: model)
      batterySection
      if model.helperInstalled {
        Section {
          NumericSettingRow(
            label: Self.helperFloorLabel, unit: "%", caption: Self.helperFloorCaption,
            field: .helperBatteryFloorPercent, model: model)
        }
      }
      temperatureSection
    }
    .formStyle(.grouped)
    .transaction { $0.animation = nil }
  }

  private var batterySection: some View {
    let enabled = model.batteryProtectionEnabled
    let caption = enabled ? Self.batteryProtectionOnCaption : Self.batteryProtectionOffCaption
    return Section {
      SwitchRow(label: Self.batteryProtectionLabel, caption: caption, isOn: enabled, model: model) { enabled in
        await model.setBatteryProtectionEnabled(enabled)
      }
      NumericSettingRow(
        label: "Release at", unit: "%", caption: Self.releaseCaption, field: .batteryLowPercent, model: model,
        secondary: !enabled)
      NumericSettingRow(
        label: "Resume at", unit: "%", caption: Self.resumeCaption, field: .batteryResumePercent, model: model,
        secondary: !enabled)
    }
  }

  private var temperatureSection: some View {
    let enabled = model.temperatureProtectionEnabled
    let caption =
      enabled
      ? Self.temperatureOnCaption(resumeCelsius: model.settings.temperatureResumeCelsius) : Self.temperatureOffCaption
    return Section {
      SwitchRow(label: Self.temperatureProtectionLabel, caption: caption, isOn: enabled, model: model) { enabled in
        await model.setTemperatureProtectionEnabled(enabled)
      }
      NumericSettingRow(
        label: "Release at", unit: "°C", caption: Self.temperatureReleaseCaption, field: .temperatureReleaseCelsius,
        model: model, secondary: !enabled)
      VStack(alignment: .leading, spacing: 4) {
        LabeledContent(Self.temperatureReadingLabel) {
          Text(model.batteryTemperatureText)
            .monospacedDigit()
        }
        if model.batteryTemperature == .unavailable {
          SettingsSectionCaption(text: Self.temperatureUnavailableCaption)
        }
      }
    } header: {
      SettingsSectionHeader(title: Self.temperatureTitle)
    } footer: {
      if model.helperInstalled {
        SettingsSectionCaption(text: Self.helperCeilingCaption(enabled: enabled))
      }
    }
  }
}

private struct SwitchRow: View {
  let label: String
  let caption: String
  let isOn: Bool
  let model: SettingsModel
  let set: @MainActor (Bool) async -> SettingsCommitResult?

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Toggle(
        label,
        isOn: Binding(
          get: { isOn },
          set: { enabled in
            Task { _ = await set(enabled) }
          })
      )
      .toggleStyle(.switch)
      .controlSize(.mini)
      .disabled(!model.canEdit)
      .accessibilityHint(Text(caption))
      SettingsSectionCaption(text: caption)
        .accessibilityHidden(true)
    }
  }
}
