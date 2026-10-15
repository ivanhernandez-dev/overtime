import AppKit
import OvertimeAppSupport
import SwiftUI

enum StatusGlyphImage {
  static let pointSize = NSSize(width: 18, height: 18)

  static func catalogImage(named assetName: String, in bundle: Bundle = .main) -> NSImage? {
    guard let image = bundle.image(forResource: assetName)?.copy() as? NSImage else { return nil }
    image.size = pointSize
    image.isTemplate = true
    return image
  }

  static func image(
    assetName: String, fallbackSymbol: String, accessibilityLabel: String, in bundle: Bundle = .main
  ) -> NSImage? {
    if let image = catalogImage(named: assetName, in: bundle) {
      image.accessibilityDescription = accessibilityLabel
      return image
    }
    guard let symbol = NSImage(systemSymbolName: fallbackSymbol, accessibilityDescription: accessibilityLabel) else {
      return nil
    }
    symbol.isTemplate = true
    return symbol
  }

  static func image(for label: StatusItemLabel, in bundle: Bundle = .main) -> NSImage? {
    image(
      assetName: label.glyph.assetName, fallbackSymbol: label.fallbackSymbol,
      accessibilityLabel: label.accessibilityLabel, in: bundle)
  }
}

struct StatusGlyphView: View, Equatable {
  static let side = CGFloat(PrismLayout.indicatorGlyphSide)

  let label: StatusItemLabel

  var body: some View {
    if let image = StatusGlyphImage.image(for: label) {
      Image(nsImage: image)
        .renderingMode(.template)
        .resizable()
        .scaledToFit()
        .frame(width: Self.side, height: Self.side)
        .foregroundStyle(.white)
        .accessibilityHidden(true)
    } else {
      Color.clear
        .frame(width: Self.side, height: Self.side)
        .accessibilityHidden(true)
    }
  }
}
