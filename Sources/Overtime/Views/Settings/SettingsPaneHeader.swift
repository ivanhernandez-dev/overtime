import OvertimeAppSupport
import SwiftUI

struct SettingsPaneHeader: View {
  static let horizontalInset: CGFloat = 20
  static let topInset: CGFloat = 16
  static let tileGap: CGFloat = 12
  static let textGap: CGFloat = 4
  static var cardPadding: EdgeInsets {
    let tilePadding = CGFloat(CornerGeometry.paneHeaderTilePadding)
    return EdgeInsets(
      top: tilePadding, leading: tilePadding, bottom: tilePadding, trailing: CGFloat(PrismLayout.cardPadding))
  }

  let pane: SettingsPane

  var body: some View {
    PrismCard(lit: true, shape: AnyShape(CornerShapes.paneHeaderCard), padding: Self.cardPadding) {
      HStack(spacing: Self.tileGap) {
        SettingsTile(pane: pane, size: .header)
        VStack(alignment: .leading, spacing: Self.textGap) {
          Text(pane.title)
            .font(.title2)
            .fontWeight(.semibold)
          Text(pane.summary)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .cornerContainer(CornerShapes.paneHeaderCard)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
    .padding(.horizontal, Self.horizontalInset)
    .padding(.top, Self.topInset)
  }
}
