import SwiftUI

struct AttentionRow: View {
  static let symbol = "exclamationmark.triangle.fill"
  static let reviewLabel = "Review in Settings…"
  static let updateSymbol = "arrow.down.circle"
  static let reviewUpdateLabel = "Review Update…"

  static func accessibilityLabel(_ text: String) -> String {
    "Needs attention: \(text)"
  }

  static func updateAccessibilityLabel(_ text: String) -> String {
    "Update available: \(text)"
  }

  let text: String
  var isUpdate = false
  let review: () -> Void

  var shownSymbol: String {
    isUpdate ? Self.updateSymbol : Self.symbol
  }

  var shownReviewLabel: String {
    isUpdate ? Self.reviewUpdateLabel : Self.reviewLabel
  }

  var shownAccessibilityLabel: String {
    isUpdate ? Self.updateAccessibilityLabel(text) : Self.accessibilityLabel(text)
  }

  private var symbolStyle: AnyShapeStyle {
    isUpdate ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange)
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: StatusRowLayout.iconGap) {
        Image(systemName: shownSymbol)
          .foregroundStyle(symbolStyle)
          .frame(width: StatusRowLayout.iconWidth)
        Text(text)
          .font(.subheadline)
          .monospacedDigit()
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(shownAccessibilityLabel)
      Button(shownReviewLabel, action: review)
        .buttonStyle(.link)
        .font(.subheadline)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
