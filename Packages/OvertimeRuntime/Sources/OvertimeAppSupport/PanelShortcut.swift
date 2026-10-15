import Foundation

public enum PanelShortcut: String, CaseIterable, Sendable {
  case pause
  case keepAwake
  case releaseUntilIdle
  case sleepNow
  case restore
  case settings
  case quit

  public enum Modifier: String, CaseIterable, Sendable {
    case control
    case option
    case shift
    case command

    public var glyph: String {
      switch self {
      case .control: "⌃"
      case .option: "⌥"
      case .shift: "⇧"
      case .command: "⌘"
      }
    }

    public var name: String {
      switch self {
      case .control: "Control"
      case .option: "Option"
      case .shift: "Shift"
      case .command: "Command"
      }
    }
  }

  public var key: Character {
    switch self {
    case .pause: "p"
    case .keepAwake: "k"
    case .releaseUntilIdle: "i"
    case .sleepNow: "s"
    case .restore: "r"
    case .settings: ","
    case .quit: "q"
    }
  }

  public var modifiers: [Modifier] {
    switch self {
    case .pause, .keepAwake, .releaseUntilIdle, .sleepNow, .restore: [.control, .command]
    case .settings, .quit: [.command]
    }
  }

  public var hint: String {
    Self.hint(key: key, modifiers: modifiers)
  }

  public var spoken: String {
    Self.spoken(key: key, modifiers: modifiers)
  }

  public static func hint(key: Character, modifiers: [Modifier]) -> String {
    ordered(modifiers).map(\.glyph).joined() + String(key).uppercased()
  }

  public static func spoken(key: Character, modifiers: [Modifier]) -> String {
    (ordered(modifiers).map(\.name) + [keyName(key)]).joined(separator: "-")
  }

  static func ordered(_ modifiers: [Modifier]) -> [Modifier] {
    Modifier.allCases.filter { modifiers.contains($0) }
  }

  static func keyName(_ key: Character) -> String {
    key == "," ? "Comma" : String(key).uppercased()
  }
}
