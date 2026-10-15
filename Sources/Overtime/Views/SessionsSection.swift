import AppKit
import OvertimeAppSupport
import SwiftUI

struct SessionsSection: View {
  let list: SessionList

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(PanelContent.header)
        .font(.subheadline)
        .fontWeight(.semibold)
        .foregroundStyle(.secondary)
      if let placeholder = list.placeholder {
        HStack(alignment: .firstTextBaseline, spacing: StatusRowLayout.iconGap) {
          SessionIcon()
          VStack(alignment: .leading, spacing: 4) {
            Text(placeholder.heading)
              .font(.body)
              .foregroundStyle(.secondary)
            Text(placeholder.body)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .accessibilityElement(children: .combine)
      }
      ForEach(list.rows) { row in
        SessionRowView(row: row)
      }
      if let summary = list.summaryText {
        Text(summary)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .padding(.leading, StatusRowLayout.textInset)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct SessionIcon: View {
  static let tileSide: CGFloat = 20
  static let glyphSide: CGFloat = 12

  var body: some View {
    Image(systemName: PanelContent.sessionIcon)
      .resizable()
      .scaledToFit()
      .foregroundStyle(.white)
      .frame(width: Self.glyphSide, height: Self.glyphSide)
      .frame(width: Self.tileSide, height: Self.tileSide)
      .background(Color(nsColor: .systemGray), in: CornerShapes.sessionTile)
      .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
      .frame(width: StatusRowLayout.iconWidth)
      .accessibilityHidden(true)
  }
}

struct SessionRowView: View {
  let row: SessionRow

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: StatusRowLayout.iconGap) {
      SessionIcon()
      Text(row.title)
        .font(.body)
        .lineLimit(1)
        .truncationMode(.middle)
        .help(row.fullPath)
      Spacer(minLength: 8)
      Text(row.caption)
        .font(.subheadline)
        .foregroundStyle(Color.green)
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(row.accessibilityText)
  }
}
