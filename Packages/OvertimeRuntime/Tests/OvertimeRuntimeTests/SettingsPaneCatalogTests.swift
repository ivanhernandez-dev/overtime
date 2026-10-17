import Foundation
import OvertimeAppSupport
import Testing

struct SettingsPaneCatalogTests {
  @Test func everyPaneHasItsSystemTileColour() {
    #expect(PaneTileColor.allCases == [.gray, .purple, .green, .blue, .orange, .red])
    #expect(
      SettingsPane.allCases == [.general, .detection, .battery, .network, .unplugProtection, .diagnostics, .about])
    #expect(SettingsPane.allCases.map(\.tileColor) == [.gray, .purple, .green, .blue, .orange, .red, .gray])
  }

  @Test func everyPaneHasAOneLineSummary() {
    let summaries = SettingsPane.allCases.map(\.summary)
    #expect(
      summaries == [
        "Launch at login, the display and notifications.",
        "How Overtime tells that Claude is working.",
        "When Overtime lets the Mac sleep to protect the battery.",
        "Switching to your iPhone hotspot when the network fails.",
        "Keeps the lid-closed Mac awake when you unplug power or a display.",
        "Detection health, the self-test and an export for bug reports.",
        "Version, updates, acknowledgements and uninstall.",
      ])
    for summary in summaries {
      #expect(summary.hasSuffix("."), "\(summary)")
      #expect(summary.count <= 66, "\(summary) has \(summary.count) characters")
      #expect(!summary.contains("\n"), "\(summary)")
    }
    #expect(Set(summaries).count == SettingsPane.allCases.count)
  }

  @Test func theTileSizesAreTheContractOnes() {
    #expect(PaneTileSize.allCases == [.sidebar, .header])
    #expect(PaneTileSize.sidebar.side == 22)
    #expect(PaneTileSize.sidebar.symbolSide == 14)
    #expect(PaneTileSize.header.side == 44)
    #expect(PaneTileSize.header.symbolSide == 26)
    #expect(PaneTile.highlightOpacity == 0.22)
  }
}
