import Foundation
import OvertimeCore

public enum LidClosedCopy {
  public static let sectionTitle = "Lid"
  public static let label = "Keep awake with the lid closed"

  public static func optionLabel(_ value: LidClosedKeepAwake) -> String {
    switch value {
    case .always: "Always"
    case .onPowerAdapter: "Only on power adapter"
    case .never: "Never"
    }
  }

  public static func caption(_ value: LidClosedKeepAwake) -> String {
    switch value {
    case .always:
      "While Claude works, closing the lid doesn't put the Mac to sleep, on battery or on power."
    case .onPowerAdapter:
      "While Claude works on power, closing the lid doesn't put the Mac to sleep. On battery, and when you unplug the charger with the lid closed, the Mac sleeps as usual."
    case .never:
      "Closing the lid puts the Mac to sleep as usual, even while Claude works. With the lid open, Overtime still keeps it from idle sleep."
    }
  }

  public static func settingNote(_ value: LidClosedKeepAwake) -> String? {
    let setting = "In Settings > General, \(label) is set to \(optionLabel(value)), so"
    switch value {
    case .always:
      return nil
    case .onPowerAdapter:
      return
        "\(setting) unplugging the charger with the lid closed lets the Mac sleep. Unplug protection still keeps it awake when you connect or disconnect a display."
    case .never:
      return "\(setting) unplug protection isn't used. It stays installed until you remove it."
    }
  }
}
