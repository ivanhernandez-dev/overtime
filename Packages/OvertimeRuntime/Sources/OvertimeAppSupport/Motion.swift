import Foundation

public enum MotionTransition: CaseIterable, Sendable {
  case rowHighlight
  case statusGlyph
  case onboardingStep
  case panelClose

  var seconds: Double {
    switch self {
    case .rowHighlight: 0.15
    case .statusGlyph: 0.2
    case .onboardingStep: 0.25
    case .panelClose: 0.15
    }
  }
}

public enum Motion {
  public static func duration(_ transition: MotionTransition, reduceMotion: Bool) -> Double? {
    reduceMotion ? nil : transition.seconds
  }
}

public struct PanelFade: Equatable, Sendable {
  private var issued = 0
  private var closing: Int?

  public init() {}

  public mutating func beginClose() -> Int {
    issued += 1
    closing = issued
    return issued
  }

  public mutating func present() {
    closing = nil
  }

  public func mayOrderOut(_ token: Int) -> Bool {
    closing == token
  }
}
