import CoreGraphics
import Foundation
import OvertimeAppSupport
import Testing

struct MenuBarPanelPlacementTests {
  typealias Placement = MenuBarPanelPlacement

  static let main = Placement.Screen(
    frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))
  static let toTheRight = Placement.Screen(
    frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
    visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1055))
  static let toTheLeft = Placement.Screen(
    frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
    visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1055))
  static let above = Placement.Screen(
    frame: CGRect(x: 0, y: 900, width: 1440, height: 900), visibleFrame: CGRect(x: 0, y: 900, width: 1440, height: 875))
  static let panel = CGSize(width: 320, height: 400)

  static func item(x: CGFloat, on screen: Placement.Screen = main) -> CGRect {
    CGRect(
      x: x, y: screen.visibleFrame.maxY, width: 30, height: screen.frame.maxY - screen.visibleFrame.maxY)
  }

  static func centre(of rect: CGRect) -> CGPoint {
    CGPoint(x: rect.midX, y: rect.midY)
  }

  static func clickedOrigin(
    anchor: CGRect, size: CGSize = panel, screens: [Placement.Screen] = [main]
  ) -> CGPoint {
    Placement.origin(panelSize: size, anchor: anchor, pointer: centre(of: anchor), clicked: true, screens: screens)
  }

  @Test func thePanelHangsUnderTheItemWithItsLeadingEdgeAligned() {
    let origin = Self.clickedOrigin(anchor: CGRect(x: 1000, y: 875, width: 30, height: 25))
    #expect(origin.x == 1000)
    #expect(origin.y == 875 - Placement.gap - 400)
  }

  @Test func anItemNearTheTrailingEdgeShiftsThePanelInsideTheVisibleFrame() {
    let origin = Self.clickedOrigin(anchor: Self.item(x: 1400))
    #expect(origin.x == 1440 - Placement.edgeMargin - 320)
    #expect(origin.y == 875 - Placement.gap - 400)
  }

  @Test func anItemNearTheLeadingEdgeKeepsTheMargin() {
    let origin = Self.clickedOrigin(anchor: Self.item(x: 2))
    #expect(origin.x == Placement.edgeMargin)
    #expect(origin.y == 875 - Placement.gap - 400)
  }

  @Test(arguments: [
    MenuBarPanelPlacementTests.toTheRight, MenuBarPanelPlacementTests.toTheLeft, MenuBarPanelPlacementTests.above,
  ])
  func thePanelStaysOnTheDisplayThatHoldsTheItem(second: Placement.Screen) {
    let anchor = Self.item(x: second.frame.midX, on: second)
    let origin = Self.clickedOrigin(anchor: anchor, screens: [Self.main, second])
    #expect(origin.x == anchor.minX)
    #expect(origin.x >= second.visibleFrame.minX + Placement.edgeMargin)
    #expect(origin.x + Self.panel.width <= second.visibleFrame.maxX - Placement.edgeMargin)
    #expect(origin.y + Self.panel.height == second.visibleFrame.maxY - Placement.gap)

    let trailing = Self.item(x: second.frame.maxX - 20, on: second)
    let shifted = Self.clickedOrigin(anchor: trailing, screens: [Self.main, second])
    #expect(shifted.x == second.visibleFrame.maxX - Placement.edgeMargin - Self.panel.width)
    #expect(shifted.y + Self.panel.height == second.visibleFrame.maxY - Placement.gap)
  }

  @Test func theTopNeverRisesAboveTheVisibleFrame() {
    let high = Self.clickedOrigin(anchor: CGRect(x: 1000, y: 880, width: 30, height: 20))
    #expect(high.y + Self.panel.height == Self.main.visibleFrame.maxY - Placement.gap)

    let hiddenMenuBar = Placement.Screen(frame: Self.main.frame, visibleFrame: Self.main.frame)
    let revealed = CGRect(x: 1000, y: 876, width: 30, height: 24)
    let low = Self.clickedOrigin(anchor: revealed, screens: [hiddenMenuBar])
    #expect(low.y + Self.panel.height == revealed.minY - Placement.gap)
    #expect(low.x == 1000)
  }

  @Test func aPanelTallerThanTheScreenKeepsItsTopUnderTheMenuBar() {
    let origin = Self.clickedOrigin(anchor: Self.item(x: 1000), size: CGSize(width: 320, height: 2000))
    #expect(origin.y == 875 - Placement.gap - 2000)
    #expect(origin.x == 1000)
  }

  @Test(arguments: [nil, CGRect.zero] as [CGRect?])
  func aMissingOrEmptyItemFrameUsesThePointer(anchor: CGRect?) {
    let centred = Placement.origin(
      panelSize: Self.panel, anchor: anchor, pointer: CGPoint(x: 700, y: 890), clicked: true, screens: [Self.main])
    #expect(centred.x == 700 - Self.panel.width / 2)
    #expect(centred.y + Self.panel.height == 875 - Placement.gap)

    let trailing = Placement.origin(
      panelSize: Self.panel, anchor: anchor, pointer: CGPoint(x: 1430, y: 890), clicked: true, screens: [Self.main])
    #expect(trailing.x == 1440 - Placement.edgeMargin - 320)

    let leading = Placement.origin(
      panelSize: Self.panel, anchor: anchor, pointer: CGPoint(x: 10, y: 890), clicked: false, screens: [Self.main])
    #expect(leading.x == Placement.edgeMargin)
    #expect(leading.y + Self.panel.height == 875 - Placement.gap)
  }

  @Test func aClickAwayFromTheReportedItemFrameUsesThePointer() {
    let origin = Placement.origin(
      panelSize: Self.panel, anchor: Self.item(x: 1000), pointer: CGPoint(x: 2400, y: 1070), clicked: true,
      screens: [Self.main, Self.toTheRight])
    #expect(origin.x == 2400 - Self.panel.width / 2)
    #expect(origin.y + Self.panel.height == Self.toTheRight.visibleFrame.maxY - Placement.gap)
  }

  @Test func anActivationWithoutAClickTrustsTheItemFrame() {
    let origin = Placement.origin(
      panelSize: Self.panel, anchor: Self.item(x: 1000), pointer: CGPoint(x: 2400, y: 1070), clicked: false,
      screens: [Self.main, Self.toTheRight])
    #expect(origin.x == 1000)
    #expect(origin.y + Self.panel.height == Self.main.visibleFrame.maxY - Placement.gap)
  }

  @Test func aPointerInsideTheSlackKeepsTheItemFrame() {
    let anchor = Self.item(x: 1000)
    let inside = CGPoint(x: anchor.minX - (Placement.anchorSlack - 1), y: anchor.midY)
    let outside = CGPoint(x: anchor.minX - (Placement.anchorSlack + 1), y: anchor.midY)
    #expect(Placement.usableAnchor(anchor, pointer: inside, clicked: true) == anchor)
    #expect(Placement.usableAnchor(anchor, pointer: outside, clicked: true) == nil)
    #expect(Placement.usableAnchor(anchor, pointer: outside, clicked: false) == anchor)

    let below = CGPoint(x: anchor.midX, y: anchor.minY - (Placement.anchorSlack - 1))
    let farBelow = CGPoint(x: anchor.midX, y: anchor.minY - (Placement.anchorSlack + 1))
    #expect(Placement.usableAnchor(anchor, pointer: below, clicked: true) == anchor)
    #expect(Placement.usableAnchor(anchor, pointer: farBelow, clicked: true) == nil)
  }

  @Test func aPointerOnTheTopEdgeOfADisplayBelongsToThatDisplay() {
    let onTheSeam = CGPoint(x: 700, y: Self.main.frame.maxY)
    #expect(Placement.screen(containing: onTheSeam, in: [Self.main, Self.above]) == Self.main)
    #expect(Placement.screen(containing: onTheSeam, in: [Self.above, Self.main]) == Self.main)
    let onTheTop = CGPoint(x: 700, y: Self.above.frame.maxY)
    #expect(Placement.screen(containing: onTheTop, in: [Self.main, Self.above]) == Self.above)
    let nowhere = CGPoint(x: 9000, y: 9000)
    #expect(Placement.screen(containing: nowhere, in: [Self.toTheRight, Self.main]) == Self.toTheRight)
    #expect(Placement.screen(containing: onTheSeam, in: []) == nil)

    let pinned = Placement.origin(
      panelSize: Self.panel, anchor: nil, pointer: CGPoint(x: 2400, y: Self.toTheRight.frame.maxY), clicked: true,
      screens: [Self.main, Self.toTheRight])
    #expect(pinned.x == 2400 - Self.panel.width / 2)
    #expect(pinned.y + Self.panel.height == Self.toTheRight.visibleFrame.maxY - Placement.gap)
  }

  @Test func withNoScreensTheOriginIsNotClamped() {
    let anchor = Self.item(x: 1400)
    let origin = Self.clickedOrigin(anchor: anchor, screens: [])
    #expect(origin.x == anchor.minX)
    #expect(origin.y == anchor.minY - Placement.gap - 400)

    let pointerOnly = Placement.origin(
      panelSize: Self.panel, anchor: nil, pointer: CGPoint(x: 700, y: 890), clicked: true, screens: [])
    #expect(pointerOnly.x == 700 - Self.panel.width / 2)
    #expect(pointerOnly.y == 890 - Placement.gap - 400)
  }

  @Test func aPanelWiderThanTheVisibleFrameStartsAtTheLeadingMargin() {
    let origin = Self.clickedOrigin(anchor: Self.item(x: 1000), size: CGSize(width: 2000, height: 400))
    #expect(origin.x == Self.main.visibleFrame.minX + Placement.edgeMargin)
    #expect(origin.y == 875 - Placement.gap - 400)
  }

  @Test func theSpacingConstantsSitOnTheFourPointGrid() {
    #expect(Placement.gap == 4)
    #expect(Placement.edgeMargin == 8)
    #expect(Placement.anchorSlack == 8)
  }
}
