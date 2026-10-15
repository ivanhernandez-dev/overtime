import AppKit
import OvertimeAppSupport
import Testing

@testable import Overtime

struct AssetCatalogBundleTests {
  static let glyphNames = StatusGlyph.allCases.map(\.assetName)

  @Test func theBundleNamesTheAppIconAndCarriesItsIconFile() {
    let info = Bundle.main.infoDictionary ?? [:]
    #expect(info["CFBundleIconName"] as? String == "AppIcon")
    #expect(info["CFBundleIconFile"] as? String == "AppIcon")
    #expect(Bundle.main.url(forResource: "AppIcon", withExtension: "icns") != nil)
    #expect(Bundle.main.url(forResource: "Assets", withExtension: "car") != nil)
  }

  @MainActor @Test(arguments: glyphNames)
  func theGlyphResolvesAsAnEighteenPointTemplateImage(_ name: String) throws {
    let image = try #require(Bundle.main.image(forResource: name))
    #expect(image.size == NSSize(width: 18, height: 18))
    #expect(image.isTemplate)
  }

  @MainActor @Test func anUnknownGlyphNameResolvesToNothing() {
    #expect(Bundle.main.image(forResource: "StatusNoSuchGlyph") == nil)
  }

  @Test func theIconMasterAndLooseArtworkAreNotBundled() {
    #expect(Bundle.main.url(forResource: "AppIcon", withExtension: "svg") == nil)
    #expect(Bundle.main.url(forResource: "rays-idle", withExtension: "svg") == nil)
  }
}
