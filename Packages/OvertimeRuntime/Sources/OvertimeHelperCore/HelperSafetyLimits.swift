import Foundation

public struct HelperSafetyLimits: Sendable, Equatable {
  public static let batteryFloorRange = 5...50
  public static let defaultBatteryFloorPercent = 10
  public static let temperatureCeilingRange = 35...60
  public static let defaultTemperatureCeilingCelsius = 60
  public static let notGiven = 0
  public static let compiled = HelperSafetyLimits(
    requestedBatteryFloorPercent: notGiven, requestedTemperatureCeilingCelsius: notGiven)

  public let batteryFloorPercent: Int
  public let temperatureCeilingCelsius: Int

  public init(requestedBatteryFloorPercent: Int, requestedTemperatureCeilingCelsius: Int) {
    batteryFloorPercent = Self.clamp(
      requestedBatteryFloorPercent, into: Self.batteryFloorRange, missing: Self.defaultBatteryFloorPercent)
    temperatureCeilingCelsius = Self.clamp(
      requestedTemperatureCeilingCelsius, into: Self.temperatureCeilingRange,
      missing: Self.defaultTemperatureCeilingCelsius)
  }

  static func clamp(_ requested: Int, into range: ClosedRange<Int>, missing: Int) -> Int {
    guard requested > notGiven else { return missing }
    return min(max(requested, range.lowerBound), range.upperBound)
  }
}
