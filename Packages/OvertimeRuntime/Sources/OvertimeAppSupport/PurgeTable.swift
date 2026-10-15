import Foundation
import OvertimeHelperCore
import OvertimeSystem

public struct PurgeItem: Sendable, Equatable {
  public enum Scope: Sendable, Equatable {
    case user
    case root
  }

  public let scope: Scope
  public let relativePath: String

  public init(scope: Scope, relativePath: String) {
    self.scope = scope
    self.relativePath = relativePath
  }

  public func absolutePath(homeDirectory: String) -> String? {
    switch scope {
    case .user:
      guard let home = Self.usableHome(homeDirectory) else { return nil }
      return home + "/" + relativePath
    case .root:
      return "/" + relativePath
    }
  }

  public static func usableHome(_ homeDirectory: String) -> String? {
    guard homeDirectory.hasPrefix("/") else { return nil }
    let parts = homeDirectory.split(separator: "/").filter { $0 != "." }
    guard !parts.isEmpty, !parts.contains("..") else { return nil }
    return "/" + parts.joined(separator: "/")
  }

  public var caskPath: String {
    switch scope {
    case .user: "~/" + relativePath
    case .root: "/" + relativePath
    }
  }
}

public struct PurgeTable: Sendable, Equatable {
  public static let devFolderName = "Overtime Dev"

  public static let release = PurgeTable(
    appIdentifier: HelperIdentity.release.appIdentifier, folderName: Paths.releaseAppName)
  public static let dev = PurgeTable(appIdentifier: HelperIdentity.dev.appIdentifier, folderName: devFolderName)

  public let appIdentifier: String
  public let folderName: String

  public init(appIdentifier: String, folderName: String) {
    self.appIdentifier = appIdentifier
    self.folderName = folderName
  }

  public var userItems: [PurgeItem] {
    [
      user("Library/Application Support/" + folderName),
      user("Library/Logs/" + folderName),
      preferencesItem,
      user("Library/Caches/" + appIdentifier),
      user("Library/HTTPStorages/" + appIdentifier),
      user("Library/HTTPStorages/" + appIdentifier + ".binarycookies"),
      user("Library/Saved Application State/" + appIdentifier + ".savedState"),
    ]
  }

  public var rootItems: [PurgeItem] {
    [
      PurgeItem(scope: .root, relativePath: "Library/Application Support/" + folderName),
      PurgeItem(scope: .root, relativePath: "Library/Logs/" + folderName),
    ]
  }

  public var preferencesItem: PurgeItem {
    user("Library/Preferences/" + appIdentifier + ".plist")
  }

  public var sparkleCache: PurgeItem {
    user("Library/Caches/" + appIdentifier + "/org.sparkle-project.Sparkle")
  }

  public var sparkleJobLabels: [String] {
    [appIdentifier + "-sparkle-updater", appIdentifier + "-sparkle-progress"]
  }

  private func user(_ relativePath: String) -> PurgeItem {
    PurgeItem(scope: .user, relativePath: relativePath)
  }
}
