import Foundation
import IOKit
import OvertimeCore

public enum BatteryTemperatureReader {
  public static let plausibleCentidegrees = -4000...10000
  static let batteryClass = "AppleSmartBattery"
  static let packClass = "AppleSmartBatteryPack"
  static let temperatureKey = "Temperature"
  static let batteryDataKey = "BatteryData"

  public static func celsius(centidegrees: Int) -> Int? {
    guard plausibleCentidegrees.contains(centidegrees) else { return nil }
    return centidegrees >= 0 ? centidegrees / 100 : -((-centidegrees + 99) / 100)
  }

  public static func classify(batteryFound: Bool, topLevel: Any?, packData: [Any?]) -> BatteryTemperatureReading {
    let candidates: [Any]
    if let topLevel {
      candidates = [topLevel]
    } else {
      candidates = packData.compactMap { entry in
        (entry as? [String: Any])?[temperatureKey]
      }
    }
    guard !candidates.isEmpty else { return .unavailable }
    var hottest: Int?
    for candidate in candidates {
      guard let centidegrees = candidate as? Int, let value = celsius(centidegrees: centidegrees) else {
        return .unreadable
      }
      hottest = max(hottest ?? value, value)
    }
    return hottest.map(BatteryTemperatureReading.celsius) ?? .unavailable
  }

  @Sendable public static func readSystem() -> BatteryTemperatureReading {
    let battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(batteryClass))
    let batteryFound = battery != IO_OBJECT_NULL
    var topLevel: Any?
    if batteryFound {
      topLevel = IORegistryEntryCreateCFProperty(battery, temperatureKey as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue()
      IOObjectRelease(battery)
    }
    var packData: [Any?] = []
    var iterator: io_iterator_t = 0
    if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(packClass), &iterator) == KERN_SUCCESS {
      while case let pack = IOIteratorNext(iterator), pack != IO_OBJECT_NULL {
        packData.append(
          IORegistryEntryCreateCFProperty(pack, batteryDataKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue())
        IOObjectRelease(pack)
      }
      IOObjectRelease(iterator)
    }
    return classify(batteryFound: batteryFound, topLevel: topLevel, packData: packData)
  }
}
