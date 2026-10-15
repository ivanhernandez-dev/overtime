import AppKit
import Observation
import OvertimeAppSupport

final class StatusItemLabelObserver {
  private let model: PanelModel
  private let apply: (StatusItemLabel) -> Void
  private var applied: StatusItemLabel?
  private var stopped = false
  private var generation = 0
  private(set) var evaluations = 0

  init(model: PanelModel, apply: @escaping (StatusItemLabel) -> Void) {
    self.model = model
    self.apply = apply
  }

  func start() {
    evaluate()
  }

  func evaluate() {
    guard !stopped else { return }
    evaluations += 1
    generation += 1
    let current = generation
    let label = withObservationTracking {
      StatusItemLabel(model.presentation)
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        self?.reevaluate(from: current)
      }
    }
    guard label != applied else { return }
    applied = label
    apply(label)
  }

  func stop() {
    stopped = true
  }

  private func reevaluate(from registration: Int) {
    guard registration == generation else { return }
    evaluate()
  }
}

final class StatusItemController: NSObject {
  static let actionMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
  static let autosaveName = "OvertimeStatusItem"
  static let clickFreshnessSeconds: Double = 1

  static func button(for type: NSEvent.EventType?) -> MenuBarPanelToggle.MouseButton {
    type == .rightMouseDown ? .right : .left
  }

  static func isClick(_ type: NSEvent.EventType?) -> Bool {
    type == .leftMouseDown || type == .rightMouseDown
  }

  static func stamp(
    for type: NSEvent.EventType?, eventSeconds: Double?, uptime: Double
  ) -> (seconds: Double, clicked: Bool) {
    guard isClick(type), let eventSeconds, uptime - eventSeconds <= clickFreshnessSeconds else {
      return (uptime, false)
    }
    return (eventSeconds, true)
  }

  private let item: NSStatusItem
  private let onClick: (MenuBarPanelToggle.MouseButton, Double, Bool) -> Void
  private var labelObserver: StatusItemLabelObserver?

  init(model: PanelModel, onClick: @escaping (MenuBarPanelToggle.MouseButton, Double, Bool) -> Void) {
    self.onClick = onClick
    item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    super.init()
    item.autosaveName = Self.autosaveName
    if let button = item.button {
      button.imagePosition = .imageOnly
      button.target = self
      button.action = #selector(itemClicked(_:))
      button.sendAction(on: Self.actionMask)
    }
    let observer = StatusItemLabelObserver(model: model) { [weak self] label in
      self?.show(label)
    }
    labelObserver = observer
    observer.start()
  }

  var anchorFrame: CGRect? {
    guard let button = item.button, let window = button.window else { return nil }
    return window.convertToScreen(button.convert(button.bounds, to: nil))
  }

  func setHighlighted(_ highlighted: Bool) {
    item.button?.highlight(highlighted)
  }

  private func show(_ label: StatusItemLabel) {
    guard let button = item.button else { return }
    button.image = StatusGlyphImage.image(for: label)
    button.setAccessibilityLabel(label.accessibilityLabel)
  }

  @objc private func itemClicked(_ sender: Any?) {
    let event = NSApp.currentEvent
    let stamp = Self.stamp(
      for: event?.type, eventSeconds: event?.timestamp, uptime: ProcessInfo.processInfo.systemUptime)
    onClick(stamp.clicked ? Self.button(for: event?.type) : .left, stamp.seconds, stamp.clicked)
  }
}
