import Foundation

public enum SystemInfo {
  static let osBuildKey = "kern.osversion"
  static let hardwareModelKey = "hw.model"
  static let maxValueBytes = 256

  public static func osBuild() -> String? {
    string(forKey: osBuildKey)
  }

  public static func hardwareModel() -> String? {
    string(forKey: hardwareModelKey)
  }

  public static func osVersion() -> String {
    osVersion(ProcessInfo.processInfo.operatingSystemVersion)
  }

  public static func osVersion(_ version: OperatingSystemVersion) -> String {
    let short = "\(version.majorVersion).\(version.minorVersion)"
    return version.patchVersion == 0 ? short : "\(short).\(version.patchVersion)"
  }

  static func string(forKey key: String) -> String? {
    var size = 0
    guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0, size <= maxValueBytes else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else { return nil }
    let bytes = buffer.prefix(min(size, buffer.count)).prefix { $0 != 0 }
    let value = String(decoding: bytes, as: UTF8.self)
    return value.isEmpty ? nil : value
  }
}
