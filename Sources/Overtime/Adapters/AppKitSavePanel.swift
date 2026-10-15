import AppKit
import UniformTypeIdentifiers

protocol SavePanelPort {
  func chooseDestination(defaultName: String) async -> URL?
}

struct AppKitSavePanel: SavePanelPort {
  static let message = "Choose where to save the diagnostics archive."
  static let prompt = "Export Archive"

  static var defaultFolder: URL? {
    FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
  }

  func chooseDestination(defaultName: String) async -> URL? {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = defaultName
    panel.directoryURL = Self.defaultFolder
    panel.message = Self.message
    panel.prompt = Self.prompt
    panel.allowedContentTypes = [.zip]
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false
    NSApp.activate()
    let response = await withCheckedContinuation { continuation in
      panel.begin { continuation.resume(returning: $0) }
    }
    guard response == .OK else { return nil }
    return panel.url
  }
}
