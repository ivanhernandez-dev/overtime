import Foundation

public enum SleepDisabledClearFailure: Sendable, Equatable {
  case unreadable
  case prompt(String)
  case stillSet
  case unconfirmed
}

public enum SleepDisabledClearOutcome: Sendable, Equatable {
  case alreadyClear
  case cleared
  case cancelled
  case failed(SleepDisabledClearFailure)

  public var isClear: Bool {
    self == .alreadyClear || self == .cleared
  }

  public var caption: String? {
    switch self {
    case .alreadyClear, .cleared: nil
    case .cancelled: SleepDisabledClearing.cancelledCaption
    case .failed: SleepDisabledClearing.failedCaption
    }
  }
}

public enum SleepDisabledClearing {
  public static let rowTitle = "Sleep is turned off system-wide (SleepDisabled)"
  public static let rowCaption =
    "Overtime didn't set this. Until it's cleared, the Mac can't sleep at all, even with the lid closed and Claude idle."
  public static let turnOnLabel = "Turn Sleep Back On…"
  public static let copyLabel = "Copy Command"
  public static let cancelledCaption = "You cancelled the administrator prompt. Sleep is still turned off system-wide."
  public static let failedCaption = "Couldn't turn sleep back on. Run this in Terminal: " + Hints.sleepDisabledCommand

  public static func run(read: () -> Bool?, prompt: any AdminPrompt) -> SleepDisabledClearOutcome {
    switch read() {
    case false?: return .alreadyClear
    case nil: return .failed(.unreadable)
    case true?: break
    }
    switch prompt.clearSleepDisabled() {
    case .cancelled: return .cancelled
    case .failed(let message): return .failed(.prompt(message))
    case .succeeded: break
    }
    switch read() {
    case false?: return .cleared
    case true?: return .failed(.stillSet)
    case nil: return .failed(.unconfirmed)
    }
  }
}
