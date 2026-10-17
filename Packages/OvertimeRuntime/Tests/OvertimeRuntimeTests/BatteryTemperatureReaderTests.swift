import Foundation
import OvertimeCore
import OvertimeHelperCore
import OvertimeSystem
import Testing

struct BatteryTemperatureReaderTests {
  @Test(arguments: [
    (3209, 32), (4500, 45), (4499, 44), (0, 0), (-1, -1), (-100, -1), (-101, -2), (10000, 100), (-4000, -40),
  ])
  func centidegreesBecomeWholeDegreesRoundedDown(_ centidegrees: Int, _ celsius: Int) {
    #expect(BatteryTemperatureReader.celsius(centidegrees: centidegrees) == celsius)
  }

  @Test(arguments: [-4001, 10001, Int.max, Int.min])
  func aValueOutsideMinus40To100DegreesIsNotATemperature(_ centidegrees: Int) {
    #expect(BatteryTemperatureReader.celsius(centidegrees: centidegrees) == nil)
  }

  @Test func theBatteryEntrysOwnTemperatureComesFirst() {
    let reading = BatteryTemperatureReader.classify(
      batteryFound: true, topLevel: 3209, packData: [["Temperature": 4000] as [String: Any]])
    #expect(reading == .celsius(32))
  }

  @Test func withoutItTheHottestPackIsUsed() {
    let packs: [Any?] = [
      ["Temperature": 3100] as [String: Any], ["Temperature": 3509] as [String: Any],
      ["Voltage": 12000] as [String: Any], nil, "x",
    ]
    #expect(BatteryTemperatureReader.classify(batteryFound: true, topLevel: nil, packData: packs) == .celsius(35))
  }

  @Test func noBatteryEntryAndNoPackIsUnavailable() {
    #expect(BatteryTemperatureReader.classify(batteryFound: false, topLevel: nil, packData: []) == .unavailable)
  }

  @Test func aBatteryWithoutATemperatureValueIsUnavailable() {
    let packs: [Any?] = [["Voltage": 12000] as [String: Any]]
    #expect(BatteryTemperatureReader.classify(batteryFound: true, topLevel: nil, packData: packs) == .unavailable)
    #expect(BatteryTemperatureReader.classify(batteryFound: true, topLevel: nil, packData: []) == .unavailable)
  }

  @Test func aValueThatIsNotAPlausibleWholeNumberIsUnreadable() {
    for topLevel in ["hot", NSNumber(value: 32.5), 20000] as [Any] {
      #expect(BatteryTemperatureReader.classify(batteryFound: true, topLevel: topLevel, packData: []) == .unreadable)
    }
    let packs: [Any?] = [["Temperature": 3100] as [String: Any], ["Temperature": "x"] as [String: Any]]
    #expect(BatteryTemperatureReader.classify(batteryFound: true, topLevel: nil, packData: packs) == .unreadable)
  }

  @Test func theHelperAndTheAppConvertATemperatureTheSameWay() {
    let edges = [-4001, -4000, -101, -100, -1, 0, 4499, 4500, 10000, 10001]
    let values = Array(stride(from: -4500, through: 10500, by: 7)) + edges
    let mismatches = values.filter { centidegrees in
      HelperBatteryTemperature.celsius(centidegrees: centidegrees)
        != BatteryTemperatureReader.celsius(centidegrees: centidegrees)
    }
    #expect(values.count > 2000)
    #expect(mismatches.isEmpty, "first mismatches: \(mismatches.prefix(5))")
  }

  @Test func aLiveReadOnThisMacIsACelsiusInRangeOrUnavailable() {
    switch BatteryTemperatureReader.readSystem() {
    case .unavailable:
      break
    case .celsius(let celsius):
      #expect((-40...100).contains(celsius))
    case .unreadable:
      Issue.record("the live battery temperature read was unreadable")
    }
  }
}
