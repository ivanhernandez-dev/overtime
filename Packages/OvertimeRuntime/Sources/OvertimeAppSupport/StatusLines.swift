import Foundation
import OvertimeCore
import OvertimeEngine

public struct StatusLine: Sendable, Equatable, Identifiable {
  public var label: String
  public var icon: String
  public var value: String
  public var detail: String?

  public var id: String { label }

  public var accessibilityText: String {
    let text = "\(label), \(Self.spokenValue(value))"
    guard let detail else { return text }
    return "\(text). \(detail)"
  }

  public static func spokenValue(_ value: String) -> String {
    let characters = Array(value)
    guard characters.count >= 2, characters[0].isUppercase, characters[1].isLowercase else { return value }
    return characters[0].lowercased() + String(characters.dropFirst())
  }

  public init(label: String, icon: String, value: String, detail: String? = nil) {
    self.label = label
    self.icon = icon
    self.value = value
    self.detail = detail
  }
}

public enum StatusLines {
  public static let unknown = "Unknown"

  public static let failoverOff = "Failover off"
  public static let failoverOn = "Failover on"
  public static let onHotspot = "On your iPhone hotspot"
  public static let onHotspotDetail = "Returns to your usual network when you open the lid."
  public static let returning = "Returning to your usual network…"
  public static let stillOnHotspot = "Still on your iPhone hotspot"
  public static let stillOnHotspotDetail = "Turn Wi-Fi off and on to return to your usual network."
  public static let rejoinedHotspotDetail = "macOS rejoined it. Choose your usual network in the Wi-Fi menu."
  public static let switchingNetworks = "Switching networks…"
  public static let wifiIcon = "wifi"
  public static let hotspotIcon = "personalhotspot"
  public static let wifiOffDetail = "Wi-Fi is off. Failover resumes when it's back on."
  public static let wiredDetail = "The Mac has a wired connection."
  public static let noHotspotDetail = "Overtime can't find an iPhone hotspot among your known networks."

  public static func offDetail(_ reason: NetOffReason, autoDetect: Bool) -> String? {
    switch reason {
    case .wifiOff: wifiOffDetail
    case .wired: wiredDetail
    case .noHotspot: autoDetect ? noHotspotDetail : nil
    case .noWifi: nil
    }
  }

  public static func networkIcon(for value: String) -> String {
    value == onHotspot || value == stillOnHotspot ? hotspotIcon : wifiIcon
  }

  public static let batteryIcons = [
    "battery.0percent", "battery.25percent", "battery.50percent", "battery.75percent", "battery.100percent",
    "battery.100percent.bolt",
  ]

  public static func batteryIcon(for reading: PowerReading?) -> String {
    switch reading {
    case .ac?:
      "battery.100percent.bolt"
    case .battery(let percent?)?:
      switch percent {
      case ...12: "battery.0percent"
      case ...37: "battery.25percent"
      case ...62: "battery.50percent"
      case ...87: "battery.75percent"
      default: "battery.100percent"
      }
    case .battery(nil)?, .noBattery?, nil:
      "battery.100percent"
    }
  }

  public static func rows(for snapshot: EngineSnapshot?) -> [StatusLine] {
    let defaults = Settings()
    let network = network(snapshot?.network, lidClosed: snapshot?.lidClosed)
    return [
      StatusLine(
        label: "Lid", icon: "laptopcomputer",
        value: lid(snapshot?.lidClosed, externalDisplays: snapshot?.externalDisplays)),
      StatusLine(
        label: "Battery", icon: batteryIcon(for: snapshot?.power),
        value: battery(
          snapshot?.power, blocked: snapshot?.batteryBlocked ?? false,
          lowPercent: snapshot?.batteryLowPercent ?? defaults.batteryLowPercent)),
      StatusLine(
        label: "Network", icon: networkIcon(for: network.value), value: network.value, detail: network.detail),
    ]
  }

  public static func lid(_ closed: Bool?, externalDisplays: Int?) -> String {
    switch closed {
    case nil: unknown
    case false?: "Open"
    case true?: (externalDisplays ?? 0) > 0 ? "Closed, external display" : "Closed"
    }
  }

  public static func battery(_ reading: PowerReading?, blocked: Bool, lowPercent: Int) -> String {
    switch reading {
    case .battery(let percent?)?:
      blocked ? "\(percent)%, on battery (below \(lowPercent)%)" : "\(percent)%, on battery"
    case .ac(let percent?)?:
      percent >= 100 ? "\(percent)%, on power adapter" : "\(percent)%, charging"
    case .noBattery?:
      "No battery"
    case .battery(nil)?, .ac(nil)?, nil:
      unknown
    }
  }

  public static func network(_ summary: NetworkSummary?, lidClosed: Bool?) -> (value: String, detail: String?) {
    guard let summary else { return (failoverOff, nil) }
    if summary.switched {
      guard lidClosed == false else {
        return summary.onHotspot == false ? (switchingNetworks, nil) : (onHotspot, onHotspotDetail)
      }
      guard let stop = summary.returnStop else { return (returning, nil) }
      return (stillOnHotspot, stop == .backOnHotspot ? rejoinedHotspotDetail : stillOnHotspotDetail)
    }
    switch summary.readiness {
    case .armed?: return (failoverOn, nil)
    case .off(let reason)?: return (failoverOff, offDetail(reason, autoDetect: summary.autoDetect))
    case nil: return (failoverOff, nil)
    }
  }
}

extension PowerReading {
  public var percent: Int? {
    switch self {
    case .ac(let percent), .battery(let percent): percent
    case .noBattery: nil
    }
  }
}
