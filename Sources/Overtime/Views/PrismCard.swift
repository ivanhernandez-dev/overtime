import AppKit
import OvertimeAppSupport
import SwiftUI

struct PrismCard<Content: View>: View {
  static var magentaCenter: UnitPoint { UnitPoint(x: 0.92, y: -0.15) }
  static var cyanCenter: UnitPoint { UnitPoint(x: 1.05, y: 0.4) }
  static var magentaRadius: CGFloat { 130 }
  static var cyanRadius: CGFloat { 120 }
  static var defaultPadding: EdgeInsets {
    let padding = CGFloat(PrismLayout.cardPadding)
    return EdgeInsets(top: padding, leading: padding, bottom: padding, trailing: padding)
  }

  let lit: Bool
  let shape: AnyShape
  let padding: EdgeInsets
  let content: Content
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.colorScheme) private var colorScheme

  init(lit: Bool, shape: AnyShape, padding: EdgeInsets = PrismCard.defaultPadding, @ViewBuilder content: () -> Content)
  {
    self.lit = lit
    self.shape = shape
    self.padding = padding
    self.content = content()
  }

  var body: some View {
    let look = resolvedLook(
      lit: lit, reduceTransparency: reduceTransparency, contrast: colorSchemeContrast, colorScheme: colorScheme)
    content
      .padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background {
        ZStack {
          Color(nsColor: .controlBackgroundColor)
          if look.showsGlow {
            glow(look.glow)
          }
        }
        .clipShape(shape)
        .accessibilityHidden(true)
      }
      .overlay {
        shape
          .stroke(Color(nsColor: .separatorColor), lineWidth: CGFloat(PrismLayout.edgeWidth) * 2)
          .clipShape(shape)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
  }

  private func glow(_ glow: PrismGlow) -> some View {
    ZStack {
      RadialGradient(
        colors: [PrismPalette.magenta.color.opacity(glow.magenta), PrismPalette.magenta.color.opacity(0)],
        center: Self.magentaCenter, startRadius: 0, endRadius: Self.magentaRadius)
      RadialGradient(
        colors: [PrismPalette.cyan.color.opacity(glow.cyan), PrismPalette.cyan.color.opacity(0)],
        center: Self.cyanCenter, startRadius: 0, endRadius: Self.cyanRadius)
    }
  }
}

private func resolvedLook(
  lit: Bool, reduceTransparency: Bool, contrast: ColorSchemeContrast, colorScheme: ColorScheme
) -> PrismLook {
  PrismLook.resolve(
    lit: lit, appearance: colorScheme == .dark ? .dark : .light, reduceTransparency: reduceTransparency,
    increaseContrast: contrast == .increased)
}

extension PrismColor {
  var color: Color {
    Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
  }
}
