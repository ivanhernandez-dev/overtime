import OvertimeAppSupport
import SwiftUI

struct SleepDisabledRow: View {
  static let symbol = "exclamationmark.triangle.fill"
  static let turnOnLabel = "Turn Sleep Back On…"

  let model: HelperPaneModel

  var body: some View {
    if model.showsSleepDisabledRow {
      SleepDisabledRowContent(
        caption: SleepDisabledClearing.rowCaption, clearing: model.clearing, clearCaption: model.clearCaption,
        turnOn: { Task { await model.turnSleepBackOn() } }, copy: { model.copyCommand() })
    }
  }
}

struct SleepDisabledRowContent: View {
  let caption: String
  let clearing: Bool
  let clearCaption: String?
  let turnOn: () -> Void
  let copy: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      StatusRow(
        symbol: SleepDisabledRow.symbol, tint: .orange, title: SleepDisabledClearing.rowTitle, caption: caption)
      HStack(spacing: 8) {
        Button(SleepDisabledRow.turnOnLabel, action: turnOn)
          .buttonStyle(.bordered)
          .controlSize(.regular)
          .disabled(clearing)
        CopyCommandButton(label: SleepDisabledClearing.copyLabel, copy: copy)
      }
      .padding(.leading, StatusRowLayout.textInset)
      if let clearCaption {
        SettingsSectionCaption(text: clearCaption)
          .padding(.leading, StatusRowLayout.textInset)
      }
    }
  }
}
