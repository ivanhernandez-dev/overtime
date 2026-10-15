import Foundation

public enum StepStatus: Codable, Sendable, Equatable {
  case pending
  case running
  case done
  case skipped(String)
  case failed(String)

  public var keyword: String {
    switch self {
    case .pending: "pending"
    case .running: "running"
    case .done: "done"
    case .skipped: "skipped"
    case .failed: "failed"
    }
  }

  public var message: String? {
    switch self {
    case .skipped(let message), .failed(let message): message
    case .pending, .running, .done: nil
    }
  }

  public var isProblem: Bool {
    switch self {
    case .skipped, .failed: true
    case .pending, .running, .done: false
    }
  }
}
