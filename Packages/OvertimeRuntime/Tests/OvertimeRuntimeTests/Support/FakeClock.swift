import Foundation
import OvertimeCore
import OvertimeSystem
import os

final class FakeClock: ClockPort {
  private struct Reading: Sendable {
    var mono: Instant
    var wall: Date
  }

  private let reading: OSAllocatedUnfairLock<Reading>

  init(mono: Instant = Instant(nanoseconds: 1_000_000_000_000), wall: Date = Date()) {
    reading = OSAllocatedUnfairLock(initialState: Reading(mono: mono, wall: wall))
  }

  func mono() -> Instant {
    reading.withLock { $0.mono }
  }

  func wall() -> Date {
    reading.withLock { $0.wall }
  }

  func set(mono: Instant, wall: Date) {
    reading.withLock { $0 = Reading(mono: mono, wall: wall) }
  }

  func advance(seconds: Double) {
    reading.withLock { reading in
      reading.mono = reading.mono.adding(seconds: seconds)
      reading.wall = reading.wall.addingTimeInterval(seconds)
    }
  }
}
