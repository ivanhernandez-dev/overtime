import Foundation
import Testing

@testable import OvertimeCore

@Suite("D-07 event counters")
struct EventCountersTests {
  typealias H = ScenarioHarness

  static func harness() -> ScenarioHarness {
    var harness = ScenarioHarness()
    harness.includeActuators = true
    return harness
  }

  static func idleAcquires(_ effects: [Effect]) -> [EffectID] {
    effects.compactMap { effect in
      if case .idleAssertion(.acquireOrRenew, let id) = effect { return id }
      return nil
    }
  }

  static func busyAt(_ harness: inout ScenarioHarness, _ seconds: Double) -> [Effect] {
    let activity = harness.activity(writtenAt: seconds, seenAt: seconds)
    return activity + harness.tick(at: seconds)
  }

  static func failFirstAcquire(_ harness: inout ScenarioHarness, _ effects: [Effect], at seconds: Double) {
    guard let id = idleAcquires(effects).first else {
      Issue.record("no idle acquire in \(effects)")
      return
    }
    _ = harness.send(.effectResult(id, .failed(code: 1)), at: seconds)
  }

  static func succeedFirstAcquire(_ harness: inout ScenarioHarness, _ effects: [Effect], at seconds: Double) {
    guard let id = idleAcquires(effects).first else {
      Issue.record("no idle acquire in \(effects)")
      return
    }
    _ = harness.send(.effectResult(id, .succeeded), at: seconds)
  }

  @Test func aHoldFailureWhileBusyRaisesBothHoldCounters() {
    var harness = Self.harness()
    let effects = Self.busyAt(&harness, 0)
    Self.failFirstAcquire(&harness, effects, at: 0.01)
    #expect(harness.state.hold.errorActive)
    #expect(harness.state.events.holdErrorEpisodes == 1)
    #expect(harness.state.events.holdErrorsWhileBusy == 1)
  }

  @Test func aSecondFailureInTheSameEpisodeRaisesNeitherAndARecoveryStartsANewEpisode() {
    var harness = Self.harness()
    Self.failFirstAcquire(&harness, Self.busyAt(&harness, 0), at: 0.01)
    let retry = Self.busyAt(&harness, 21)
    Self.failFirstAcquire(&harness, retry, at: 21.01)
    #expect(harness.state.hold.errorActive)
    #expect(harness.state.events.holdErrorEpisodes == 1)
    #expect(harness.state.events.holdErrorsWhileBusy == 1)

    let recovery = Self.busyAt(&harness, 62)
    Self.succeedFirstAcquire(&harness, recovery, at: 62.01)
    #expect(!harness.state.hold.errorActive)
    #expect(harness.state.events.holdErrorEpisodes == 1)

    let renewal = Self.busyAt(&harness, 64)
    Self.failFirstAcquire(&harness, renewal, at: 64.01)
    #expect(harness.state.hold.errorActive)
    #expect(harness.state.events.holdErrorEpisodes == 2)
    #expect(harness.state.events.holdErrorsWhileBusy == 2)
  }

  @Test func aHoldFailureWhileNotBusyRaisesOnlyTheEpisodeCounter() {
    var harness = Self.harness()
    _ = harness.tick(at: 0)
    let forced = harness.send(.command(.force(.indefinite)), at: 1)
    Self.failFirstAcquire(&harness, forced, at: 1.01)
    #expect(harness.state.busy.busy == false)
    #expect(harness.state.events.holdErrorEpisodes == 1)
    #expect(harness.state.events.holdErrorsWhileBusy == 0)
  }

  @Test func wantGoingOffForTheBatteryFloorRaisesBatteryReleases() {
    var harness = Self.harness()
    _ = Self.busyAt(&harness, 0)
    #expect(harness.state.want.wanted == true)
    _ = harness.send(.power(.battery(percent: 5)), at: 1)
    #expect(harness.state.want.wanted == false)
    #expect(harness.state.want.reason == "battery")
    #expect(harness.state.events.batteryReleases == 1)
    _ = harness.send(.power(.battery(percent: 4)), at: 2)
    #expect(harness.state.events.batteryReleases == 1)
  }

  @Test func theBatteryFloorWhileNothingIsWantedIsNotARelease() {
    var harness = Self.harness()
    _ = harness.tick(at: 0)
    _ = harness.send(.power(.battery(percent: 5)), at: 1)
    #expect(harness.state.battery.blocked)
    #expect(harness.state.events.batteryReleases == 0)
  }

  @Test func wantGoingOffForTheTemperatureLimitRaisesTemperatureReleases() {
    var harness = Self.harness()
    harness.settings.temperatureProtectionEnabled = true
    _ = Self.busyAt(&harness, 0)
    #expect(harness.state.want.wanted == true)
    _ = harness.send(.batteryTemperature(.celsius(46)), at: 1)
    #expect(harness.state.want.wanted == false)
    #expect(harness.state.events.temperatureReleases == 1)
    #expect(harness.state.events.batteryReleases == 0)
  }

  @Test func theTemperatureLimitWhileNothingIsWantedIsNotARelease() {
    var harness = Self.harness()
    _ = harness.tick(at: 0)
    _ = harness.send(.batteryTemperature(.celsius(46)), at: 1)
    #expect(harness.state.events.temperatureReleases == 0)
  }

  @Test func busyTurningOnBelowTheFloorRaisesBusyStartsBelowFloor() {
    var harness = Self.harness()
    _ = harness.tick(at: 0)
    _ = harness.send(.power(.battery(percent: 5)), at: 1)
    _ = Self.busyAt(&harness, 2)
    #expect(harness.state.busy.busy == true)
    #expect(harness.state.want.wanted == false)
    #expect(harness.state.events.busyStartsBelowFloor == 1)
    _ = Self.busyAt(&harness, 4)
    #expect(harness.state.events.busyStartsBelowFloor == 1)
  }

  @Test func busyTurningOnAboveTheFloorLeavesBusyStartsBelowFloorAlone() {
    var harness = Self.harness()
    _ = harness.tick(at: 0)
    _ = harness.send(.power(.battery(percent: 80)), at: 1)
    _ = Self.busyAt(&harness, 2)
    #expect(harness.state.busy.busy == true)
    #expect(harness.state.events.busyStartsBelowFloor == 0)
  }

  @Test func aStuckIgnoredDecisionRaisesStuckReleases() {
    var harness = H()
    let results = harness.ticks(from: 0, to: 60, every: 1, facts: H.claudeCaffeinate)
    let stuck = results.flatMap(\.effects).filter { $0 == H.stuck }.count
    #expect(stuck == 1)
    #expect(harness.state.events.stuckReleases == 1)
  }

  @Test func aSleepWhileWantedIsUnexpectedUnlessOvertimeAskedForIt() {
    var harness = Self.harness()
    _ = Self.busyAt(&harness, 0)
    _ = harness.send(.systemWillSleep, at: 1)
    #expect(harness.state.events.unexpectedSleeps == 1)
    _ = harness.send(.systemHasPoweredOn, at: 2)
    _ = harness.send(.command(.sleepNow), at: 3)
    #expect(harness.state.events.sleepRequested)
    _ = harness.send(.systemWillSleep, at: 4)
    #expect(harness.state.events.unexpectedSleeps == 1)
    _ = harness.send(.systemHasPoweredOn, at: 5)
    #expect(!harness.state.events.sleepRequested)
    _ = Self.busyAt(&harness, 5)
    _ = harness.send(.systemWillSleep, at: 6)
    #expect(harness.state.events.unexpectedSleeps == 2)
  }

  static func sleepRequest(in effects: [Effect]) -> EffectID? {
    for effect in effects {
      if case .requestSleep(let id) = effect { return id }
    }
    return nil
  }

  @Test(arguments: [EffectOutcome.failed(code: 1), .timedOut])
  func aSleepRequestThatDidNotSucceedNoLongerHidesTheNextSleepWhileWanted(_ outcome: EffectOutcome) throws {
    var harness = Self.harness()
    _ = Self.busyAt(&harness, 0)
    let id = try #require(Self.sleepRequest(in: harness.send(.command(.sleepNow), at: 1)))
    #expect(harness.state.events.sleepRequested)
    #expect(harness.state.events.sleepRequest == id)
    _ = harness.send(.effectResult(id, outcome), at: 2)
    #expect(!harness.state.events.sleepRequested)
    #expect(harness.state.events.sleepRequest == nil)
    _ = harness.send(.command(.resume), at: 3)
    _ = Self.busyAt(&harness, 3)
    #expect(harness.state.want.wanted == true)
    _ = harness.send(.systemWillSleep, at: 4)
    #expect(harness.state.events.unexpectedSleeps == 1)
  }

  @Test func aSleepRequestThatSucceededStillCoversTheSleepThatFollowsIt() throws {
    var harness = Self.harness()
    _ = Self.busyAt(&harness, 0)
    let id = try #require(Self.sleepRequest(in: harness.send(.command(.sleepNow), at: 1)))
    _ = harness.send(.effectResult(id, .succeeded), at: 2)
    #expect(harness.state.events.sleepRequested)
    #expect(harness.state.events.sleepRequest == nil)
    _ = harness.send(.command(.resume), at: 3)
    _ = Self.busyAt(&harness, 3)
    #expect(harness.state.want.wanted == true)
    _ = harness.send(.systemWillSleep, at: 4)
    #expect(harness.state.events.unexpectedSleeps == 0)
    _ = harness.send(.systemHasPoweredOn, at: 5)
    #expect(!harness.state.events.sleepRequested)
  }

  @Test func aFailedResultOfAnotherEffectLeavesTheSleepRequestInPlace() throws {
    var harness = Self.harness()
    _ = Self.busyAt(&harness, 0)
    let id = try #require(Self.sleepRequest(in: harness.send(.command(.sleepNow), at: 1)))
    _ = harness.send(.effectResult(EffectID(value: id.value + 1_000), .failed(code: 1)), at: 2)
    #expect(harness.state.events.sleepRequested)
    #expect(harness.state.events.sleepRequest == id)
    _ = harness.send(.systemHasPoweredOn, at: 3)
    #expect(!harness.state.events.sleepRequested)
    #expect(harness.state.events.sleepRequest == nil)
    _ = harness.send(.effectResult(id, .failed(code: 1)), at: 4)
    #expect(!harness.state.events.sleepRequested)
  }

  @Test func aSleepWhileNothingIsWantedIsNotUnexpected() {
    var harness = Self.harness()
    _ = harness.tick(at: 0)
    _ = harness.send(.systemWillSleep, at: 1)
    #expect(harness.state.events.unexpectedSleeps == 0)
  }

  @Test func forceSinceFollowsTheCurrentForce() {
    var harness = Self.harness()
    _ = harness.tick(at: 0)
    #expect(harness.state.events.forceSince == nil)
    _ = harness.send(.command(.force(.indefinite)), at: 1)
    #expect(harness.state.events.forceSince == harness.instant(1))
    _ = harness.send(.command(.force(.indefinite)), at: 5)
    #expect(harness.state.events.forceSince == harness.instant(5))
    _ = harness.tick(at: 6)
    #expect(harness.state.events.forceSince == harness.instant(5))
    _ = harness.send(.command(.resume), at: 7)
    #expect(harness.state.events.forceSince == nil)
    _ = harness.send(.command(.force(.forSeconds(10))), at: 8)
    #expect(harness.state.events.forceSince == harness.instant(8))
    _ = harness.tick(at: 20)
    #expect(harness.state.want.force == nil)
    #expect(harness.state.events.forceSince == nil)
    _ = harness.send(.command(.force(.indefinite)), at: 21)
    _ = harness.send(.command(.pause(.indefinite)), at: 22)
    #expect(harness.state.events.forceSince == nil)
  }

  static func tickUntilIdle(_ harness: inout ScenarioHarness, from start: Double) -> (Instant?, Double) {
    var second = start
    var lastBusyWhileBusy = harness.state.want.lastBusy
    while harness.state.busy.busy == true && second < start + 3_600 {
      lastBusyWhileBusy = harness.state.want.lastBusy
      second += 2
      _ = harness.tick(at: second)
    }
    return (lastBusyWhileBusy, second)
  }

  @Test func busyEndedAtChangesOnlyWhenBusyEnds() {
    var harness = Self.harness()
    _ = harness.tick(at: 0)
    #expect(harness.state.events.busyEndedAt == nil)
    for second in stride(from: 1.0, through: 9, by: 2) {
      _ = Self.busyAt(&harness, second)
      #expect(harness.state.busy.busy == true)
      #expect(harness.state.events.busyEndedAt == nil)
    }
    let (lastBusy, endedAt) = Self.tickUntilIdle(&harness, from: 9)
    #expect(harness.state.busy.busy == false)
    let firstEnd = harness.state.events.busyEndedAt
    #expect(firstEnd != nil)
    #expect(firstEnd == lastBusy)
    for second in stride(from: endedAt + 2, through: endedAt + 40, by: 2) {
      _ = harness.tick(at: second)
      #expect(harness.state.events.busyEndedAt == firstEnd)
    }
    let restart = endedAt + 100
    for second in stride(from: restart, through: restart + 8, by: 2) {
      _ = Self.busyAt(&harness, second)
      #expect(harness.state.busy.busy == true)
      #expect(harness.state.events.busyEndedAt == firstEnd)
    }
    let (secondLastBusy, _) = Self.tickUntilIdle(&harness, from: restart + 8)
    #expect(harness.state.busy.busy == false)
    #expect(harness.state.events.busyEndedAt == secondLastBusy)
    #expect(harness.state.events.busyEndedAt != firstEnd)
  }

  @Test func countersNeverDecrease() {
    var harness = Self.harness()
    var previous = harness.state.events
    func check(_ harness: ScenarioHarness) {
      let current = harness.state.events
      #expect(current.holdErrorEpisodes >= previous.holdErrorEpisodes)
      #expect(current.holdErrorsWhileBusy >= previous.holdErrorsWhileBusy)
      #expect(current.batteryReleases >= previous.batteryReleases)
      #expect(current.busyStartsBelowFloor >= previous.busyStartsBelowFloor)
      #expect(current.stuckReleases >= previous.stuckReleases)
      #expect(current.unexpectedSleeps >= previous.unexpectedSleeps)
      previous = current
    }
    Self.failFirstAcquire(&harness, Self.busyAt(&harness, 0), at: 0.01)
    check(harness)
    _ = harness.send(.systemWillSleep, at: 1)
    check(harness)
    _ = harness.send(.systemHasPoweredOn, at: 2)
    check(harness)
    _ = harness.send(.power(.battery(percent: 5)), at: 3)
    check(harness)
    _ = harness.send(.power(.ac(percent: 90)), at: 4)
    check(harness)
    _ = harness.send(.command(.releaseUntilIdle), at: 5)
    check(harness)
    _ = harness.send(.stop, at: 6)
    check(harness)
    for second in stride(from: 7.0, through: 400, by: 7) {
      _ = harness.tick(at: second, caffeinate: true)
      check(harness)
    }
    #expect(previous.holdErrorEpisodes == 1)
    #expect(previous.unexpectedSleeps == 1)
    #expect(previous.batteryReleases == 1)
  }

  @Test func theCountersAreNotPersisted() throws {
    var harness = Self.harness()
    Self.failFirstAcquire(&harness, Self.busyAt(&harness, 0), at: 0.01)
    _ = harness.send(.systemWillSleep, at: 1)
    #expect(harness.state.events != EventCounters())
    var zeroed = harness.state
    zeroed.events = EventCounters()
    #expect(Reducer.persistedState(harness.state) == Reducer.persistedState(zeroed))
    let labels = Mirror(reflecting: harness.state.persisted).children.compactMap(\.label)
    #expect(!labels.contains("events"))
    let encoded = try JSONEncoder().encode(harness.state.persisted)
    let text = String(decoding: encoded, as: UTF8.self)
    for name in ["events", "holdError", "batteryReleases", "stuckReleases", "unexpectedSleeps", "forceSince"] {
      #expect(!text.contains(name))
    }
  }
}
