import OvertimeAppSupport
import SwiftUI

extension PanelShortcut.Modifier {
  var eventModifier: EventModifiers {
    switch self {
    case .control: .control
    case .option: .option
    case .shift: .shift
    case .command: .command
    }
  }
}

extension PanelShortcut {
  var keyboardShortcut: KeyboardShortcut {
    KeyboardShortcut(KeyEquivalent(key), modifiers: EventModifiers(modifiers.map { $0.eventModifier }))
  }
}

extension View {
  func panelShortcut(_ shortcut: PanelShortcut) -> some View {
    self.keyboardShortcut(shortcut.keyboardShortcut)
  }
}

extension Motion {
  static func animation(_ transition: MotionTransition, reduceMotion: Bool) -> Animation? {
    duration(transition, reduceMotion: reduceMotion).map { Animation.easeOut(duration: $0) }
  }
}
