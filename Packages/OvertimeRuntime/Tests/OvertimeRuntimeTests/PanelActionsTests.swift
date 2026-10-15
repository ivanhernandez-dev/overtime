import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import Testing

struct PanelActionsTests {
  static let pauseRows: [ControlAvailability.PauseRow] = [.pauseMenu, .resume]
  static let keepAwakeRows: [ControlAvailability.KeepAwakeRow] = [.keepAwakeMenu, .stopKeepingAwake]

  static func pauseTile(_ row: ControlAvailability.PauseRow) -> PanelActionTile {
    switch row {
    case .pauseMenu:
      PanelActionTile(
        slot: .pause, kind: .pauseMenu, symbol: "pause.circle", title: ControlMapping.pauseLabel, shortcut: .pause,
        opensMenu: true, isEnabled: true)
    case .resume:
      PanelActionTile(
        slot: .pause, kind: .resume, symbol: "play.circle", title: ControlMapping.resumeLabel, shortcut: .pause,
        opensMenu: false, isEnabled: true)
    }
  }

  static func keepAwakeTile(_ row: ControlAvailability.KeepAwakeRow) -> PanelActionTile {
    switch row {
    case .keepAwakeMenu:
      PanelActionTile(
        slot: .keepAwake, kind: .keepAwakeMenu, symbol: "cup.and.saucer", title: ControlMapping.keepAwakeLabel,
        shortcut: .keepAwake, opensMenu: true, isEnabled: true)
    case .stopKeepingAwake:
      PanelActionTile(
        slot: .keepAwake, kind: .stopKeepingAwake, symbol: "stop.circle", title: ControlMapping.stopKeepingAwakeLabel,
        shortcut: .keepAwake, opensMenu: false, isEnabled: true)
    }
  }

  static let sleepNowTile = PanelActionTile(
    slot: .sleepNow, kind: .sleepNow, symbol: "moon", title: SleepConfirmation.sleepNowLabel, shortcut: .sleepNow,
    opensMenu: false, isEnabled: true)

  @Test(arguments: pauseRows, keepAwakeRows)
  func theTilesArePauseKeepAwakeAndSleepNowInThatOrder(
    _ pauseRow: ControlAvailability.PauseRow, _ keepAwakeRow: ControlAvailability.KeepAwakeRow
  ) throws {
    let availability = ControlAvailability(pauseRow: pauseRow, keepAwakeRow: keepAwakeRow, releaseEnabled: true)
    let tiles = PanelActions.tiles(availability, confirmingSleep: false)
    try #require(tiles.count == 3)
    #expect(tiles.map(\.slot) == [.pause, .keepAwake, .sleepNow])
    #expect(tiles[0] == Self.pauseTile(pauseRow))
    #expect(tiles[1] == Self.keepAwakeTile(keepAwakeRow))
    #expect(tiles[2] == Self.sleepNowTile)
    #expect(tiles.allSatisfy { $0.isEnabled })
    #expect(!PanelActions.showsSleepConfirmation(availability, confirmingSleep: false))
  }

  @Test func sleepNowLosesItsShortcutWhileItsConfirmationShows() throws {
    let availability = ControlAvailability(pauseRow: .pauseMenu, keepAwakeRow: .keepAwakeMenu, releaseEnabled: true)
    let confirming = PanelActions.tiles(availability, confirmingSleep: true)
    try #require(confirming.count == 3)
    #expect(confirming[2].slot == .sleepNow)
    #expect(!confirming[2].isEnabled)
    #expect(confirming[2].shortcut == nil)
    #expect(confirming[0] == Self.pauseTile(.pauseMenu))
    #expect(confirming[1] == Self.keepAwakeTile(.keepAwakeMenu))
    #expect(PanelActions.showsSleepConfirmation(availability, confirmingSleep: true))
    let resting = PanelActions.tiles(availability, confirmingSleep: false)
    try #require(resting.count == 3)
    #expect(resting[2] == Self.sleepNowTile)
    #expect(!PanelActions.showsSleepConfirmation(availability, confirmingSleep: false))
  }

  @Test func theEngineBoundTilesFollowTheEngine() throws {
    let availability = ControlAvailability.from(StatusPresentation.presentation(for: .error(.notResponding)))
    #expect(!availability.engineControlsEnabled)
    for confirming in [false, true] {
      let tiles = PanelActions.tiles(availability, confirmingSleep: confirming)
      try #require(tiles.count == 3)
      #expect(tiles.map(\.slot) == [.pause, .keepAwake, .sleepNow])
      #expect(tiles.allSatisfy { !$0.isEnabled })
      #expect(tiles[2].shortcut == .sleepNow)
      #expect(!PanelActions.showsSleepConfirmation(availability, confirmingSleep: confirming))
    }
  }

  @Test func theMenuTilesShowTheChevronSymbol() {
    #expect(PanelActions.menuSymbol == "chevron.down")
  }
}
