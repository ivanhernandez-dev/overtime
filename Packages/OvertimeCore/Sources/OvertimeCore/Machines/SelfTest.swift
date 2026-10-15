import Foundation

public enum SelfTestFailure: Sendable, Equatable {
  case clamshellRefused(Int32)
  case assertionRefused(Int32)
  case timedOut
  case watchdogNotRunning
  case stateNotSaved

  var reason: String {
    switch self {
    case .clamshellRefused: "clamshellRefused"
    case .assertionRefused: "assertionRefused"
    case .timedOut: "timedOut"
    case .watchdogNotRunning: "watchdogNotRunning"
    case .stateNotSaved: "stateNotSaved"
    }
  }

  var code: Int32? {
    switch self {
    case .clamshellRefused(let code), .assertionRefused(let code): code
    case .timedOut, .watchdogNotRunning, .stateNotSaved: nil
    }
  }
}

public enum SelfTestSkip: Sendable, Equatable {
  case amphetamine
  case otherTool(String)
  case sleepDisabled

  var reason: String {
    switch self {
    case .amphetamine: "amphetamine"
    case .otherTool: "otherTool"
    case .sleepDisabled: "sleepDisabled"
    }
  }
}

public enum SelfTestStatus: Sendable, Equatable {
  case notRun
  case waiting
  case running
  case passed
  case failed(SelfTestFailure)
  case skipped(SelfTestSkip)
}

public enum SelfTestStep: String, Sendable, CaseIterable {
  case clamshellOn
  case clamshellOff
  case assertionAcquire
  case assertionRelease

  var isClamshell: Bool {
    self == .clamshellOn || self == .clamshellOff
  }
}

public struct SelfTestPending: Sendable, Equatable {
  public var ids: [SelfTestStep: EffectID]
  public var outcomes: [SelfTestStep: EffectOutcome]

  public init(ids: [SelfTestStep: EffectID], outcomes: [SelfTestStep: EffectOutcome] = [:]) {
    self.ids = ids
    self.outcomes = outcomes
  }

  public var isComplete: Bool {
    SelfTestStep.allCases.allSatisfy { outcomes[$0] != nil }
  }

  public func step(for id: EffectID) -> SelfTestStep? {
    SelfTestStep.allCases.first { ids[$0] == id }
  }
}

public struct SelfTestState: Sendable, Equatable {
  public var status: SelfTestStatus
  public var pending: SelfTestPending?
  public var errorActive: Bool
  public var runs: UInt64
  public var failures: UInt64
  public var osBuild: String?

  public init(
    status: SelfTestStatus = .notRun,
    pending: SelfTestPending? = nil,
    errorActive: Bool = false,
    runs: UInt64 = 0,
    failures: UInt64 = 0,
    osBuild: String? = nil
  ) {
    self.status = status
    self.pending = pending
    self.errorActive = errorActive
    self.runs = runs
    self.failures = failures
    self.osBuild = osBuild
  }
}

public enum SelfTest {
  public static let watchdogNotRunningCode: Int32 = -1
  public static let stateNotSavedCode: Int32 = -3
  public static let lockBusyCode: Int32 = -4

  public static func runnable(_ state: AppState) -> Bool {
    state.hold.lidClose == .released && !state.persisted.ownsHold && state.hold.idle == .released
      && state.want.wanted != true && state.lastLidClosed == false && !state.hold.stopping
  }

  public static func request(_ state: inout AppState, facts: SelfTestFacts, now: Instant) -> [Effect] {
    guard state.selfTest.pending == nil else { return [] }
    state.selfTest.osBuild = facts.osBuild ?? state.selfTest.osBuild
    if let skip = skip(for: facts) {
      state.selfTest.status = .skipped(skip)
      let reason = DecisionField(key: "reason", value: skip.reason)
      return [.log(Decision(keyword: .selftest, verb: "skipped", fields: [reason]))]
    }
    guard runnable(state) else {
      state.selfTest.status = .waiting
      return []
    }
    let persisted = LidCloseHold.ownership(true, state: &state)
    var ids: [SelfTestStep: EffectID] = [:]
    for step in SelfTestStep.allCases {
      ids[step] = Hold.allocate(&state)
    }
    state.selfTest.pending = SelfTestPending(ids: ids)
    state.selfTest.status = .running
    EventCounters.bump(&state.selfTest.runs)
    return [.log(Decision(keyword: .selftest, verb: "start")), .persist(persisted), .sentinel(.arm)]
      + SelfTestStep.allCases.compactMap { step in ids[step].map { effect(step, id: $0) } }
  }

  public static func handleResult(
    _ id: EffectID, _ outcome: EffectOutcome, state: inout AppState, now: Instant
  ) -> [Effect]? {
    guard var pending = state.selfTest.pending, let step = pending.step(for: id) else {
      noteEngage(id, outcome, state: &state)
      return nil
    }
    pending.outcomes[step] = outcome
    state.selfTest.pending = pending
    guard pending.isComplete else { return [] }
    state.selfTest.pending = nil
    let line = conclude(firstFailure(pending), state: &state)
    let lateOn = pending.outcomes[.clamshellOn] == .timedOut
    if lateOn, let on = pending.ids[.clamshellOn] {
      LidCloseHold.track(on, state: &state, now: now)
      state.hold.onWrites[on]?.timedOut = true
    }
    guard holdIsFree(state) else { return [line] }
    guard pending.outcomes[.clamshellOff] == .succeeded, !lateOn else {
      return [line, LidCloseHold.release(.selfTest, state: &state)]
    }
    let persisted = LidCloseHold.ownership(false, state: &state)
    return [.sentinel(.disarm), .persist(persisted), line]
  }

  static func skip(for facts: SelfTestFacts) -> SelfTestSkip? {
    if facts.amphetamineRunning { return .amphetamine }
    if let tool = facts.otherTool { return .otherTool(Reducer.loggable(tool)) }
    return facts.sleepDisabled == false ? nil : .sleepDisabled
  }

  static func firstFailure(_ pending: SelfTestPending) -> SelfTestFailure? {
    for step in SelfTestStep.allCases {
      switch pending.outcomes[step] {
      case .succeeded?, nil:
        continue
      case .timedOut?:
        return .timedOut
      case .failed(let code)?:
        if code == watchdogNotRunningCode { return .watchdogNotRunning }
        if code == lockBusyCode { return .timedOut }
        if code == stateNotSavedCode, step.isClamshell { return .stateNotSaved }
        return step.isClamshell ? .clamshellRefused(code) : .assertionRefused(code)
      }
    }
    return nil
  }

  static func conclude(_ failure: SelfTestFailure?, state: inout AppState) -> Effect {
    guard let failure else {
      state.selfTest.status = .passed
      state.selfTest.errorActive = false
      return .log(Decision(keyword: .selftest, verb: "passed"))
    }
    state.selfTest.status = .failed(failure)
    state.selfTest.errorActive = true
    EventCounters.bump(&state.selfTest.failures)
    var fields = [DecisionField(key: "reason", value: failure.reason)]
    if let code = failure.code {
      fields.append(DecisionField(key: "code", value: String(format: "0x%08X", UInt32(bitPattern: code))))
    }
    return .log(Decision(keyword: .selftest, verb: "failed", fields: fields))
  }

  static func noteEngage(_ id: EffectID, _ outcome: EffectOutcome, state: inout AppState) {
    guard state.selfTest.errorActive, outcome == .succeeded, state.hold.lidClose == .acquiring(id) else { return }
    state.selfTest.errorActive = false
  }

  static func holdIsFree(_ state: AppState) -> Bool {
    !state.hold.stopping && state.hold.lidClose == .released && state.hold.goals[.lidClose] != true
  }

  static func effect(_ step: SelfTestStep, id: EffectID) -> Effect {
    switch step {
    case .clamshellOn: .clamshell(on: true, id: id, why: .selfTest)
    case .clamshellOff: .clamshell(on: false, id: id, why: .selfTest)
    case .assertionAcquire: .idleAssertion(.acquireOrRenew(timeoutSeconds: Hold.timeoutSeconds), id: id)
    case .assertionRelease: .idleAssertion(.release, id: id)
    }
  }
}
