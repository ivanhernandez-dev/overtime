import Foundation

public enum LidClosedKeepAwake: String, Codable, Sendable, CaseIterable {
  case always
  case onPowerAdapter
  case never

  public func allows(power: PowerReading?) -> Bool {
    switch self {
    case .always:
      true
    case .never:
      false
    case .onPowerAdapter:
      switch power {
      case .ac, .noBattery: true
      case .battery, nil: false
      }
    }
  }

  public static func powerWord(_ reading: PowerReading?) -> String {
    switch reading {
    case .ac: "ac"
    case .battery: "battery"
    case .noBattery: "noBattery"
    case nil: "unknown"
    }
  }
}
