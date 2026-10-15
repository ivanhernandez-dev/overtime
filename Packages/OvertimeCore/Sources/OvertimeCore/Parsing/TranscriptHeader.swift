import Foundation

public enum TranscriptHeader {
  public static let maxBytes = 65_536
  public static let maxEntrypointBytes = 128

  private static let marker: [UInt8] = Array(#""entrypoint":""#.utf8)
  private static let quote = UInt8(ascii: "\"")

  public static func entrypoint(in bytes: [UInt8]) -> String? {
    let limit = min(bytes.count, maxBytes)
    guard limit > marker.count else { return nil }
    var index = 0
    while index + marker.count < limit {
      if matchesMarker(bytes, at: index) {
        let start = index + marker.count
        var end = start
        while end < limit && bytes[end] != quote {
          end += 1
        }
        guard end < limit, end - start <= maxEntrypointBytes else { return nil }
        return String(decoding: bytes[start..<end], as: UTF8.self)
      }
      index += 1
    }
    return nil
  }

  private static func matchesMarker(_ bytes: [UInt8], at index: Int) -> Bool {
    for offset in 0..<marker.count where bytes[index + offset] != marker[offset] {
      return false
    }
    return true
  }
}
