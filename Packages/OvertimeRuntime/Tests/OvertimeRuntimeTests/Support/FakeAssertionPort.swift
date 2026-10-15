import Foundation
import OvertimeCore
import OvertimeSystem
import os

final class FakeAssertionPort: AssertionPort {
  enum Call: Sendable, Equatable {
    case acquireOrRenew(AssertionKind, Int)
    case release(AssertionKind)
  }

  private struct Script: Sendable {
    var calls: [Call] = []
    var acquireOutcomes: [EffectOutcome] = []
    var acquireBlockSeconds: Double = 0
    var blockedReturns = 0
    var foreign: [ForeignAssertion] = []
  }

  private let script = OSAllocatedUnfairLock(initialState: Script())
  private let unblock = DispatchSemaphore(value: 0)

  var calls: [Call] {
    script.withLock { $0.calls }
  }

  var blockedCallsReturned: Int {
    script.withLock { $0.blockedReturns }
  }

  var foreignTable: [ForeignAssertion] {
    script.withLock { $0.foreign }
  }

  func seedForeign(_ assertions: [ForeignAssertion]) {
    script.withLock { $0.foreign += assertions }
  }

  func queueAcquireOutcomes(_ outcomes: [EffectOutcome]) {
    script.withLock { $0.acquireOutcomes += outcomes }
  }

  func blockAcquires(forSeconds seconds: Double) {
    script.withLock { $0.acquireBlockSeconds = seconds }
  }

  func releaseBlockedCalls() {
    unblock.signal()
  }

  func acquireOrRenew(_ kind: AssertionKind, timeoutSeconds: Int) -> EffectOutcome {
    let (outcome, block) = script.withLock { script -> (EffectOutcome, Double) in
      script.calls.append(.acquireOrRenew(kind, timeoutSeconds))
      let outcome = script.acquireOutcomes.isEmpty ? .succeeded : script.acquireOutcomes.removeFirst()
      return (outcome, script.acquireBlockSeconds)
    }
    if block > 0 {
      _ = unblock.wait(timeout: .now() + block)
      script.withLock { $0.blockedReturns += 1 }
    }
    return outcome
  }

  func release(_ kind: AssertionKind) -> EffectOutcome {
    script.withLock { $0.calls.append(.release(kind)) }
    return .succeeded
  }
}
