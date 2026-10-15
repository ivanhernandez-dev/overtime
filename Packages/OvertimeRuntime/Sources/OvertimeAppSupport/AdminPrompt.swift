import Foundation

public enum AdminOutcome: Sendable, Equatable {
  case succeeded
  case cancelled
  case failed(String)
}

public protocol AdminPrompt: Sendable {
  func clearSleepDisabled() -> AdminOutcome
}
