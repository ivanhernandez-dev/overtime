import AppKit
import OvertimeAppSupport
import SwiftUI

struct OvertimeApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

  var body: some Scene {
    ShellScene()
  }
}

struct InertTestHostApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

  var body: some Scene {
    ShellScene()
  }
}

struct ShellScene: Scene {
  var body: some Scene {
    Settings {
      EmptyView()
    }
    .commands {
      CommandGroup(replacing: .appSettings) {}
    }
  }
}

struct StatusItemLabel: Equatable {
  let glyph: StatusGlyph
  let fallbackSymbol: String
  let accessibilityLabel: String

  init(_ presentation: StatusPresentation) {
    glyph = presentation.glyph
    fallbackSymbol = presentation.fallbackGlyph
    accessibilityLabel = presentation.accessibilityLabel
  }
}
