import Foundation

public enum Reducer {
  public static let maxLoggedEntrypointLength = 64
  public static let maxSeenEntrypoints = 256

  public static func reduce(_ state: inout AppState, _ event: Stamped<Event>, _ settings: Settings) -> [Effect] {
    let before = state
    var effects = reduceEvent(&state, event, settings)
    EventCounters.observe(&state, before: before, event: event.event, effects: effects, now: event.mono)
    let derived = persistedState(state)
    if derived != state.persisted {
      state.persisted = derived
      effects.append(.persist(derived))
    }
    let helper = HelperIntent.step(&state, event: event.event, now: event.mono, batch: effects)
    return helper.before + effects + helper.after
  }

  static func reduceEvent(_ state: inout AppState, _ event: Stamped<Event>, _ settings: Settings) -> [Effect] {
    let now = event.mono
    state.lastEventAt = max(state.lastEventAt ?? now, now)
    state.lastEventWall = event.wall
    let startedAt = state.startedAt ?? now
    state.startedAt = startedAt
    let effects = reduceMachines(&state, event, settings, startedAt: startedAt)
    if case .tick = event.event { return effects }
    if case .command(.sleepNow) = event.event { return effects }
    return effects + lidPipeline(&state, event: event.event, now: now, prior: effects, settings: settings)
  }

  static func lidPipeline(
    _ state: inout AppState, event: Event, now: Instant, prior: [Effect], settings: Settings
  ) -> [Effect] {
    let lid = LidDisplay.step(&state, event: event, now: now)
    let verification = SleepVerification.step(&state, event: event, now: now, holdEffects: prior)
    return lid + verification + NetworkFailover.step(&state, event: event, now: now, settings: settings)
  }

  static func reduceMachines(
    _ state: inout AppState, _ event: Stamped<Event>, _ settings: Settings, startedAt: Instant
  ) -> [Effect] {
    let now = event.mono
    switch event.event {
    case .transcriptActivity(let activity):
      let eligible = isEligible(activity, settings: settings)
      let at = min(activity.at, now)
      state.busy.lastTranscriptEventAt = max(state.busy.lastTranscriptEventAt ?? at, at)
      if eligible {
        state.busy.lastEligibleTranscript = max(state.busy.lastEligibleTranscript ?? at, at)
      }
      var effects: [Effect] = []
      if let entrypoint = activity.entrypoint.map({ loggable($0) }),
        !state.busy.seenEntrypoints.contains(entrypoint),
        state.busy.seenEntrypoints.count < maxSeenEntrypoints
      {
        state.busy.seenEntrypoints.insert(entrypoint)
        effects.append(
          .log(
            Decision(
              keyword: .entrypoint,
              verb: "new",
              fields: [
                DecisionField(key: "value", value: entrypoint),
                DecisionField(key: "ignored", value: eligible ? "false" : "true"),
              ]
            )))
      }
      guard eligible, state.busy.busy == false,
        Busy.eligibleTranscript(state.busy, within: settings.transcriptWindowSeconds, now: now)
      else { return effects }
      let decisions = busyAndWant(&state, now: now, wall: event.wall, settings: settings)
      return effects + decisions.map(Effect.log) + Hold.reconcile(&state, now: now, settings: settings)
    case .transcriptRoots:
      return Health.evaluate(
        &state.health, event: event.event, now: now, agents: nil,
        lastTranscriptEventAt: state.busy.lastTranscriptEventAt, startedAt: startedAt
      ).map(Effect.log)
    case .power(let reading):
      var decisions = Battery.step(
        &state.battery, reading, low: settings.batteryLowPercent, resume: settings.batteryResumePercent)
      if state.busy.busy != nil {
        decisions += busyAndWant(&state, now: now, wall: event.wall, settings: settings)
      }
      return decisions.map(Effect.log) + Hold.reconcile(&state, now: now, settings: settings)
    case .launched(let facts):
      let decisions = launch(&state, facts, now: now, wall: event.wall)
      LidCloseHold.launched(facts, state: &state)
      let normalized = persistedState(state)
      state.persisted = normalized
      return decisions.map(Effect.log) + [.persist(normalized)]
    case .command(.sleepNow):
      return [.log(Decision(keyword: .command, verb: "sleepNow")), .requestSleep(id: Hold.allocate(&state))]
    case .command(let command):
      var decisions = Want.apply(command, to: &state.want, now: now, wall: event.wall)
      if state.busy.busy != nil {
        decisions += busyAndWant(&state, now: now, wall: event.wall, settings: settings)
      }
      return decisions.map(Effect.log) + Hold.reconcile(&state, now: now, settings: settings)
    case .selfTest(let facts):
      return SelfTest.request(&state, facts: facts, now: now)
    case .helperFacts(let facts):
      state.helper.facts = facts
      return []
    case .effectResult(let id, let outcome):
      let results =
        HelperIntent.handleResult(id, outcome, state: &state, now: now)
        ?? SelfTest.handleResult(id, outcome, state: &state, now: now)
        ?? Hold.handleResult(id, outcome, state: &state, now: now)
      return results + Hold.reconcile(&state, now: now, settings: settings)
    case .systemWillSleep:
      LidCloseHold.willSleep(state: &state)
      return []
    case .systemHasPoweredOn:
      LidCloseHold.poweredOn(state: &state, now: now)
      return Hold.reconcile(&state, now: now, settings: settings)
    case .sentinelLost:
      return LidCloseHold.sentinelLost(state: &state, now: now)
    case .stop:
      return Hold.stop(state: &state)
    case .screenLock(let status):
      return screenLockWarning(&state, status)
    case .netProbeResult, .netCycleDone:
      return []
    case .lidChanged(let closed, _, let externalDisplays):
      state.lastLidClosed = closed
      if closed, let externalDisplays {
        state.lastExternalDisplays = externalDisplays
      }
      return Hold.reconcile(&state, now: now, settings: settings)
    case .tick(let facts):
      let caffeinate = facts.agents.busyProcessCount > 0
      if caffeinate && !state.busy.claudeCaffeinate {
        state.busy.caffeinateSince = now
      } else if !caffeinate {
        state.busy.caffeinateSince = nil
      }
      state.busy.claudeCaffeinate = caffeinate
      state.lastLidClosed = facts.lidClosed
      state.lastExternalDisplays = facts.externalDisplays
      state.lastFullWake = facts.fullWake
      let decisions = busyAndWant(&state, now: now, wall: event.wall, settings: settings)
      let hold = Hold.reconcile(&state, now: now, settings: settings, tick: true)
      let lid = lidPipeline(&state, event: event.event, now: now, prior: hold, settings: settings)
      let health = Health.evaluate(
        &state.health, event: event.event, now: now, agents: facts.agents,
        lastTranscriptEventAt: state.busy.lastTranscriptEventAt, startedAt: startedAt)
      let coexistence = Coexistence.step(&state, facts: facts.coexistence, now: now)
      return decisions.map(Effect.log) + hold + lid + health.map(Effect.log) + coexistence
    }
  }

  static func launch(_ state: inout AppState, _ facts: LaunchFacts, now: Instant, wall: Date) -> [Decision] {
    state.bootSessionUUID = facts.bootSessionUUID
    let persisted: PersistedState
    switch facts.persisted {
    case .missing:
      state.persisted = PersistedState()
      return []
    case .corrupt:
      state.persisted = PersistedState()
      return [Decision(keyword: .error, verb: "state corrupt")]
    case .state(let loaded):
      persisted = loaded
    }
    state.persisted = persisted
    let sameBoot = facts.bootSessionUUID != nil && persisted.bootSessionUUID == facts.bootSessionUUID
    var decisions: [Decision] = []
    if let pause = restoredPause(persisted.pause, sameBoot: sameBoot) {
      if Want.isExpired(pause, now: now, wall: wall) {
        decisions.append(Decision(keyword: .override, verb: "pauseExpired"))
      } else {
        state.want.pause = pause
      }
    }
    if persisted.releaseUntilIdle {
      if sameBoot {
        state.want.override = true
      } else {
        decisions.append(
          Decision(
            keyword: .override, verb: "releaseUntilIdleDropped", fields: [DecisionField(key: "reason", value: "reboot")]
          ))
      }
    }
    if persisted.forceActive {
      decisions.append(
        Decision(
          keyword: .override, verb: "forceDropped",
          fields: [DecisionField(key: "reason", value: sameBoot ? "relaunch" : "reboot")]))
    }
    return decisions
  }

  static func screenLockWarning(_ state: inout AppState, _ status: ScreenLockStatus) -> [Effect] {
    let fields: [DecisionField]
    switch status {
    case .immediate:
      return []
    case .delayed(let seconds):
      fields = [DecisionField(key: "reason", value: "delay"), DecisionField(key: "seconds", value: String(seconds))]
    case .off:
      fields = [DecisionField(key: "reason", value: "off")]
    case .unknown:
      fields = [DecisionField(key: "reason", value: "unverified")]
    }
    guard !state.screenLockWarned else { return [] }
    state.screenLockWarned = true
    return [.log(Decision(keyword: .warn, verb: "screenLock", fields: fields))]
  }

  static func restoredPause(_ pause: PersistedPause?, sameBoot: Bool) -> PauseState? {
    guard let pause else { return nil }
    switch pause.kind {
    case PersistedPause.timed:
      guard let wall = pause.wallDeadline else { return nil }
      if sameBoot, let mono = pause.monoDeadlineNanoseconds {
        return .untilMono(Instant(nanoseconds: mono), wall: wall)
      }
      return .untilWall(wall)
    case PersistedPause.until:
      return pause.wallDeadline.map(PauseState.untilWall)
    case PersistedPause.indefinite:
      return .indefinite
    default:
      return nil
    }
  }

  static func persistedState(_ state: AppState) -> PersistedState {
    var persisted = state.persisted
    persisted.version = PersistedState.currentVersion
    persisted.bootSessionUUID = state.bootSessionUUID
    persisted.pause = PersistedPause(state.want.pause)
    persisted.releaseUntilIdle = state.want.override
    persisted.forceActive = state.want.force != nil
    return persisted
  }

  static func busyAndWant(_ state: inout AppState, now: Instant, wall: Date, settings: Settings) -> [Decision] {
    let decisions = Busy.evaluate(&state.busy, now: now, settings: settings)
    return decisions
      + Want.evaluate(
        &state.want, busy: state.busy.busy ?? false, batteryBlocked: state.battery.blocked, now: now, wall: wall,
        settings: settings)
  }

  public static func nextDeadline(_ state: AppState, _ settings: Settings) -> Instant? {
    var candidates: [Instant] = []
    if let last = state.busy.lastEligibleTranscript {
      candidates += windowEdges(from: last, seconds: settings.transcriptWindowSeconds)
      if state.busy.claudeCaffeinate {
        candidates += windowEdges(from: last, seconds: settings.stuckWindowSeconds)
      }
    }
    if state.busy.claudeCaffeinate, let since = state.busy.caffeinateSince {
      candidates.append(since.adding(seconds: Timing.freshCaffeinateSeconds))
    }
    if let lastBusy = state.want.lastBusy {
      candidates.append(lastBusy.adding(seconds: settings.releaseGraceSeconds))
    }
    if let pause = state.want.pause, let deadline = pauseDeadline(pause, state: state) {
      candidates.append(deadline)
    }
    if case .untilMono(let deadline)? = state.want.force {
      candidates.append(deadline)
    }
    candidates += state.hold.retryDeadlines
    candidates += LidCloseHold.deadlines(state.hold)
    candidates += LidDisplay.deadlines(state)
    candidates += SleepVerification.deadlines(state)
    candidates += NetworkFailover.deadlines(state, settings)
    candidates += HelperIntent.deadlines(state)
    let upcoming = candidates.filter { deadline in
      guard let lastEventAt = state.lastEventAt else { return true }
      return deadline > lastEventAt
    }
    return upcoming.min()
  }

  static func pauseDeadline(_ pause: PauseState, state: AppState) -> Instant? {
    switch pause {
    case .untilMono(let deadline, _):
      return deadline
    case .untilWall(let date):
      guard let lastEventAt = state.lastEventAt, let lastEventWall = state.lastEventWall else { return nil }
      return lastEventAt.adding(seconds: max(0, date.timeIntervalSince(lastEventWall)))
    case .indefinite:
      return nil
    }
  }

  static func windowEdges(from start: Instant, seconds: Double) -> [Instant] {
    let end = start.adding(seconds: seconds)
    let lastInside = Instant(nanoseconds: end.nanoseconds > start.nanoseconds ? end.nanoseconds - 1 : end.nanoseconds)
    return [lastInside, end]
  }

  static func isEligible(_ activity: TranscriptActivity, settings: Settings) -> Bool {
    guard let entrypoint = activity.entrypoint else { return true }
    return !EntrypointGlob.matchesAny(settings.ignoredEntrypoints, value: entrypoint)
  }

  static func loggable(_ value: String, limit: Int = maxLoggedEntrypointLength) -> String {
    var scalars = String.UnicodeScalarView()
    for scalar in value.unicodeScalars.prefix(limit) {
      let isControl = scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
      scalars.append(isControl ? "?" : scalar)
    }
    return String(scalars)
  }
}
