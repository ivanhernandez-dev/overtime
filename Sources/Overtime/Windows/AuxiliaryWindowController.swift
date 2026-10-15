import AppKit
import SwiftUI

final class AuxiliaryWindowController {
  static let styleMask: NSWindow.StyleMask = [.titled, .closable]

  private(set) var title: String
  let contentSize: CGSize
  private let makeContent: () -> AnyView
  private let closeGate: CloseGate

  private(set) var window: NSWindow?

  init(
    title: String, contentSize: CGSize, shouldClose: @escaping () -> Bool = { true },
    didClose: @escaping () -> Void = {}, makeContent: @escaping () -> AnyView
  ) {
    self.title = title
    self.contentSize = contentSize
    self.makeContent = makeContent
    closeGate = CloseGate(shouldClose: shouldClose, didClose: didClose)
  }

  var allowsClose: Bool {
    closeGate.shouldClose()
  }

  var didClose: () -> Void {
    closeGate.didClose
  }

  func show() {
    if window == nil {
      let hosting = NSHostingController(rootView: makeContent())
      hosting.sizingOptions = [.preferredContentSize]
      let window = NSWindow(contentViewController: hosting)
      window.title = title
      window.styleMask = Self.styleMask
      window.isReleasedWhenClosed = false
      window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
      window.hidesOnDeactivate = false
      window.delegate = closeGate
      window.setContentSize(contentSize)
      window.center()
      self.window = window
    }
    NSApplication.shared.activate()
    window?.orderFrontRegardless()
    window?.makeKey()
  }

  func setTitle(_ title: String) {
    self.title = title
    window?.title = title
  }

  func close() {
    window?.close()
  }
}

final class CloseGate: NSObject, NSWindowDelegate {
  let shouldClose: () -> Bool
  let didClose: () -> Void

  init(shouldClose: @escaping () -> Bool, didClose: @escaping () -> Void) {
    self.shouldClose = shouldClose
    self.didClose = didClose
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    shouldClose()
  }

  func windowWillClose(_ notification: Notification) {
    didClose()
  }
}
