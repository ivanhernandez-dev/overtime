public enum HelperCommands {
  public static let pmset = "/usr/bin/pmset"
  public static let clamshellSleepSelector: UInt32 = 12

  public static func arguments(disable: Bool) -> [String] {
    ["-a", "disablesleep", disable ? "1" : "0"]
  }
}
