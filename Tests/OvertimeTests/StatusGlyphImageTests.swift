import AppKit
import OvertimeAppSupport
import Testing

@testable import Overtime

struct StatusGlyphImageTests {
  static let states: [PanelState] = [
    .starting, .idle, .holding, .lidClosedHolding, .grace, .paused, .releasedUntilIdle, .batteryFloor, .override,
    .uninstalling, .error(.holdFailed),
  ]

  static let unknownAsset = "StatusNoSuchGlyph"
  static let unknownSymbol = "overtime.no.such.symbol"

  @MainActor @Test(arguments: StatusGlyph.allCases)
  func everyStatusGlyphLoadsFromTheCatalogAtEighteenPointsAsATemplate(_ glyph: StatusGlyph) throws {
    let image = try #require(StatusGlyphImage.catalogImage(named: glyph.assetName))
    #expect(image.size == NSSize(width: 18, height: 18))
    #expect(image.size == StatusGlyphImage.pointSize)
    #expect(image.isTemplate)
    #expect(image.isValid)
  }

  @MainActor @Test func theStatusItemImageHasOneSizeInEveryState() throws {
    #expect(Self.states.count == 11)
    for state in Self.states {
      let presentation = StatusPresentation.presentation(for: state)
      let image = try #require(StatusGlyphImage.image(for: StatusItemLabel(presentation)), "\(state)")
      #expect(image.size == NSSize(width: 18, height: 18), "\(state)")
      #expect(image.isTemplate, "\(state)")
      #expect(image.accessibilityDescription == presentation.accessibilityLabel, "\(state)")
    }
  }

  @MainActor @Test func aMissingCatalogImageFallsBackToTheStateSymbol() throws {
    #expect(StatusGlyphImage.catalogImage(named: Self.unknownAsset) == nil)
    let image = try #require(
      StatusGlyphImage.image(
        assetName: Self.unknownAsset, fallbackSymbol: "moon", accessibilityLabel: "Overtime, idle"))
    #expect(image.isTemplate)
    #expect(image.accessibilityDescription == "Overtime, idle")
    #expect(
      StatusGlyphImage.image(
        assetName: Self.unknownAsset, fallbackSymbol: Self.unknownSymbol, accessibilityLabel: "Overtime, idle") == nil)
    for state in Self.states {
      let presentation = StatusPresentation.presentation(for: state)
      let fallback = StatusGlyphImage.image(
        assetName: Self.unknownAsset, fallbackSymbol: presentation.fallbackGlyph,
        accessibilityLabel: presentation.accessibilityLabel)
      #expect(fallback?.isTemplate == true, "\(state)")
      #expect(fallback?.accessibilityDescription == presentation.accessibilityLabel, "\(state)")
    }
  }

  @MainActor @Test func resolvingAnImageNeverChangesTheNextLookup() throws {
    let name = StatusGlyph.idle.assetName
    let first = try #require(StatusGlyphImage.catalogImage(named: name))
    first.size = NSSize(width: 40, height: 40)
    first.isTemplate = false
    let second = try #require(StatusGlyphImage.catalogImage(named: name))
    #expect(second !== first)
    #expect(second.size == StatusGlyphImage.pointSize)
    #expect(second.isTemplate)
    let label = StatusItemLabel(StatusPresentation.presentation(for: .idle))
    let third = try #require(StatusGlyphImage.image(for: label))
    third.size = NSSize(width: 7, height: 7)
    third.isTemplate = false
    let fourth = try #require(StatusGlyphImage.image(for: label))
    #expect(fourth.size == StatusGlyphImage.pointSize)
    #expect(fourth.isTemplate)
    let source = try #require(Bundle.main.image(forResource: name))
    #expect(source.size == StatusGlyphImage.pointSize)
    #expect(source.isTemplate)
  }

  @MainActor @Test func theIndicatorGlyphFillsItsTwentyPointPlace() {
    #expect(StatusGlyphView.side == 20)
    #expect(StatusGlyphView.side == CGFloat(PrismLayout.indicatorGlyphSide))
    #expect(StatusGlyphView.side < CGFloat(PrismLayout.indicatorSide))
  }

  @MainActor @Test func theGlyphViewIsEqualForTheSameLabel() {
    let idle = StatusItemLabel(StatusPresentation.presentation(for: .idle))
    let holding = StatusItemLabel(StatusPresentation.presentation(for: .holding))
    #expect(StatusGlyphView(label: idle) == StatusGlyphView(label: idle))
    #expect(StatusGlyphView(label: idle) != StatusGlyphView(label: holding))
  }
}
