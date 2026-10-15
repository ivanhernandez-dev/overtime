import Foundation

public enum MenuBarPanelPlacement {
  public struct Screen: Equatable, Sendable {
    public let frame: CGRect
    public let visibleFrame: CGRect

    public init(frame: CGRect, visibleFrame: CGRect) {
      self.frame = frame
      self.visibleFrame = visibleFrame
    }

    public static func == (lhs: Screen, rhs: Screen) -> Bool {
      MenuBarPanelPlacement.same(lhs.frame, rhs.frame)
        && MenuBarPanelPlacement.same(lhs.visibleFrame, rhs.visibleFrame)
    }
  }

  public static let gap: CGFloat = 4
  public static let edgeMargin: CGFloat = 8
  public static let anchorSlack: CGFloat = 8

  public static func usableAnchor(_ anchor: CGRect?, pointer: CGPoint, clicked: Bool) -> CGRect? {
    guard let anchor, anchor.size.width > 0, anchor.size.height > 0 else { return nil }
    guard clicked else { return anchor }
    let insideX = pointer.x >= left(anchor) - anchorSlack && pointer.x <= right(anchor) + anchorSlack
    let insideY = pointer.y >= bottom(anchor) - anchorSlack && pointer.y <= top(anchor) + anchorSlack
    return insideX && insideY ? anchor : nil
  }

  public static func screen(containing point: CGPoint, in screens: [Screen]) -> Screen? {
    let underTheTopEdge = screens.first { screen in
      point.x >= left(screen.frame) && point.x < right(screen.frame) && point.y > bottom(screen.frame)
        && point.y <= top(screen.frame)
    }
    let onAnyEdge = screens.first { screen in
      point.x >= left(screen.frame) && point.x <= right(screen.frame) && point.y >= bottom(screen.frame)
        && point.y <= top(screen.frame)
    }
    return underTheTopEdge ?? onAnyEdge ?? screens.first
  }

  public static func origin(
    panelSize: CGSize, anchor: CGRect?, pointer: CGPoint, clicked: Bool, screens: [Screen]
  ) -> CGPoint {
    let usable = usableAnchor(anchor, pointer: pointer, clicked: clicked)
    let reference =
      usable.map { CGPoint(x: left($0) + $0.size.width / 2, y: bottom($0) + $0.size.height / 2) } ?? pointer
    var x = usable.map { left($0) } ?? (pointer.x - panelSize.width / 2)
    var topEdge = usable.map { bottom($0) } ?? pointer.y
    if let display = screen(containing: reference, in: screens) {
      let lowest = left(display.visibleFrame) + edgeMargin
      let highest = right(display.visibleFrame) - edgeMargin - panelSize.width
      x = highest < lowest ? lowest : min(max(x, lowest), highest)
      topEdge = usable.map { min(bottom($0), top(display.visibleFrame)) } ?? top(display.visibleFrame)
    }
    return CGPoint(x: x, y: topEdge - gap - panelSize.height)
  }

  static func same(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
    lhs.origin.x == rhs.origin.x && lhs.origin.y == rhs.origin.y && lhs.size.width == rhs.size.width
      && lhs.size.height == rhs.size.height
  }

  private static func left(_ rect: CGRect) -> CGFloat {
    rect.origin.x
  }

  private static func right(_ rect: CGRect) -> CGFloat {
    rect.origin.x + rect.size.width
  }

  private static func bottom(_ rect: CGRect) -> CGFloat {
    rect.origin.y
  }

  private static func top(_ rect: CGRect) -> CGFloat {
    rect.origin.y + rect.size.height
  }
}
