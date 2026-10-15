import Foundation

public enum EntrypointGlob {
  private static let star = UInt8(ascii: "*")

  public static func matches(pattern: String, value: String) -> Bool {
    let pattern = Array(pattern.utf8)
    let value = Array(value.utf8)
    var patternIndex = 0
    var valueIndex = 0
    var lastStar: Int?
    var resumeAt = 0
    while valueIndex < value.count {
      if patternIndex < pattern.count && pattern[patternIndex] == star {
        lastStar = patternIndex
        resumeAt = valueIndex
        patternIndex += 1
      } else if patternIndex < pattern.count && pattern[patternIndex] == value[valueIndex] {
        patternIndex += 1
        valueIndex += 1
      } else if let lastStar {
        patternIndex = lastStar + 1
        resumeAt += 1
        valueIndex = resumeAt
      } else {
        return false
      }
    }
    while patternIndex < pattern.count && pattern[patternIndex] == star {
      patternIndex += 1
    }
    return patternIndex == pattern.count
  }

  public static func matchesAny(_ patterns: [String], value: String) -> Bool {
    patterns.contains { matches(pattern: $0, value: value) }
  }
}
