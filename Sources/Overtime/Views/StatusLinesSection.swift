import OvertimeAppSupport
import SwiftUI

struct StatusChipRow: View {
  let chips: [StatusChip]

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 4) {
        ForEach(chips) { chip in
          StatusChipView(chip: chip)
        }
      }
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 4) {
          ForEach(chips.filter { $0.kind != .network }) { chip in
            StatusChipView(chip: chip)
          }
        }
        ForEach(chips.filter { $0.kind == .network }) { chip in
          StatusChipView(chip: chip)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct StatusChipView: View {
  let chip: StatusChip

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: chip.symbol)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(chip.text)
        .foregroundStyle(.primary)
    }
    .font(.subheadline)
    .padding(.horizontal, CGFloat(CornerGeometry.chipHorizontalPadding))
    .padding(.vertical, CGFloat(CornerGeometry.chipVerticalPadding))
    .background(.quaternary, in: Capsule())
    .fixedSize()
    .help(chip.help)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(chip.accessibilityText)
  }
}

struct StatusDetailsSection: View {
  let details: [StatusDetail]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(details) { detail in
        HStack(alignment: .firstTextBaseline, spacing: StatusRowLayout.iconGap) {
          Image(systemName: detail.symbol)
            .frame(width: StatusRowLayout.iconWidth)
          Text(detail.text)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityHidden(true)
  }
}
