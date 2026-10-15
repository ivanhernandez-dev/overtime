import Foundation
import OvertimeCore

public protocol ClockPort: Sendable {
  func mono() -> Instant
  func wall() -> Date
}

public struct SystemClock: ClockPort {
  public init() {}

  public func mono() -> Instant {
    Instant(nanoseconds: clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW))
  }

  public func wall() -> Date {
    Date()
  }
}
