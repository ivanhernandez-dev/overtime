import Foundation
import Testing

@testable import OvertimeCore

@Suite("Self-test machine (OPS-09)")
struct SelfTestMachineTests {
  static let openLid = TickFacts(lidClosed: false, fullWake: true)
  static let facts = SelfTestFacts(sleepDisabled: false, osBuild: "26A428")
  static let start = Effect.log(Decision(keyword: .selftest, verb: "start"))
  static let passed = Effect.log(Decision(keyword: .selftest, verb: "passed"))
  static let owned = PersistedState(ownsHold: true, sentinelArmed: true)

  enum Waiting: String, Sendable, CaseIterable, CustomTestStringConvertible {
    case lidClosed
    case lidUnknown
    case wanted
    case lidCloseHeld

    var testDescription: String { rawValue }

    func prepare(_ driver: inout HoldDriver) {
      switch self {
      case .lidClosed:
        driver.send(.tick(TickFacts(lidClosed: true, fullWake: true)), at: 0)
      case .lidUnknown:
        driver.send(.tick(TickFacts(fullWake: true)), at: 0)
      case .wanted:
        driver.send(.tick(TickFacts(lidClosed: false, fullWake: false)), at: 0)
        driver.send(.command(.force(.indefinite)), at: 1)
      case .lidCloseHeld:
        driver.send(.tick(SelfTestMachineTests.openLid), at: 0)
        driver.send(.command(.force(.indefinite)), at: 1)
      }
    }

    func recover(_ driver: inout HoldDriver) {
      switch self {
      case .lidClosed, .lidUnknown:
        driver.send(.tick(SelfTestMachineTests.openLid), at: 3)
      case .wanted, .lidCloseHeld:
        driver.send(.command(.resume), at: 3)
      }
    }
  }

  enum Blocker: String, Sendable, CaseIterable, CustomTestStringConvertible {
    case lidCloseAcquiring
    case lidCloseHeld
    case lidCloseReleasing
    case lidCloseFailed
    case ownsHold
    case idleAcquiring
    case idleHeld
    case idleReleasing
    case wanted
    case lidClosed
    case lidUnknown
    case stopping

    var testDescription: String { rawValue }

    func apply(_ state: inout AppState) {
      let id = EffectID(value: 7)
      switch self {
      case .lidCloseAcquiring: state.hold.lidClose = .acquiring(id)
      case .lidCloseHeld: state.hold.lidClose = .held
      case .lidCloseReleasing: state.hold.lidClose = .releasing(id)
      case .lidCloseFailed: state.hold.lidClose = .failed(attempts: 1, retryAt: Instant(nanoseconds: 1))
      case .ownsHold: state.persisted.ownsHold = true
      case .idleAcquiring: state.hold.idle = .acquiring(id)
      case .idleHeld: state.hold.idle = .held
      case .idleReleasing: state.hold.idle = .releasing(id)
      case .wanted: state.want.wanted = true
      case .lidClosed: state.lastLidClosed = true
      case .lidUnknown: state.lastLidClosed = nil
      case .stopping: state.hold.stopping = true
      }
    }
  }

  static func idle() -> ScenarioHarness {
    var harness = ScenarioHarness(mode: .live)
    harness.includeActuators = true
    _ = harness.send(.tick(openLid), at: 0)
    return harness
  }

  static func runnableState() -> AppState {
    var state = AppState(mode: .live)
    state.lastLidClosed = false
    state.want.wanted = false
    return state
  }

  static func actuatorIDs(_ effects: [Effect]) -> [EffectID] {
    effects.compactMap { effect in
      switch effect {
      case .clamshell(_, let id, _), .idleAssertion(_, let id): id
      default: nil
      }
    }
  }

  static func batch(_ ids: [EffectID]) -> [Effect] {
    [
      start,
      .persist(owned),
      .sentinel(.arm),
      .clamshell(on: true, id: ids[0], why: .selfTest),
      .clamshell(on: false, id: ids[1], why: .selfTest),
      .idleAssertion(.acquireOrRenew(timeoutSeconds: 300), id: ids[2]),
      .idleAssertion(.release, id: ids[3]),
    ]
  }

  struct Run {
    var harness: ScenarioHarness
    let ids: [EffectID]

    mutating func answer(_ index: Int, _ outcome: EffectOutcome = .succeeded, at seconds: Double = 2) -> [Effect] {
      harness.send(.effectResult(ids[index], outcome), at: seconds)
    }

    mutating func answerAll(
      _ outcomes: [EffectOutcome], order: [Int] = [0, 1, 2, 3], at seconds: Double = 2
    ) -> [Effect] {
      var last: [Effect] = []
      for index in order {
        last = answer(index, outcomes[index], at: seconds)
      }
      return last
    }
  }

  static func rerun(_ harness: ScenarioHarness, at seconds: Double) throws -> Run {
    var harness = harness
    let ids = actuatorIDs(harness.send(.selfTest(facts), at: seconds))
    try #require(ids.count == 4)
    return Run(harness: harness, ids: ids)
  }

  static func started(at seconds: Double = 1) throws -> Run {
    var harness = idle()
    let ids = actuatorIDs(harness.send(.selfTest(facts), at: seconds))
    try #require(ids.count == 4)
    return Run(harness: harness, ids: ids)
  }

  @Test func aRequestWithTheLidOpenAndTheEngineIdleEmitsOneArmFirstBatch() throws {
    var harness = Self.idle()
    let effects = harness.send(.selfTest(Self.facts), at: 1)
    let ids = Self.actuatorIDs(effects)
    try #require(ids.count == 4)
    #expect(effects == Self.batch(ids))
    #expect(harness.state.selfTest.status == .running)
    #expect(harness.state.persisted == Self.owned)
    #expect(harness.state.selfTest.runs == 1)
  }

  @Test func theFourEffectIDsAreDistinctAndTheHoldMachineTracksNoneOfThem() throws {
    var harness = Self.idle()
    let hold = harness.state.hold
    let ids = Self.actuatorIDs(harness.send(.selfTest(Self.facts), at: 1))
    try #require(ids.count == 4)
    #expect(Set(ids).count == 4)
    #expect(harness.state.hold.onWrites.isEmpty)
    #expect(harness.state.hold.renewals.isEmpty)
    #expect(harness.state.hold == hold)
    #expect(harness.state.selfTest.pending?.ids.count == 4)
    for (step, id) in zip(SelfTestStep.allCases, ids) {
      #expect(harness.state.selfTest.pending?.ids[step] == id)
    }
  }

  @Test func fourSuccessesPassThenDisarmAndGiveUpOwnership() throws {
    var run = try Self.started()
    let hold = run.harness.state.hold
    for index in 0..<3 {
      #expect(run.answer(index).isEmpty)
      #expect(run.harness.state.selfTest.status == .running)
      #expect(run.harness.state.persisted.ownsHold)
    }
    #expect(run.answer(3) == [.sentinel(.disarm), .persist(PersistedState()), Self.passed])
    #expect(run.harness.state.selfTest.status == .passed)
    #expect(run.harness.state.selfTest.pending == nil)
    #expect(run.harness.state.persisted == PersistedState())
    #expect(run.harness.state.selfTest.failures == 0)
    #expect(!run.harness.state.selfTest.errorActive)
    #expect(run.harness.state.hold == hold)
  }

  @Test func resultsArrivingInAnyOrderStillPassOnTheLastOne() throws {
    var run = try Self.started()
    for index in [3, 2, 1] {
      #expect(run.answer(index).isEmpty)
    }
    #expect(run.answer(0) == [.sentinel(.disarm), .persist(PersistedState()), Self.passed])
    #expect(run.harness.state.selfTest.status == .passed)
  }

  @Test(arguments: Waiting.allCases)
  func aRequestThatIsNotSafeWaitsAndWritesNothingThenRunsOnceItIsSafe(_ setup: Waiting) throws {
    var driver = HoldDriver()
    setup.prepare(&driver)
    let persisted = driver.harness.state.persisted
    let hold = driver.harness.state.hold
    #expect(!SelfTest.runnable(driver.harness.state))
    #expect(driver.harness.send(.selfTest(Self.facts), at: 2).isEmpty)
    #expect(driver.harness.state.selfTest.status == .waiting)
    #expect(driver.harness.state.selfTest.pending == nil)
    #expect(driver.harness.state.selfTest.runs == 0)
    #expect(driver.harness.state.persisted == persisted)
    #expect(driver.harness.state.hold == hold)

    setup.recover(&driver)
    #expect(SelfTest.runnable(driver.harness.state))
    let effects = driver.harness.send(.selfTest(Self.facts), at: 4)
    let ids = Self.actuatorIDs(effects)
    try #require(ids.count == 4)
    #expect(effects == Self.batch(ids))
    #expect(driver.harness.state.selfTest.status == .running)
  }

  @Test func theBaselineStateIsRunnableAndAnUnknownWantCountsAsNotWanted() {
    var state = Self.runnableState()
    #expect(SelfTest.runnable(state))
    state.want.wanted = nil
    #expect(SelfTest.runnable(state))
  }

  @Test(arguments: Blocker.allCases)
  func eachUnsafeConditionAloneMakesItNotRunnable(_ blocker: Blocker) {
    var state = Self.runnableState()
    blocker.apply(&state)
    #expect(!SelfTest.runnable(state))
  }

  @Test func aSecondRequestWhileATestRunsIsIgnored() throws {
    var run = try Self.started()
    let before = run.harness.state
    let second = SelfTestFacts(sleepDisabled: false, osBuild: "26A430")
    #expect(run.harness.send(.selfTest(second), at: 2).isEmpty)
    #expect(run.harness.state.selfTest == before.selfTest)
    #expect(run.harness.state.persisted == before.persisted)
    #expect(run.harness.state.nextEffectID == before.nextEffectID)
  }

  @Test func theRequestKeepsTheOSBuildEvenWhileWaiting() {
    var harness = ScenarioHarness(mode: .live)
    harness.includeActuators = true
    #expect(harness.state.selfTest.osBuild == nil)
    _ = harness.send(.selfTest(Self.facts), at: 0)
    #expect(harness.state.selfTest.status == .waiting)
    #expect(harness.state.selfTest.osBuild == "26A428")
    _ = harness.send(.selfTest(SelfTestFacts(sleepDisabled: false)), at: 1)
    #expect(harness.state.selfTest.osBuild == "26A428")
    _ = harness.send(.selfTest(SelfTestFacts(sleepDisabled: false, osBuild: "26A430")), at: 2)
    #expect(harness.state.selfTest.osBuild == "26A430")
  }

  @Test func aResultForAnotherEffectIsLeftToTheHoldMachine() throws {
    var run = try Self.started()
    let foreign = EffectID(value: 9_999)
    #expect(!run.ids.contains(foreign))
    let before = run.harness.state
    let now = run.harness.instant(2)
    #expect(SelfTest.handleResult(foreign, .succeeded, state: &run.harness.state, now: now) == nil)
    #expect(run.harness.state == before)
    var idle = Self.runnableState()
    #expect(SelfTest.handleResult(foreign, .succeeded, state: &idle, now: now) == nil)
  }

  @Test func healthIgnoresASelfTestRequest() {
    var health = HealthState(warnedRoots: ["/x"], rootIssues: ["/x": .missing], silenceWarned: true)
    let before = health
    let now = Instant(nanoseconds: 5)
    let decisions = Health.evaluate(
      &health, event: .selfTest(Self.facts), now: now, agents: nil, lastTranscriptEventAt: nil, startedAt: now)
    #expect(decisions.isEmpty)
    #expect(health == before)
  }

  @Test func aSelfTestClearNeverStartsASleepCheck() throws {
    var state = AppState(mode: .live)
    state.lastLidClosed = true
    state.lastExternalDisplays = 0
    state.want.wanted = false
    let id = EffectID(value: 3)
    #expect(SleepVerification.startsVerification(state, holdEffects: [.clamshell(on: false, id: id, why: .release)]))
    #expect(!SleepVerification.startsVerification(state, holdEffects: [.clamshell(on: false, id: id, why: .selfTest)]))

    var run = try Self.started()
    #expect(run.harness.state.verification == .idle)
    for index in 0..<4 {
      _ = run.answer(index)
    }
    #expect(run.harness.state.verification == .idle)
  }

  @Test func theDecisionLinesReadSelfTest() {
    #expect(DecisionKeyword.selftest.rawValue == "SELFTEST")
    #expect(ClamshellWhy.selfTest.rawValue == "selfTest")
    let line = DecisionFormatter.line(
      Decision(keyword: .selftest, verb: "start"), wall: Date(timeIntervalSince1970: 0),
      timeZone: TimeZone(identifier: "UTC") ?? .current)
    #expect(line.hasSuffix(" SELFTEST start"))
  }

  static let ok = EffectOutcome.succeeded
  static let refusal = Int32(bitPattern: 0xE000_02C2)
  static let allOK = [ok, ok, ok, ok]
  static let released = Effect.log(Decision(keyword: .hold, verb: "release"))
  static let giveUp: [Effect] = [.sentinel(.disarm), .persist(PersistedState())]

  struct Mapping: Sendable, CustomTestStringConvertible {
    var name: String
    var outcomes: [EffectOutcome]
    var failure: SelfTestFailure

    var testDescription: String { name }
  }

  static let mappings: [Mapping] = [
    Mapping(name: "onUnwatched", outcomes: [.failed(code: -1), ok, ok, ok], failure: .watchdogNotRunning),
    Mapping(name: "onTimedOut", outcomes: [.timedOut, ok, ok, ok], failure: .timedOut),
    Mapping(name: "onRefused", outcomes: [.failed(code: refusal), ok, ok, ok], failure: .clamshellRefused(refusal)),
    Mapping(name: "onUnpersisted", outcomes: [.failed(code: -3), ok, ok, ok], failure: .stateNotSaved),
    Mapping(name: "offUnpersisted", outcomes: [ok, .failed(code: -3), ok, ok], failure: .stateNotSaved),
    Mapping(name: "acquireMinusThree", outcomes: [ok, ok, .failed(code: -3), ok], failure: .assertionRefused(-3)),
    Mapping(name: "onLockBusy", outcomes: [.failed(code: -4), ok, ok, ok], failure: .timedOut),
    Mapping(name: "offLockBusy", outcomes: [ok, .failed(code: -4), ok, ok], failure: .timedOut),
    Mapping(name: "acquireLockBusy", outcomes: [ok, ok, .failed(code: -4), ok], failure: .timedOut),
    Mapping(name: "releaseLockBusy", outcomes: [ok, ok, ok, .failed(code: -4)], failure: .timedOut),
    Mapping(name: "onMinusTwo", outcomes: [.failed(code: -2), ok, ok, ok], failure: .clamshellRefused(-2)),
    Mapping(name: "acquireMinusFive", outcomes: [ok, ok, .failed(code: -5), ok], failure: .assertionRefused(-5)),
    Mapping(name: "offRefused", outcomes: [ok, .failed(code: refusal), ok, ok], failure: .clamshellRefused(refusal)),
    Mapping(name: "offTimedOut", outcomes: [ok, .timedOut, ok, ok], failure: .timedOut),
    Mapping(name: "acquireRefused", outcomes: [ok, ok, .failed(code: 5), ok], failure: .assertionRefused(5)),
    Mapping(name: "acquireTimedOut", outcomes: [ok, ok, .timedOut, ok], failure: .timedOut),
    Mapping(name: "releaseRefused", outcomes: [ok, ok, ok, .failed(code: 5)], failure: .assertionRefused(5)),
    Mapping(
      name: "onAndAcquireFail", outcomes: [.failed(code: refusal), ok, .failed(code: 5), ok],
      failure: .clamshellRefused(refusal)),
    Mapping(
      name: "offAndReleaseFail", outcomes: [ok, .failed(code: refusal), ok, .timedOut],
      failure: .clamshellRefused(refusal)),
    Mapping(
      name: "acquireAndReleaseFail", outcomes: [ok, ok, .timedOut, .failed(code: 5)], failure: .timedOut),
    Mapping(
      name: "everyStepFails", outcomes: [.failed(code: -1), .timedOut, .failed(code: 5), .failed(code: 6)],
      failure: .watchdogNotRunning),
  ]

  struct SafeFailure: Sendable, CustomTestStringConvertible {
    var name: String
    var outcomes: [EffectOutcome]
    var reason: String
    var code: String?

    var testDescription: String { name }
  }

  static let safeFailures: [SafeFailure] = [
    SafeFailure(name: "onUnwatched", outcomes: [.failed(code: -1), ok, ok, ok], reason: "watchdogNotRunning"),
    SafeFailure(
      name: "onRefused", outcomes: [.failed(code: refusal), ok, ok, ok], reason: "clamshellRefused",
      code: "0xE00002C2"),
    SafeFailure(name: "onUnpersisted", outcomes: [.failed(code: -3), ok, ok, ok], reason: "stateNotSaved"),
    SafeFailure(name: "acquireLockBusy", outcomes: [ok, ok, .failed(code: -4), ok], reason: "timedOut"),
    SafeFailure(
      name: "acquireRefused", outcomes: [ok, ok, .failed(code: 5), ok], reason: "assertionRefused",
      code: "0x00000005"),
    SafeFailure(name: "releaseTimedOut", outcomes: [ok, ok, ok, .timedOut], reason: "timedOut"),
  ]

  struct Skip: Sendable, CustomTestStringConvertible {
    var name: String
    var facts: SelfTestFacts
    var skip: SelfTestSkip
    var reason: String

    var testDescription: String { name }
  }

  static let skips: [Skip] = [
    Skip(
      name: "amphetamine", facts: SelfTestFacts(amphetamineRunning: true, sleepDisabled: false), skip: .amphetamine,
      reason: "amphetamine"),
    Skip(
      name: "otherTool", facts: SelfTestFacts(otherTool: "Keeper", sleepDisabled: false), skip: .otherTool("Keeper"),
      reason: "otherTool"),
    Skip(
      name: "sleepDisabledOn", facts: SelfTestFacts(sleepDisabled: true), skip: .sleepDisabled, reason: "sleepDisabled"),
    Skip(
      name: "sleepDisabledUnreadable", facts: SelfTestFacts(sleepDisabled: nil), skip: .sleepDisabled,
      reason: "sleepDisabled"),
    Skip(
      name: "amphetamineBeforeTheRest",
      facts: SelfTestFacts(amphetamineRunning: true, otherTool: "Keeper", sleepDisabled: true), skip: .amphetamine,
      reason: "amphetamine"),
    Skip(
      name: "otherToolBeforeSleepDisabled", facts: SelfTestFacts(otherTool: "Keeper", sleepDisabled: nil),
      skip: .otherTool("Keeper"), reason: "otherTool"),
  ]

  struct Write: Equatable {
    var id: EffectID
    var why: ClamshellWhy
  }

  static func writes(_ effects: [Effect], on wanted: Bool) -> [Write] {
    effects.compactMap { effect in
      guard case .clamshell(let on, let id, let why) = effect, on == wanted else { return nil }
      return Write(id: id, why: why)
    }
  }

  static func failed(_ reason: String, code: String? = nil) -> Effect {
    var fields = [DecisionField(key: "reason", value: reason)]
    if let code {
      fields.append(DecisionField(key: "code", value: code))
    }
    return .log(Decision(keyword: .selftest, verb: "failed", fields: fields))
  }

  static func skipped(_ reason: String) -> Effect {
    .log(Decision(keyword: .selftest, verb: "skipped", fields: [DecisionField(key: "reason", value: reason)]))
  }

  static func forced(_ run: inout Run, at seconds: Double = 1.5) throws -> (on: Write, idle: EffectID) {
    let engage = run.harness.send(.command(.force(.indefinite)), at: seconds)
    let on = try #require(writes(engage, on: true).first)
    let idle = try #require(
      engage.compactMap { effect -> EffectID? in
        if case .idleAssertion(.acquireOrRenew, let id) = effect { id } else { nil }
      }.first)
    #expect(on.why == .engage)
    #expect(engage.contains(.sentinel(.arm)))
    #expect(run.harness.state.hold.lidClose == .acquiring(on.id))
    return (on, idle)
  }

  @Test(arguments: mappings, [[0, 1, 2, 3], [3, 2, 1, 0], [2, 0, 3, 1]])
  func theResultMapsToTheFirstFailingStepInBatchOrder(_ row: Mapping, _ order: [Int]) throws {
    var run = try Self.started()
    _ = run.answerAll(row.outcomes, order: order)
    #expect(run.harness.state.selfTest.status == .failed(row.failure))
    #expect(run.harness.state.selfTest.pending == nil)
    #expect(run.harness.state.selfTest.errorActive)
    #expect(run.harness.state.selfTest.failures == 1)
    #expect(run.harness.state.selfTest.runs == 1)
  }

  @Test(arguments: safeFailures)
  func aFailureWithTheBitClearedDisarmsGivesUpOwnershipAndLogsItsReason(_ row: SafeFailure) throws {
    var run = try Self.started()
    let hold = run.harness.state.hold
    let effects = run.answerAll(row.outcomes)
    #expect(effects == Self.giveUp + [Self.failed(row.reason, code: row.code)])
    #expect(run.harness.state.persisted == PersistedState())
    #expect(run.harness.state.hold == hold)
  }

  @Test(arguments: [EffectOutcome.timedOut, .failed(code: refusal)])
  func anOffWriteThatDidNotSucceedKeepsOwnershipAndHandsTheClearToTheHoldRelease(_ off: EffectOutcome) throws {
    var run = try Self.started()
    let effects = run.answerAll([Self.ok, off, Self.ok, Self.ok])
    let line = off == .timedOut ? Self.failed("timedOut") : Self.failed("clamshellRefused", code: "0xE00002C2")
    let clear = try #require(Self.writes(effects, on: false).first)
    #expect(effects == [line, .clamshell(on: false, id: clear.id, why: .selfTest)])
    #expect(run.harness.state.persisted == Self.owned)
    #expect(run.harness.state.hold.lidClose == .releasing(clear.id))
    #expect(run.harness.state.hold.goals[.lidClose] == false)
    #expect(run.harness.state.hold.onWrites.isEmpty)
    #expect(run.harness.state.verification == .idle)
    #expect(!SelfTest.runnable(run.harness.state))

    let cleared = run.harness.send(.effectResult(clear.id, .succeeded), at: 3)
    #expect(cleared == Self.giveUp + [Self.released])
    #expect(run.harness.state.persisted == PersistedState())
    #expect(run.harness.state.hold.lidClose == .released)
    #expect(SelfTest.runnable(run.harness.state))
  }

  @Test func aHandedOffClearThatFailsIsRetriedByTheHoldPathUntilTheBitIsCleared() throws {
    var run = try Self.started()
    let effects = run.answerAll([Self.ok, .timedOut, Self.ok, Self.ok])
    let clear = try #require(Self.writes(effects, on: false).first)
    let refused = run.harness.send(.effectResult(clear.id, .failed(code: Self.refusal)), at: 3)
    #expect(!refused.contains(.sentinel(.disarm)))
    #expect(run.harness.state.persisted == Self.owned)
    let retryAt = run.harness.instant(3 + Timing.releaseRetrySeconds)
    #expect(run.harness.state.hold.lidClose == .failed(attempts: 1, retryAt: retryAt))

    let early = run.harness.send(.tick(Self.openLid), at: 12)
    #expect(Self.writes(early, on: false).isEmpty)
    #expect(run.harness.state.persisted == Self.owned)

    let retry = run.harness.send(.tick(Self.openLid), at: 13)
    let second = try #require(Self.writes(retry, on: false).first)
    #expect(second.why == .release)
    #expect(Self.writes(retry, on: true).isEmpty)
    #expect(!retry.contains(.sentinel(.disarm)))
    #expect(run.harness.state.persisted == Self.owned)

    let cleared = run.harness.send(.effectResult(second.id, .succeeded), at: 13)
    #expect(cleared.contains(.sentinel(.disarm)))
    #expect(cleared.contains(.persist(PersistedState())))
    #expect(run.harness.state.persisted == PersistedState())
    #expect(run.harness.state.hold.lidClose == .released)
    #expect(run.harness.state.verification == .idle)
  }

  @Test func aHoldThatEngagesWhileTheResultsAreInFlightIsNeverDisarmedPitfall6() throws {
    var run = try Self.started()
    let engage = try Self.forced(&run)
    #expect(run.answerAll(Self.allOK) == [Self.passed])
    #expect(run.harness.state.selfTest.status == .passed)
    #expect(run.harness.state.persisted.ownsHold)
    #expect(run.harness.state.persisted.sentinelArmed)
    #expect(run.harness.state.hold.lidClose == .acquiring(engage.on.id))

    let held = run.harness.send(.effectResult(engage.on.id, .succeeded), at: 2)
    #expect(!held.contains(.sentinel(.disarm)))
    #expect(run.harness.state.hold.lidClose == .held)
    #expect(run.harness.state.persisted.ownsHold)
    #expect(run.harness.state.persisted.sentinelArmed)
  }

  @Test func aHoldAlreadyHeldWhenTheResultsArriveIsNeverDisarmed() throws {
    var run = try Self.started()
    let engage = try Self.forced(&run)
    _ = run.harness.send(.effectResult(engage.on.id, .succeeded), at: 1.6)
    #expect(run.harness.state.hold.lidClose == .held)
    #expect(run.answerAll(Self.allOK) == [Self.passed])
    #expect(run.harness.state.hold.lidClose == .held)
    #expect(run.harness.state.persisted.ownsHold)
    #expect(run.harness.state.persisted.sentinelArmed)
  }

  @Test(arguments: [true, false])
  func aFailedOffWriteStartsNoSecondClearOnceTheHoldMachineOwnsTheBit(_ engageAnsweredFirst: Bool) throws {
    var run = try Self.started()
    let engage = try Self.forced(&run)
    if engageAnsweredFirst {
      _ = run.harness.send(.effectResult(engage.on.id, .succeeded), at: 1.6)
    }
    let phase = run.harness.state.hold.lidClose
    #expect(run.answerAll([Self.ok, .timedOut, Self.ok, Self.ok]) == [Self.failed("timedOut")])
    #expect(run.harness.state.selfTest.status == .failed(.timedOut))
    #expect(run.harness.state.hold.lidClose == phase)
    #expect(run.harness.state.persisted.ownsHold)
    #expect(run.harness.state.persisted.sentinelArmed)
  }

  @Test func aStopWhileTheResultsAreInFlightLeavesTheTeardownToTheHoldMachine() throws {
    var run = try Self.started()
    let stop = run.harness.send(.stop, at: 1.5)
    let clear = try #require(Self.writes(stop, on: false).first)
    #expect(!stop.contains(.sentinel(.bye)))
    #expect(run.answerAll(Self.allOK) == [Self.passed])
    #expect(run.harness.state.persisted.ownsHold)
    let done = run.harness.send(.effectResult(clear.id, .succeeded), at: 3)
    #expect(done == [.sentinel(.disarm), .sentinel(.bye), .persist(PersistedState()), Self.released])
  }

  @Test func noDisarmOrClearFollowsTheByeWhenResultsArriveAfterTheStopFinished() throws {
    var run = try Self.started()
    let stop = run.harness.send(.stop, at: 1.5)
    let clear = try #require(Self.writes(stop, on: false).first)
    let done = run.harness.send(.effectResult(clear.id, .succeeded), at: 2)
    #expect(done.contains(.sentinel(.bye)))
    #expect(run.harness.state.hold.lidClose == .released)
    #expect(run.answerAll([Self.ok, .timedOut, Self.ok, Self.ok], at: 3) == [Self.failed("timedOut")])
    #expect(run.harness.state.persisted == PersistedState())
    #expect(run.harness.state.hold.lidClose == .released)
  }

  @Test(arguments: skips)
  func aSkipWritesNothingAndIsNeverAFailure(_ row: Skip) {
    var harness = Self.idle()
    let before = harness.state
    #expect(SelfTest.runnable(before))
    #expect(harness.send(.selfTest(row.facts), at: 1) == [Self.skipped(row.reason)])
    #expect(harness.state.selfTest.status == .skipped(row.skip))
    #expect(harness.state.selfTest.pending == nil)
    #expect(harness.state.selfTest.runs == 0)
    #expect(harness.state.selfTest.failures == 0)
    #expect(!harness.state.selfTest.errorActive)
    #expect(harness.state.persisted == before.persisted)
    #expect(harness.state.hold == before.hold)
    #expect(harness.state.nextEffectID == before.nextEffectID)
  }

  @Test func aSkipIsDecidedBeforeTheSafetyWait() {
    var harness = ScenarioHarness(mode: .live)
    harness.includeActuators = true
    _ = harness.send(.tick(TickFacts(lidClosed: true, fullWake: true)), at: 0)
    #expect(!SelfTest.runnable(harness.state))
    let effects = harness.send(.selfTest(SelfTestFacts(amphetamineRunning: true, sleepDisabled: false)), at: 1)
    #expect(Self.actuatorIDs(effects).isEmpty)
    #expect(harness.state.selfTest.status == .skipped(.amphetamine))
  }

  @Test func theOtherToolNameIsBoundedAndCarriesNoControlCharacters() {
    var harness = Self.idle()
    let name = "Kee\u{07}per\n" + String(repeating: "x", count: 200)
    _ = harness.send(.selfTest(SelfTestFacts(otherTool: name, sleepDisabled: false)), at: 1)
    guard case .skipped(.otherTool(let stored)) = harness.state.selfTest.status else {
      Issue.record("expected a skip naming the other tool, got \(harness.state.selfTest.status)")
      return
    }
    #expect(stored.hasPrefix("Kee?per?x"))
    #expect(stored.unicodeScalars.count == Reducer.maxLoggedEntrypointLength)
  }

  @Test func aFailureRaisesTheErrorFlagAndCounterAndASkipLeavesBothAlone() throws {
    var run = try Self.started()
    _ = run.answerAll([.failed(code: Self.refusal), Self.ok, Self.ok, Self.ok])
    #expect(run.harness.state.selfTest.errorActive)
    #expect(run.harness.state.selfTest.failures == 1)
    _ = run.harness.send(.selfTest(SelfTestFacts(amphetamineRunning: true, sleepDisabled: false)), at: 3)
    #expect(run.harness.state.selfTest.status == .skipped(.amphetamine))
    #expect(run.harness.state.selfTest.errorActive)
    #expect(run.harness.state.selfTest.failures == 1)
    #expect(run.harness.state.selfTest.runs == 1)
  }

  @Test func aLaterPassClearsTheErrorFlagAndASecondFailureCountsAgain() throws {
    var run = try Self.started()
    _ = run.answerAll([.failed(code: Self.refusal), Self.ok, Self.ok, Self.ok])
    var second = try Self.rerun(run.harness, at: 3)
    #expect(second.harness.state.selfTest.errorActive)
    #expect(second.answerAll(Self.allOK, at: 4) == Self.giveUp + [Self.passed])
    #expect(second.harness.state.selfTest.status == .passed)
    #expect(!second.harness.state.selfTest.errorActive)
    #expect(second.harness.state.selfTest.failures == 1)
    #expect(second.harness.state.selfTest.runs == 2)

    var third = try Self.rerun(second.harness, at: 5)
    _ = third.answerAll([Self.ok, Self.ok, .timedOut, Self.ok], at: 6)
    #expect(third.harness.state.selfTest.errorActive)
    #expect(third.harness.state.selfTest.failures == 2)
    #expect(third.harness.state.selfTest.runs == 3)
  }

  @Test func aLidCloseEngageThatSucceedsClearsTheErrorFlag() throws {
    var run = try Self.started()
    _ = run.answerAll([.failed(code: Self.refusal), Self.ok, Self.ok, Self.ok])
    let engage = try Self.forced(&run, at: 3)
    _ = run.harness.send(.effectResult(engage.idle, .succeeded), at: 3)
    #expect(run.harness.state.hold.idle == .held)
    #expect(run.harness.state.selfTest.errorActive)
    _ = run.harness.send(.effectResult(engage.on.id, .succeeded), at: 3)
    #expect(run.harness.state.hold.lidClose == .held)
    #expect(!run.harness.state.selfTest.errorActive)
    #expect(run.harness.state.selfTest.status == .failed(.clamshellRefused(Self.refusal)))
    #expect(run.harness.state.selfTest.failures == 1)
  }

  @Test(arguments: [EffectOutcome.timedOut, .failed(code: refusal)])
  func aLidCloseEngageThatDoesNotSucceedKeepsTheErrorFlag(_ outcome: EffectOutcome) throws {
    var run = try Self.started()
    _ = run.answerAll([.failed(code: Self.refusal), Self.ok, Self.ok, Self.ok])
    let engage = try Self.forced(&run, at: 3)
    _ = run.harness.send(.effectResult(engage.on.id, outcome), at: 3)
    #expect(run.harness.state.hold.lidClose != .held)
    #expect(run.harness.state.selfTest.errorActive)
  }

  @Test func aTimedOutOnWriteIsQuarantinedUntilALateLandingCanNoLongerLeaveTheBitSet() throws {
    var run = try Self.started()
    let effects = run.answerAll([.timedOut, Self.ok, Self.ok, Self.ok])
    let clear = try #require(Self.writes(effects, on: false).first)
    #expect(effects == [Self.failed("timedOut"), .clamshell(on: false, id: clear.id, why: .selfTest)])
    #expect(run.harness.state.hold.onWrites == [run.ids[0]: OnWrite(since: run.harness.instant(2), timedOut: true)])
    #expect(run.harness.state.persisted == Self.owned)

    let first = run.harness.send(.effectResult(clear.id, .succeeded), at: 2)
    #expect(!first.contains(.sentinel(.disarm)))
    #expect(run.harness.state.persisted == Self.owned)
    #expect(run.harness.state.hold.lateWriteClearAt == run.harness.instant(2 + Timing.lateWriteClearSeconds))

    let settledAt = 2 + Timing.lateWriteQuarantineSeconds
    var disarmedAt: [Double] = []
    var clears = 0
    for second in stride(from: 4.0, through: settledAt + 40, by: 2.0) {
      var queue = run.harness.send(.tick(Self.openLid), at: second)
      while !queue.isEmpty {
        let effect = queue.removeFirst()
        if effect == .sentinel(.disarm) {
          disarmedAt.append(second)
        }
        guard case .clamshell(let on, let id, _) = effect else { continue }
        #expect(!on)
        clears += 1
        queue += run.harness.send(.effectResult(id, .succeeded), at: second)
      }
      if second < settledAt {
        #expect(run.harness.state.persisted.ownsHold)
        #expect(!SelfTest.runnable(run.harness.state))
      }
    }
    #expect(disarmedAt == [settledAt])
    #expect(clears == Int(Timing.lateWriteQuarantineSeconds / Timing.lateWriteClearSeconds))
    #expect(run.harness.state.persisted == PersistedState())
    #expect(SelfTest.runnable(run.harness.state))
  }

  @Test func aTimedOutOnWriteIsStillTrackedWhenTheHoldMachineOwnsTheBit() throws {
    var run = try Self.started()
    _ = try Self.forced(&run)
    #expect(run.answerAll([.timedOut, Self.ok, Self.ok, Self.ok]) == [Self.failed("timedOut")])
    #expect(run.harness.state.hold.onWrites[run.ids[0]] == OnWrite(since: run.harness.instant(2), timedOut: true))
    #expect(run.harness.state.persisted.ownsHold)
  }
}
