import OvertimeAppSupport
import SwiftUI

struct OnboardingCheckRows: View {
  let model: OnboardingModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(model.checkRows) { row in
        OnboardingCheckRowView(row: row) { link in model.open(link) }
      }
      switch model.systemSleep {
      case .row(let row):
        OnboardingCheckRowView(row: row) { link in model.open(link) }
      case .sleepDisabledRow:
        if let helper = model.helper {
          SleepDisabledRow(model: helper)
        }
      case .nothing:
        EmptyView()
      }
    }
  }

  static func tint(for icon: CheckRow.Icon) -> Color {
    switch icon {
    case .pass: .green
    case .warning: .orange
    case .info: .secondary
    }
  }
}

struct OnboardingCheckRowView: View {
  let row: CheckRow
  let open: (CheckRow.Link) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      StatusRow(
        symbol: row.icon.symbol, tint: OnboardingCheckRows.tint(for: row.icon), title: row.title,
        caption: row.caption)
      if let link = row.link {
        Button(link.label) { open(link) }
          .buttonStyle(.link)
          .font(.subheadline)
          .padding(.leading, StatusRowLayout.textInset)
      }
    }
  }
}
