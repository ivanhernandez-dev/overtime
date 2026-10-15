import OvertimeAppSupport
import Testing

struct MenuBarPanelToggleTests {
  typealias Toggle = MenuBarPanelToggle

  static let opened: [Toggle.Effect] = [.present, .startWatching]
  static let closed: [Toggle.Effect] = [.stopWatching, .dismiss]
  static let closeEvents: [Toggle.Event] = [
    .outsideClick, .escape, .resignActive, .resignKey, .spaceChange, .windowOpened,
  ]
  static let buttonPairs: [(Toggle.MouseButton, Toggle.MouseButton)] = [
    (.left, .left), (.left, .right), (.right, .left), (.right, .right),
  ]

  static func shown(at seconds: Double, button: Toggle.MouseButton = .left) -> Toggle {
    var toggle = Toggle()
    #expect(toggle.handle(.itemClick(button), at: seconds) == opened)
    return toggle
  }

  static func hidden(after event: Toggle.Event, shownAt: Double, closedAt: Double) -> Toggle {
    var toggle = shown(at: shownAt)
    #expect(toggle.handle(event, at: closedAt) == closed)
    return toggle
  }

  @Test func aNewToggleIsHiddenWithNoHistory() {
    let toggle = Toggle()
    #expect(!toggle.isShown)
    #expect(toggle.shownAt == nil)
    #expect(toggle.lastClose == nil)
  }

  @Test(arguments: MenuBarPanelToggle.MouseButton.allCases)
  func anItemClickWhileHiddenPresentsAndStartsWatching(button: Toggle.MouseButton) {
    var toggle = Toggle()
    #expect(toggle.handle(.itemClick(button), at: 5) == Self.opened)
    #expect(toggle.isShown)
    #expect(toggle.shownAt == 5)
    #expect(toggle.lastClose == nil)
  }

  @Test(arguments: MenuBarPanelToggleTests.buttonPairs)
  func anItemClickWhileShownStopsWatchingAndDismisses(opening: Toggle.MouseButton, closing: Toggle.MouseButton) {
    var toggle = Self.shown(at: 5, button: opening)
    #expect(toggle.handle(.itemClick(closing), at: 6) == Self.closed)
    #expect(!toggle.isShown)
    #expect(toggle.shownAt == nil)
    #expect(toggle.lastClose == Toggle.Close(cause: .itemClick(closing), at: 6))
  }

  @Test func aRightClickDecidesExactlyAsALeftClick() {
    let states: [(toggle: Toggle, at: Double, expected: [Toggle.Effect])] = [
      (Toggle(), 5, Self.opened),
      (Self.shown(at: 5), 6, Self.closed),
      (Self.hidden(after: .outsideClick, shownAt: 5, closedAt: 6), 6.1, []),
      (Self.hidden(after: .outsideClick, shownAt: 5, closedAt: 6), 7, Self.opened),
    ]
    for state in states {
      var left = state.toggle
      var right = state.toggle
      let leftEffects = left.handle(.itemClick(.left), at: state.at)
      let rightEffects = right.handle(.itemClick(.right), at: state.at)
      #expect(leftEffects == state.expected)
      #expect(rightEffects == leftEffects)
      #expect(right.isShown == left.isShown)
      #expect(right.shownAt == left.shownAt)
    }
  }

  @Test(arguments: MenuBarPanelToggleTests.closeEvents)
  func everyCloseEventDismissesWhileShown(event: Toggle.Event) {
    var toggle = Self.shown(at: 5)
    #expect(toggle.handle(event, at: 6) == Self.closed)
    #expect(!toggle.isShown)
    #expect(toggle.shownAt == nil)
    #expect(toggle.lastClose == Toggle.Close(cause: event, at: 6))
  }

  @Test(arguments: MenuBarPanelToggleTests.closeEvents)
  func everyCloseEventIsIgnoredWhileHidden(event: Toggle.Event) {
    var toggle = Toggle()
    let before = toggle
    #expect(toggle.handle(event, at: 3) == [])
    #expect(toggle == before)
  }

  @Test func theClickThatOpenedThePanelIsNotAnOutsideClick() {
    var toggle = Self.shown(at: 10)
    #expect(toggle.handle(.outsideClick, at: 10) == [])
    #expect(toggle.isShown)
    #expect(toggle.handle(.outsideClick, at: 9.5) == [])
    #expect(toggle.isShown)
    #expect(toggle.shownAt == 10)
    #expect(toggle.handle(.outsideClick, at: 10.001) == Self.closed)
    #expect(!toggle.isShown)
  }

  @Test(arguments: MenuBarPanelToggleTests.closeEvents)
  func anItemClickRightAfterAnotherCloseStaysClosed(event: Toggle.Event) {
    var toggle = Self.hidden(after: event, shownAt: -1, closedAt: 0)
    let afterClose = toggle
    #expect(toggle.handle(.itemClick(.left), at: 0) == [])
    #expect(toggle.handle(.itemClick(.right), at: Toggle.reopenGuardSeconds / 2) == [])
    #expect(!toggle.isShown)
    #expect(toggle == afterClose)
  }

  @Test(arguments: MenuBarPanelToggleTests.closeEvents)
  func anItemClickAtTheGuardReopens(event: Toggle.Event) {
    var toggle = Self.hidden(after: event, shownAt: -1, closedAt: 0)
    #expect(toggle.handle(.itemClick(.left), at: Toggle.reopenGuardSeconds) == Self.opened)
    #expect(toggle.isShown)

    var ignoredFirst = Self.hidden(after: event, shownAt: -1, closedAt: 0)
    #expect(ignoredFirst.handle(.itemClick(.right), at: Toggle.reopenGuardSeconds / 2) == [])
    #expect(ignoredFirst.handle(.itemClick(.right), at: Toggle.reopenGuardSeconds) == Self.opened)
    #expect(ignoredFirst.shownAt == Toggle.reopenGuardSeconds)
  }

  @Test func aClickStampedBeforeTheCloseStaysClosed() {
    var toggle = Self.hidden(after: .resignActive, shownAt: 30, closedAt: 30.5)
    #expect(toggle.handle(.itemClick(.left), at: 30.2) == [])
    #expect(!toggle.isShown)
    #expect(toggle.lastClose == Toggle.Close(cause: .resignActive, at: 30.5))
  }

  @Test(arguments: MenuBarPanelToggle.MouseButton.allCases)
  func aSecondItemClickAfterAnItemCloseReopensAtOnce(button: Toggle.MouseButton) {
    var toggle = Self.hidden(after: .itemClick(button), shownAt: 1, closedAt: 2)
    #expect(toggle.handle(.itemClick(.left), at: 2.05) == Self.opened)
    #expect(toggle.isShown)
    #expect(toggle.shownAt == 2.05)
  }

  @Test func watchingStartsOnlyWithPresentAndStopsOnlyWithDismiss() {
    let script: [(Toggle.Event, Double)] = [
      (.escape, 0), (.itemClick(.left), 1), (.outsideClick, 1), (.outsideClick, 2), (.itemClick(.right), 2.1),
      (.itemClick(.right), 3), (.itemClick(.left), 4), (.itemClick(.left), 4.05), (.escape, 5), (.resignKey, 5.1),
      (.itemClick(.right), 6), (.resignActive, 7), (.itemClick(.left), 8), (.spaceChange, 9), (.itemClick(.left), 10),
      (.windowOpened, 11), (.itemClick(.right), 12), (.resignKey, 13), (.spaceChange, 14),
    ]
    var toggle = Toggle()
    var watching = false
    var opens = 0
    var closes = 0
    for (event, seconds) in script {
      let effects = toggle.handle(event, at: seconds)
      #expect(effects == [] || effects == Self.opened || effects == Self.closed)
      for effect in effects {
        switch effect {
        case .present:
          opens += 1
        case .dismiss:
          closes += 1
        case .startWatching:
          #expect(!watching)
          watching = true
        case .stopWatching:
          #expect(watching)
          watching = false
        }
      }
      #expect(watching == toggle.isShown)
    }
    #expect(script.count >= 12)
    #expect(opens == 7)
    #expect(closes == 7)
    #expect(!watching)
  }

  @Test func aShowRequestOpensAHiddenPanelEvenInsideTheReopenGuard() {
    var fresh = Toggle()
    #expect(fresh.handle(.show, at: 5) == Self.opened)
    #expect(fresh.isShown)
    #expect(fresh.shownAt == 5)
    #expect(fresh.lastClose == nil)

    for event in Self.closeEvents {
      var toggle = Self.hidden(after: event, shownAt: -1, closedAt: 0)
      #expect(toggle.handle(.itemClick(.left), at: 0.1) == [])
      #expect(toggle.handle(.show, at: 0.1) == Self.opened)
      #expect(toggle.isShown)
      #expect(toggle.shownAt == 0.1)
      #expect(toggle.lastClose == Toggle.Close(cause: event, at: 0))
    }
  }

  @Test func aShowRequestLeavesAShownPanelAlone() {
    var toggle = Self.shown(at: 5)
    let before = toggle
    #expect(toggle.handle(.show, at: 6) == [])
    #expect(toggle == before)
    #expect(toggle.isShown)
    #expect(toggle.shownAt == 5)
  }

  @Test func aPanelOpenedByAShowRequestClosesLikeAnyOther() {
    var toggle = Toggle()
    #expect(toggle.handle(.show, at: 5) == Self.opened)
    #expect(toggle.handle(.outsideClick, at: 5) == [])
    #expect(toggle.handle(.itemClick(.left), at: 6) == Self.closed)
    #expect(!toggle.isShown)
  }

  @Test func theReopenGuardIsThreeTenthsOfASecond() {
    #expect(Toggle.reopenGuardSeconds == 0.3)
  }

  struct LocalClick: Sendable {
    let inPanel: Bool
    let windowLevel: Int?
    let outside: Bool
  }

  static let localClicks = [
    LocalClick(inPanel: true, windowLevel: 0, outside: false),
    LocalClick(inPanel: false, windowLevel: 0, outside: true),
    LocalClick(inPanel: false, windowLevel: 25, outside: true),
    LocalClick(inPanel: false, windowLevel: 101, outside: false),
    LocalClick(inPanel: false, windowLevel: 102, outside: false),
    LocalClick(inPanel: false, windowLevel: nil, outside: false),
  ]

  @Test(arguments: MenuBarPanelToggleTests.localClicks)
  func aLocalClickIsOutsideOnlyOutsideThePanelAndBelowItsLevel(click: LocalClick) {
    let outside = Toggle.localClickIsOutside(
      inPanel: click.inPanel, windowLevel: click.windowLevel, panelLevel: 101)
    #expect(outside == click.outside)
  }
}
