import OvertimeAppSupport
import OvertimeHelperCore
import SwiftUI

struct BatteryPane: View {
  static let releaseCaption =
    "On battery at or below this level, Overtime stops keeping the Mac awake so it can sleep."
  static let resumeCaption = "Overtime resumes on power, or when the battery reaches this level."
  static let helperCaption =
    "Unplug protection also releases at \(HelperMachine.batteryFloorPercent)% on its own. That limit is fixed."

  let model: SettingsModel

  var body: some View {
    Form {
      SaveErrorSection(model: model)
      Section {
        NumericSettingRow(
          label: "Release at", unit: "%", caption: Self.releaseCaption, field: .batteryLowPercent, model: model)
        NumericSettingRow(
          label: "Resume at", unit: "%", caption: Self.resumeCaption, field: .batteryResumePercent, model: model)
      } footer: {
        if model.helperInstalled {
          SettingsSectionCaption(text: Self.helperCaption)
        }
      }
    }
    .formStyle(.grouped)
    .transaction { $0.animation = nil }
  }
}
