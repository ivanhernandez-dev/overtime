import AppKit

protocol FolderPickerPort {
  func chooseFolder() async -> URL?
}

struct AppKitFolderPicker: FolderPickerPort {
  static let prompt = "Add Folder"

  func chooseFolder() async -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    panel.resolvesAliases = true
    panel.prompt = Self.prompt
    NSApp.activate()
    let response = await withCheckedContinuation { continuation in
      panel.begin { continuation.resume(returning: $0) }
    }
    guard response == .OK else { return nil }
    return panel.url
  }
}
