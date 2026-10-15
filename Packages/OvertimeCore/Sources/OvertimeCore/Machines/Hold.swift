import Foundation

public enum BackendPhase: Sendable, Equatable {
  case released
  case acquiring(EffectID)
  case held
  case releasing(EffectID)
  case failed(attempts: Int, retryAt: Instant)
}

public enum LaunchHoldAction: Sendable, Equatable {
  case reclaim
  case clearIfUnwanted
}

public struct OnWrite: Sendable, Equatable {
  public var since: Instant
  public var timedOut: Bool

  public init(since: Instant, timedOut: Bool = false) {
    self.since = since
    self.timedOut = timedOut
  }
}

public enum HoldBackend: String, Sendable, CaseIterable {
  case idle
  case display
  case lidClose
}

public struct HoldState: Sendable, Equatable {
  public var idle: BackendPhase
  public var display: BackendPhase
  public var lidClose: BackendPhase
  public var nextReassert: Instant?
  public var wakeBurst: [Instant]
  public var periodicReassertLogged: Bool
  public var pendingLaunch: LaunchHoldAction?
  public var stopping: Bool
  public var errorActive: Bool
  public var renewals: [HoldBackend: EffectID]
  public var attempts: [HoldBackend: Int]
  public var goals: [HoldBackend: Bool]
  public var onWrites: [EffectID: OnWrite]
  public var lateWriteClearAt: Instant?
  public var releaseFailures: Int

  public init(idle: BackendPhase = .released, display: BackendPhase = .released, errorActive: Bool = false) {
    self.idle = idle
    self.display = display
    self.lidClose = .released
    self.nextReassert = nil
    self.wakeBurst = []
    self.periodicReassertLogged = false
    self.pendingLaunch = nil
    self.stopping = false
    self.errorActive = errorActive
    self.renewals = [:]
    self.attempts = [:]
    self.goals = [:]
    self.onWrites = [:]
    self.lateWriteClearAt = nil
    self.releaseFailures = 0
  }

  public subscript(backend: HoldBackend) -> BackendPhase {
    get {
      switch backend {
      case .idle: idle
      case .display: display
      case .lidClose: lidClose
      }
    }
    set {
      switch backend {
      case .idle: idle = newValue
      case .display: display = newValue
      case .lidClose: lidClose = newValue
      }
    }
  }

  public var retryDeadlines: [Instant] {
    HoldBackend.allCases.compactMap { backend in
      if case .failed(_, let retryAt) = self[backend] { return retryAt }
      return nil
    }
  }
}

public enum Hold {
  public static var timeoutSeconds: Int { Int(Timing.assertionTimeoutSeconds) }

  public static func backoffSeconds(_ attempts: Int) -> Double {
    let exponent = min(max(attempts - 1, 0), 16)
    return min(Timing.backoffBaseSeconds * Double(1 << exponent), Timing.backoffCapSeconds)
  }

  public static func reconcile(
    _ state: inout AppState, now: Instant, settings: Settings, tick: Bool = false
  ) -> [Effect] {
    guard !state.hold.stopping else { return [] }
    let wanted = state.want.wanted == true
    let lidClose = LidCloseHold.step(desired: wanted, state: &state, now: now, tick: tick)
    let idle = step(.idle, desired: wanted, state: &state, now: now, tick: tick)
    let display = step(
      .display, desired: displayDesired(state, wanted: wanted, settings: settings), state: &state, now: now,
      tick: tick)
    let releasesDisplay = display.contains { effect in
      if case .displayAssertion(.release, _) = effect { return true }
      return false
    }
    return releasesDisplay ? display + lidClose + idle : lidClose + idle + display
  }

  public static func stop(state: inout AppState) -> [Effect] {
    guard !state.hold.stopping else { return [] }
    state.hold.stopping = true
    state.hold.nextReassert = nil
    state.hold.wakeBurst.removeAll()
    let holding = LidCloseHold.mayHold(state)
    if holding {
      state.hold.releaseFailures = 0
    }
    var effects: [Effect] = holding ? [LidCloseHold.release(state: &state)] : []
    for backend in [HoldBackend.idle, .display] where state.hold[backend] != .released {
      effects.append(request(backend, acquire: false, state: &state))
    }
    return holding ? effects : effects + [.sentinel(.bye)]
  }

  public static func displayDesired(_ state: AppState, wanted: Bool, settings: Settings) -> Bool {
    guard wanted, settings.keepDisplayOn else { return false }
    return state.lastLidClosed != true || (state.lastExternalDisplays ?? 0) > 0
  }

  public static func handleResult(
    _ id: EffectID, _ outcome: EffectOutcome, state: inout AppState, now: Instant
  ) -> [Effect] {
    if let effects = LidCloseHold.handleResult(id, outcome, state: &state, now: now) {
      return effects
    }
    for backend in [HoldBackend.idle, .display] {
      switch state.hold[backend] {
      case .acquiring(let current) where current == id:
        guard outcome == .succeeded else { return fail(backend, state: &state, now: now) }
        state.hold[backend] = .held
        return [log(backend, "acquired")] + succeed(backend, state: &state)
      case .releasing(let current) where current == id:
        guard outcome == .succeeded else { return fail(backend, state: &state, now: now) }
        state.hold[backend] = .released
        return [log(backend, "released")] + succeed(backend, state: &state)
      case .held where state.hold.renewals[backend] == id:
        state.hold.renewals[backend] = nil
        guard outcome == .succeeded else { return fail(backend, state: &state, now: now) }
        return succeed(backend, state: &state)
      default:
        continue
      }
    }
    return []
  }

  static func step(
    _ backend: HoldBackend, desired: Bool, state: inout AppState, now: Instant, tick: Bool
  ) -> [Effect] {
    switch (state.hold[backend], desired) {
    case (.released, true):
      return [request(backend, acquire: true, state: &state)]
    case (.held, true):
      guard tick else { return [] }
      let id = allocate(&state)
      state.hold.renewals[backend] = id
      return [effect(backend, .acquireOrRenew(timeoutSeconds: timeoutSeconds), id)]
    case (.held, false), (.acquiring, false):
      return [request(backend, acquire: false, state: &state)]
    case (.failed(let attempts, let retryAt), _):
      if state.hold.goals[backend] != desired {
        return [request(backend, acquire: desired, state: &state)]
      }
      guard tick, now >= retryAt else { return [] }
      let retry = Effect.log(
        Decision(
          keyword: .hold, verb: "retry",
          fields: [
            DecisionField(key: "backend", value: backend.rawValue),
            DecisionField(key: "attempt", value: String(attempts + 1)),
          ]))
      return [retry, request(backend, acquire: desired, state: &state)]
    default:
      return []
    }
  }

  static func request(_ backend: HoldBackend, acquire: Bool, state: inout AppState) -> Effect {
    let id = allocate(&state)
    state.hold.renewals[backend] = nil
    state.hold.goals[backend] = acquire
    state.hold[backend] = acquire ? .acquiring(id) : .releasing(id)
    return effect(backend, acquire ? .acquireOrRenew(timeoutSeconds: timeoutSeconds) : .release, id)
  }

  static func fail(_ backend: HoldBackend, state: inout AppState, now: Instant) -> [Effect] {
    let attempts = (state.hold.attempts[backend] ?? 0) + 1
    let clearing = backend == .lidClose && state.hold.goals[backend] == false
    let delay = clearing ? Timing.releaseRetrySeconds : backoffSeconds(attempts)
    state.hold.attempts[backend] = attempts
    state.hold[backend] = .failed(attempts: attempts, retryAt: now.adding(seconds: delay))
    var effects: [Effect] = [
      .log(
        Decision(
          keyword: .hold, verb: "failed",
          fields: [
            DecisionField(key: "backend", value: backend.rawValue),
            DecisionField(key: "attempt", value: String(attempts)),
            DecisionField(key: "retryIn", value: String(Int(delay))),
          ]))
    ]
    if !state.hold.errorActive {
      state.hold.errorActive = true
      effects.append(
        .log(
          Decision(keyword: .error, verb: "hold", fields: [DecisionField(key: "backend", value: backend.rawValue)])))
    }
    return effects
  }

  static func succeed(_ backend: HoldBackend, state: inout AppState) -> [Effect] {
    state.hold.attempts[backend] = nil
    let failing = HoldBackend.allCases.contains { (state.hold.attempts[$0] ?? 0) > 0 }
    guard state.hold.errorActive, !failing else { return [] }
    state.hold.errorActive = false
    return [.log(Decision(keyword: .hold, verb: "recovered"))]
  }

  static func allocate(_ state: inout AppState) -> EffectID {
    let id = EffectID(value: state.nextEffectID)
    state.nextEffectID &+= 1
    return id
  }

  static func effect(_ backend: HoldBackend, _ action: AssertionAction, _ id: EffectID) -> Effect {
    switch backend {
    case .idle: .idleAssertion(action, id: id)
    case .display: .displayAssertion(action, id: id)
    case .lidClose: .clamshell(on: action != .release, id: id, why: action == .release ? .release : .engage)
    }
  }

  static func log(_ backend: HoldBackend, _ verb: String) -> Effect {
    .log(Decision(keyword: .hold, verb: backend.rawValue + " " + verb))
  }
}

public enum LidCloseHold {
  public static let burstOffsetsSeconds: [Double] = [1, 2, 3, 4, 5, 6]
  public static let burstGraceSeconds: Double = 0.5
  public static let maxTrackedOnWrites = 64

  public static func step(desired: Bool, state: inout AppState, now: Instant, tick: Bool) -> [Effect] {
    if let last = state.hold.wakeBurst.last, now > last.adding(seconds: burstGraceSeconds) {
      state.hold.wakeBurst.removeAll()
    }
    if let launch = state.hold.pendingLaunch, state.hold.lidClose == .released {
      return resolveLaunch(launch, desired: desired, state: &state, now: now, tick: tick)
    }
    switch (state.hold.lidClose, desired) {
    case (.released, true):
      guard state.lastFullWake == true else { return [] }
      return engage(.engage, state: &state, now: now)
    case (.held, true):
      return reassert(state: &state, now: now)
    case (.held, false), (.acquiring, false):
      return [release(state: &state)]
    case (.released, false):
      return followUpClear(state: &state, now: now, tick: tick)
    case (.failed, false) where state.hold.goals[.lidClose] != false:
      return [release(state: &state)]
    case (.failed, true) where state.hold.goals[.lidClose] != true:
      guard state.lastFullWake == true else { return [] }
      return engage(.engage, state: &state, now: now)
    case (.failed(let attempts, let retryAt), _):
      guard tick, now >= retryAt else { return [] }
      guard desired else { return [retryLog(attempts: attempts), release(state: &state)] }
      guard state.lastFullWake == true else { return [] }
      return [retryLog(attempts: attempts)] + engage(.engage, state: &state, now: now)
    default:
      return []
    }
  }

  public static func handleResult(
    _ id: EffectID, _ outcome: EffectOutcome, state: inout AppState, now: Instant
  ) -> [Effect]? {
    let tracked = state.hold.onWrites[id]
    if tracked != nil {
      state.hold.onWrites[id] = outcome == .timedOut ? OnWrite(since: now, timedOut: true) : nil
    }
    switch state.hold.lidClose {
    case .acquiring(let current) where current == id:
      let launch = state.hold.pendingLaunch
      state.hold.pendingLaunch = nil
      guard outcome == .succeeded else { return Hold.fail(.lidClose, state: &state, now: now) }
      state.hold.lidClose = .held
      let verb = launch == .reclaim ? "reclaim" : "engage"
      return [.log(Decision(keyword: .hold, verb: verb))] + Hold.succeed(.lidClose, state: &state)
    case .releasing(let current) where current == id:
      let launch = state.hold.pendingLaunch
      state.hold.pendingLaunch = nil
      guard outcome == .succeeded else { return releaseFailed(state: &state, now: now) }
      state.hold.releaseFailures = 0
      state.hold.lidClose = .released
      state.hold.nextReassert = nil
      state.hold.wakeBurst.removeAll()
      state.hold.periodicReassertLogged = false
      let verb = launch == nil ? "release" : "clearStale"
      if lateWriteUnsettled(state.hold, now: now) {
        state.hold.lateWriteClearAt = now.adding(seconds: Timing.lateWriteClearSeconds)
        let quarantine = DecisionField(key: "quarantine", value: "lateWrite")
        return [.log(Decision(keyword: .hold, verb: verb, fields: [quarantine]))]
          + Hold.succeed(.lidClose, state: &state)
      }
      state.hold.lateWriteClearAt = nil
      let persisted = ownership(false, state: &state)
      var sentinel: [Effect] = [.sentinel(.disarm)]
      if state.hold.stopping {
        sentinel.append(.sentinel(.bye))
      }
      return sentinel + [.persist(persisted), .log(Decision(keyword: .hold, verb: verb))]
        + Hold.succeed(.lidClose, state: &state)
    case .held where state.hold.renewals[.lidClose] == id:
      state.hold.renewals[.lidClose] = nil
      guard outcome == .succeeded else { return Hold.fail(.lidClose, state: &state, now: now) }
      return Hold.succeed(.lidClose, state: &state)
    default:
      guard let tracked, outcome == .succeeded, strayWriteNeedsClear(id, tracked, state: state) else { return nil }
      let fields = [
        DecisionField(key: "backend", value: HoldBackend.lidClose.rawValue),
        DecisionField(key: "action", value: "lateWrite"),
      ]
      return [.log(Decision(keyword: .error, verb: "hold", fields: fields)), release(state: &state)]
    }
  }

  static func releaseFailed(state: inout AppState, now: Instant) -> [Effect] {
    state.hold.releaseFailures += 1
    let effects = Hold.fail(.lidClose, state: &state, now: now)
    if state.hold.stopping && state.hold.releaseFailures == 1 {
      return effects + [release(state: &state)]
    }
    guard state.hold.releaseFailures == Timing.releaseFailuresBeforeEscalation else { return effects }
    let fields = [
      DecisionField(key: "backend", value: HoldBackend.lidClose.rawValue),
      DecisionField(key: "action", value: "escalate"),
    ]
    return effects + [
      .log(Decision(keyword: .error, verb: "hold", fields: fields)), .sentinel(.respawn), .sentinel(.arm),
    ]
  }

  static func strayWriteNeedsClear(_ id: EffectID, _ tracked: OnWrite, state: AppState) -> Bool {
    switch state.hold.lidClose {
    case .held, .acquiring:
      return false
    case .failed where state.hold.goals[.lidClose] == true:
      return false
    case .releasing(let current) where !tracked.timedOut && current.value > id.value:
      return false
    default:
      return true
    }
  }

  public static func lateWriteUnsettled(_ hold: HoldState, now: Instant) -> Bool {
    let quarantine = Instant.nanoseconds(forSeconds: Timing.lateWriteQuarantineSeconds)
    return hold.onWrites.values.contains { now.nanoseconds(since: $0.since) < quarantine }
  }

  static func followUpClear(state: inout AppState, now: Instant, tick: Bool) -> [Effect] {
    guard tick, let at = state.hold.lateWriteClearAt, now >= at else { return [] }
    state.hold.lateWriteClearAt = nil
    return [.log(Decision(keyword: .hold, verb: "clearLateWrite")), release(state: &state)]
  }

  static func track(_ id: EffectID, state: inout AppState, now: Instant) {
    state.hold.onWrites[id] = OnWrite(since: now)
    let excess = state.hold.onWrites.count - maxTrackedOnWrites
    guard excess > 0 else { return }
    for oldest in state.hold.onWrites.keys.sorted(by: { $0.value < $1.value }).prefix(excess) {
      state.hold.onWrites[oldest] = nil
    }
  }

  public static func mayHold(_ state: AppState) -> Bool {
    state.hold.lidClose != .released || state.persisted.ownsHold || state.hold.pendingLaunch != nil
  }

  public static func sentinelLost(state: inout AppState, now: Instant) -> [Effect] {
    let lost = Effect.log(Decision(keyword: .sentinel, verb: "lost"))
    let replaceArmed: [Effect] = [.sentinel(.respawn), .sentinel(.arm)]
    guard !state.hold.stopping else {
      guard mayHold(state) else { return [lost] }
      state.hold.releaseFailures = 0
      return [lost] + replaceArmed + [release(.watchdogLost, state: &state)]
    }
    guard mayHold(state) else { return [lost, .sentinel(.respawn)] }
    state.hold.wakeBurst.removeAll()
    state.hold.releaseFailures = 0
    let clear = release(.watchdogLost, state: &state)
    guard state.want.wanted == true, state.lastFullWake == true else {
      return [lost, clear] + replaceArmed
    }
    let reengage = engage(.reassert, state: &state, now: now).filter { $0 != .sentinel(.arm) }
    return [lost, clear] + replaceArmed + [reassertLog("watchdogLost")] + reengage
  }

  public static func launched(_ facts: LaunchFacts, state: inout AppState) {
    state.hold.pendingLaunch = launchAction(facts)
    guard case .state(let loaded) = facts.persisted, loaded.ownsHold, state.hold.pendingLaunch != .reclaim else {
      return
    }
    state.persisted.ownsHold = false
    state.persisted.sentinelArmed = false
  }

  public static func launchAction(_ facts: LaunchFacts) -> LaunchHoldAction? {
    switch facts.persisted {
    case .missing, .corrupt:
      return .clearIfUnwanted
    case .state(let loaded):
      guard loaded.ownsHold else { return loaded.sentinelArmed ? .clearIfUnwanted : nil }
      guard let current = facts.bootSessionUUID, let recorded = loaded.bootSessionUUID else {
        return .clearIfUnwanted
      }
      return current == recorded ? .reclaim : nil
    }
  }

  static func resolveLaunch(
    _ launch: LaunchHoldAction, desired: Bool, state: inout AppState, now: Instant, tick: Bool
  ) -> [Effect] {
    guard tick else { return [] }
    guard desired else { return [release(.clearStale, state: &state)] }
    guard state.lastFullWake == true else { return [] }
    return engage(launch == .reclaim ? .reclaim : .engage, state: &state, now: now)
  }

  public static func poweredOn(state: inout AppState, now: Instant) {
    state.lastFullWake = false
    switch state.hold.lidClose {
    case .held, .acquiring:
      state.hold.wakeBurst = burstOffsetsSeconds.map { now.adding(seconds: $0) }
    default:
      break
    }
  }

  public static func willSleep(state: inout AppState) {
    state.lastFullWake = false
  }

  public static func deadlines(_ hold: HoldState) -> [Instant] {
    hold.wakeBurst + (hold.nextReassert.map { [$0] } ?? []) + (hold.lateWriteClearAt.map { [$0] } ?? [])
  }

  static func engage(_ why: ClamshellWhy, state: inout AppState, now: Instant) -> [Effect] {
    let persisted = ownership(true, state: &state)
    let id = Hold.allocate(&state)
    state.hold.pendingLaunch = why == .reclaim ? .reclaim : nil
    state.hold.renewals[.lidClose] = nil
    state.hold.goals[.lidClose] = true
    state.hold.lidClose = .acquiring(id)
    state.hold.nextReassert = now.adding(seconds: Timing.reassertEverySeconds)
    state.hold.lateWriteClearAt = nil
    state.hold.releaseFailures = 0
    track(id, state: &state, now: now)
    return [.persist(persisted), .sentinel(.arm), .clamshell(on: true, id: id, why: why)]
  }

  static func reassert(state: inout AppState, now: Instant) -> [Effect] {
    guard state.lastFullWake == true, state.hold.renewals[.lidClose] == nil else { return [] }
    if let first = state.hold.wakeBurst.first {
      guard first <= now else { return [] }
      state.hold.wakeBurst.removeAll { $0 <= now }
      if state.hold.wakeBurst.isEmpty {
        state.hold.nextReassert = now.adding(seconds: Timing.reassertEverySeconds)
      }
      return [reassertLog("afterWake")] + write(.reassertAfterWake, state: &state, now: now)
    }
    guard let next = state.hold.nextReassert, now >= next else { return [] }
    state.hold.nextReassert = now.adding(seconds: Timing.reassertEverySeconds)
    var effects: [Effect] = []
    if !state.hold.periodicReassertLogged {
      state.hold.periodicReassertLogged = true
      effects.append(reassertLog("periodic"))
    }
    return effects + write(.reassert, state: &state, now: now)
  }

  static func write(_ why: ClamshellWhy, state: inout AppState, now: Instant) -> [Effect] {
    let id = Hold.allocate(&state)
    state.hold.renewals[.lidClose] = id
    track(id, state: &state, now: now)
    return [.sentinel(.arm), .clamshell(on: true, id: id, why: why)]
  }

  static func reassertLog(_ why: String) -> Effect {
    .log(Decision(keyword: .hold, verb: "reassert", fields: [DecisionField(key: "why", value: why)]))
  }

  static func release(_ why: ClamshellWhy = .release, state: inout AppState) -> Effect {
    let id = Hold.allocate(&state)
    if why != .clearStale {
      state.hold.pendingLaunch = nil
    }
    state.hold.renewals[.lidClose] = nil
    state.hold.goals[.lidClose] = false
    state.hold.lidClose = .releasing(id)
    return .clamshell(on: false, id: id, why: why)
  }

  static func ownership(_ owns: Bool, state: inout AppState) -> PersistedState {
    var persisted = Reducer.persistedState(state)
    persisted.ownsHold = owns
    persisted.sentinelArmed = owns
    state.persisted = persisted
    return persisted
  }

  static func retryLog(attempts: Int) -> Effect {
    .log(
      Decision(
        keyword: .hold, verb: "retry",
        fields: [
          DecisionField(key: "backend", value: HoldBackend.lidClose.rawValue),
          DecisionField(key: "attempt", value: String(attempts + 1)),
        ]))
  }
}
