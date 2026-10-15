import AppKit
import OvertimeAppSupport
import SwiftUI

final class MenuBarPanel: NSPanel {
  var onCancel: () -> Void = {}

  override var canBecomeKey: Bool {
    true
  }

  override var canBecomeMain: Bool {
    false
  }

  override func cancelOperation(_ sender: Any?) {
    onCancel()
  }
}

struct MenuBarPanelContent: View {
  let model: PanelModel

  var body: some View {
    PanelView(model: model)
      .cornerContainer(CornerShapes.panel)
      .overlay {
        CornerShapes.panel
          .strokeBorder(Color(nsColor: .separatorColor), lineWidth: MenuBarPanelController.hairlineWidth)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
  }
}

final class MenuBarPanelController {
  static let styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
  static let level: NSWindow.Level = .popUpMenu
  static let collectionBehavior: NSWindow.CollectionBehavior = [
    .moveToActiveSpace, .transient, .ignoresCycle, .fullScreenAuxiliary,
  ]
  static let cornerRadius = CGFloat(CornerGeometry.panelRadius)
  static let hairlineWidth: CGFloat = 0.5
  static let watchedClicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

  struct Placed {
    let anchor: CGRect?
    let pointer: CGPoint
    let clicked: Bool
  }

  private let model: PanelModel
  private let anchor: () -> CGRect?
  private let setHighlighted: (Bool) -> Void
  private(set) var toggle = MenuBarPanelToggle()
  private(set) var fade = PanelFade()
  private(set) var panel: MenuBarPanel?
  private var hosting: NSHostingController<MenuBarPanelContent>?
  private var placed: Placed?
  private var monitors: [Any] = []
  private var observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []

  init(model: PanelModel, anchor: @escaping () -> CGRect?, setHighlighted: @escaping (Bool) -> Void) {
    self.model = model
    self.anchor = anchor
    self.setHighlighted = setHighlighted
  }

  var isWatching: Bool {
    !monitors.isEmpty || !observers.isEmpty
  }

  func send(_ event: MenuBarPanelToggle.Event, at seconds: Double, clicked: Bool = false) {
    for effect in toggle.handle(event, at: seconds) {
      perform(effect, clicked: clicked)
    }
  }

  func show(at seconds: Double) {
    send(.show, at: seconds)
  }

  private func perform(_ effect: MenuBarPanelToggle.Effect, clicked: Bool) {
    switch effect {
    case .present:
      present(clicked: clicked)
    case .startWatching:
      startWatching()
    case .stopWatching:
      stopWatching()
    case .dismiss:
      dismiss()
    }
  }

  private func present(clicked: Bool) {
    let panel = self.panel ?? makePanel()
    fade.present()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0
      panel.animator().alphaValue = 1
    }
    panel.ignoresMouseEvents = false
    panel.layoutIfNeeded()
    placed = Placed(anchor: anchor(), pointer: NSEvent.mouseLocation, clicked: clicked)
    place(panel)
    panel.orderFrontRegardless()
    panel.makeKey()
    setHighlighted(true)
  }

  private func dismiss() {
    setHighlighted(false)
    guard let panel else { return }
    let token = fade.beginClose()
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    guard let seconds = Motion.duration(.panelClose, reduceMotion: reduceMotion) else {
      finishClose(token)
      return
    }
    panel.ignoresMouseEvents = true
    NSAnimationContext.runAnimationGroup { context in
      context.duration = seconds
      panel.animator().alphaValue = 0
    } completionHandler: { [weak self] in
      MainActor.assumeIsolated {
        self?.finishClose(token)
      }
    }
  }

  private func finishClose(_ token: Int) {
    guard fade.mayOrderOut(token), let panel else { return }
    panel.orderOut(nil)
    panel.alphaValue = 1
    panel.ignoresMouseEvents = false
  }

  private func place(_ panel: MenuBarPanel) {
    guard let placed else { return }
    let screens = NSScreen.screens.map { screen in
      MenuBarPanelPlacement.Screen(frame: screen.frame, visibleFrame: screen.visibleFrame)
    }
    let origin = MenuBarPanelPlacement.origin(
      panelSize: panel.frame.size, anchor: placed.anchor, pointer: placed.pointer, clicked: placed.clicked,
      screens: screens)
    if panel.frame.origin != origin {
      panel.setFrameOrigin(origin)
    }
  }

  private func makePanel() -> MenuBarPanel {
    let hosting = NSHostingController(rootView: MenuBarPanelContent(model: model))
    hosting.sizingOptions = [.preferredContentSize]
    let content = hosting.view
    let panel = MenuBarPanel(
      contentRect: CGRect(origin: .zero, size: content.fittingSize), styleMask: Self.styleMask, backing: .buffered,
      defer: true)
    panel.level = Self.level
    panel.collectionBehavior = Self.collectionBehavior
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.animationBehavior = .none
    panel.onCancel = { [weak self] in
      self?.send(.escape, at: ProcessInfo.processInfo.systemUptime)
    }
    let material = NSVisualEffectView()
    material.material = .popover
    material.blendingMode = .behindWindow
    material.state = .active
    material.maskImage = Self.cornerMask()
    panel.contentView = material
    content.translatesAutoresizingMaskIntoConstraints = false
    material.addSubview(content)
    let edges = [
      content.leadingAnchor.constraint(equalTo: material.leadingAnchor),
      content.trailingAnchor.constraint(equalTo: material.trailingAnchor),
      content.topAnchor.constraint(equalTo: material.topAnchor),
      content.bottomAnchor.constraint(equalTo: material.bottomAnchor),
    ]
    for edge in edges {
      edge.isActive = true
    }
    self.hosting = hosting
    self.panel = panel
    return panel
  }

  static func cornerMask() -> NSImage {
    let cap = ceil(CGFloat(CornerGeometry.maskCapFactor) * cornerRadius)
    let edge = cap * 2 + 1
    let shape = CornerShapes.panel
    let mask = NSImage(size: CGSize(width: edge, height: edge), flipped: false) { rect in
      guard let context = NSGraphicsContext.current?.cgContext else { return false }
      context.addPath(shape.path(in: rect).cgPath)
      context.setFillColor(NSColor.black.cgColor)
      context.fillPath()
      return true
    }
    mask.capInsets = NSEdgeInsets(top: cap, left: cap, bottom: cap, right: cap)
    mask.resizingMode = .stretch
    return mask
  }

  private func startWatching() {
    guard !isWatching, let panel else { return }
    let global = NSEvent.addGlobalMonitorForEvents(matching: Self.watchedClicks) { [weak self] event in
      let seconds = event.timestamp
      MainActor.assumeIsolated {
        self?.send(.outsideClick, at: seconds)
      }
    }
    let local = NSEvent.addLocalMonitorForEvents(matching: Self.watchedClicks) { [weak self] event in
      let seconds = event.timestamp
      let window = event.window
      MainActor.assumeIsolated {
        self?.localClick(in: window, at: seconds)
      }
      return event
    }
    monitors = [global, local].compactMap { $0 }
    let center = NotificationCenter.default
    observe(NSWindow.didResignKeyNotification, object: panel, on: center) { controller in
      controller.send(.resignKey, at: ProcessInfo.processInfo.systemUptime)
    }
    observe(NSApplication.didResignActiveNotification, object: NSApp, on: center) { controller in
      controller.send(.resignActive, at: ProcessInfo.processInfo.systemUptime)
    }
    let workspace = NSWorkspace.shared.notificationCenter
    observe(NSWorkspace.activeSpaceDidChangeNotification, object: nil, on: workspace) { controller in
      controller.send(.spaceChange, at: ProcessInfo.processInfo.systemUptime)
    }
    observe(NSWindow.didBecomeKeyNotification, object: nil, on: center) { controller in
      controller.anotherWindowBecameKey()
    }
    observe(NSWindow.didResizeNotification, object: panel, on: center) { controller in
      controller.contentResized()
    }
  }

  private func stopWatching() {
    for monitor in monitors {
      NSEvent.removeMonitor(monitor)
    }
    monitors = []
    for observer in observers {
      observer.center.removeObserver(observer.token)
    }
    observers = []
  }

  private func observe(
    _ name: Notification.Name, object: AnyObject?, on center: NotificationCenter,
    _ handler: @escaping @MainActor (MenuBarPanelController) -> Void
  ) {
    let token = center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        handler(self)
      }
    }
    observers.append((center, token))
  }

  private func localClick(in window: NSWindow?, at seconds: Double) {
    guard let panel else { return }
    let outside = MenuBarPanelToggle.localClickIsOutside(
      inPanel: window === panel, windowLevel: window?.level.rawValue, panelLevel: panel.level.rawValue)
    if outside {
      send(.outsideClick, at: seconds)
    }
  }

  private func anotherWindowBecameKey() {
    guard let panel, let key = NSApp.keyWindow, key !== panel, key.level.rawValue < panel.level.rawValue else {
      return
    }
    send(.windowOpened, at: ProcessInfo.processInfo.systemUptime)
  }

  private func contentResized() {
    guard toggle.isShown, let panel else { return }
    place(panel)
  }
}
