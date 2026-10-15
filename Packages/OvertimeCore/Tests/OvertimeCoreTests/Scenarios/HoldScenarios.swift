import Foundation
import Testing

@testable import OvertimeCore

@Suite("Hold scenarios #18-#24")
struct HoldScenarios {
  typealias H = ScenarioHarness

  static let fullWake = TickFacts(fullWake: true)
  static let engaged = Effect.log(Decision(keyword: .hold, verb: "engage"))
  static let released = Effect.log(Decision(keyword: .hold, verb: "release"))
  static let idleAcquired = Effect.log(Decision(keyword: .hold, verb: "idle acquired"))
  static let idleReleased = Effect.log(Decision(keyword: .hold, verb: "idle released"))

  static func liveHarness() -> ScenarioHarness {
    var harness = ScenarioHarness(mode: .live)
    harness.includeActuators = true
    return harness
  }

  static func ownership(_ owns: Bool) -> PersistedState {
    PersistedState(ownsHold: owns, sentinelArmed: owns)
  }

  static func clamshellEffects(_ effects: [Effect]) -> [(on: Bool, id: EffectID, why: ClamshellWhy)] {
    effects.compactMap { effect in
      if case .clamshell(let on, let id, let why) = effect { return (on, id, why) }
      return nil
    }
  }

  static func idleID(_ effects: [Effect]) -> EffectID? {
    effects.lazy.compactMap { effect -> EffectID? in
      if case .idleAssertion(_, let id) = effect { return id }
      return nil
    }.first
  }

  static func engagedHarness() -> ScenarioHarness? {
    var harness = liveHarness()
    _ = harness.send(.tick(fullWake), at: -2)
    let effects = harness.activity(writtenAt: 0, seenAt: 0)
    guard let engage = clamshellEffects(effects).first, let idle = idleID(effects) else { return nil }
    _ = harness.send(.effectResult(engage.id, .succeeded), at: 0.01)
    _ = harness.send(.effectResult(idle, .succeeded), at: 0.02)
    return harness
  }

  @Test("#18 busy with no hold engages the lid-close hold and owns it")
  func scenario18BusyEngagesAndOwnsTheHold() {
    var harness = Self.liveHarness()
    _ = harness.send(.tick(Self.fullWake), at: -2)
    let effects = harness.activity(writtenAt: 0, seenAt: 0)
    guard let engage = Self.clamshellEffects(effects).first, let idle = Self.idleID(effects) else {
      Issue.record("no clamshell engage or idle acquire: \(effects)")
      return
    }
    #expect(
      effects == [
        H.busy(true, source: "transcript"),
        H.want(true),
        .persist(Self.ownership(true)),
        .sentinel(.arm),
        .clamshell(on: true, id: engage.id, why: .engage),
        .idleAssertion(.acquireOrRenew(timeoutSeconds: 300), id: idle),
      ])
    #expect(harness.state.hold.lidClose == .acquiring(engage.id))
    #expect(harness.state.persisted.ownsHold)
    #expect(harness.state.persisted.sentinelArmed)
    #expect(harness.send(.effectResult(engage.id, .succeeded), at: 0.01) == [Self.engaged])
    #expect(harness.send(.effectResult(idle, .succeeded), at: 0.02) == [Self.idleAcquired])
    #expect(harness.state.hold.lidClose == .held)
    #expect(harness.state.hold.idle == .held)
  }

  @Test("#23 idle past the grace releases the owned hold, then disarms and drops ownership")
  func scenario23IdleReleasesTheOwnedHold() {
    guard var harness = Self.engagedHarness() else {
      Issue.record("the hold did not engage")
      return
    }
    let effects = harness.send(.tick(Self.fullWake), at: 200)
    let clears = Self.clamshellEffects(effects)
    guard let clear = clears.first, let idle = Self.idleID(effects) else {
      Issue.record("no release effects: \(effects)")
      return
    }
    #expect(clears.count == 1)
    #expect(
      effects == [
        H.busy(false, source: "transcript"),
        H.want(false),
        .clamshell(on: false, id: clear.id, why: .release),
        .idleAssertion(.release, id: idle),
      ])
    #expect(!effects.contains(.sentinel(.disarm)))
    #expect(harness.state.hold.lidClose == .releasing(clear.id))
    #expect(harness.state.persisted.ownsHold)
    #expect(
      harness.send(.effectResult(clear.id, .succeeded), at: 200.01) == [
        .sentinel(.disarm), .persist(Self.ownership(false)), Self.released,
      ])
    #expect(harness.send(.effectResult(idle, .succeeded), at: 200.02) == [Self.idleReleased])
    #expect(harness.state.hold.lidClose == .released)
    #expect(harness.state.persisted.ownsHold == false)
    #expect(harness.state.persisted.sentinelArmed == false)
  }

  @Test func engageWaitsForAFullWakeTickAndHappensOnTheFirstOne() {
    var harness = Self.liveHarness()
    _ = harness.send(.tick(TickFacts()), at: -2)
    let busy = harness.activity(writtenAt: 0, seenAt: 0)
    #expect(Self.clamshellEffects(busy).isEmpty)
    #expect(!busy.contains(.sentinel(.arm)))
    #expect(harness.state.hold.lidClose == .released)
    #expect(harness.state.persisted.ownsHold == false)
    #expect(Self.clamshellEffects(harness.send(.tick(TickFacts(fullWake: false)), at: 2)).isEmpty)
    #expect(harness.state.hold.lidClose == .released)
    let woken = harness.send(.tick(Self.fullWake), at: 4)
    let engages = Self.clamshellEffects(woken)
    #expect(engages.count == 1)
    guard let engage = engages.first else { return }
    #expect(engage.on && engage.why == .engage)
    #expect(
      Array(woken.prefix(3)) == [
        .persist(Self.ownership(true)), .sentinel(.arm), .clamshell(on: true, id: engage.id, why: .engage),
      ])
  }

  @Test func shadowRecordsTheSameHoldEffectsAsLive() {
    func replay(_ mode: RunMode) -> [Effect] {
      var harness = ScenarioHarness(mode: mode)
      harness.includeActuators = true
      var effects = harness.send(.tick(Self.fullWake), at: -2)
      effects += harness.activity(writtenAt: 0, seenAt: 0)
      for engage in Self.clamshellEffects(effects) {
        effects += harness.send(.effectResult(engage.id, .succeeded), at: 0.01)
      }
      effects += harness.send(.tick(Self.fullWake), at: 200)
      return effects
    }
    #expect(replay(.shadow) == replay(.live))
  }

  @Test("#19 release until idle while owning clears the bit and does not reopen while busy")
  func scenario19ReleaseUntilIdleDoesNotReopen() {
    var driver = HoldDriver()
    driver.tick(at: -2, fullWake: true, agents: .none)
    driver.send(.transcriptActivity(TranscriptActivity(at: driver.harness.instant(0))), at: 0)
    #expect(driver.harness.state.hold.lidClose == .held)
    let command = driver.send(.command(.releaseUntilIdle), at: 1)
    guard let clear = Self.clamshellEffects(command).first, let idle = Self.idleID(command) else {
      Issue.record("no release effects: \(command)")
      return
    }
    var stillOwned = Self.ownership(true)
    stillOwned.releaseUntilIdle = true
    #expect(
      command == [
        .log(Decision(keyword: .override, verb: "releaseUntilIdle")),
        .log(Decision(keyword: .want, verb: "off", fields: [.init(key: "reason", value: "override")])),
        .clamshell(on: false, id: clear.id, why: .release),
        .idleAssertion(.release, id: idle),
        .persist(stillOwned),
      ])
    var released = Self.ownership(false)
    released.releaseUntilIdle = true
    #expect(driver.batches.contains([.sentinel(.disarm), .persist(released), Self.released]))
    #expect(driver.harness.state.hold.lidClose == .released)
    let writesBefore = driver.writes.count
    for second in stride(from: 2.0, through: 176.0, by: 2.0) {
      driver.tick(at: second, fullWake: true, agents: .none)
    }
    #expect(driver.harness.state.want.lastBusy == driver.harness.instant(118))
    #expect(driver.writes.count == writesBefore)
    #expect(driver.harness.state.want.override)
    let cleared = Decision(
      keyword: .override, verb: "cleared",
      fields: [DecisionField(key: "msg", value: "Claude idle: automatic management resumed")])
    #expect(driver.lines(cleared).isEmpty)
    driver.tick(at: 178, fullWake: true, agents: .none)
    #expect(driver.lines(cleared) == [178])
    #expect(driver.harness.state.want.override == false)
    #expect(driver.writes.count == writesBefore)
  }

  @Test("#20 powerd cleared the bit: the hold is re-asserted without an override")
  func scenario20PowerdClearIsReasserted() {
    var driver = HoldDriver.engaged()
    for second in stride(from: 2.0, through: 8.0, by: 2.0) {
      driver.tick(at: second, fullWake: true)
    }
    let effects = driver.tick(at: 10, fullWake: true)
    let writes = Self.clamshellEffects(effects)
    #expect(writes.count == 1)
    guard let write = writes.first else { return }
    #expect(write.on && write.why == .reassert)
    #expect(effects.contains(.log(HoldDriver.reassertLine("periodic"))))
    #expect(driver.harness.state.want.override == false)
    #expect(driver.harness.state.hold.lidClose == .held)
    driver.send(.systemHasPoweredOn, at: 12)
    for second in stride(from: 13.0, through: 19.0, by: 1.0) {
      driver.tick(at: second, fullWake: true)
    }
    #expect(driver.writeTimes(.reassertAfterWake) == [13, 14, 15, 16, 17, 18])
    #expect(driver.harness.state.want.override == false)
  }

  static let foreignFacts = CoexistenceFacts(
    amphetamineRunning: true, sleepDisabled: false,
    foreignAssertions: [ForeignAssertion(pid: 4242, type: "PreventUserIdleSystemSleep", processName: "Keeper")])

  static func coexistenceWarnings(_ driver: HoldDriver) -> [Decision] {
    driver.decisions.map(\.decision).filter { $0.keyword == .warn && $0.verb.hasPrefix("coexistence") }
  }

  static func isOwnKind(_ effect: Effect) -> Bool {
    switch effect {
    case .log, .persist, .sentinel, .clamshell, .idleAssertion, .displayAssertion, .displaySleepNow, .requestSleep,
      .net, .helper:
      true
    }
  }

  static func coexistingDriver() -> (driver: HoldDriver, engage: [Effect]) {
    var driver = HoldDriver()
    driver.tick(at: -2, fullWake: true, agents: .none)
    let engage = driver.send(.transcriptActivity(TranscriptActivity(at: driver.harness.instant(0))), at: 0)
    driver.send(.tick(TickFacts(fullWake: true, coexistence: foreignFacts)), at: 2)
    driver.send(.tick(TickFacts(fullWake: true)), at: 4)
    driver.send(.tick(TickFacts(fullWake: true, coexistence: foreignFacts)), at: 32)
    return (driver, engage)
  }

  @Test("#21 another keep-awake tool running: engage exactly as #18 and warn once, touching nothing foreign")
  func scenario21CoexistenceWarnsOnceAndTakesOnlyTheOwnHold() {
    let (driver, engage) = Self.coexistingDriver()
    guard let clamshell = Self.clamshellEffects(engage).first, let idle = Self.idleID(engage) else {
      Issue.record("no clamshell engage or idle acquire: \(engage)")
      return
    }
    #expect(
      engage == [
        H.busy(true, source: "transcript"),
        H.want(true),
        .persist(Self.ownership(true)),
        .sentinel(.arm),
        .clamshell(on: true, id: clamshell.id, why: .engage),
        .idleAssertion(.acquireOrRenew(timeoutSeconds: 300), id: idle),
      ])
    #expect(driver.harness.state.hold.lidClose == .held)
    #expect(
      Self.coexistenceWarnings(driver) == [
        Decision(
          keyword: .warn, verb: "coexistence",
          fields: [
            DecisionField(key: "amphetamine", value: "true"),
            DecisionField(key: "sleepDisabled", value: "false"),
            DecisionField(key: "foreign", value: "0"),
            DecisionField(key: "names", value: "none"),
          ])
      ])
    let everything = driver.batches.flatMap { $0 }
    #expect(everything.allSatisfy(Self.isOwnKind))
    #expect(!everything.contains { String(describing: $0).contains("4242") })
  }

  @Test("#22 after #21, idle past the grace releases only Overtime's own hold")
  func scenario22ReleaseTouchesOnlyTheOwnHold() {
    var (driver, _) = Self.coexistingDriver()
    let release = driver.send(.tick(TickFacts(fullWake: true, coexistence: Self.foreignFacts)), at: 200)
    guard let clear = Self.clamshellEffects(release).first, let idle = Self.idleID(release) else {
      Issue.record("no release effects: \(release)")
      return
    }
    #expect(
      release == [
        H.busy(false, source: "transcript"),
        H.want(false),
        .clamshell(on: false, id: clear.id, why: .release),
        .idleAssertion(.release, id: idle),
      ])
    #expect(driver.batches.contains([.sentinel(.disarm), .persist(Self.ownership(false)), Self.released]))
    #expect(driver.harness.state.hold.lidClose == .released)
    #expect(driver.harness.state.hold.idle == .released)
    #expect(Self.coexistenceWarnings(driver).count == 1)
    let everything = driver.batches.flatMap { $0 }
    #expect(everything.allSatisfy(Self.isOwnKind))
    #expect(!everything.contains { String(describing: $0).contains("4242") })
  }

  @Test("#24 a timed-out engage keeps ownership, backs off 20-300 s and clears at once when unwanted")
  func scenario24FailedEngageBacksOff() {
    var driver = HoldDriver()
    driver.clamshellOutcome = .timedOut
    driver.tick(at: -2, fullWake: true)
    driver.send(.transcriptActivity(TranscriptActivity(at: driver.harness.instant(0))), at: 0)
    #expect(driver.harness.state.hold.lidClose == .failed(attempts: 1, retryAt: driver.harness.instant(20)))
    #expect(driver.harness.state.hold.errorActive)
    #expect(driver.harness.state.persisted.ownsHold)
    #expect(driver.harness.state.persisted.sentinelArmed)
    for second in stride(from: 1.0, through: 910.0, by: 1.0) {
      driver.tick(at: second, fullWake: true)
    }
    let engages = driver.writeTimes(.engage)
    #expect(engages == [0, 20, 60, 140, 300, 600, 900])
    #expect(zip(engages.dropFirst(), engages).map { $0 - $1 } == [20, 40, 80, 160, 300, 300])
    let everything = driver.batches.flatMap { $0 }
    #expect(!everything.contains(.sentinel(.disarm)))
    #expect(
      !everything.contains { effect in
        if case .persist(let state) = effect { return !state.ownsHold }
        return false
      })
    #expect(driver.harness.state.persisted.ownsHold)
    let paused = driver.send(.command(.pause(.indefinite)), at: 911)
    let clears = Self.clamshellEffects(paused)
    #expect(clears.count == 1)
    #expect(clears.first.map { !$0.on && $0.why == .release } == true)
  }
}
