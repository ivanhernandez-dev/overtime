import Foundation
import OvertimeAppSupport
import os

final class FakeAdminPrompt: AdminPrompt {
  private let state: OSAllocatedUnfairLock<(outcome: AdminOutcome, calls: Int)>

  init(_ outcome: AdminOutcome = .succeeded) {
    state = OSAllocatedUnfairLock(initialState: (outcome, 0))
  }

  var calls: Int {
    state.withLock { $0.calls }
  }

  func clearSleepDisabled() -> AdminOutcome {
    state.withLock { state in
      state.calls += 1
      return state.outcome
    }
  }
}
