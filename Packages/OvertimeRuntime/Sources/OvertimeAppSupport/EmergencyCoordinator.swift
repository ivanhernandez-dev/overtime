import Foundation
import OvertimeCore
import OvertimeEngine
import os

public struct RestoreResult: Sendable, Equatable {
  public enum Kind: Sendable, Equatable {
    case restored
    case helperNotCleared
    case failed
    case inProgress
  }

  public var kind: Kind
  public var copy: String?
  public var engineUnresponsive: Bool

  public init(kind: Kind, copy: String?, engineUnresponsive: Bool = false) {
    self.kind = kind
    self.copy = copy
    self.engineUnresponsive = engineUnresponsive
  }
}

public final class EmergencyCoordinator: Sendable {
  public static let restoredCopy = "Normal sleep restored."
  public static let helperNotClearedCopy =
    "Overtime released its own hold, but unplug protection didn't confirm that system sleep is back on."
  public static let failedCopy =
    "Couldn't restore normal sleep. Run Overtime.app/Contents/MacOS/Overtime --reset in Terminal."
  public static let failedWithSleepDisabledCopy =
    "Couldn't restore normal sleep, and unplug protection didn't confirm that SleepDisabled is off. "
    + "Run Overtime.app/Contents/MacOS/Overtime --reset in Terminal."
  public static let resultSeconds: Double = 10

  private let reset: any EmergencyResetting
  private let releaseUntilIdle: @Sendable () async -> Bool?
  private let followUpBoundSeconds: Double

  public init(
    reset: any EmergencyResetting,
    releaseUntilIdle: @escaping @Sendable () async -> Bool?,
    followUpBoundSeconds: Double = Timing.systemCallTimeoutSeconds
  ) {
    self.reset = reset
    self.releaseUntilIdle = releaseUntilIdle
    self.followUpBoundSeconds = followUpBoundSeconds
  }

  public func restore(show: @Sendable (RestoreResult) async -> Void = { _ in }) async -> RestoreResult {
    var result: RestoreResult
    switch await reset.run() {
    case .restored(_, helperCleared: true):
      result = RestoreResult(kind: .restored, copy: Self.restoredCopy)
    case .restored(_, helperCleared: false):
      result = RestoreResult(kind: .helperNotCleared, copy: Self.helperNotClearedCopy)
    case .clearFailed(_, helperCleared: true):
      result = RestoreResult(kind: .failed, copy: Self.failedCopy)
    case .clearFailed(_, helperCleared: false):
      result = RestoreResult(kind: .failed, copy: Self.failedWithSleepDisabledCopy)
    case .inProgress:
      return RestoreResult(kind: .inProgress, copy: nil)
    }
    await show(result)
    result.engineUnresponsive = await followUp() == nil
    return result
  }

  private func followUp() async -> Bool? {
    let answer = OSAllocatedUnfairLock<Bool?>(initialState: nil)
    let releaseUntilIdle = releaseUntilIdle
    let finished = await Engine.bounded(seconds: followUpBoundSeconds) {
      let sent = await releaseUntilIdle()
      answer.withLock { $0 = sent }
    }
    guard finished else { return nil }
    return answer.withLock { $0 }
  }
}
