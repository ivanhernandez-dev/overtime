import Foundation
import IOKit

public struct RegistryReader: Sendable {
  static let rootDomainClass = "IOPMrootDomain"
  static let lidStateKey = "AppleClamshellState"
  static let capabilitiesKey = "System Capabilities"
  static let displayServiceClass = "DCPAVServiceProxy"
  static let displayLocationKey = "Location"
  static let externalLocation = "External"
  static let hidSystemClass = "IOHIDSystem"
  static let hidIdleKey = "HIDIdleTime"
  static let sleepDisabledKey = "SleepDisabled"
  public static let graphicsCapability = 0x2

  public init() {}

  public func lidClosed() -> Bool? {
    rootDomainBool(Self.lidStateKey)
  }

  public func sleepDisabled() -> Bool? {
    rootDomainBool(Self.sleepDisabledKey)
  }

  public func systemCapabilities() -> Int? {
    (rootDomainProperty(Self.capabilitiesKey) as? NSNumber)?.intValue
  }

  public func externalDisplayCount() -> Int? {
    guard let matching = IOServiceMatching(Self.displayServiceClass) else { return nil }
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(iterator) }
    var count = 0
    while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
      let location = IORegistryEntryCreateCFProperty(
        service, Self.displayLocationKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
      if location as? String == Self.externalLocation {
        count += 1
      }
      IOObjectRelease(service)
    }
    return count
  }

  public func hidIdleSeconds() -> Double? {
    guard let matching = IOServiceMatching(Self.hidSystemClass) else { return nil }
    let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
    guard service != IO_OBJECT_NULL else { return nil }
    defer { IOObjectRelease(service) }
    let value = IORegistryEntryCreateCFProperty(service, Self.hidIdleKey as CFString, kCFAllocatorDefault, 0)?
      .takeRetainedValue()
    guard let nanoseconds = (value as? NSNumber)?.int64Value, nanoseconds >= 0 else { return nil }
    return Double(nanoseconds) / 1_000_000_000
  }

  public static func isFullWake(capabilities: Int?) -> Bool? {
    capabilities.map { $0 & graphicsCapability != 0 }
  }

  func rootDomainBool(_ key: String) -> Bool? {
    guard let value = rootDomainProperty(key) else { return nil }
    if let flag = value as? Bool { return flag }
    return (value as? NSNumber)?.boolValue
  }

  func rootDomainProperty(_ key: String) -> Any? {
    guard let matching = IOServiceMatching(Self.rootDomainClass) else { return nil }
    let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
    guard service != IO_OBJECT_NULL else { return nil }
    defer { IOObjectRelease(service) }
    return IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
  }
}
