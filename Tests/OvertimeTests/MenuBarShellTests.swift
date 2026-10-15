import AppKit
import Foundation
import OvertimeAppSupport
import OvertimeSystem
import Testing

@testable import Overtime

@MainActor
struct MenuBarShellTests {
  static func failedPresentation() -> StatusPresentation {
    StatusPresentation.derive(snapshot: nil, hostFailure: .storageUnavailable, engineUnresponsive: false)
  }

  static func keyEquivalents(in menu: NSMenu) -> [String] {
    menu.items.flatMap { item in
      [item.keyEquivalent] + (item.submenu.map { keyEquivalents(in: $0) } ?? [])
    }
  }

  @Test func theTestHostBuildsNoMenuBar() throws {
    #expect(AppMode.current == .testHost)
    let delegate = try #require(AppDelegate.shared)
    #expect(!delegate.menuBarAttached)
    let shellWindows = NSApp.windows.filter { window in
      let name = String(describing: type(of: window))
      return name.contains("StatusBar") || name.contains("MenuBarPanel")
    }
    #expect(shellWindows.isEmpty)
  }

  @Test func onlyTheTestHostGoesWithoutAMenuBar() throws {
    #expect(!AppDelegate.buildsMenuBar(for: .testHost))
    #expect(AppDelegate.buildsMenuBar(for: .blocked(.storageUnavailable)))
    let folder = try TestFolder()
    let lock = try InstanceLock.acquire(at: folder.url.appendingPathComponent("menu-bar-shell.lock"))
    defer { lock.release() }
    #expect(AppDelegate.buildsMenuBar(for: .live(HeldLocks(primary: lock, secondary: nil))))
  }

  @Test func theStatusItemLabelCarriesTheGlyphTheFallbackAndTheSpokenLabel() {
    let starting = PanelModel().presentation
    let failed = Self.failedPresentation()
    for presentation in [starting, failed] {
      let label = StatusItemLabel(presentation)
      #expect(label.glyph == presentation.glyph)
      #expect(label.fallbackSymbol == presentation.fallbackGlyph)
      #expect(label.accessibilityLabel == presentation.accessibilityLabel)
      #expect(!label.fallbackSymbol.isEmpty)
      #expect(!label.accessibilityLabel.isEmpty)
    }
    #expect(StatusItemLabel(starting) != StatusItemLabel(failed))
  }

  @Test func theLabelObserverAppliesTheFirstLabelAndEachChangeOnce() async {
    let model = PanelModel()
    var applied: [StatusItemLabel] = []
    let observer = StatusItemLabelObserver(model: model) { applied.append($0) }
    observer.start()
    #expect(applied == [StatusItemLabel(model.presentation)])
    #expect(observer.evaluations == 1)

    model.hostFailure = .storageUnavailable
    #expect(await waitUntil { applied.count == 2 })
    #expect(applied.last == StatusItemLabel(Self.failedPresentation()))
    for _ in 0..<10 { await Task.yield() }
    #expect(applied.count == 2)

    let evaluations = observer.evaluations
    observer.evaluate()
    #expect(applied.count == 2)
    #expect(observer.evaluations == evaluations + 1)

    model.hostFailure = nil
    #expect(await waitUntil { applied.count == 3 })
    #expect(applied.last == applied.first)
    for _ in 0..<10 { await Task.yield() }
    #expect(applied.count == 3)
  }

  @Test func aStoppedLabelObserverAppliesNothingMore() async {
    let model = PanelModel()
    var applied: [StatusItemLabel] = []
    let observer = StatusItemLabelObserver(model: model) { applied.append($0) }
    observer.start()
    #expect(applied.count == 1)
    observer.stop()
    let evaluations = observer.evaluations
    #expect(evaluations == 1)

    model.hostFailure = .storageUnavailable
    for _ in 0..<10 { await Task.yield() }
    #expect(applied.count == 1)
    #expect(observer.evaluations == evaluations)

    observer.evaluate()
    #expect(applied.count == 1)
    #expect(observer.evaluations == evaluations)
  }

  @Test func bothMouseButtonsSendTheItemAction() {
    #expect(StatusItemController.actionMask == [.leftMouseDown, .rightMouseDown])
    #expect(StatusItemController.button(for: .rightMouseDown) == .right)
    #expect(StatusItemController.button(for: .leftMouseDown) == .left)
    #expect(StatusItemController.button(for: nil) == .left)
    #expect(StatusItemController.button(for: .keyDown) == .left)
    #expect(StatusItemController.isClick(.leftMouseDown))
    #expect(StatusItemController.isClick(.rightMouseDown))
    #expect(!StatusItemController.isClick(nil))
    #expect(!StatusItemController.isClick(.keyDown))

    let fresh = StatusItemController.stamp(for: .rightMouseDown, eventSeconds: 99.5, uptime: 100)
    #expect(fresh.seconds == 99.5)
    #expect(fresh.clicked)
    let stale = StatusItemController.stamp(
      for: .leftMouseDown, eventSeconds: 100 - StatusItemController.clickFreshnessSeconds - 0.5, uptime: 100)
    #expect(stale.seconds == 100)
    #expect(!stale.clicked)
    let key = StatusItemController.stamp(for: .keyDown, eventSeconds: 99.9, uptime: 100)
    #expect(key.seconds == 100)
    #expect(!key.clicked)
    let none = StatusItemController.stamp(for: nil, eventSeconds: nil, uptime: 100)
    #expect(none.seconds == 100)
    #expect(!none.clicked)
  }

  @Test func aNewPanelControllerHasBuiltNoWindowAndWatchesNothing() {
    var highlights: [Bool] = []
    let controller = MenuBarPanelController(
      model: PanelModel(), anchor: { nil }, setHighlighted: { highlights.append($0) })
    #expect(controller.panel == nil)
    #expect(!controller.isWatching)
    #expect(!controller.toggle.isShown)

    controller.send(.escape, at: 1)
    controller.send(.outsideClick, at: 2)
    controller.send(.resignKey, at: 3)
    #expect(controller.panel == nil)
    #expect(!controller.isWatching)
    #expect(controller.toggle == MenuBarPanelToggle())
    #expect(highlights.isEmpty)
  }

  @Test func thePanelShellIsANonActivatingPopUpLevelPanel() {
    #expect(MenuBarPanelController.styleMask.contains(.nonactivatingPanel))
    #expect(MenuBarPanelController.styleMask.contains(.borderless))
    #expect(!MenuBarPanelController.styleMask.contains(.titled))
    #expect(MenuBarPanelController.level == .popUpMenu)
    #expect(MenuBarPanelController.collectionBehavior.contains(.moveToActiveSpace))
    #expect(MenuBarPanelController.collectionBehavior.contains(.fullScreenAuxiliary))
    #expect(MenuBarPanelController.cornerRadius == 24)
  }

  @Test func thePanelMaskCoversTheContinuousCorner() {
    let radius = MenuBarPanelController.cornerRadius
    #expect(radius == CGFloat(CornerGeometry.panelRadius))
    #expect(radius == 24)
    let cap = ceil(CGFloat(CornerGeometry.maskCapFactor) * radius)
    #expect(cap == 39)
    let mask = MenuBarPanelController.cornerMask()
    let insets = mask.capInsets
    for inset in [insets.top, insets.left, insets.bottom, insets.right] {
      #expect(inset == cap)
      #expect(inset >= 1.53 * radius)
    }
    #expect(mask.size.width == 2 * cap + 1)
    #expect(mask.size.height == mask.size.width)
    #expect(mask.resizingMode == .stretch)
  }

  @Test func closingTheLastWindowNeverQuitsTheApp() throws {
    let delegate = try #require(AppDelegate.shared)
    #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp))
  }

  @Test func theMainMenuOffersNoSettingsShortcut() throws {
    let menu = try #require(NSApp.mainMenu)
    let equivalents = Self.keyEquivalents(in: menu)
    #expect(equivalents.contains("q"))
    #expect(!equivalents.contains(","))
  }
}
