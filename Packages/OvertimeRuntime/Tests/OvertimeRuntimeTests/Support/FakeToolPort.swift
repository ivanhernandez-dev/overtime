import Foundation
import OvertimeSystem
import os

final class FakeToolPort: ToolPort {
  struct Call: Sendable, Equatable {
    var executable: String
    var arguments: [String]
  }

  typealias Responder = @Sendable (String, [String]) -> ToolOutcome?

  private let recorded = OSAllocatedUnfairLock<[Call]>(initialState: [])
  private let outcome: OSAllocatedUnfairLock<ToolOutcome>
  private let responder: OSAllocatedUnfairLock<Responder?>

  init(outcome: ToolOutcome = .finished(exitCode: 0, stdout: "", stderr: ""), responder: Responder? = nil) {
    self.outcome = OSAllocatedUnfairLock(initialState: outcome)
    self.responder = OSAllocatedUnfairLock(initialState: responder)
  }

  var calls: [Call] {
    recorded.withLock { $0 }
  }

  func setOutcome(_ next: ToolOutcome) {
    outcome.withLock { $0 = next }
  }

  func setResponder(_ next: Responder?) {
    responder.withLock { $0 = next }
  }

  func run(_ executable: String, _ arguments: [String]) -> ToolOutcome {
    recorded.withLock { $0.append(Call(executable: executable, arguments: arguments)) }
    if let scripted = responder.withLock({ $0 })?(executable, arguments) {
      return scripted
    }
    return outcome.withLock { $0 }
  }
}
