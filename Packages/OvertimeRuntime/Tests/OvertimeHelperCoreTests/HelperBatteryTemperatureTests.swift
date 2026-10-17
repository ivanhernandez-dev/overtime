import OvertimeHelperCore
import Testing

struct HelperBatteryTemperatureTests {
  static let table: [(Int, Int?)] = [
    (3209, 32), (4500, 45), (4499, 44), (0, 0), (-1, -1), (-100, -1), (-101, -2), (10000, 100), (-4000, -40),
    (-4001, nil), (10001, nil), (Int.max, nil), (Int.min, nil),
  ]

  @Test(arguments: table)
  func centidegreesBecomeWholeDegreesForTheHelper(_ centidegrees: Int, _ celsius: Int?) {
    #expect(HelperBatteryTemperature.celsius(centidegrees: centidegrees) == celsius)
  }
}
