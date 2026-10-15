import Foundation
import OvertimeCore

public struct CheckRow: Sendable, Equatable, Identifiable {
  public enum Icon: Sendable, Equatable, CaseIterable {
    case pass
    case warning
    case info

    public var symbol: String {
      switch self {
      case .pass: "checkmark.circle.fill"
      case .warning: "exclamationmark.triangle.fill"
      case .info: "info.circle"
      }
    }
  }

  public enum Link: Sendable, Equatable, CaseIterable {
    case lockScreen
    case wifi

    public var label: String {
      switch self {
      case .lockScreen: "Open Lock Screen Settings"
      case .wifi: "Open Wi-Fi Settings"
      }
    }

    public var url: URL {
      switch self {
      case .lockScreen: SystemSettingsLinks.lockScreen
      case .wifi: SystemSettingsLinks.wifi
      }
    }
  }

  public enum Check: String, Sendable, Equatable, CaseIterable {
    case screenLock
    case hotspot
    case askToJoin
    case systemSleep
  }

  public let check: Check
  public let icon: Icon
  public let title: String
  public let caption: String?
  public let link: Link?

  public var id: Check { check }

  public init(check: Check, icon: Icon, title: String, caption: String? = nil, link: Link? = nil) {
    self.check = check
    self.icon = icon
    self.title = title
    self.caption = caption
    self.link = link
  }
}

public enum AskToJoinHotspots: Sendable, Equatable, CaseIterable {
  case automatic
  case notAutomatic
  case unreadable
}

public enum SystemSleepCheck: Sendable, Equatable {
  case row(CheckRow)
  case sleepDisabledRow
  case nothing
}

public enum OnboardingChecks {
  public static let askToJoin = askToJoin(reading: .unreadable)

  public static func screenLock(_ status: ScreenLockStatus) -> CheckRow {
    switch status {
    case .immediate:
      CheckRow(check: .screenLock, icon: .pass, title: "Screen lock asks for your password immediately.")
    case .delayed:
      CheckRow(
        check: .screenLock, icon: .warning, title: "Screen lock waits before asking for your password.",
        caption: "With the lid closed and the display off, the Mac stays unlocked until then.", link: .lockScreen)
    case .off:
      CheckRow(
        check: .screenLock, icon: .warning,
        title: "The Mac doesn't ask for a password after the display turns off.",
        caption: "Anyone who opens the lid can use it.", link: .lockScreen)
    case .unknown:
      CheckRow(
        check: .screenLock, icon: .info, title: "Overtime couldn't read the screen lock setting.",
        caption:
          "In System Settings > Lock Screen, set Require password after screen saver begins or display is turned off to Immediately.",
        link: .lockScreen)
    }
  }

  public static func hotspot(knownNetworks: [String]?) -> CheckRow {
    guard let knownNetworks else {
      return CheckRow(
        check: .hotspot, icon: .info, title: "Overtime couldn't read your known networks.",
        caption: "You can check your known networks in System Settings > Wi-Fi.", link: .wifi)
    }
    guard knownNetworks.contains(where: { $0.contains(StartupChecks.autodetectMarker) }) else {
      return CheckRow(
        check: .hotspot, icon: .info, title: "No iPhone hotspot among your known networks.",
        caption: "Join your iPhone's hotspot once so failover can use it later.")
    }
    return CheckRow(
      check: .hotspot, icon: .pass, title: "A known iPhone hotspot was found.",
      caption: "You can choose it in Settings > Network.")
  }

  public static func askToJoin(reading: AskToJoinHotspots) -> CheckRow {
    switch reading {
    case .automatic:
      CheckRow(check: .askToJoin, icon: .pass, title: "Ask to join hotspots is set to Automatic.")
    case .notAutomatic:
      CheckRow(
        check: .askToJoin, icon: .info, title: "Ask to join hotspots isn't set to Automatic.",
        caption: "Failover works best when macOS can join your iPhone's hotspot on its own.", link: .wifi)
    case .unreadable:
      CheckRow(
        check: .askToJoin, icon: .info, title: "Check Ask to join hotspots.",
        caption:
          "Failover works best when System Settings > Wi-Fi > Ask to join hotspots is set to Automatic. Overtime can't read this setting.",
        link: .wifi)
    }
  }

  public static func systemSleep(sleepDisabled: Bool?, helperOwns: Bool?) -> SystemSleepCheck {
    switch sleepDisabled {
    case false?:
      .row(CheckRow(check: .systemSleep, icon: .pass, title: "System sleep is on."))
    case true?:
      helperOwns == false ? .sleepDisabledRow : .nothing
    case nil:
      .nothing
    }
  }
}
