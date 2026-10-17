import Foundation
import OvertimeHelperCore
import Testing

struct HelperSafetyLimitsTests {
  @Test(arguments: [(0, 0), (-1, -1), (Int.min, Int.min)])
  func aMissingRequestGivesTheCompiledDefaults(_ floor: Int, _ ceiling: Int) {
    let limits = HelperSafetyLimits(requestedBatteryFloorPercent: floor, requestedTemperatureCeilingCelsius: ceiling)
    #expect(limits.batteryFloorPercent == 10)
    #expect(limits.temperatureCeilingCelsius == 60)
  }

  @Test(arguments: [(1, 5), (4, 5), (5, 5), (25, 25), (50, 50), (51, 50), (Int.max, 50)])
  func aFloorOutsideFiveToFiftyIsClampedIntoIt(_ requested: Int, _ enforced: Int) {
    let limits = HelperSafetyLimits(
      requestedBatteryFloorPercent: requested, requestedTemperatureCeilingCelsius: HelperSafetyLimits.notGiven)
    #expect(limits.batteryFloorPercent == enforced)
    #expect(limits.temperatureCeilingCelsius == 60)
  }

  @Test(arguments: [(1, 35), (34, 35), (35, 35), (45, 45), (60, 60), (61, 60), (Int.max, 60)])
  func aCeilingOutsideThirtyFiveToSixtyIsClampedIntoIt(_ requested: Int, _ enforced: Int) {
    let limits = HelperSafetyLimits(
      requestedBatteryFloorPercent: HelperSafetyLimits.notGiven, requestedTemperatureCeilingCelsius: requested)
    #expect(limits.temperatureCeilingCelsius == enforced)
    #expect(limits.batteryFloorPercent == 10)
  }

  @Test func theCompiledLimitsAreTheDocumentedOnes() {
    #expect(HelperSafetyLimits.batteryFloorRange == 5...50)
    #expect(HelperSafetyLimits.defaultBatteryFloorPercent == 10)
    #expect(HelperSafetyLimits.temperatureCeilingRange == 35...60)
    #expect(HelperSafetyLimits.defaultTemperatureCeilingCelsius == 60)
    #expect(HelperSafetyLimits.notGiven == 0)
    #expect(HelperSafetyLimits.compiled.batteryFloorPercent == 10)
    #expect(HelperSafetyLimits.compiled.temperatureCeilingCelsius == 60)
  }
}
