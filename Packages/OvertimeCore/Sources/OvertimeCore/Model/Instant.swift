import Foundation

public struct Instant: Sendable, Hashable, Comparable, Codable {
  public var nanoseconds: UInt64

  public init(nanoseconds: UInt64) {
    self.nanoseconds = nanoseconds
  }

  public static func < (lhs: Instant, rhs: Instant) -> Bool {
    lhs.nanoseconds < rhs.nanoseconds
  }

  public static func nanoseconds(forSeconds seconds: Double) -> UInt64 {
    let scaled = (seconds * 1_000_000_000).rounded()
    guard !scaled.isNaN, scaled > 0 else { return 0 }
    guard scaled < Double(UInt64.max) else { return UInt64.max }
    return UInt64(scaled)
  }

  public func adding(seconds: Double) -> Instant {
    guard !seconds.isNaN else { return self }
    if seconds >= 0 {
      let (sum, overflow) = nanoseconds.addingReportingOverflow(Instant.nanoseconds(forSeconds: seconds))
      return Instant(nanoseconds: overflow ? UInt64.max : sum)
    }
    let delta = Instant.nanoseconds(forSeconds: -seconds)
    return Instant(nanoseconds: nanoseconds >= delta ? nanoseconds - delta : 0)
  }

  public func nanoseconds(since earlier: Instant) -> UInt64 {
    nanoseconds >= earlier.nanoseconds ? nanoseconds - earlier.nanoseconds : 0
  }

  public func seconds(since earlier: Instant) -> Double {
    Double(nanoseconds(since: earlier)) / 1_000_000_000
  }
}

public struct Stamped<E: Sendable & Equatable>: Sendable, Equatable {
  public var mono: Instant
  public var wall: Date
  public var event: E

  public init(mono: Instant, wall: Date, event: E) {
    self.mono = mono
    self.wall = wall
    self.event = event
  }
}
