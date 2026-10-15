import AppKit
import OvertimeAppSupport
import SwiftUI

struct PrismIndicator<Content: View>: View {
  let lit: Bool
  let content: Content
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.colorScheme) private var colorScheme

  init(lit: Bool, @ViewBuilder content: () -> Content) {
    self.lit = lit
    self.content = content()
  }

  var body: some View {
    let look = PrismLook.resolve(
      lit: lit, appearance: colorScheme == .dark ? .dark : .light, reduceTransparency: reduceTransparency,
      increaseContrast: colorSchemeContrast == .increased)
    let side = CGFloat(PrismLayout.indicatorSide)
    ZStack {
      Circle()
        .fill(PrismPalette.indicatorColor(look.indicator)?.color ?? Color(nsColor: .systemGray))
      content
        .environment(\.colorScheme, .dark)
    }
    .frame(width: side, height: side)
    .accessibilityHidden(true)
  }
}
