import Foundation
import Testing

@testable import OvertimeCore

@Suite("Helper intent (D-20)")
struct HelperIntentTests {
  enum Unready: String, Sendable, CaseIterable, CustomTestStringConvertible {
    case noFacts
    case notInstalled
    case unreachable
    case notCurrent
    case nothing

    var testDescription: String { rawValue }

    var facts: HelperFacts? {
      switch self {
      case .noFacts: nil
      case .notInstalled: HelperFacts(installed: false, reachable: true, current: true)
      case .unreachable: HelperFacts(installed: true, reachable: false, current: true)
      case .notCurrent: HelperFacts(installed: true, reachable: true, current: false)
      case .nothing: HelperFacts(installed: false, reachable: false, current: false)
      }
    }
  }

  static let ready = HelperFacts(installed: true, reachable: true, current: true)
  static let engageLine = Decision(keyword: .hold, verb: "helper engage")
  static let lidOpened = Event.lidChanged(closed: false, sleepBit: nil, externalDisplays: nil)
  static let lidClosed = Event.lidChanged(closed: true, sleepBit: nil, externalDisplays: 0)

  static func releaseLine(_ reason: HelperReleaseReason) -> Decision {
    Decision(keyword: .hold, verb: "helper release", fields: [DecisionField(key: "reason", value: reason.rawValue)])
  }

  static func tick(closed: Bool?, agents: AgentSignals = HoldDriver.busyAgents, fullWake: Bool? = true) -> Event {
    .tick(TickFacts(agents: agents, lidClosed: closed, externalDisplays: 0, fullWake: fullWake))
  }

  static func working(lidClosed: Bool, facts: HelperFacts? = ready) -> HoldDriver {
    var driver = HoldDriver()
    if let facts {
      driver.send(.helperFacts(facts), at: -4)
    }
    driver.send(tick(closed: lidClosed), at: -2)
    driver.send(.transcriptActivity(TranscriptActivity(at: driver.harness.instant(0))), at: 0)
    return driver
  }

  static func engaged() -> HoldDriver {
    working(lidClosed: true)
  }

  static func helperActions(_ effects: some Sequence<Effect>) -> [HelperAction] {
    effects.compactMap { effect in
      if case .helper(let action, _) = effect { return action }
      return nil
    }
  }

  static func helperID(_ action: HelperAction, in effects: [Effect]) -> EffectID? {
    effects.compactMap { effect -> EffectID? in
      if case .helper(action, let id) = effect { return id }
      return nil
    }.first
  }

  static func helperLines(_ effects: [Effect]) -> [Decision] {
    ScenarioHarness.decisions(effects).filter { $0.verb.contains("helper") }
  }

  static func ownClear(in effects: [Effect]) -> Int? {
    effects.firstIndex { effect in
      if case .clamshell(on: false, _, _) = effect { return true }
      return false
    }
  }

  static func desiredState() -> AppState {
    var state = AppState(mode: .live)
    state.want.wanted = true
    state.lastLidClosed = true
    state.helper.facts = ready
    return state
  }

  @Test func theSetupEngagesTheHelperAndTheAppsOwnHold() {
    let driver = Self.engaged()
    #expect(driver.harness.state.helper.phase == .engaged)
    #expect(driver.harness.state.helper.lastContact == driver.harness.instant(0))
    #expect(driver.harness.state.hold.lidClose == .held)
    #expect(driver.harness.state.want.wanted == true)
  }

  @Test func withReadyFactsWantedAndTheLidClosedATickEndsWithTheHelperEngage() throws {
    var driver = Self.working(lidClosed: false)
    #expect(driver.harness.state.helper.phase == .idle)
    #expect(Self.helperActions(driver.batches.flatMap { $0 }).isEmpty)
    let effects = driver.harness.send(Self.tick(closed: true), at: 2)
    guard case .helper(.engage, let id)? = effects.last else {
      Issue.record("the batch does not end with a helper engage: \(effects)")
      return
    }
    #expect(effects.dropLast().last == .log(Self.engageLine))
    #expect(Self.helperActions(effects) == [.engage])
    #expect(Self.helperLines(effects) == [Self.engageLine])
    #expect(driver.harness.state.helper.phase == .engaging(id))
  }

  @Test func anEngageThatSucceededMovesThePhaseToEngagedAndRecordsTheContact() throws {
    var driver = Self.working(lidClosed: false)
    let effects = driver.harness.send(Self.tick(closed: true), at: 2)
    let id = try #require(Self.helperID(.engage, in: effects))
    #expect(driver.harness.state.helper.lastContact == nil)
    let after = driver.harness.send(.effectResult(id, .succeeded), at: 3)
    #expect(Self.helperActions(after).isEmpty)
    #expect(Self.helperLines(after).isEmpty)
    #expect(driver.harness.state.helper.phase == .engaged)
    #expect(driver.harness.state.helper.lastContact == driver.harness.instant(3))
  }

  @Test func theHelperIsEngagedAfterTheAppsOwnHoldInTheSameBatch() throws {
    var driver = HoldDriver()
    driver.send(.helperFacts(Self.ready), at: -4)
    driver.send(Self.tick(closed: true), at: -2)
    #expect(driver.harness.state.helper.phase == .idle)
    let effects = driver.harness.send(.transcriptActivity(TranscriptActivity(at: driver.harness.instant(0))), at: 0)
    let own = try #require(
      effects.firstIndex { effect in
        if case .clamshell(on: true, _, .engage) = effect { return true }
        return false
      })
    let helper = try #require(effects.firstIndex { Self.helperActions([$0]) == [.engage] })
    #expect(own < helper)
    #expect(helper == effects.count - 1)
  }

  @Test func aLidThatClosesWhileClaudeWorksEngagesInThatStep() {
    var driver = Self.working(lidClosed: false)
    let effects = driver.harness.send(Self.lidClosed, at: 2)
    #expect(Self.helperActions(effects) == [.engage])
    #expect(Self.helperActions(effects.suffix(1)) == [.engage])
  }

  @Test func readyFactsThatArriveWhileClaudeWorksWithTheLidClosedEngageInThatStep() throws {
    var driver = Self.working(lidClosed: true, facts: nil)
    #expect(Self.helperActions(driver.batches.flatMap { $0 }).isEmpty)
    let effects = driver.harness.send(.helperFacts(Self.ready), at: 2)
    let id = try #require(Self.helperID(.engage, in: effects))
    #expect(effects == [.log(Self.engageLine), .helper(.engage, id: id)])
    #expect(driver.harness.state.helper.facts == Self.ready)
  }

  @Test func factsAloneAreStoredAndEmitNothing() {
    var harness = ScenarioHarness(mode: .live)
    harness.includeActuators = true
    _ = harness.send(Self.tick(closed: true, agents: .none), at: 0)
    #expect(harness.send(.helperFacts(Self.ready), at: 1).isEmpty)
    #expect(harness.state.helper.facts == Self.ready)
    #expect(harness.state.helper.phase == .idle)
    let unready = HelperFacts(installed: true, reachable: false, current: true, owns: false, sleepDisabled: true)
    #expect(harness.send(.helperFacts(unready), at: 2).isEmpty)
    #expect(harness.state.helper.facts == unready)
  }

  @Test(arguments: Unready.allCases)
  func withoutReadyFactsNoHelperEffectIsEverEmitted(_ unready: Unready) {
    var driver = Self.working(lidClosed: true, facts: unready.facts)
    for second in stride(from: 2.0, through: 60.0, by: 2.0) {
      driver.send(Self.tick(closed: true), at: second)
    }
    driver.send(Self.lidOpened, at: 61)
    driver.send(Self.lidClosed, at: 62)
    driver.send(.command(.pause(.indefinite)), at: 63)
    driver.send(.command(.resume), at: 64)
    driver.send(Self.tick(closed: true), at: 66)
    driver.send(.command(.force(.indefinite)), at: 67)
    driver.send(.command(.sleepNow), at: 68)
    driver.send(.systemHasPoweredOn, at: 69)
    driver.send(Self.tick(closed: true), at: 70)
    driver.send(.command(.releaseUntilIdle), at: 71)
    driver.send(.power(.battery(percent: 5)), at: 72)
    driver.send(.power(.ac(percent: 80)), at: 73)
    driver.send(Self.tick(closed: true), at: 74)
    driver.send(.stop, at: 75)
    let effects = driver.batches.flatMap { $0 }
    #expect(driver.batches.count > 40)
    #expect(Self.helperActions(effects).isEmpty)
    #expect(Self.helperLines(effects).isEmpty)
    #expect(driver.harness.state.helper.phase == .idle)
    #expect(driver.harness.state.helper.lastContact == nil)
  }

  @Test func whenTheLidOpensTheHelperReleaseIsTheFirstEffectOfItsBatch() throws {
    var driver = Self.engaged()
    let effects = driver.harness.send(Self.lidOpened, at: 5)
    guard case .helper(.release, let id)? = effects.first else {
      Issue.record("the batch does not start with a helper release: \(effects)")
      return
    }
    #expect(effects.first(where: ScenarioHarness.isActuator) == .helper(.release, id: id))
    #expect(effects.dropFirst().first == .log(Self.releaseLine(.lidOpen)))
    #expect(Self.helperActions(effects) == [.release])
    #expect(Self.helperLines(effects) == [Self.releaseLine(.lidOpen)])
    #expect(driver.harness.state.helper.phase == .releasing(id))
    #expect(driver.harness.state.helper.lastContact == nil)
    #expect(Self.ownClear(in: effects) == nil)
    #expect(driver.harness.state.hold.lidClose == .held)
  }

  @Test func aBatchThatAlsoClearsTheAppsOwnBitReleasesTheHelperBeforeIt() throws {
    var driver = Self.engaged()
    let effects = driver.harness.send(Self.tick(closed: false, agents: .none), at: 400)
    guard case .helper(.release, _)? = effects.first else {
      Issue.record("the batch does not start with a helper release: \(effects)")
      return
    }
    let clear = try #require(Self.ownClear(in: effects))
    #expect(clear > 0)
    #expect(Self.helperActions(effects) == [.release])
    #expect(Self.helperLines(effects) == [Self.releaseLine(.lidOpen)])
  }

  @Test func aReleaseThatWasAnsweredReturnsToIdle() throws {
    var driver = Self.engaged()
    let effects = driver.harness.send(Self.lidOpened, at: 5)
    let id = try #require(Self.helperID(.release, in: effects))
    let after = driver.harness.send(.effectResult(id, .succeeded), at: 6)
    #expect(Self.helperActions(after).isEmpty)
    #expect(driver.harness.state.helper.phase == .idle)
  }

  @Test func anEngageResultThatArrivesAfterTheReleaseWasSentIsIgnored() throws {
    var driver = Self.working(lidClosed: false)
    let engage = try #require(Self.helperID(.engage, in: driver.harness.send(Self.tick(closed: true), at: 2)))
    let released = driver.harness.send(Self.lidOpened, at: 3)
    let release = try #require(Self.helperID(.release, in: released))
    #expect(Self.helperActions(released.prefix(1)) == [.release])
    let late = driver.harness.send(.effectResult(engage, .succeeded), at: 4)
    #expect(Self.helperActions(late).isEmpty)
    #expect(driver.harness.state.helper.phase == .releasing(release))
    #expect(driver.harness.state.helper.lastContact == nil)
    _ = driver.harness.send(.effectResult(release, .succeeded), at: 5)
    #expect(driver.harness.state.helper.phase == .idle)
  }

  @Test func aLidThatClosesAgainWaitsForTheReleaseBeforeItEngages() throws {
    var driver = Self.engaged()
    let release = try #require(Self.helperID(.release, in: driver.harness.send(Self.lidOpened, at: 5)))
    let closed = driver.harness.send(Self.lidClosed, at: 6)
    #expect(Self.helperActions(closed).isEmpty)
    #expect(driver.harness.state.helper.phase == .releasing(release))
    let done = driver.harness.send(.effectResult(release, .succeeded), at: 7)
    #expect(Self.helperActions(done) == [.engage])
    #expect(Self.helperActions(done.suffix(1)) == [.engage])
  }

  @Test(arguments: [false, nil] as [Bool?])
  func theHelperIsNeverEngagedWithoutAFullWake(_ fullWake: Bool?) {
    var driver = Self.working(lidClosed: false)
    let dark = driver.harness.send(Self.tick(closed: true, fullWake: fullWake), at: 2)
    #expect(Self.helperActions(dark).isEmpty)
    #expect(driver.harness.state.helper.phase == .idle)
    #expect(HelperIntent.desired(driver.harness.state))
    let awake = driver.harness.send(Self.tick(closed: true, fullWake: true), at: 4)
    #expect(Self.helperActions(awake) == [.engage])
  }

  @Test(arguments: [false, nil] as [Bool?])
  func anEngagedHelperIsNotReleasedByATickWithoutAFullWake(_ fullWake: Bool?) {
    var driver = Self.engaged()
    let effects = driver.harness.send(Self.tick(closed: true, fullWake: fullWake), at: 2)
    #expect(Self.helperActions(effects).isEmpty)
    #expect(driver.harness.state.helper.phase == .engaged)
  }

  @Test func theHelperIsDesiredOnlyWhileEveryConditionHolds() {
    let base = Self.desiredState()
    #expect(HelperIntent.desired(base))
    var state = base
    state.want.wanted = false
    #expect(!HelperIntent.desired(state))
    state.want.wanted = nil
    #expect(!HelperIntent.desired(state))
    state = base
    state.lastLidClosed = false
    #expect(!HelperIntent.desired(state))
    state.lastLidClosed = nil
    #expect(!HelperIntent.desired(state))
    state.lid.closed = true
    #expect(HelperIntent.desired(state))
    state = base
    state.lid.closed = false
    #expect(!HelperIntent.desired(state))
    state = base
    state.battery.blocked = true
    #expect(!HelperIntent.desired(state))
    state = base
    state.helper.facts = nil
    #expect(!HelperIntent.desired(state))
    state = base
    state.hold.stopping = true
    #expect(!HelperIntent.desired(state))
    state = base
    state.helper.suppressedUntilWake = true
    #expect(!HelperIntent.desired(state))
  }

  static let helperFloor: Comment =
    "the helper refuses and releases at or below 10% on any power source (H-CR-01), so the app treats that charge as not ready and stops asking until the charge is above it"

  static func reading(_ onAC: Bool, _ percent: Int?) -> PowerReading {
    onAC ? .ac(percent: percent) : .battery(percent: percent)
  }

  @Test(arguments: [true, false], [0, 1, 5, 9, 10])
  func atOrBelowTheHelpersFloorOnAnyPowerSourceTheHelperIsNotDesired(_ onAC: Bool, _ percent: Int) {
    var state = Self.desiredState()
    #expect(HelperIntent.desired(state))
    _ = HelperIntent.step(&state, event: .power(Self.reading(onAC, percent)), now: Instant(nanoseconds: 0), batch: [])
    #expect(!HelperIntent.desired(state), Self.helperFloor)
  }

  @Test(arguments: [true, false], [11, 12, 50, 100, nil] as [Int?])
  func aboveTheHelpersFloorOrWithAnUnknownChargeTheFloorDoesNotStopTheHelper(_ onAC: Bool, _ percent: Int?) {
    var state = Self.desiredState()
    _ = HelperIntent.step(&state, event: .power(Self.reading(true, 5)), now: Instant(nanoseconds: 0), batch: [])
    _ = HelperIntent.step(&state, event: .power(Self.reading(onAC, percent)), now: Instant(nanoseconds: 0), batch: [])
    #expect(HelperIntent.desired(state))
    _ = HelperIntent.step(&state, event: .power(.noBattery), now: Instant(nanoseconds: 0), batch: [])
    #expect(HelperIntent.desired(state))
  }

  @Test func theAppsFloorForTheHelperIsTheHelpersOwn() {
    #expect(HelperIntent.helperBatteryFloorPercent == 10)
  }

  @Test func onExternalPowerAtTheHelpersFloorTheAppNeverAsksTheHelperAndKeepsItsOwnHold() {
    var driver = HoldDriver()
    driver.send(.helperFacts(Self.ready), at: -6)
    driver.send(.power(.ac(percent: 10)), at: -5)
    driver.send(Self.tick(closed: true), at: -2)
    driver.send(.transcriptActivity(TranscriptActivity(at: driver.harness.instant(0))), at: 0)
    for second in stride(from: 2.0, through: 120.0, by: 2.0) {
      driver.send(Self.tick(closed: true), at: second)
    }
    let effects = driver.batches.flatMap { $0 }
    #expect(Self.helperActions(effects).isEmpty, Self.helperFloor)
    #expect(Self.helperLines(effects).isEmpty, Self.helperFloor)
    #expect(driver.harness.state.helper.phase == .idle)
    #expect(driver.harness.state.hold.lidClose == .held)
    #expect(driver.harness.state.want.wanted == true)
    let resumed = driver.harness.send(.power(.ac(percent: 11)), at: 121)
    #expect(Self.helperActions(resumed) == [.engage])
  }

  @Test func anEngagedHelperIsReleasedWhenTheChargeOnExternalPowerFallsToTheFloorAndNotAskedAgain() throws {
    var driver = Self.engaged()
    let effects = driver.harness.send(.power(.ac(percent: 10)), at: 5)
    guard case .helper(.release, let id)? = effects.first else {
      Issue.record("the batch does not start with a helper release: \(effects)")
      return
    }
    #expect(effects.dropFirst().first == .log(Self.releaseLine(.battery)), Self.helperFloor)
    #expect(Self.ownClear(in: effects) == nil)
    _ = driver.harness.send(.effectResult(id, .succeeded), at: 5)
    var later: [Effect] = []
    for second in stride(from: 6.0, through: 120.0, by: 2.0) {
      later += driver.harness.send(Self.tick(closed: true), at: second)
    }
    #expect(Self.helperActions(later).isEmpty, Self.helperFloor)
    #expect(Self.helperLines(later).isEmpty, Self.helperFloor)
    #expect(driver.harness.state.hold.lidClose == .held)
  }

  @Test func onBatteryWithALowerReleaseSettingTheHelpersFloorStillStopsTheAsking() {
    var driver = HoldDriver()
    driver.harness.settings.batteryLowPercent = 5
    driver.send(.helperFacts(Self.ready), at: -6)
    driver.send(.power(.battery(percent: 8)), at: -5)
    driver.send(Self.tick(closed: true), at: -2)
    driver.send(.transcriptActivity(TranscriptActivity(at: driver.harness.instant(0))), at: 0)
    for second in stride(from: 2.0, through: 120.0, by: 2.0) {
      driver.send(Self.tick(closed: true), at: second)
    }
    #expect(!driver.harness.state.battery.blocked)
    #expect(Self.helperActions(driver.batches.flatMap { $0 }).isEmpty, Self.helperFloor)
  }

  @Test(arguments: Unready.allCases)
  func factsThatAreNotReadyNeverMakeTheHelperDesired(_ unready: Unready) {
    var state = Self.desiredState()
    state.helper.facts = unready.facts
    #expect(!HelperIntent.desired(state))
  }

  @Test func factsAreReadyOnlyWhenInstalledReachableAndCurrent() {
    for installed in [false, true] {
      for reachable in [false, true] {
        for current in [false, true] {
          for owns in [nil, false, true] as [Bool?] {
            let facts = HelperFacts(
              installed: installed, reachable: reachable, current: current, owns: owns, sleepDisabled: owns)
            #expect(facts.ready == (installed && reachable && current))
          }
        }
      }
    }
    #expect(Self.ready.owns == nil)
    #expect(Self.ready.sleepDisabled == nil)
  }

  @Test func detectionHealthIgnoresHelperFacts() {
    var health = HealthState(warnedRoots: ["/missing"], rootIssues: ["/missing": .missing], silenceWarned: true)
    let before = health
    let decisions = Health.evaluate(
      &health, event: .helperFacts(Self.ready), now: Instant(nanoseconds: 10), agents: nil,
      lastTranscriptEventAt: nil, startedAt: Instant(nanoseconds: 1))
    #expect(decisions.isEmpty)
    #expect(health == before)
  }

  @Test func theHelperLinesUseTheHoldKeyword() {
    #expect(Self.engageLine.keyword.rawValue == "HOLD")
    #expect(Self.engageLine.verb == "helper engage")
    let line = DecisionFormatter.line(
      Self.releaseLine(.lidOpen), wall: Date(timeIntervalSince1970: 0), timeZone: TimeZone(secondsFromGMT: 0) ?? .gmt)
    #expect(line.hasSuffix(" HOLD helper release reason=lidOpen"))
    let reasons = ["lidOpen", "battery", "notWanted", "sleepNow", "stop", "notReady"]
    #expect(HelperReleaseReason.allCases.map(\.rawValue) == reasons)
  }

  enum Transition: String, Sendable, CaseIterable, CustomTestStringConvertible {
    case batteryFloor
    case pause
    case releaseUntilIdle
    case forceStopped
    case forceExpired
    case helperRemoved
    case helperUnreachable
    case helperOutOfDate
    case stop

    var testDescription: String { rawValue }

    var reason: HelperReleaseReason {
      switch self {
      case .batteryFloor: .battery
      case .pause, .releaseUntilIdle, .forceStopped, .forceExpired: .notWanted
      case .helperRemoved, .helperUnreachable, .helperOutOfDate: .notReady
      case .stop: .stop
      }
    }

    var clearsTheAppsOwnHold: Bool {
      reason != .notReady
    }

    var at: Double {
      self == .forceExpired ? 70 : 5
    }

    var event: Event {
      switch self {
      case .batteryFloor: .power(.battery(percent: 5))
      case .pause: .command(.pause(.indefinite))
      case .releaseUntilIdle: .command(.releaseUntilIdle)
      case .forceStopped: .command(.resume)
      case .forceExpired: HelperIntentTests.tick(closed: true, agents: .none)
      case .helperRemoved: .helperFacts(HelperFacts(installed: false, reachable: false, current: false))
      case .helperUnreachable: .helperFacts(HelperFacts(installed: true, reachable: false, current: true))
      case .helperOutOfDate: .helperFacts(HelperFacts(installed: true, reachable: true, current: false))
      case .stop: .stop
      }
    }

    func prepare() -> HoldDriver {
      switch self {
      case .forceStopped: HelperIntentTests.forced(.indefinite)
      case .forceExpired: HelperIntentTests.forced(.forSeconds(60))
      default: HelperIntentTests.engaged()
      }
    }
  }

  enum Holding: String, Sendable, CaseIterable, CustomTestStringConvertible {
    case busyClaude
    case forced

    var testDescription: String { rawValue }

    func prepare() -> HoldDriver {
      self == .forced ? HelperIntentTests.forced(.indefinite) : HelperIntentTests.engaged()
    }
  }

  static let failures: [EffectOutcome] = [.failed(code: -5), .failed(code: 4097), .timedOut]

  static func forced(_ spec: ForceSpec) -> HoldDriver {
    var driver = HoldDriver()
    driver.send(.helperFacts(ready), at: -4)
    driver.send(tick(closed: true, agents: .none), at: -2)
    driver.send(.command(.force(spec)), at: 0)
    return driver
  }

  static func errorLine(_ action: HelperAction, _ outcome: EffectOutcome, retry: Bool) -> Decision {
    var fields: [DecisionField] = []
    switch outcome {
    case .failed(let code): fields.append(DecisionField(key: "code", value: String(code)))
    case .timedOut: fields.append(DecisionField(key: "reason", value: "timedOut"))
    case .succeeded: break
    }
    if retry {
      fields.append(DecisionField(key: "retryIn", value: "30"))
    }
    return Decision(keyword: .error, verb: "helper \(action.rawValue) failed", fields: fields)
  }

  static func sleepID(in effects: [Effect]) -> EffectID? {
    effects.compactMap { effect -> EffectID? in
      if case .requestSleep(let id) = effect { return id }
      return nil
    }.first
  }

  static func sleepRequested() throws -> (driver: HoldDriver, sleep: EffectID) {
    var driver = engaged()
    let effects = driver.harness.send(.command(.sleepNow), at: 5)
    let release = try #require(helperID(.release, in: effects))
    let sleep = try #require(sleepID(in: effects))
    _ = driver.harness.send(.effectResult(release, .succeeded), at: 5)
    return (driver, sleep)
  }

  static func engageFailed(_ outcome: EffectOutcome) throws -> (driver: HoldDriver, effects: [Effect]) {
    var driver = working(lidClosed: false)
    let id = try #require(helperID(.engage, in: driver.harness.send(tick(closed: true), at: 2)))
    let effects = driver.harness.send(.effectResult(id, outcome), at: 3)
    return (driver, effects)
  }

  static func deadlineSteps(_ driver: inout HoldDriver, through end: Double, sending action: HelperAction) -> [Double] {
    var times: [Double] = []
    while let deadline = Reducer.nextDeadline(driver.harness.state, driver.harness.settings),
      driver.harness.seconds(deadline) <= end
    {
      let at = driver.harness.seconds(deadline)
      if helperActions(driver.send(tick(closed: true), at: at)).contains(action) {
        times.append(at)
      }
    }
    return times
  }

  @Test(arguments: Transition.allCases)
  func everyTransitionThatEndsTheHelpersPurposeReleasesItFirst(_ transition: Transition) throws {
    var driver = transition.prepare()
    try #require(driver.harness.state.helper.phase == .engaged)
    let effects = driver.harness.send(transition.event, at: transition.at)
    guard case .helper(.release, let id)? = effects.first else {
      Issue.record("the batch does not start with a helper release: \(effects)")
      return
    }
    #expect(effects.firstIndex(where: ScenarioHarness.isActuator) == 0)
    #expect(effects.dropFirst().first == .log(Self.releaseLine(transition.reason)))
    #expect(Self.helperActions(effects) == [.release])
    #expect(Self.helperLines(effects) == [Self.releaseLine(transition.reason)])
    #expect(driver.harness.state.helper.phase == .releasing(id))
    #expect((Self.ownClear(in: effects) != nil) == transition.clearsTheAppsOwnHold)
  }

  @Test func stopReleasesTheHelperBeforeEveryEffectOfTheStopAndNothingEngagesAfterIt() {
    var driver = Self.engaged()
    let batches = StopSequenceTests.send(&driver, .stop, at: 5)
    #expect(
      StopSequenceTests.steps(batches) == [
        .helper(.release), .clamshell(on: false, why: .release), .idle(release: true), .sentinel(.disarm),
        .sentinel(.bye), .persist(ownsHold: false),
      ])
    #expect(driver.harness.state.helper.phase == .idle)
    var later = StopSequenceTests.send(&driver, Self.tick(closed: true), at: 7)
    later += StopSequenceTests.send(&driver, .systemHasPoweredOn, at: 8)
    later += StopSequenceTests.send(&driver, Self.tick(closed: true), at: 9)
    later += StopSequenceTests.send(&driver, .helperFacts(Self.ready), at: 10)
    later += StopSequenceTests.send(&driver, Self.lidClosed, at: 11)
    #expect(Self.helperActions(later.flatMap { $0 }).isEmpty)
  }

  @Test(arguments: Holding.allCases)
  func sleepNowReleasesTheHelperBeforeTheSleepRequestAndLeavesTheHoldAndOverridesAlone(_ holding: Holding) throws {
    var driver = holding.prepare()
    try #require(driver.harness.state.helper.phase == .engaged)
    let want = driver.harness.state.want
    let hold = driver.harness.state.hold
    let busy = driver.harness.state.busy
    let effects = driver.harness.send(.command(.sleepNow), at: 5)
    try #require(effects.count == 4)
    guard case .helper(.release, let release) = effects[0], case .requestSleep(let sleep) = effects[3] else {
      Issue.record("expected a helper release first and the sleep request last: \(effects)")
      return
    }
    #expect(effects[1] == .log(Self.releaseLine(.sleepNow)))
    #expect(effects[2] == SleepNowCommandTests.logLine)
    #expect(release != sleep)
    #expect(driver.harness.state.want == want)
    #expect(driver.harness.state.hold == hold)
    #expect(driver.harness.state.busy == busy)
    #expect(driver.harness.state.helper.phase == .releasing(release))
    #expect(driver.harness.state.helper.suppressedUntilWake)
  }

  @Test func afterSleepNowTheHelperStaysReleasedUntilTheSystemHasPoweredOnAgain() throws {
    let requested = try Self.sleepRequested()
    var driver = requested.driver
    var quiet = driver.harness.send(.effectResult(requested.sleep, .succeeded), at: 5)
    for second in [6.0, 8, 10, 30, 60] {
      quiet += driver.harness.send(Self.tick(closed: true), at: second)
    }
    #expect(driver.harness.state.want.wanted == true)
    #expect(driver.harness.state.hold.lidClose == .held)
    #expect(Self.helperActions(quiet).isEmpty)
    #expect(driver.harness.state.helper.phase == .idle)
    #expect(driver.harness.state.helper.suppressedUntilWake)
    let woke = driver.harness.send(.systemHasPoweredOn, at: 61)
    #expect(Self.helperActions(woke).isEmpty)
    #expect(!driver.harness.state.helper.suppressedUntilWake)
    let dark = driver.harness.send(Self.tick(closed: true, fullWake: false), at: 62)
    #expect(Self.helperActions(dark).isEmpty)
    let awake = driver.harness.send(Self.tick(closed: true, fullWake: true), at: 63)
    #expect(Self.helperActions(awake) == [.engage])
  }

  @Test(arguments: [EffectOutcome.failed(code: 1), .timedOut])
  func aSleepRequestThatDidNotSucceedLetsTheHelperEngageAgain(_ outcome: EffectOutcome) throws {
    let requested = try Self.sleepRequested()
    var driver = requested.driver
    let quiet = driver.harness.send(Self.tick(closed: true), at: 6)
    #expect(Self.helperActions(quiet).isEmpty)
    let effects = driver.harness.send(.effectResult(requested.sleep, outcome), at: 7)
    #expect(Self.helperActions(effects) == [.engage])
    #expect(Self.helperActions(effects.suffix(1)) == [.engage])
    #expect(!driver.harness.state.helper.suppressedUntilWake)
  }

  @Test func sleepNowWithTheHelperIdleSendsItNothingAndStillHoldsItBackUntilTheWake() {
    var driver = Self.working(lidClosed: false)
    let effects = driver.harness.send(.command(.sleepNow), at: 5)
    #expect(effects.count == 2)
    #expect(effects.first == SleepNowCommandTests.logLine)
    #expect(Self.helperActions(effects).isEmpty)
    #expect(Self.helperActions(driver.harness.send(Self.lidClosed, at: 6)).isEmpty)
    #expect(Self.helperActions(driver.harness.send(Self.tick(closed: true), at: 7)).isEmpty)
    _ = driver.harness.send(.systemHasPoweredOn, at: 8)
    #expect(Self.helperActions(driver.harness.send(Self.tick(closed: true), at: 9)) == [.engage])
  }

  @Test func aSecondSleepNowWhileTheReleaseIsInFlightSendsNoSecondRelease() {
    var driver = Self.engaged()
    #expect(Self.helperActions(driver.harness.send(.command(.sleepNow), at: 5)) == [.release])
    let second = driver.harness.send(.command(.sleepNow), at: 6)
    #expect(second.count == 2)
    #expect(Self.helperActions(second).isEmpty)
  }

  @Test func sleepNowWhileTheEngageIsStillInFlightReleasesFirst() {
    var driver = Self.working(lidClosed: false)
    #expect(Self.helperActions(driver.harness.send(Self.tick(closed: true), at: 2)) == [.engage])
    let effects = driver.harness.send(.command(.sleepNow), at: 3)
    #expect(Self.helperActions(effects.prefix(1)) == [.release])
    #expect(effects.dropFirst().first == .log(Self.releaseLine(.sleepNow)))
    #expect(Self.sleepID(in: effects) != nil)
  }

  @Test(arguments: failures)
  func aFailedEngageIsLoggedAndKeepAwakeStaysOnTheAppsOwnHold(_ outcome: EffectOutcome) throws {
    let (driver, effects) = try Self.engageFailed(outcome)
    #expect(Self.helperLines(effects) == [Self.errorLine(.engage, outcome, retry: true)])
    #expect(Self.helperActions(effects).isEmpty)
    #expect(driver.harness.state.helper.phase == .failed(retryAt: driver.harness.instant(33)))
    #expect(driver.harness.state.helper.lastContact == nil)
    #expect(Self.ownClear(in: effects) == nil)
    #expect(driver.harness.state.hold.lidClose == .held)
    #expect(driver.harness.state.want.wanted == true)
  }

  @Test(arguments: failures)
  func aFailedEngageIsRetriedThirtySecondsLaterWhileStillWanted(_ outcome: EffectOutcome) throws {
    var (driver, _) = try Self.engageFailed(outcome)
    var quiet: [Effect] = []
    for second in stride(from: 4.0, through: 32.0, by: 2.0) {
      quiet += driver.harness.send(Self.tick(closed: true), at: second)
    }
    #expect(Self.helperActions(quiet).isEmpty)
    let retry = driver.harness.send(Self.tick(closed: true), at: 33)
    guard case .helper(.engage, let id)? = retry.last else {
      Issue.record("no engage at the retry time: \(retry)")
      return
    }
    #expect(retry.dropLast().last == .log(Self.engageLine))
    #expect(driver.harness.state.helper.phase == .engaging(id))
    _ = driver.harness.send(.effectResult(id, .succeeded), at: 33)
    #expect(driver.harness.state.helper.phase == .engaged)
    #expect(driver.harness.state.helper.lastContact == driver.harness.instant(33))
  }

  @Test func aRetryWaitsForATickAndForAFullWake() throws {
    var (driver, _) = try Self.engageFailed(.timedOut)
    var quiet = driver.harness.send(.helperFacts(Self.ready), at: 40)
    quiet += driver.harness.send(Self.lidClosed, at: 41)
    quiet += driver.harness.send(Self.tick(closed: true, fullWake: false), at: 42)
    quiet += driver.harness.send(Self.tick(closed: true, fullWake: nil), at: 44)
    #expect(Self.helperActions(quiet).isEmpty)
    #expect(Self.helperActions(driver.harness.send(Self.tick(closed: true), at: 46)) == [.engage])
  }

  @Test func aFailedEngageThatIsNoLongerWantedIsReleasedInsteadOfRetried() throws {
    var (driver, _) = try Self.engageFailed(.timedOut)
    let opened = driver.harness.send(Self.lidOpened, at: 10)
    guard case .helper(.release, let id)? = opened.first else {
      Issue.record("the batch does not start with a helper release: \(opened)")
      return
    }
    #expect(opened.dropFirst().first == .log(Self.releaseLine(.lidOpen)))
    _ = driver.harness.send(.effectResult(id, .succeeded), at: 10)
    #expect(driver.harness.state.helper.phase == .idle)
    #expect(Self.helperActions(driver.harness.send(Self.tick(closed: false), at: 33)).isEmpty)
  }

  @Test func sleepNowAfterAFailedEngageStillReleasesFirst() throws {
    var (driver, _) = try Self.engageFailed(.timedOut)
    let effects = driver.harness.send(.command(.sleepNow), at: 5)
    #expect(Self.helperActions(effects.prefix(1)) == [.release])
    #expect(effects.dropFirst().first == .log(Self.releaseLine(.sleepNow)))
  }

  @Test func anEngagedHelperHearsFromTheEngineAfterTwentySecondsAndNotOnEveryTick() {
    var driver = Self.engaged()
    var quiet: [Effect] = []
    for second in stride(from: 2.0, through: 18.0, by: 2.0) {
      quiet += driver.harness.send(Self.tick(closed: true), at: second)
    }
    quiet += driver.harness.send(Self.tick(closed: true), at: 19)
    #expect(Self.helperActions(quiet).isEmpty)
    let beat = driver.harness.send(Self.tick(closed: true), at: 20)
    #expect(Self.helperActions(beat) == [.heartbeat])
    #expect(Self.helperActions(beat.suffix(1)) == [.heartbeat])
    #expect(Self.helperLines(beat).isEmpty)
    #expect(driver.harness.state.helper.phase == .engaged)
  }

  @Test func whileEngagedTheEngineSendsOneHeartbeatPerTwentySeconds() {
    var driver = Self.engaged()
    var times: [Double] = []
    for second in stride(from: 2.0, through: 100.0, by: 2.0) {
      if Self.helperActions(driver.send(Self.tick(closed: true), at: second)) == [.heartbeat] {
        times.append(second)
      }
    }
    #expect(times == [20, 40, 60, 80, 100])
    #expect(Self.helperActions(driver.batches.flatMap { $0 }).filter { $0 == .heartbeat }.count == 5)
    #expect(driver.harness.state.helper.phase == .engaged)
  }

  @Test func anAnsweredHeartbeatMovesTheNextOneTwentySecondsAfterTheAnswer() throws {
    var driver = Self.engaged()
    let id = try #require(Self.helperID(.heartbeat, in: driver.harness.send(Self.tick(closed: true), at: 20)))
    #expect(Self.helperActions(driver.harness.send(.effectResult(id, .succeeded), at: 21)).isEmpty)
    #expect(driver.harness.state.helper.lastContact == driver.harness.instant(21))
    #expect(Self.helperActions(driver.harness.send(Self.tick(closed: true), at: 40)).isEmpty)
    #expect(Self.helperActions(driver.harness.send(Self.tick(closed: true), at: 41)) == [.heartbeat])
  }

  static let reducerArithmeticOnly: Comment =
    "This pins the reducer's timing only. The live interpreter answers every heartbeat within its 5 s bound, and one that fails or times out ends the engagement (03-REVIEW.md C-IN-02)"

  @Test func whileAHeartbeatResultIsOutstandingTheNextOneIsDueTwentySecondsAfterItWasSent() {
    var driver = Self.engaged()
    #expect(
      Self.helperActions(driver.harness.send(Self.tick(closed: true), at: 20)) == [.heartbeat],
      Self.reducerArithmeticOnly)
    #expect(
      Self.helperActions(driver.harness.send(Self.tick(closed: true), at: 30)).isEmpty, Self.reducerArithmeticOnly)
    #expect(
      Self.helperActions(driver.harness.send(Self.tick(closed: true), at: 40)) == [.heartbeat],
      Self.reducerArithmeticOnly)
    #expect(driver.harness.state.helper.phase == .engaged, Self.reducerArithmeticOnly)
  }

  @Test func oneHeartbeatThatTimesOutEndsTheEngagementAndNoFurtherHeartbeatIsSent() throws {
    var driver = Self.engaged()
    let id = try #require(Self.helperID(.heartbeat, in: driver.harness.send(Self.tick(closed: true), at: 20)))
    _ = driver.harness.send(.effectResult(id, .timedOut), at: 25)
    #expect(driver.harness.state.helper.phase == .failed(retryAt: driver.harness.instant(55)))
    #expect(Self.helperActions(driver.harness.send(Self.tick(closed: true), at: 40)).isEmpty)
    #expect(Self.helperActions(driver.harness.send(Self.tick(closed: true), at: 54)).isEmpty)
    #expect(Self.helperActions(driver.harness.send(Self.tick(closed: true), at: 55)) == [.engage])
  }

  @Test(arguments: failures)
  func aFailedHeartbeatIsLoggedAndTheEngageIsRetried(_ outcome: EffectOutcome) throws {
    var driver = Self.engaged()
    let id = try #require(Self.helperID(.heartbeat, in: driver.harness.send(Self.tick(closed: true), at: 20)))
    let effects = driver.harness.send(.effectResult(id, outcome), at: 21)
    #expect(Self.helperLines(effects) == [Self.errorLine(.heartbeat, outcome, retry: true)])
    #expect(Self.helperActions(effects).isEmpty)
    #expect(driver.harness.state.helper.phase == .failed(retryAt: driver.harness.instant(51)))
    #expect(driver.harness.state.helper.lastContact == nil)
    #expect(Self.ownClear(in: effects) == nil)
    #expect(driver.harness.state.hold.lidClose == .held)
    #expect(Self.helperActions(driver.harness.send(Self.tick(closed: true), at: 50)).isEmpty)
    #expect(Self.helperActions(driver.harness.send(Self.tick(closed: true), at: 51)) == [.engage])
  }

  @Test func aHeartbeatIsSentOnlyFromATick() {
    var driver = Self.engaged()
    var effects = driver.harness.send(.helperFacts(Self.ready), at: 25)
    effects += driver.harness.send(Self.lidClosed, at: 26)
    effects += driver.harness.send(.transcriptActivity(TranscriptActivity(at: driver.harness.instant(27))), at: 27)
    effects += driver.harness.send(.power(.ac(percent: 80)), at: 28)
    #expect(Self.helperActions(effects).isEmpty)
    #expect(Self.helperActions(driver.harness.send(Self.tick(closed: true), at: 29)) == [.heartbeat])
  }

  @Test func aHeartbeatResultThatArrivesAfterTheReleaseIsIgnored() throws {
    var driver = Self.engaged()
    let beat = try #require(Self.helperID(.heartbeat, in: driver.harness.send(Self.tick(closed: true), at: 20)))
    let release = try #require(Self.helperID(.release, in: driver.harness.send(Self.lidOpened, at: 21)))
    let late = driver.harness.send(.effectResult(beat, .timedOut), at: 22)
    #expect(Self.helperLines(late).isEmpty)
    #expect(Self.helperActions(late).isEmpty)
    #expect(driver.harness.state.helper.phase == .releasing(release))
  }

  @Test func aHeartbeatResultFromAnEarlierEngagementIsIgnored() throws {
    var driver = Self.engaged()
    let beat = try #require(Self.helperID(.heartbeat, in: driver.harness.send(Self.tick(closed: true), at: 20)))
    let release = try #require(Self.helperID(.release, in: driver.harness.send(Self.lidOpened, at: 21)))
    _ = driver.harness.send(.effectResult(release, .succeeded), at: 22)
    let engage = try #require(Self.helperID(.engage, in: driver.harness.send(Self.lidClosed, at: 23)))
    _ = driver.harness.send(.effectResult(engage, .succeeded), at: 24)
    try #require(driver.harness.state.helper.phase == .engaged)
    let late = driver.harness.send(.effectResult(beat, .timedOut), at: 25)
    #expect(Self.helperLines(late).isEmpty)
    #expect(driver.harness.state.helper.phase == .engaged)
    #expect(driver.harness.state.helper.lastContact == driver.harness.instant(24))
  }

  @Test func aResultOfTheAppsOwnHoldIsNeverTakenForTheHeartbeat() throws {
    var driver = Self.engaged()
    let effects = driver.harness.send(Self.tick(closed: true), at: 20)
    let beat = try #require(Self.helperID(.heartbeat, in: effects))
    let renewal = try #require(
      effects.compactMap { effect -> EffectID? in
        if case .idleAssertion(.acquireOrRenew, let id) = effect { return id }
        return nil
      }.first)
    let own = driver.harness.send(.effectResult(renewal, .failed(code: 5)), at: 21)
    #expect(Self.helperLines(own).isEmpty)
    #expect(driver.harness.state.helper.phase == .engaged)
    guard case .failed = driver.harness.state.hold.idle else {
      Issue.record("the app's own hold did not see its result: \(driver.harness.state.hold.idle)")
      return
    }
    let answered = driver.harness.send(.effectResult(beat, .timedOut), at: 22)
    #expect(Self.helperLines(answered) == [Self.errorLine(.heartbeat, .timedOut, retry: true)])
  }

  @Test func noHeartbeatIsSentWhileTheEngageIsStillInFlight() {
    var driver = Self.working(lidClosed: false)
    #expect(Self.helperActions(driver.harness.send(Self.tick(closed: true), at: 2)) == [.engage])
    var effects: [Effect] = []
    for second in stride(from: 4.0, through: 60.0, by: 2.0) {
      effects += driver.harness.send(Self.tick(closed: true), at: second)
    }
    #expect(Self.helperActions(effects).isEmpty)
  }

  @Test(arguments: failures)
  func aFailedReleaseIsLoggedAndTheAppsOwnClearOfTheSameBatchStillRuns(_ outcome: EffectOutcome) throws {
    var driver = Self.engaged()
    let effects = driver.harness.send(.command(.pause(.indefinite)), at: 5)
    let release = try #require(Self.helperID(.release, in: effects))
    let index = try #require(Self.ownClear(in: effects))
    guard case .clamshell(on: false, let clear, .release) = effects[index] else {
      Issue.record("no release clear in \(effects)")
      return
    }
    #expect(index > 0)
    let failed = driver.harness.send(.effectResult(release, outcome), at: 6)
    #expect(Self.helperLines(failed) == [Self.errorLine(.release, outcome, retry: false)])
    #expect(Self.helperActions(failed).isEmpty)
    #expect(driver.harness.state.helper.phase == .idle)
    #expect(driver.harness.state.hold.lidClose == .releasing(clear))
    _ = driver.harness.send(.effectResult(clear, .succeeded), at: 6)
    #expect(driver.harness.state.hold.lidClose == .released)
    #expect(driver.harness.state.persisted.ownsHold == false)
    var later: [Effect] = []
    for second in [8.0, 10, 40, 70] {
      later += driver.harness.send(Self.tick(closed: true), at: second)
    }
    #expect(Self.helperActions(later).isEmpty)
  }

  @Test func theNextDeadlineIncludesTheNextHeartbeat() {
    var driver = Self.working(lidClosed: true, facts: nil)
    driver.send(.helperFacts(Self.ready), at: 3)
    #expect(driver.harness.state.helper.phase == .engaged)
    #expect(Self.deadlineSteps(&driver, through: 70, sending: .heartbeat) == [23, 43, 63])
  }

  @Test func theNextDeadlineIncludesTheRetryOfAFailedEngage() {
    var driver = Self.working(lidClosed: true, facts: nil)
    driver.helperOutcome = .failed(code: -5)
    driver.send(.helperFacts(Self.ready), at: 3.5)
    #expect(driver.harness.state.helper.phase == .failed(retryAt: driver.harness.instant(33.5)))
    driver.helperOutcome = .succeeded
    #expect(Self.deadlineSteps(&driver, through: 40, sending: .engage) == [33.5])
    #expect(driver.harness.state.helper.phase == .engaged)
  }

  @Test func theHelpersOwnDeadlinesFollowItsPhase() {
    var state = Self.desiredState()
    let contact = Instant(nanoseconds: 7_000_000_000)
    let retry = Instant(nanoseconds: 9_000_000_000)
    #expect(HelperIntent.deadlines(state).isEmpty)
    state.helper.phase = .engaging(EffectID(value: 1))
    #expect(HelperIntent.deadlines(state).isEmpty)
    state.helper.phase = .releasing(EffectID(value: 2))
    state.helper.lastContact = contact
    #expect(HelperIntent.deadlines(state).isEmpty)
    state.helper.phase = .engaged
    #expect(HelperIntent.deadlines(state) == [contact.adding(seconds: 20)])
    state.helper.phase = .failed(retryAt: retry)
    #expect(HelperIntent.deadlines(state) == [retry])
    state.lastEventAt = Instant(nanoseconds: 1)
    #expect(Reducer.nextDeadline(state, Settings()) == retry)
  }

  @Test func thePeriodsAreTheDocumentedOnesAndTheGapBetweenTwoAnsweredHeartbeatsIsInsideTheHelpersTimeout() {
    #expect(HelperIntent.heartbeatSeconds == 20)
    #expect(HelperIntent.retrySeconds == 30)
    let helperHeartbeatTimeoutSeconds = 55.0
    let worstGapBetweenTwoAnsweredHeartbeats =
      HelperIntent.heartbeatSeconds + Timing.systemCallTimeoutSeconds + Timing.tickSeconds
    #expect(worstGapBetweenTwoAnsweredHeartbeats == 27)
    #expect(worstGapBetweenTwoAnsweredHeartbeats < helperHeartbeatTimeoutSeconds)
    let twoPeriodsWithOneCallAndOneTick =
      2 * HelperIntent.heartbeatSeconds + Timing.systemCallTimeoutSeconds + Timing.tickSeconds
    #expect(twoPeriodsWithOneCallAndOneTick < helperHeartbeatTimeoutSeconds, Self.reducerArithmeticOnly)
  }
}
