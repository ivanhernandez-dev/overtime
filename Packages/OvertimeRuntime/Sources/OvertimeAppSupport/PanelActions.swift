import Foundation

public struct PanelActionTile: Sendable, Equatable, Identifiable {
  public enum Slot: Sendable, Equatable, Hashable, CaseIterable {
    case pause
    case keepAwake
    case sleepNow
  }

  public enum Kind: Sendable, Equatable, CaseIterable {
    case pauseMenu
    case resume
    case keepAwakeMenu
    case stopKeepingAwake
    case sleepNow
  }

  public var slot: Slot
  public var kind: Kind
  public var symbol: String
  public var title: String
  public var shortcut: PanelShortcut?
  public var opensMenu: Bool
  public var isEnabled: Bool

  public var id: Slot { slot }

  public init(
    slot: Slot, kind: Kind, symbol: String, title: String, shortcut: PanelShortcut?, opensMenu: Bool, isEnabled: Bool
  ) {
    self.slot = slot
    self.kind = kind
    self.symbol = symbol
    self.title = title
    self.shortcut = shortcut
    self.opensMenu = opensMenu
    self.isEnabled = isEnabled
  }
}

public enum PanelActions {
  public static let menuSymbol = "chevron.down"

  public static func tiles(_ availability: ControlAvailability, confirmingSleep: Bool) -> [PanelActionTile] {
    let enabled = availability.engineControlsEnabled
    let confirming = showsSleepConfirmation(availability, confirmingSleep: confirmingSleep)
    let pause =
      switch availability.pauseRow {
      case .pauseMenu:
        PanelActionTile(
          slot: .pause, kind: .pauseMenu, symbol: "pause.circle", title: ControlMapping.pauseLabel, shortcut: .pause,
          opensMenu: true, isEnabled: enabled)
      case .resume:
        PanelActionTile(
          slot: .pause, kind: .resume, symbol: "play.circle", title: ControlMapping.resumeLabel, shortcut: .pause,
          opensMenu: false, isEnabled: enabled)
      }
    let keepAwake =
      switch availability.keepAwakeRow {
      case .keepAwakeMenu:
        PanelActionTile(
          slot: .keepAwake, kind: .keepAwakeMenu, symbol: "cup.and.saucer", title: ControlMapping.keepAwakeLabel,
          shortcut: .keepAwake, opensMenu: true, isEnabled: enabled)
      case .stopKeepingAwake:
        PanelActionTile(
          slot: .keepAwake, kind: .stopKeepingAwake, symbol: "stop.circle",
          title: ControlMapping.stopKeepingAwakeLabel, shortcut: .keepAwake, opensMenu: false, isEnabled: enabled)
      }
    let sleepNow = PanelActionTile(
      slot: .sleepNow, kind: .sleepNow, symbol: "moon", title: SleepConfirmation.sleepNowLabel,
      shortcut: confirming ? nil : .sleepNow, opensMenu: false, isEnabled: enabled && !confirming)
    return [pause, keepAwake, sleepNow]
  }

  public static func showsSleepConfirmation(_ availability: ControlAvailability, confirmingSleep: Bool) -> Bool {
    availability.engineControlsEnabled && confirmingSleep
  }
}
