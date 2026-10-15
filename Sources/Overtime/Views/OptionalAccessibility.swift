import SwiftUI

extension View {
  @ViewBuilder
  func accessibilityHint(ifPresent hint: String?) -> some View {
    if #available(macOS 15, *) {
      accessibilityHint(Text(hint ?? ""), isEnabled: hint != nil)
    } else {
      accessibilityHint(Text(hint ?? ""))
    }
  }

  @ViewBuilder
  func help(ifPresent text: String?) -> some View {
    if let text {
      help(text)
    } else {
      self
    }
  }
}
