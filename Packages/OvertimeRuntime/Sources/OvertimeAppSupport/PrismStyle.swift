import Foundation

public struct PrismColor: Sendable, Equatable {
  public let hex: UInt32

  public init(hex: UInt32) {
    self.hex = hex
  }

  public init(white: Double) {
    let level = Self.channel(white * 255)
    self.hex = level << 16 | level << 8 | level
  }

  public var red: Double { component(shift: 16) }
  public var green: Double { component(shift: 8) }
  public var blue: Double { component(shift: 0) }

  public var relativeLuminance: Double {
    0.2126 * Self.linear(red) + 0.7152 * Self.linear(green) + 0.0722 * Self.linear(blue)
  }

  public func scaled(by factor: Double) -> PrismColor {
    let red = Self.channel(byte(shift: 16) * factor)
    let green = Self.channel(byte(shift: 8) * factor)
    let blue = Self.channel(byte(shift: 0) * factor)
    return PrismColor(hex: red << 16 | green << 8 | blue)
  }

  public func contrastRatio(with other: PrismColor) -> Double {
    let own = relativeLuminance
    let theirs = other.relativeLuminance
    return (max(own, theirs) + 0.05) / (min(own, theirs) + 0.05)
  }

  private func byte(shift: UInt32) -> Double {
    Double((hex >> shift) & 0xFF)
  }

  private func component(shift: UInt32) -> Double {
    byte(shift: shift) / 255
  }

  private static func channel(_ value: Double) -> UInt32 {
    UInt32(min(max(value.rounded(), 0), 255))
  }

  private static func linear(_ channel: Double) -> Double {
    channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
  }
}

public struct PrismStop: Sendable, Equatable {
  public let color: PrismColor
  public let location: Double

  public init(color: PrismColor, location: Double) {
    self.color = color
    self.location = location
  }
}

public struct PrismGlow: Sendable, Equatable {
  public let magenta: Double
  public let cyan: Double

  public init(magenta: Double, cyan: Double) {
    self.magenta = magenta
    self.cyan = cyan
  }

  public static let none = PrismGlow(magenta: 0, cyan: 0)
}

public enum PrismAppearance: Sendable, Equatable, CaseIterable {
  case light
  case dark
}

public enum PrismIndicatorFill: Sendable, Equatable {
  case magenta
  case deepMagenta
  case neutral
  case deepNeutral
}

public enum PrismPalette {
  public static let magenta = PrismColor(hex: 0xFF2FB9)
  public static let violet = PrismColor(hex: 0x8A5CFF)
  public static let cyan = PrismColor(hex: 0x19D3FF)
  public static let deepScale = 0.8
  public static let deepMagenta = magenta.scaled(by: deepScale)
  public static let deepNeutral = PrismColor(white: 0.4)
  public static let white = PrismColor(white: 1)

  public static func indicatorColor(_ fill: PrismIndicatorFill) -> PrismColor? {
    switch fill {
    case .magenta: magenta
    case .deepMagenta: deepMagenta
    case .neutral: nil
    case .deepNeutral: deepNeutral
    }
  }

  public static func glow(_ appearance: PrismAppearance) -> PrismGlow {
    switch appearance {
    case .dark: PrismGlow(magenta: 0.55, cyan: 0.50)
    case .light: PrismGlow(magenta: 0.30, cyan: 0.26)
    }
  }
}

public struct PrismLook: Sendable, Equatable {
  public let showsGlow: Bool
  public let indicator: PrismIndicatorFill
  public let glow: PrismGlow

  public init(showsGlow: Bool, indicator: PrismIndicatorFill, glow: PrismGlow) {
    self.showsGlow = showsGlow
    self.indicator = indicator
    self.glow = glow
  }

  public static func resolve(
    lit: Bool, appearance: PrismAppearance, reduceTransparency: Bool, increaseContrast: Bool
  ) -> PrismLook {
    let solid = reduceTransparency || increaseContrast
    guard lit else { return PrismLook(showsGlow: false, indicator: solid ? .deepNeutral : .neutral, glow: .none) }
    guard !solid else { return PrismLook(showsGlow: false, indicator: .deepMagenta, glow: .none) }
    return PrismLook(showsGlow: true, indicator: .magenta, glow: PrismPalette.glow(appearance))
  }
}

public enum PrismLayout {
  public static let cardPadding = 12.0
  public static let edgeWidth = 0.5
  public static let indicatorSide = 36.0
  public static let indicatorGlyphSide = 20.0
}
