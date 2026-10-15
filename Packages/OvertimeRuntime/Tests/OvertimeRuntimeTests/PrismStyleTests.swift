import Foundation
import OvertimeAppSupport
import Testing

struct PrismStyleTests {
  struct LookCase: Sendable, CustomTestStringConvertible {
    let lit: Bool
    let appearance: PrismAppearance
    let reduceTransparency: Bool
    let increaseContrast: Bool

    var testDescription: String {
      "lit \(lit), \(appearance), reduce transparency \(reduceTransparency), increase contrast \(increaseContrast)"
    }
  }

  static let lookCases: [LookCase] = [false, true].flatMap { lit in
    PrismAppearance.allCases.flatMap { appearance in
      [false, true].flatMap { reduce in
        [false, true].map { contrast in
          LookCase(lit: lit, appearance: appearance, reduceTransparency: reduce, increaseContrast: contrast)
        }
      }
    }
  }

  @Test func thePaletteIsTheApprovedPrism() {
    #expect(PrismPalette.magenta.hex == 0xFF2FB9)
    #expect(PrismPalette.violet.hex == 0x8A5CFF)
    #expect(PrismPalette.cyan.hex == 0x19D3FF)
    #expect(PrismPalette.violet.red == 138.0 / 255)
    #expect(PrismPalette.violet.green == 92.0 / 255)
    #expect(PrismPalette.violet.blue == 255.0 / 255)
    #expect(PrismPalette.deepScale == 0.8)
    #expect(PrismPalette.deepMagenta.hex == 0xCC2694)
    #expect(PrismPalette.deepMagenta.hex == PrismPalette.magenta.scaled(by: PrismPalette.deepScale).hex)
    #expect(PrismPalette.deepNeutral.hex == 0x666666)
    #expect(PrismPalette.deepNeutral.hex == PrismColor(white: 0.4).hex)
    #expect(PrismPalette.white.hex == 0xFFFFFF)
  }

  @Test(arguments: lookCases)
  func theLookGlowsOnlyWhenLitAndTransparencyIsAllowed(_ testCase: LookCase) {
    #expect(Self.lookCases.count == 16)
    let look = PrismLook.resolve(
      lit: testCase.lit, appearance: testCase.appearance, reduceTransparency: testCase.reduceTransparency,
      increaseContrast: testCase.increaseContrast)
    let flat = testCase.reduceTransparency || testCase.increaseContrast
    switch (testCase.lit, flat) {
    case (true, false):
      #expect(
        look == PrismLook(showsGlow: true, indicator: .magenta, glow: PrismPalette.glow(testCase.appearance)))
      #expect(look.glow.magenta > 0)
      #expect(look.glow.cyan > 0)
    case (true, true):
      #expect(look == PrismLook(showsGlow: false, indicator: .deepMagenta, glow: PrismGlow(magenta: 0, cyan: 0)))
    case (false, false):
      #expect(look == PrismLook(showsGlow: false, indicator: .neutral, glow: PrismGlow(magenta: 0, cyan: 0)))
    case (false, true):
      #expect(look == PrismLook(showsGlow: false, indicator: .deepNeutral, glow: PrismGlow(magenta: 0, cyan: 0)))
    }
  }

  @Test func theLightGlowIsFainterThanTheDarkGlow() {
    let dark = PrismPalette.glow(.dark)
    let light = PrismPalette.glow(.light)
    #expect(dark == PrismGlow(magenta: 0.55, cyan: 0.50))
    #expect(light == PrismGlow(magenta: 0.30, cyan: 0.26))
    #expect(light.magenta < dark.magenta)
    #expect(light.cyan < dark.cyan)
    for appearance in PrismAppearance.allCases {
      let flat = PrismLook.resolve(lit: true, appearance: appearance, reduceTransparency: true, increaseContrast: false)
      #expect(!flat.showsGlow)
      #expect(flat.glow == PrismGlow(magenta: 0, cyan: 0))
      let unlit = PrismLook.resolve(
        lit: false, appearance: appearance, reduceTransparency: false, increaseContrast: false)
      #expect(!unlit.showsGlow)
      #expect(unlit.glow == PrismGlow(magenta: 0, cyan: 0))
    }
  }

  @Test func theIndicatorSizesAreTheContractOnes() {
    #expect(PrismLayout.cardPadding == 12)
    #expect(PrismLayout.edgeWidth == 0.5)
    #expect(PrismLayout.indicatorSide == 36)
    #expect(PrismLayout.indicatorGlyphSide == 20)
    #expect(PrismLayout.indicatorGlyphSide < PrismLayout.indicatorSide)
  }

  @Test func theIndicatorGlyphKeepsItsContrast() {
    let white = PrismPalette.white
    #expect(white.relativeLuminance == 1)
    #expect(abs(PrismPalette.magenta.relativeLuminance - 0.268) <= 0.001)
    let magenta = PrismPalette.magenta.contrastRatio(with: white)
    let deepMagenta = PrismPalette.deepMagenta.contrastRatio(with: white)
    let deepNeutral = PrismPalette.deepNeutral.contrastRatio(with: white)
    #expect(abs(magenta - 3.30) <= 0.01, "magenta gives \(magenta)")
    #expect(abs(deepMagenta - 4.92) <= 0.01, "deep magenta gives \(deepMagenta)")
    #expect(abs(deepNeutral - 5.74) <= 0.01, "deep neutral gives \(deepNeutral)")
    #expect(magenta >= 3)
    #expect(deepMagenta >= 4.5)
    #expect(deepNeutral >= 4.5)
    for color in [PrismPalette.magenta, PrismPalette.deepMagenta, PrismPalette.deepNeutral] {
      #expect(color.contrastRatio(with: white) == white.contrastRatio(with: color))
    }
    #expect(PrismPalette.indicatorColor(.magenta) == PrismPalette.magenta)
    #expect(PrismPalette.indicatorColor(.deepMagenta) == PrismPalette.deepMagenta)
    #expect(PrismPalette.indicatorColor(.deepNeutral) == PrismPalette.deepNeutral)
    #expect(PrismPalette.indicatorColor(.neutral) == nil)
  }
}
