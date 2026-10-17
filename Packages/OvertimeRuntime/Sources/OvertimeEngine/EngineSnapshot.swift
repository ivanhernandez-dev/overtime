import Foundation
import OvertimeCore
import OvertimeSystem

public enum DetectionWarning: Sendable, Equatable, Hashable {
  case rootMissing(String)
  case rootUnreadable(String)
  case terminalSilence

  public var path: String? {
    switch self {
    case .rootMissing(let path), .rootUnreadable(let path):
      path
    case .terminalSilence:
      nil
    }
  }

  public static func warnings(from health: HealthState) -> [DetectionWarning] {
    let roots = health.rootIssues.keys.sorted().compactMap { path -> DetectionWarning? in
      switch health.rootIssues[path] {
      case .missing:
        .rootMissing(path)
      case .unreadable:
        .rootUnreadable(path)
      case .ok, nil:
        nil
      }
    }
    return health.silenceWarned ? roots + [.terminalSilence] : roots
  }
}

public struct NetworkSummary: Sendable, Equatable {
  public enum Phase: String, Sendable, Equatable {
    case idle
    case joining
    case waitingAfterCycle
  }

  public var wired: Bool?
  public var wifiFound: Bool
  public var onHotspot: Bool?
  public var switched: Bool
  public var readiness: NetReadiness?
  public var phase: Phase
  public var returnStop: ReturnStop?
  public var autoDetect: Bool

  public var returnStalled: Bool {
    returnStop != nil
  }

  public init(
    wired: Bool? = nil, wifiFound: Bool = false, onHotspot: Bool? = nil, switched: Bool = false,
    readiness: NetReadiness? = nil, phase: Phase = .idle, returnStop: ReturnStop? = nil, autoDetect: Bool = false
  ) {
    self.wired = wired
    self.wifiFound = wifiFound
    self.onHotspot = onHotspot
    self.switched = switched
    self.readiness = readiness
    self.phase = phase
    self.returnStop = returnStop
    self.autoDetect = autoDetect
  }

  public static func summary(state: AppState, settings: Settings) -> NetworkSummary? {
    let facts = state.network.facts
    guard facts != nil || state.persisted.switchedToHotspot else { return nil }
    return NetworkSummary(
      wired: facts?.wired,
      wifiFound: facts?.wifiInterface != nil,
      onHotspot: facts?.onHotspot,
      switched: state.persisted.switchedToHotspot,
      readiness: NetworkFailover.readiness(state, settings: settings),
      phase: phase(state.network.phase),
      returnStop: NetworkFailover.returnStop(state),
      autoDetect: settings.hotspot.isEmpty && settings.hotspotAutoDetect
    )
  }

  public static func phase(_ phase: NetPhase) -> Phase {
    switch phase {
    case .idle: .idle
    case .joining: .joining
    case .waitingAfterCycle: .waitingAfterCycle
    }
  }
}

public struct EngineSnapshot: Sendable, Equatable {
  public var mode: RunMode
  public var busy: Bool?
  public var wanted: Bool?
  public var reason: String?
  public var releaseUntilIdle: Bool
  public var pause: PauseState?
  public var force: ForceState?
  public var batteryBlocked: Bool
  public var holdError: Bool
  public var lidClosed: Bool?
  public var sessions: [SessionSummary]
  public var wantedSince: Instant?
  public var graceDeadline: Instant?
  public var batteryLowPercent: Int
  public var batteryResumePercent: Int
  public var keepDisplayOn: Bool
  public var power: PowerReading?
  public var externalDisplays: Int?
  public var coexistenceWarned: Bool
  public var amphetamineRunning: Bool
  public var otherTools: [String]
  public var events: EventCounters
  public var detectionWarnings: [DetectionWarning]
  public var selfTest: SelfTestStatus
  public var selfTestErrorActive: Bool
  public var selfTestFailures: UInt64
  public var selfTestRuns: UInt64
  public var osBuild: String?
  public var helperEngaged: Bool
  public var helperFacts: HelperFacts?
  public var network: NetworkSummary?

  public var busyEndedAt: Instant? {
    events.busyEndedAt
  }

  public init(
    mode: RunMode = .live,
    busy: Bool? = nil,
    wanted: Bool? = nil,
    reason: String? = nil,
    releaseUntilIdle: Bool = false,
    pause: PauseState? = nil,
    force: ForceState? = nil,
    batteryBlocked: Bool = false,
    holdError: Bool = false,
    lidClosed: Bool? = nil,
    sessions: [SessionSummary] = [],
    wantedSince: Instant? = nil,
    graceDeadline: Instant? = nil,
    batteryLowPercent: Int = Settings().batteryLowPercent,
    batteryResumePercent: Int = Settings().batteryResumePercent,
    keepDisplayOn: Bool = Settings().keepDisplayOn,
    power: PowerReading? = nil,
    externalDisplays: Int? = nil,
    coexistenceWarned: Bool = false,
    amphetamineRunning: Bool = false,
    otherTools: [String] = [],
    events: EventCounters = EventCounters(),
    detectionWarnings: [DetectionWarning] = [],
    selfTest: SelfTestStatus = .notRun,
    selfTestErrorActive: Bool = false,
    selfTestFailures: UInt64 = 0,
    selfTestRuns: UInt64 = 0,
    osBuild: String? = nil,
    helperEngaged: Bool = false,
    helperFacts: HelperFacts? = nil,
    network: NetworkSummary? = nil
  ) {
    self.network = network
    self.helperEngaged = helperEngaged
    self.helperFacts = helperFacts
    self.selfTest = selfTest
    self.selfTestErrorActive = selfTestErrorActive
    self.selfTestFailures = selfTestFailures
    self.selfTestRuns = selfTestRuns
    self.osBuild = osBuild
    self.mode = mode
    self.busy = busy
    self.wanted = wanted
    self.reason = reason
    self.releaseUntilIdle = releaseUntilIdle
    self.pause = pause
    self.force = force
    self.batteryBlocked = batteryBlocked
    self.holdError = holdError
    self.lidClosed = lidClosed
    self.sessions = sessions
    self.wantedSince = wantedSince
    self.graceDeadline = graceDeadline
    self.batteryLowPercent = batteryLowPercent
    self.batteryResumePercent = batteryResumePercent
    self.keepDisplayOn = keepDisplayOn
    self.power = power
    self.externalDisplays = externalDisplays
    self.coexistenceWarned = coexistenceWarned
    self.amphetamineRunning = amphetamineRunning
    self.otherTools = otherTools
    self.events = events
    self.detectionWarnings = detectionWarnings
  }

  public init(
    state: AppState, settings: Settings = Settings(), sessions: [SessionSummary] = [], power: PowerReading? = nil,
    coexistence: CoexistenceFacts? = nil
  ) {
    let warned = state.coexistence.warned
    self.init(
      mode: state.mode,
      busy: state.busy.busy,
      wanted: state.want.wanted,
      reason: state.want.reason,
      releaseUntilIdle: state.want.override,
      pause: state.want.pause,
      force: state.want.force,
      batteryBlocked: state.battery.blocked,
      holdError: state.hold.errorActive,
      lidClosed: state.lid.closed ?? state.lastLidClosed,
      sessions: sessions,
      wantedSince: state.want.wantedSince,
      graceDeadline: Self.graceDeadline(state: state, settings: settings),
      batteryLowPercent: settings.batteryLowPercent,
      batteryResumePercent: settings.batteryResumePercent,
      keepDisplayOn: settings.keepDisplayOn,
      power: power,
      externalDisplays: state.lid.closed == true ? state.lid.externalDisplays : state.lastExternalDisplays,
      coexistenceWarned: warned,
      amphetamineRunning: coexistence?.amphetamineRunning ?? false,
      otherTools: warned ? Self.toolNames(coexistence?.foreignAssertions ?? []) : [],
      events: state.events,
      detectionWarnings: DetectionWarning.warnings(from: state.health),
      selfTest: state.selfTest.status,
      selfTestErrorActive: state.selfTest.errorActive,
      selfTestFailures: state.selfTest.failures,
      selfTestRuns: state.selfTest.runs,
      osBuild: state.selfTest.osBuild,
      helperEngaged: Self.helperEngaged(state.helper.phase),
      helperFacts: state.helper.facts,
      network: NetworkSummary.summary(state: state, settings: settings)
    )
  }

  public static func helperEngaged(_ phase: HelperPhase) -> Bool {
    switch phase {
    case .engaging, .engaged:
      true
    case .idle, .releasing, .failed:
      false
    }
  }

  public static let maxToolNameLength = 32

  public static func toolNames(_ assertions: [ForeignAssertion]) -> [String] {
    let names = assertions.compactMap { assertion -> String? in
      guard let name = cleanedToolName(assertion.processName) else { return nil }
      guard let parent = cleanedToolName(assertion.parentName) else { return name }
      return name + " (started by " + parent + ")"
    }
    return Array(Set(names)).sorted()
  }

  static func cleanedToolName(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let printable = String(
      String.UnicodeScalarView(
        raw.unicodeScalars.prefix(maxToolNameLength).filter { $0.value >= 0x20 && !(0x7F...0x9F).contains($0.value) }
      ))
    let trimmed = printable.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? nil : trimmed
  }

  public static func graceDeadline(state: AppState, settings: Settings) -> Instant? {
    guard state.want.reason == "busy", state.busy.busy == false, let lastBusy = state.want.lastBusy else { return nil }
    return lastBusy.adding(seconds: settings.releaseGraceSeconds)
  }
}
