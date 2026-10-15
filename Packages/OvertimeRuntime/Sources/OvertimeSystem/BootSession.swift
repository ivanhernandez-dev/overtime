import Foundation

public enum BootSession {
  public static func current() -> String? {
    var size = 0
    guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0, size <= 256 else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return nil }
    let bytes = buffer.prefix(min(size, buffer.count)).prefix { $0 != 0 }
    let value = String(decoding: bytes, as: UTF8.self)
    return value.isEmpty ? nil : value
  }
}
