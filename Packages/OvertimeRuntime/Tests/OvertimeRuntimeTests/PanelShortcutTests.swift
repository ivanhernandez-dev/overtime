import OvertimeAppSupport
import Testing

struct PanelShortcutTests {
  typealias Modifier = PanelShortcut.Modifier

  static let panelActions: [PanelShortcut] = [.pause, .keepAwake, .releaseUntilIdle, .sleepNow, .restore]
  static let applesControlCommandKeys: Set<Character> = [" ", "f", "n", "q", "d", "t", "a"]
  static let auditProposals: [(key: Character, modifiers: Set<Modifier>)] = [
    ("p", [.command]), ("k", [.command]), ("i", [.command]), ("s", [.shift, .command]), ("r", [.shift, .command]),
  ]

  @Test func theKeyMapIsTheApprovedOne() {
    let expected: [(PanelShortcut, Character, [Modifier])] = [
      (.pause, "p", [.control, .command]),
      (.keepAwake, "k", [.control, .command]),
      (.releaseUntilIdle, "i", [.control, .command]),
      (.sleepNow, "s", [.control, .command]),
      (.restore, "r", [.control, .command]),
      (.settings, ",", [.command]),
      (.quit, "q", [.command]),
    ]
    #expect(expected.map(\.0) == PanelShortcut.allCases)
    for (shortcut, key, modifiers) in expected {
      #expect(shortcut.key == key, "\(shortcut)")
      #expect(shortcut.modifiers == modifiers, "\(shortcut)")
    }
  }

  @Test func noTwoShortcutsShareAKeyAndItsModifiers() {
    let pairs = PanelShortcut.allCases.map { shortcut in
      (shortcut.modifiers.map(\.rawValue) + [String(shortcut.key)]).joined(separator: "+")
    }
    #expect(PanelShortcut.allCases.count == 7)
    #expect(Set(pairs).count == PanelShortcut.allCases.count, "\(pairs)")
  }

  @Test func noPanelActionUsesAShortcutOnApplesList() {
    #expect(Self.panelActions.count == 5)
    for shortcut in Self.panelActions {
      let modifiers = Set(shortcut.modifiers)
      #expect(shortcut.modifiers.count == 2, "\(shortcut)")
      #expect(modifiers == [.control, .command], "\(shortcut)")
      #expect(!Self.applesControlCommandKeys.contains(shortcut.key), "\(shortcut)")
      #expect(
        !Self.auditProposals.contains { $0.key == shortcut.key && $0.modifiers == modifiers }, "\(shortcut)")
    }
  }

  @Test func theHintWritesTheModifiersInApplesOrderAndTheKeyInCapitals() {
    let expected: [(PanelShortcut, String)] = [
      (.pause, "⌃⌘P"), (.keepAwake, "⌃⌘K"), (.releaseUntilIdle, "⌃⌘I"), (.sleepNow, "⌃⌘S"), (.restore, "⌃⌘R"),
      (.settings, "⌘,"), (.quit, "⌘Q"),
    ]
    #expect(expected.map(\.0) == PanelShortcut.allCases)
    for (shortcut, hint) in expected {
      #expect(shortcut.hint == hint, "\(shortcut)")
    }
    #expect(Modifier.allCases == [.control, .option, .shift, .command])
    #expect(Modifier.allCases.map(\.glyph) == ["⌃", "⌥", "⇧", "⌘"])
    #expect(PanelShortcut.hint(key: "a", modifiers: [.command, .shift, .option, .control]) == "⌃⌥⇧⌘A")
    #expect(PanelShortcut.hint(key: ",", modifiers: [.command, .shift]) == "⇧⌘,")
  }

  @Test func theSpokenFormNamesTheKeysInWords() {
    let expected: [(PanelShortcut, String)] = [
      (.pause, "Control-Command-P"), (.keepAwake, "Control-Command-K"),
      (.releaseUntilIdle, "Control-Command-I"), (.sleepNow, "Control-Command-S"),
      (.restore, "Control-Command-R"), (.settings, "Command-Comma"), (.quit, "Command-Q"),
    ]
    #expect(expected.map(\.0) == PanelShortcut.allCases)
    for (shortcut, spoken) in expected {
      #expect(shortcut.spoken == spoken, "\(shortcut)")
      let ascii = shortcut.spoken.unicodeScalars.allSatisfy { $0.isASCII }
      #expect(ascii, "\(shortcut)")
    }
    #expect(Modifier.allCases.map(\.name) == ["Control", "Option", "Shift", "Command"])
    #expect(
      PanelShortcut.spoken(key: "a", modifiers: [.command, .shift, .option, .control])
        == "Control-Option-Shift-Command-A")
  }
}
