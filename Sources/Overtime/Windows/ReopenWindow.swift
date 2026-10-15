import SwiftUI

struct ReopenWindow: View {
  static let banner =
    "Overtime runs in the menu bar. If you can't see its icon, the menu bar may be full, "
    + "or the icon may be hidden in System Settings > Menu Bar."
  static let closeLabel = "Close Window"

  let model: PanelModel
  let close: () -> Void

  var body: some View {
    PanelView(model: model, banner: Self.banner)
      .frame(width: 320)
      .background {
        Button(Self.closeLabel, action: close)
          .keyboardShortcut("w")
          .frame(width: 0, height: 0)
          .opacity(0)
          .accessibilityHidden(true)
        if !model.sleepConfirmation.isConfirming {
          Button(Self.closeLabel, action: close)
            .keyboardShortcut(.cancelAction)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
      }
  }

  static func controller(model: PanelModel) -> AuxiliaryWindowController {
    let window = WindowReference()
    let controller = AuxiliaryWindowController(title: "Overtime", contentSize: CGSize(width: 320, height: 240)) {
      AnyView(ReopenWindow(model: model) { window.controller?.close() })
    }
    window.controller = controller
    return controller
  }
}

private final class WindowReference {
  weak var controller: AuxiliaryWindowController?
}
