public protocol HelperSystemPort {
  func readSleepDisabled() -> Bool?
  func writeSleepDisabled(_ disabled: Bool) -> Bool
  func lidClosed() -> Bool?
  func clamshellEdge() -> Bool
  func power() -> HelperPowerFacts?
  func thermal() -> HelperThermalFacts?
  func pause(milliseconds: Int)
}

public protocol HelperLogPort {
  func record(_ line: String)
}

public protocol HelperClock {
  func now() -> Double
}

public struct HelperConnectionID: Sendable, Hashable {
  public let number: UInt64

  public init(_ number: UInt64) {
    self.number = number
  }
}

public struct HelperPowerFacts: Sendable, Equatable {
  public static let warningNone = 1
  public static let warningEarly = 2
  public static let warningFinal = 3

  public let onBattery: Bool
  public let percent: Int
  public let warningLevel: Int

  public init(onBattery: Bool, percent: Int, warningLevel: Int) {
    self.onBattery = onBattery
    self.percent = percent
    self.warningLevel = warningLevel
  }
}

public struct HelperThermalFacts: Sendable, Equatable {
  public let pressureLevel: Int
  public let critical: Bool

  public init(pressureLevel: Int, critical: Bool) {
    self.pressureLevel = pressureLevel
    self.critical = critical
  }
}
