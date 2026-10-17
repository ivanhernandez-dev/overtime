import AppKit
import OvertimeAppSupport
import Testing

@testable import Overtime

struct SymbolAvailabilityTests {
  static let stateSymbols = [
    "moon", "sun.max", "laptopcomputer", "hourglass.tophalf.fill", "pause.circle", "pause.circle.fill", "battery.25",
    "bolt.fill", "exclamationmark.triangle.fill", "exclamationmark.triangle",
  ]

  static let rowSymbols = [
    "battery.0percent", "battery.25percent", "battery.50percent", "battery.75percent", "battery.100percent",
    "battery.100percent.bolt", "checkmark", "wifi", "terminal", "info.circle", "play.circle", "cup.and.saucer",
    "stop.circle", "arrow.uturn.backward.circle", "arrow.counterclockwise.circle", "display", "circle",
    "checkmark.circle.fill", "minus.circle.fill", "xmark.circle.fill", "chevron.down",
  ]

  static let bodyPointSize: CGFloat = 13

  static func bodySizeWidth(of name: String) -> CGFloat? {
    let configuration = NSImage.SymbolConfiguration(pointSize: bodyPointSize, weight: .regular)
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
      .withSymbolConfiguration(configuration)?.size.width
  }

  static let phaseThreeSymbols = [
    "gearshape", "waveform.path.ecg", "battery.75percent", "wifi", "powerplug", "stethoscope",
    "exclamationmark.triangle.fill", "checkmark.circle.fill", "xmark.circle.fill", "minus.circle.fill",
    "minus.circle", "circle", "clock", "info.circle", "folder", "shield", "checkmark.shield",
    "checkmark.shield.fill", "laptopcomputer", "arrow.triangle.2.circlepath", "power", "bell.badge", "location",
    "checklist", "checkmark.seal", "terminal", "sun.max.fill", "moon.zzz", "personalhotspot", "menubar.rectangle",
    "hand.raised",
  ]

  static let phaseFiveSymbols = [
    "info.circle", "arrow.down.circle", "circle", "checkmark.circle.fill", "minus.circle.fill", "xmark.circle.fill",
    "exclamationmark.triangle.fill",
  ]

  @Test func thePhaseFiveListCoversEverySymbolInItsUISpec() {
    #expect(Set(Self.phaseFiveSymbols).count == 7)
  }

  @MainActor @Test func theUpdateRowUsesOnlyListedSymbols() {
    #expect(Set([AttentionRow.symbol, AttentionRow.updateSymbol]).isSubset(of: Set(Self.phaseFiveSymbols)))
  }

  @Test func theListCoversEverySymbolInTheUISpec() {
    #expect(Set(Self.stateSymbols + Self.rowSymbols).count == 31)
  }

  @Test func theDisplaySwitchSymbolIsListed() {
    #expect(Self.rowSymbols.contains(ControlMapping.keepDisplayOnSymbol))
    #expect(Set(Self.stateSymbols + Self.rowSymbols).count == 31)
  }

  @Test func theMenuTileChevronIsListed() {
    #expect(!PanelActions.menuSymbol.isEmpty)
    #expect(Self.rowSymbols.contains(PanelActions.menuSymbol))
  }

  @Test func theBatteryRowUsesOnlyListedSymbols() {
    #expect(StatusLines.batteryIcons.count == 6)
    #expect(Set(StatusLines.batteryIcons).isSubset(of: Set(Self.rowSymbols)))
  }

  @Test func theCopiedAndSessionSymbolsAreListed() {
    #expect(Set([CopyConfirmation.copiedSymbol, PanelContent.sessionIcon]).isSubset(of: Set(Self.rowSymbols)))
  }

  @MainActor @Test(arguments: stateSymbols + rowSymbols + phaseThreeSymbols + phaseFiveSymbols)
  func everyListedSymbolFitsTheIconColumnAtTheBodySize(_ name: String) throws {
    let width = try #require(Self.bodySizeWidth(of: name), "\(name) does not resolve")
    #expect(width > 0)
    #expect(width <= StatusRowLayout.iconWidth, "\(name) is \(width) pt wide at the body size")
  }

  @Test func theIconColumnCheckSeesASymbolWiderThanSixteenPoints() throws {
    let width = try #require(Self.bodySizeWidth(of: "laptopcomputer"))
    #expect(width > 16)
  }

  @Test func everyStateFallbackSymbolIsListed() {
    #expect(StatusGlyphImageTests.states.count == 11)
    let fallbacks = Set(StatusGlyphImageTests.states.map { StatusPresentation.presentation(for: $0).fallbackGlyph })
    #expect(fallbacks.count == 8)
    #expect(fallbacks.isSubset(of: Set(Self.stateSymbols)))
  }

  @Test func thePhaseThreeListCoversEverySymbolInItsUISpec() {
    #expect(Set(Self.phaseThreeSymbols).count == 31)
  }

  @Test func theOnboardingRowsUseOnlyListedSymbols() {
    let listed = Set(Self.phaseThreeSymbols)
    #expect(Set(OnboardingFlow.welcomeRows.map(\.symbol)).isSubset(of: listed))
    #expect(Set(OnboardingFlow.locationRows.map(\.symbol)).isSubset(of: listed))
    #expect(listed.contains(OnboardingFlow.finishRow.symbol))
    #expect(OnboardingFlow.locationRows.map(\.symbol) == ["wifi", "personalhotspot", "hand.raised"])
  }

  @Test func theSettingsSidebarUsesOnlyListedSymbols() {
    #expect(Set(SettingsPane.allCases.map(\.symbol)).isSubset(of: Set(Self.phaseThreeSymbols)))
  }

  @Test func theNetworkRowUsesOnlyListedSymbols() {
    #expect(
      Set([StatusLines.wifiIcon, StatusLines.hotspotIcon]).isSubset(of: Set(Self.rowSymbols + Self.phaseThreeSymbols)))
  }

  @Test(arguments: stateSymbols + rowSymbols + phaseThreeSymbols + phaseFiveSymbols)
  func theSymbolResolves(_ name: String) {
    #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil)
  }
}
