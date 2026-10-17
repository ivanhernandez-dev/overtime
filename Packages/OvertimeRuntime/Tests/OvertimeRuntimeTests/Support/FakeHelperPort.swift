import Foundation
import OvertimeCore
import OvertimeEngine
import os

extension HelperPort {
  func engage() -> EffectOutcome {
    engage(limits: HelperLimits(settings: Settings()))
  }
}

final class FakeHelperPort: HelperPort {
  private struct Script: Sendable {
    var calls: [HelperAction] = []
    var limits: [HelperLimits] = []
    var outcomes: [HelperAction: [EffectOutcome]] = [:]
    var held: Set<HelperAction> = []
    var requested = 0
    var signaled = 0
    var returned = 0
  }

  static let heldSeconds: Double = 120

  private let script = OSAllocatedUnfairLock(initialState: Script())
  private let gate = DispatchSemaphore(value: 0)
  private let observer: @Sendable (HelperAction) -> Void

  init(observer: @escaping @Sendable (HelperAction) -> Void = { _ in }) {
    self.observer = observer
  }

  var calls: [HelperAction] {
    script.withLock { $0.calls }
  }

  var engageLimits: [HelperLimits] {
    script.withLock { $0.limits }
  }

  var heldReturned: Int {
    script.withLock { $0.returned }
  }

  func queue(_ outcome: EffectOutcome, for action: HelperAction) {
    script.withLock { $0.outcomes[action, default: []].append(outcome) }
  }

  func holdNext(_ action: HelperAction) {
    script.withLock {
      $0.held.insert(action)
      $0.requested += 1
    }
  }

  func releaseHeld() {
    let pending = script.withLock { script -> Int in
      defer { script.signaled = script.requested }
      return script.requested - script.signaled
    }
    for _ in 0..<pending {
      gate.signal()
    }
  }

  func engage(limits: HelperLimits) -> EffectOutcome {
    script.withLock { $0.limits.append(limits) }
    return perform(.engage)
  }

  func release() -> EffectOutcome {
    perform(.release)
  }

  func heartbeat() -> EffectOutcome {
    perform(.heartbeat)
  }

  private func perform(_ action: HelperAction) -> EffectOutcome {
    observer(action)
    let (held, outcome) = script.withLock { script -> (Bool, EffectOutcome) in
      script.calls.append(action)
      var outcome = EffectOutcome.succeeded
      if var queued = script.outcomes[action], !queued.isEmpty {
        outcome = queued.removeFirst()
        script.outcomes[action] = queued
      }
      return (script.held.remove(action) != nil, outcome)
    }
    if held {
      _ = gate.wait(timeout: .now() + Self.heldSeconds)
      script.withLock { $0.returned += 1 }
    }
    return outcome
  }
}
