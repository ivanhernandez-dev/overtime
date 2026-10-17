import Foundation

public enum VerificationState: Sendable, Equatable {
  case idle
  case pending(deadline: Instant)
}

public enum SleepVerification {
  public static func step(
    _ state: inout AppState, event: Event, now: Instant, holdEffects: [Effect], settings: Settings = Settings()
  ) -> [Effect] {
    var effects: [Effect] = []
    if case .pending(let deadline) = state.verification {
      effects = check(&state, event: event, now: now, deadline: deadline, settings: settings)
    }
    if startsVerification(state, holdEffects: holdEffects, settings: settings) {
      state.verification = .pending(deadline: now.adding(seconds: Timing.releaseVerificationSeconds))
    }
    return effects
  }

  public static func deadlines(_ state: AppState) -> [Instant] {
    guard case .pending(let deadline) = state.verification else { return [] }
    return [deadline]
  }

  static func check(
    _ state: inout AppState, event: Event, now: Instant, deadline: Instant, settings: Settings
  ) -> [Effect] {
    if case .systemWillSleep = event {
      state.verification = .idle
      return [.log(Decision(keyword: .verify, verb: "sleep ok"))]
    }
    if LidDisplay.observation(event) == false {
      return cancel(&state, reason: "lidOpened")
    }
    if Hold.lidCloseDesired(state, settings: settings) {
      return cancel(&state, reason: "wanted")
    }
    guard case .tick = event, now >= deadline else { return [] }
    state.verification = .idle
    return [
      .log(
        Decision(keyword: .verify, verb: "sleep failed", fields: [DecisionField(key: "action", value: "requestSleep")])),
      .log(Decision(keyword: .error, verb: "sleep not observed")),
      .requestSleep(id: Hold.allocate(&state)),
    ]
  }

  static func cancel(_ state: inout AppState, reason: String) -> [Effect] {
    state.verification = .idle
    return [.log(Decision(keyword: .verify, verb: "cancelled", fields: [DecisionField(key: "reason", value: reason)]))]
  }

  static func startsVerification(_ state: AppState, holdEffects: [Effect], settings: Settings = Settings()) -> Bool {
    guard !state.hold.stopping, !Hold.lidCloseDesired(state, settings: settings) else { return false }
    let clears = holdEffects.contains { effect in
      guard case .clamshell(false, _, let why) = effect else { return false }
      return why == .release || why == .clearStale
    }
    guard clears, (state.lid.closed ?? state.lastLidClosed) == true else { return false }
    let externalDisplays = state.lid.closed == true ? state.lid.externalDisplays : (state.lastExternalDisplays ?? 0)
    return externalDisplays == 0
  }
}
