import os

public final class StuckWindowBox: Sendable {
  private let value: OSAllocatedUnfairLock<Double>

  public init(seconds: Double) {
    value = OSAllocatedUnfairLock(initialState: seconds)
  }

  public var seconds: Double {
    get { value.withLock { $0 } }
    set { value.withLock { $0 = newValue } }
  }
}
