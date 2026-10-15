import Foundation

public struct NetworkFacts: Sendable, Equatable {
  public var wifiInterface: String?
  public var onHotspot: Bool?
  public var wired: Bool?
  public var wifiPowered: Bool?
  public var autoHotspot: String?

  public init(
    wifiInterface: String? = nil, onHotspot: Bool? = nil, wired: Bool? = nil, wifiPowered: Bool? = nil,
    autoHotspot: String? = nil
  ) {
    self.wifiInterface = wifiInterface
    self.onHotspot = onHotspot
    self.wired = wired
    self.wifiPowered = wifiPowered
    self.autoHotspot = autoHotspot
  }
}

public enum HotspotSource: String, Sendable, Equatable {
  case configured
  case auto
}

public struct EffectiveHotspot: Sendable, Equatable {
  public var name: String
  public var source: HotspotSource

  public init(name: String, source: HotspotSource) {
    self.name = name
    self.source = source
  }
}

public enum NetOffReason: String, Sendable, Equatable, CaseIterable {
  case noHotspot
  case noWifi
  case wired
  case wifiOff
}

public enum NetReadiness: Sendable, Equatable {
  case armed(HotspotSource)
  case off(NetOffReason)
}

public enum NetPhase: Sendable, Equatable {
  case idle
  case joining(until: Instant)
  case waitingAfterCycle(until: Instant)
}

public enum ReturnStop: String, Sendable, Equatable, CaseIterable {
  case adminRequired
  case powerUnknown
  case backOnHotspot
}

public enum ReturnCycle: Sendable, Equatable {
  case idle
  case inFlight
  case retryAt(Instant)
  case done
  case stopped(ReturnStop)
}

public struct NetworkState: Sendable, Equatable {
  public var fails: Int
  public var nextProbe: Instant?
  public var nextTry: Instant?
  public var waitSeconds: Double
  public var phase: NetPhase
  public var facts: NetworkFacts?
  public var lidClosed: Bool?
  public var episodeLogged: Bool
  public var joinLandsBy: Instant?
  public var cyclesEmitted: UInt64
  public var cyclesDone: UInt64
  public var returnCycle: ReturnCycle
  public var returnSequence: UInt64?
  public var returnWaitSeconds: Double
  public var returnUnreadable: Int

  public init() {
    cyclesEmitted = 0
    cyclesDone = 0
    returnCycle = .idle
    returnSequence = nil
    returnWaitSeconds = Timing.netWaitMinSeconds
    returnUnreadable = 0
    fails = 0
    nextProbe = nil
    nextTry = nil
    waitSeconds = Timing.netWaitMinSeconds
    phase = .idle
    facts = nil
    lidClosed = nil
    episodeLogged = false
    joinLandsBy = nil
  }
}

public enum NetworkFailover {
  public static let joiningMessage = "Offline with lid closed: joining the hotspot"

  public static func effectiveHotspot(_ settings: Settings, _ facts: NetworkFacts?) -> EffectiveHotspot? {
    if !settings.hotspot.isEmpty {
      return EffectiveHotspot(name: settings.hotspot, source: .configured)
    }
    guard settings.hotspotAutoDetect, let candidate = facts?.autoHotspot, Settings.isValidSSID(candidate) else {
      return nil
    }
    return EffectiveHotspot(name: candidate, source: .auto)
  }

  public static func readiness(_ state: AppState, settings: Settings) -> NetReadiness? {
    guard let facts = state.network.facts else { return nil }
    guard let hotspot = effectiveHotspot(settings, facts) else { return .off(.noHotspot) }
    if facts.wifiInterface == nil { return .off(.noWifi) }
    if facts.wired == true { return .off(.wired) }
    if facts.wifiPowered == false { return .off(.wifiOff) }
    return .armed(hotspot.source)
  }

  public static func step(_ state: inout AppState, event: Event, now: Instant, settings: Settings) -> [Effect] {
    switch event {
    case .tick(let facts):
      return tick(&state, facts: facts.network, now: now, settings: settings)
    case .netProbeResult(let online):
      guard gated(state, now: now, settings: settings), state.network.phase == .idle, state.lastFullWake == true
      else { return [] }
      return online ? restored(&state) : failed(&state, now: now, settings: settings)
    case .netCycleDone(let outcome):
      return cycleDone(&state, outcome: outcome, now: now)
    case .lidChanged:
      return lidTransition(&state)
    default:
      return []
    }
  }

  public static func deadlines(_ state: AppState, _ settings: Settings) -> [Instant] {
    switch state.network.phase {
    case .joining(let until), .waitingAfterCycle(let until):
      return [until]
    case .idle:
      guard let next = state.network.nextProbe, probing(state, settings: settings) else { return [] }
      return [next]
    }
  }

  static func tick(_ state: inout AppState, facts: NetworkFacts?, now: Instant, settings: Settings) -> [Effect] {
    state.network.facts = facts
    var effects = lidTransition(&state)
    guard let facts else { return effects }
    if state.network.phase != .idle && !gated(state, now: now, settings: settings) {
      effects += abandonPhase(&state)
    } else {
      effects += advancePhase(&state, facts: facts, now: now)
    }
    effects += joinMark(&state, facts: facts, now: now)
    if openStable(state, now: now), state.persisted.switchedToHotspot, state.network.phase == .idle,
      state.lastFullWake != false, !state.hold.stopping, let onHotspot = facts.onHotspot
    {
      effects += onHotspot ? returnIfDue(&state, now: now) : forgetSwitch(&state)
    }
    effects += episodeLine(&state, now: now, settings: settings)
    guard gated(state, now: now, settings: settings), state.network.phase == .idle, state.lastFullWake == true
    else { return effects }
    if let next = state.network.nextProbe, now < next { return effects }
    state.network.nextProbe = now.adding(seconds: Timing.netEverySeconds)
    return effects + [.net(.probe)]
  }

  static func episodeLine(_ state: inout AppState, now: Instant, settings: Settings) -> [Effect] {
    guard !state.network.episodeLogged, state.want.wanted == true, LidDisplay.isClosedStable(state.lid, now: now),
      let readiness = readiness(state, settings: settings)
    else { return [] }
    state.network.episodeLogged = true
    let line: Decision
    switch readiness {
    case .armed(let source):
      line = Decision(keyword: .net, verb: "armed", fields: [DecisionField(key: "hotspot", value: source.rawValue)])
    case .off(let reason):
      line = Decision(keyword: .net, verb: "off", fields: [DecisionField(key: "reason", value: reason.rawValue)])
    }
    return [.log(line)]
  }

  static func advancePhase(_ state: inout AppState, facts: NetworkFacts, now: Instant) -> [Effect] {
    switch state.network.phase {
    case .idle:
      return []
    case .joining(let until):
      if facts.onHotspot == true { return connected(&state) }
      guard now >= until, state.lastFullWake == true else { return [] }
      state.network.phase = .waitingAfterCycle(until: now.adding(seconds: Timing.hotspotJoinWaitSeconds))
      return [.log(line("cycleWifi", couldNotJoinMessage)), cycle(&state)]
    case .waitingAfterCycle(let until):
      if facts.onHotspot == true { return connected(&state) }
      if now >= until { state.network.phase = .idle }
      return []
    }
  }

  static func abandonPhase(_ state: inout AppState) -> [Effect] {
    guard state.network.phase != .idle else { return [] }
    if state.network.facts?.onHotspot == true { return connected(&state) }
    state.network.phase = .idle
    return []
  }

  static func failed(_ state: inout AppState, now: Instant, settings: Settings) -> [Effect] {
    state.network.fails += 1
    guard state.network.fails >= Timing.netFailsNeeded else { return [] }
    if let next = state.network.nextTry, now < next { return [] }
    if state.network.facts?.wifiPowered == false { return [] }
    let effects: [Effect]
    if state.network.facts?.onHotspot == true {
      effects = [.log(line("cycleWifi", offlineOnHotspotMessage)), cycle(&state)]
    } else {
      guard let hotspot = effectiveHotspot(settings, state.network.facts) else { return [] }
      let join = Decision(
        keyword: .net, verb: "join",
        fields: [
          DecisionField(key: "msg", value: joiningMessage),
          DecisionField(key: "hotspot", value: hotspot.source.rawValue),
        ])
      state.persisted.hotspotJoinStarted = true
      state.network.joinLandsBy = now.adding(seconds: Timing.hotspotJoinLandSeconds)
      effects = [.log(join), .persist(state.persisted), .net(.joinHotspot(hotspot.name))]
      state.network.phase = .joining(until: now.adding(seconds: Timing.hotspotJoinWaitSeconds))
    }
    state.network.nextTry = now.adding(seconds: state.network.waitSeconds)
    state.network.waitSeconds = min(state.network.waitSeconds * 2, Timing.netWaitMaxSeconds)
    return effects
  }

  static func restored(_ state: inout AppState) -> [Effect] {
    let wasFailing = state.network.fails >= Timing.netFailsNeeded
    state.network.fails = 0
    state.network.waitSeconds = Timing.netWaitMinSeconds
    return wasFailing ? [.log(line("restored", "Connection restored"))] : []
  }

  static func connected(_ state: inout AppState) -> [Effect] {
    state.network.phase = .idle
    state.persisted.switchedToHotspot = true
    clearJoinMark(&state)
    return [.persist(state.persisted), .log(line("connected", "Connected to hotspot"))]
  }

  static func joinMark(_ state: inout AppState, facts: NetworkFacts, now: Instant) -> [Effect] {
    guard state.persisted.hotspotJoinStarted else { return [] }
    if facts.onHotspot == true {
      guard state.persisted.switchedToHotspot else { return connected(&state) }
      clearJoinMark(&state)
      return [.persist(state.persisted)]
    }
    guard facts.onHotspot == false, openStable(state, now: now) else { return [] }
    if let landsBy = state.network.joinLandsBy, now < landsBy { return [] }
    clearJoinMark(&state)
    return [.persist(state.persisted)]
  }

  static func clearJoinMark(_ state: inout AppState) {
    state.persisted.hotspotJoinStarted = false
    state.network.joinLandsBy = nil
  }

  static func forgetSwitch(_ state: inout AppState) -> [Effect] {
    state.persisted.switchedToHotspot = false
    resetReturn(&state)
    return [.persist(state.persisted)]
  }

  static func resetReturn(_ state: inout AppState) {
    state.network.returnCycle = .idle
    state.network.returnWaitSeconds = Timing.netWaitMinSeconds
    state.network.returnUnreadable = 0
  }

  static func cycle(_ state: inout AppState) -> Effect {
    state.network.cyclesEmitted &+= 1
    return .net(.cycleWifi)
  }

  static func returnIfDue(_ state: inout AppState, now: Instant) -> [Effect] {
    switch state.network.returnCycle {
    case .idle:
      break
    case .retryAt(let at) where now >= at:
      break
    case .done:
      return stopReturn(&state, reason: .backOnHotspot)
    case .retryAt, .inFlight, .stopped:
      return []
    }
    let effect = cycle(&state)
    state.network.returnCycle = .inFlight
    state.network.returnSequence = state.network.cyclesEmitted
    return [.log(line("cycleWifi", lidOpenedMessage)), effect]
  }

  public static func completesReturnCycle(_ state: AppState) -> Bool {
    guard let sequence = state.network.returnSequence else { return false }
    return state.network.cyclesDone &+ 1 == sequence
  }

  static func cycleDone(_ state: inout AppState, outcome: NetCycleOutcome, now: Instant) -> [Effect] {
    let isReturn = completesReturnCycle(state)
    state.network.cyclesDone = min(state.network.cyclesDone &+ 1, state.network.cyclesEmitted)
    guard isReturn else { return [] }
    state.network.returnSequence = nil
    guard state.network.returnCycle == .inFlight else { return [] }
    let unreadable = outcome == .powerUnknown ? state.network.returnUnreadable + 1 : 0
    state.network.returnUnreadable = unreadable
    switch outcome {
    case .succeeded:
      state.network.returnCycle = .done
      return []
    case .adminRequired:
      return stopReturn(&state, reason: .adminRequired)
    case .powerUnknown where unreadable >= unreadableReturnsToStop:
      return stopReturn(&state, reason: .powerUnknown)
    case .failed, .refused, .powerUnknown:
      return retryReturn(&state, now: now)
    }
  }

  public static let unreadableReturnsToStop = 3

  static func retryReturn(_ state: inout AppState, now: Instant) -> [Effect] {
    state.network.returnCycle = .retryAt(now.adding(seconds: state.network.returnWaitSeconds))
    state.network.returnWaitSeconds = min(state.network.returnWaitSeconds * 2, Timing.netWaitMaxSeconds)
    return []
  }

  static func lidTransition(_ state: inout AppState) -> [Effect] {
    let closed = state.lid.closed ?? state.lastLidClosed
    defer { state.network.lidClosed = closed }
    guard state.network.lidClosed == true, closed == false else { return [] }
    state.network.episodeLogged = false
    state.network.fails = 0
    state.network.nextTry = nil
    state.network.waitSeconds = Timing.netWaitMinSeconds
    resetReturn(&state)
    return abandonPhase(&state)
  }

  static func gated(_ state: AppState, now: Instant, settings: Settings) -> Bool {
    !state.hold.stopping && probing(state, settings: settings) && LidDisplay.isClosedStable(state.lid, now: now)
  }

  static func probing(_ state: AppState, settings: Settings) -> Bool {
    guard state.want.wanted == true, state.lid.closed == true else { return false }
    switch readiness(state, settings: settings) {
    case .armed, .off(.wifiOff): return true
    case .off, nil: return false
    }
  }

  static func openStable(_ state: AppState, now: Instant) -> Bool {
    guard state.lid.closed == false, let since = state.lid.since else { return false }
    return now.nanoseconds(since: since) >= Instant.nanoseconds(forSeconds: Timing.lidStableSeconds)
  }

  static func line(_ verb: String, _ message: String) -> Decision {
    Decision(keyword: .net, verb: verb, fields: [DecisionField(key: "msg", value: message)])
  }

  static func stopReturn(_ state: inout AppState, reason: ReturnStop) -> [Effect] {
    state.network.returnCycle = .stopped(reason)
    return [.log(returnStopped(reason: reason))]
  }

  public static func returnStop(_ state: AppState) -> ReturnStop? {
    guard case .stopped(let reason) = state.network.returnCycle else { return nil }
    return reason
  }

  static func returnStopped(reason: ReturnStop) -> Decision {
    let message = reason == .backOnHotspot ? rejoinedHotspotMessage : returnStoppedMessage
    return Decision(
      keyword: .net, verb: "return stopped",
      fields: [DecisionField(key: "reason", value: reason.rawValue), DecisionField(key: "msg", value: message)])
  }

  static let returnStoppedMessage = "Still on the hotspot: turn Wi-Fi off and on to return to your usual network"
  static let rejoinedHotspotMessage =
    "Still on the hotspot: macOS rejoined it, choose your usual network in the Wi-Fi menu"
  static let couldNotJoinMessage = "Could not join hotspot: power-cycling Wi-Fi so macOS picks a network"
  static let offlineOnHotspotMessage =
    "Offline while on hotspot: power-cycling Wi-Fi in case another network is available"
  static let lidOpenedMessage =
    "Lid opened after switching to hotspot: power-cycling Wi-Fi to return to the best network"
}
