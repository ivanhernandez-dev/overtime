import Foundation

public struct HealthState: Sendable, Equatable {
  public var warnedRoots: Set<String>
  public var rootIssues: [String: RootStatus]
  public var silenceWarned: Bool
  public var quietRoots: Set<String>

  public init(
    warnedRoots: Set<String> = [], rootIssues: [String: RootStatus] = [:], silenceWarned: Bool = false,
    quietRoots: Set<String> = []
  ) {
    self.warnedRoots = warnedRoots
    self.rootIssues = rootIssues
    self.silenceWarned = silenceWarned
    self.quietRoots = quietRoots
  }
}

public enum Health {
  public static let maxLoggedRootLength = 512

  public static func evaluate(
    _ state: inout HealthState,
    event: Event,
    now: Instant,
    agents: AgentSignals?,
    lastTranscriptEventAt: Instant?,
    startedAt: Instant
  ) -> [Decision] {
    switch event {
    case .transcriptRoots(let roots):
      return rootDecisions(&state, roots)
    case .tick:
      guard let agents else { return [] }
      return silenceDecisions(
        &state, now: now, starts: agents.terminalAgentStarts, lastTranscriptEventAt: lastTranscriptEventAt,
        startedAt: startedAt)
    case .transcriptActivity, .power, .command, .launched, .effectResult, .systemWillSleep, .systemHasPoweredOn,
      .lidChanged, .sentinelLost, .screenLock, .netProbeResult, .netCycleDone, .stop, .selfTest, .helperFacts:
      return []
    }
  }

  static func rootDecisions(_ state: inout HealthState, _ roots: [RootHealth]) -> [Decision] {
    state.rootIssues = Dictionary(
      roots.filter(warns).map { ($0.path, $0.status) }, uniquingKeysWith: { _, latest in latest })
    var decisions: [Decision] = []
    for root in roots {
      let loggedRoot = Reducer.loggable(root.path, limit: maxLoggedRootLength)
      switch root.status {
      case .ok:
        state.quietRoots.remove(root.path)
        guard state.warnedRoots.remove(root.path) != nil else { continue }
        decisions.append(
          Decision(
            keyword: .warn, verb: "detectionHealth cleared", fields: [DecisionField(key: "root", value: loggedRoot)]))
      case .missing where root.origin == .inferred:
        guard state.quietRoots.insert(root.path).inserted else { continue }
        decisions.append(
          Decision(
            keyword: .check, verb: "transcriptRoot absent", fields: [DecisionField(key: "root", value: loggedRoot)]))
      case .missing, .unreadable:
        guard state.warnedRoots.insert(root.path).inserted else { continue }
        decisions.append(
          Decision(
            keyword: .warn,
            verb: "detectionHealth",
            fields: [
              DecisionField(key: "reason", value: root.status == .missing ? "rootMissing" : "rootUnreadable"),
              DecisionField(key: "root", value: loggedRoot),
            ]
          ))
      }
    }
    return decisions
  }

  static func warns(_ root: RootHealth) -> Bool {
    switch root.status {
    case .ok:
      false
    case .missing:
      root.origin == .configured
    case .unreadable:
      true
    }
  }

  static func silenceDecisions(
    _ state: inout HealthState,
    now: Instant,
    starts: [Instant],
    lastTranscriptEventAt: Instant?,
    startedAt: Instant
  ) -> [Decision] {
    let limit = Instant.nanoseconds(forSeconds: Timing.healthSilenceSeconds)
    let silent = starts.contains { start in
      let since = max(start, startedAt)
      guard now >= since, now.nanoseconds(since: since) >= limit else { return false }
      guard let lastTranscriptEventAt else { return true }
      return lastTranscriptEventAt < since
    }
    guard silent else {
      state.silenceWarned = false
      return []
    }
    guard !state.silenceWarned else { return [] }
    state.silenceWarned = true
    return [
      Decision(
        keyword: .warn,
        verb: "detectionHealth",
        fields: [
          DecisionField(key: "reason", value: "terminalClaudeSilent"),
          DecisionField(key: "after", value: Busy.seconds(Timing.healthSilenceSeconds)),
        ]
      )
    ]
  }
}
