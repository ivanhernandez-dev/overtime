import Foundation

public struct MenuBarPanelToggle: Equatable, Sendable {
  public enum MouseButton: Equatable, Sendable, CaseIterable {
    case left
    case right
  }

  public enum Event: Equatable, Sendable {
    case itemClick(MouseButton)
    case outsideClick
    case escape
    case resignActive
    case resignKey
    case spaceChange
    case windowOpened
    case show

    var isItemClick: Bool {
      if case .itemClick = self { return true }
      return false
    }
  }

  public enum Effect: Equatable, Sendable {
    case present
    case startWatching
    case stopWatching
    case dismiss
  }

  public struct Close: Equatable, Sendable {
    public let cause: Event
    public let at: Double

    public init(cause: Event, at: Double) {
      self.cause = cause
      self.at = at
    }
  }

  public static let reopenGuardSeconds: Double = 0.3

  public private(set) var isShown = false
  public private(set) var shownAt: Double?
  public private(set) var lastClose: Close?

  public init() {}

  public mutating func handle(_ event: Event, at seconds: Double) -> [Effect] {
    switch (isShown, event) {
    case (false, .itemClick):
      if let lastClose, !lastClose.cause.isItemClick, seconds - lastClose.at < Self.reopenGuardSeconds {
        return []
      }
      isShown = true
      shownAt = seconds
      return [.present, .startWatching]
    case (false, .outsideClick), (false, .escape), (false, .resignActive), (false, .resignKey),
      (false, .spaceChange), (false, .windowOpened):
      return []
    case (false, .show):
      isShown = true
      shownAt = seconds
      return [.present, .startWatching]
    case (true, .show):
      return []
    case (true, .outsideClick):
      if let shownAt, seconds <= shownAt {
        return []
      }
      return close(because: event, at: seconds)
    case (true, .itemClick), (true, .escape), (true, .resignActive), (true, .resignKey), (true, .spaceChange),
      (true, .windowOpened):
      return close(because: event, at: seconds)
    }
  }

  private mutating func close(because event: Event, at seconds: Double) -> [Effect] {
    isShown = false
    shownAt = nil
    lastClose = Close(cause: event, at: seconds)
    return [.stopWatching, .dismiss]
  }

  public static func localClickIsOutside(inPanel: Bool, windowLevel: Int?, panelLevel: Int) -> Bool {
    guard !inPanel, let windowLevel else { return false }
    return windowLevel < panelLevel
  }
}
