import AppKit
import SwiftUI

struct PanelVisibility: NSViewRepresentable {
  let report: (ObjectIdentifier, Bool) -> Void

  func makeNSView(context: Context) -> VisibilityProbeView {
    VisibilityProbeView(report: report)
  }

  func updateNSView(_ view: VisibilityProbeView, context: Context) {
    view.report = report
  }

  static func dismantleNSView(_ view: VisibilityProbeView, coordinator: ()) {
    view.stopObserving()
  }
}

final class VisibilityProbeView: NSView {
  var report: (ObjectIdentifier, Bool) -> Void
  private var observer: NSObjectProtocol?
  private var lastReported: Bool?

  init(report: @escaping (ObjectIdentifier, Bool) -> Void) {
    self.report = report
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    stopObserving()
    guard let window else { return }
    observer = NotificationCenter.default.addObserver(
      forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.publish() }
    }
    publish()
  }

  func stopObserving() {
    if let observer {
      NotificationCenter.default.removeObserver(observer)
      self.observer = nil
    }
    send(false)
  }

  private func publish() {
    send(window?.occlusionState.contains(.visible) == true)
  }

  private func send(_ visible: Bool) {
    guard lastReported != visible else { return }
    lastReported = visible
    report(ObjectIdentifier(self), visible)
  }
}
