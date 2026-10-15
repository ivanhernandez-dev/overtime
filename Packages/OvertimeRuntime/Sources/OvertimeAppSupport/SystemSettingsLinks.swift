import Foundation

public enum SystemSettingsLinks {
  public static let scheme = "x-apple.systempreferences:"
  public static let locationServices = link("com.apple.preference.security?Privacy_LocationServices")
  public static let notifications = link("com.apple.Notifications-Settings.extension")
  public static let lockScreen = link("com.apple.Lock-Screen-Settings.extension")
  public static let wifi = link("com.apple.wifi-settings-extension")

  static let systemSettingsApp = URL(fileURLWithPath: "/System/Applications/System Settings.app")

  static func link(_ anchor: String) -> URL {
    URL(string: scheme + anchor) ?? systemSettingsApp
  }
}
