import Foundation
import OvertimeCore

public struct Paths: Sendable, Equatable {
  public var supportDirectory: URL
  public var logsDirectory: URL

  public init(supportDirectory: URL, logsDirectory: URL) {
    self.supportDirectory = supportDirectory
    self.logsDirectory = logsDirectory
  }

  public static let releaseAppName = "Overtime"

  public static func resolve(
    environment: [String: String], homeDirectory: String, appName: String = Paths.releaseAppName
  ) -> Paths {
    if let home = environment["OVERTIME_HOME"], !home.isEmpty {
      let root = URL(fileURLWithPath: home, isDirectory: true)
      return Paths(
        supportDirectory: root.appendingPathComponent("support", isDirectory: true),
        logsDirectory: root.appendingPathComponent("logs", isDirectory: true)
      )
    }
    let library = URL(fileURLWithPath: homeDirectory, isDirectory: true).appendingPathComponent(
      "Library", isDirectory: true)
    return Paths(
      supportDirectory: library.appendingPathComponent("Application Support/\(appName)", isDirectory: true),
      logsDirectory: library.appendingPathComponent("Logs/\(appName)", isDirectory: true)
    )
  }

  public func decisionLog(_ mode: RunMode) -> URL {
    logsDirectory.appendingPathComponent(mode == .live ? "overtimed.log" : "overtimed-shadow.log")
  }

  public func errorLog(_ mode: RunMode) -> URL {
    logsDirectory.appendingPathComponent(mode == .live ? "overtimed-error.log" : "overtimed-shadow-error.log")
  }

  public func stateFile(_ mode: RunMode) -> URL {
    supportDirectory.appendingPathComponent(mode == .live ? "state.json" : "shadow-state.json")
  }

  public func lockFile(_ mode: RunMode) -> URL {
    supportDirectory.appendingPathComponent(mode == .live ? "overtimed.lock" : "overtimed-shadow.lock")
  }

  public func controlSocket(_ mode: RunMode) -> URL {
    supportDirectory.appendingPathComponent(mode == .live ? "overtimed.sock" : "overtimed-shadow.sock")
  }

  public var settingsFile: URL {
    supportDirectory.appendingPathComponent("settings.json")
  }

  public var loginItemRecord: URL {
    supportDirectory.appendingPathComponent("login-item.json")
  }

  public var preferencesFile: URL {
    supportDirectory.appendingPathComponent("preferences.json")
  }

  public var wifiCycleMarker: URL {
    supportDirectory.appendingPathComponent("wifi-cycle.json")
  }

  public var relaunchHistory: URL {
    supportDirectory.appendingPathComponent("relaunch-history")
  }

  public var relaunchSuppression: URL {
    supportDirectory.appendingPathComponent("relaunch-suppressed")
  }

  public var sentinelLog: URL {
    logsDirectory.appendingPathComponent("sentinel.log")
  }

  public func createDirectories() throws {
    let fileManager = FileManager.default
    for directory in [supportDirectory, logsDirectory] {
      try fileManager.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path(percentEncoded: false))
    }
  }
}
