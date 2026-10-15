import AppKit

struct AmphetamineLocator {
  static let bundleIdentifier = "com.if.Amphetamine"
  static let defaultPath = "/Applications/Amphetamine.app"

  var applicationURL: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
  var fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }

  func isInstalled() -> Bool {
    applicationURL(Self.bundleIdentifier) != nil || fileExists(Self.defaultPath)
  }
}
