import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing
import os

@testable import OvertimeAppSupport

final class FakeNotificationPort: NotificationPort {
  private struct State {
    var authorization: NotificationAuthorization
    var postResult = true
    var posted: [NotificationIntent] = []
    var calls: [String] = []
  }

  private let state: OSAllocatedUnfairLock<State>

  init(authorization: NotificationAuthorization = .authorized) {
    state = OSAllocatedUnfairLock(initialState: State(authorization: authorization))
  }

  var posted: [NotificationIntent] {
    state.withLock { $0.posted }
  }

  var calls: [String] {
    state.withLock { $0.calls }
  }

  var authorizationReads: Int {
    calls.filter { $0 == "authorization" }.count
  }

  var requestedAuthorization: Bool {
    calls.contains("requestAuthorization")
  }

  func setAuthorization(_ authorization: NotificationAuthorization) {
    state.withLock { $0.authorization = authorization }
  }

  func setPostResult(_ result: Bool) {
    state.withLock { $0.postResult = result }
  }

  func authorization() async -> NotificationAuthorization {
    state.withLock { state in
      state.calls.append("authorization")
      return state.authorization
    }
  }

  func requestAuthorization() async -> NotificationAuthorization {
    state.withLock { state in
      state.calls.append("requestAuthorization")
      return state.authorization
    }
  }

  func post(_ intent: NotificationIntent) async -> Bool {
    state.withLock { state in
      state.calls.append("post")
      guard state.postResult else { return false }
      state.posted.append(intent)
      return true
    }
  }

  @discardableResult
  func wait(seconds: Double = 5, until predicate: @Sendable (FakeNotificationPort) -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
      if predicate(self) { return true }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return predicate(self)
  }
}

final class DecisionRecorder: Sendable {
  private let lines = OSAllocatedUnfairLock<[Decision]>(initialState: [])

  var decisions: [Decision] {
    lines.withLock { $0 }
  }

  func record(_ decision: Decision) {
    lines.withLock { $0.append(decision) }
  }
}

final class ScriptedSnapshotHost: EngineHosting {
  let clock: any ClockPort
  let engineToken = UUID()
  private struct State {
    var continuation: AsyncStream<EngineSnapshot>.Continuation?
    var pending: [EngineSnapshot] = []
    var subscriptions = 0
    var terminated = 0
    var helperUpdates: [HelperFacts] = []
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  init(clock: any ClockPort = FakeClock()) {
    self.clock = clock
  }

  var subscriptions: Int {
    state.withLock { $0.subscriptions }
  }

  var terminated: Int {
    state.withLock { $0.terminated }
  }

  func yield(_ snapshot: EngineSnapshot) {
    let continuation = state.withLock { state -> AsyncStream<EngineSnapshot>.Continuation? in
      if state.continuation == nil { state.pending.append(snapshot) }
      return state.continuation
    }
    continuation?.yield(snapshot)
  }

  func finish() {
    state.withLock { $0.continuation }?.finish()
  }

  func snapshots() async -> AsyncStream<EngineSnapshot> {
    let (stream, continuation) = AsyncStream.makeStream(of: EngineSnapshot.self)
    let state = state
    continuation.onTermination = { _ in
      state.withLock { $0.terminated += 1 }
    }
    let pending = state.withLock { state -> [EngineSnapshot] in
      state.continuation = continuation
      state.subscriptions += 1
      defer { state.pending.removeAll() }
      return state.pending
    }
    for snapshot in pending {
      continuation.yield(snapshot)
    }
    return stream
  }

  func send(_ request: CtlRequest) async -> CtlResponse? {
    nil
  }

  func probe() async -> EngineSnapshot? {
    nil
  }

  func apply(settings: Settings) async -> Bool {
    true
  }

  func requestSelfTest() async {}

  var helperUpdates: [HelperFacts] {
    state.withLock { $0.helperUpdates }
  }

  func updateHelper(_ facts: HelperFacts) async {
    state.withLock { $0.helperUpdates.append(facts) }
  }
}

struct NotificationPolicyTests {
  static let start = Instant(nanoseconds: 1_000_000_000_000)

  static func snapshot(
    holdErrorsWhileBusy: UInt64 = 0, holdErrorEpisodes: UInt64? = nil, busy: Bool? = true
  ) -> EngineSnapshot {
    EngineSnapshot(
      busy: busy,
      events: EventCounters(
        holdErrorEpisodes: holdErrorEpisodes ?? holdErrorsWhileBusy, holdErrorsWhileBusy: holdErrorsWhileBusy))
  }

  static func step(
    _ state: inout NotificationPolicyState, _ snapshot: EngineSnapshot, at seconds: Double = 0,
    preferences: AppPreferences = AppPreferences(), authorization: NotificationAuthorization = .authorized
  ) -> [NotificationIntent] {
    NotificationPolicy.step(
      &state, snapshot: snapshot, preferences: preferences, authorization: authorization,
      now: start.adding(seconds: seconds))
  }

  static func categories(_ intents: [NotificationIntent]) -> [NotificationCategory] {
    intents.map(\.category)
  }

  @Test func aHoldErrorWhileBusyPostsOneKeepAwakeFailedIntent() {
    var state = NotificationPolicyState()
    let intents = Self.step(&state, Self.snapshot(holdErrorsWhileBusy: 1))
    #expect(intents.count == 1)
    let intent = intents.first
    #expect(intent?.category == .keepAwakeFailed)
    #expect(intent?.title == "Keep-awake failed")
    #expect(
      intent?.body
        == "Overtime couldn't keep the Mac awake while Claude is working, and will retry. Until it succeeds, the Mac may sleep."
    )
    #expect(intent?.sound == true)
    #expect(intent?.turnOffAction == false)
    #expect(intent?.identifier == "overtime.keepAwakeFailed")
    #expect(intent?.threadIdentifier == "overtime.keepAwakeFailed")
  }

  @Test func theSameSnapshotAgainPostsNothing() {
    var state = NotificationPolicyState()
    let snapshot = Self.snapshot(holdErrorsWhileBusy: 1)
    #expect(Self.step(&state, snapshot).count == 1)
    #expect(Self.step(&state, snapshot, at: 700).isEmpty)
    #expect(Self.step(&state, snapshot, at: 1_400).isEmpty)
  }

  @Test func aSwitchedOffCategoryPostsNothing() {
    var state = NotificationPolicyState()
    var preferences = AppPreferences()
    preferences.notifications["keepAwakeFailed"] = false
    #expect(Self.step(&state, Self.snapshot(holdErrorsWhileBusy: 1), preferences: preferences).isEmpty)
    #expect(state.lastPosted.isEmpty)
  }

  @Test(arguments: [NotificationAuthorization.denied, .notDetermined])
  func withoutAuthorizationEveryIntentIsDropped(_ authorization: NotificationAuthorization) {
    var state = NotificationPolicyState()
    #expect(Self.step(&state, Self.snapshot(holdErrorsWhileBusy: 1), authorization: authorization).isEmpty)
    #expect(Self.step(&state, Self.snapshot(holdErrorsWhileBusy: 1), at: 5).isEmpty)
    #expect(state.lastPosted.isEmpty)
  }

  @Test func provisionalAuthorizationPosts() {
    var state = NotificationPolicyState()
    #expect(Self.step(&state, Self.snapshot(holdErrorsWhileBusy: 1), authorization: .provisional).count == 1)
  }

  @Test func theCapDropsASecondIntentAt599SecondsAndAdmitsOneAt600() {
    var state = NotificationPolicyState()
    #expect(Self.step(&state, Self.snapshot(holdErrorsWhileBusy: 1), at: 0).count == 1)
    #expect(Self.step(&state, Self.snapshot(holdErrorsWhileBusy: 2), at: 599).isEmpty)
    #expect(Self.step(&state, Self.snapshot(holdErrorsWhileBusy: 3), at: 600).count == 1)
    #expect(Self.step(&state, Self.snapshot(holdErrorsWhileBusy: 4), at: 1_199).isEmpty)
  }

  @Test func aReplayedOlderSnapshotPostsNothing() {
    var state = NotificationPolicyState()
    #expect(Self.step(&state, Self.snapshot(holdErrorsWhileBusy: 2), at: 0).count == 1)
    #expect(Self.step(&state, Self.snapshot(holdErrorsWhileBusy: 1), at: 700).isEmpty)
    #expect(Self.step(&state, Self.snapshot(holdErrorsWhileBusy: 2), at: 1_400).isEmpty)
    #expect(Self.step(&state, Self.snapshot(holdErrorsWhileBusy: 3), at: 2_100).count == 1)
  }

  @Test func aHoldErrorWhileNotBusyPostsNothing() {
    var state = NotificationPolicyState()
    let snapshot = Self.snapshot(holdErrorsWhileBusy: 0, holdErrorEpisodes: 1, busy: false)
    #expect(Self.step(&state, snapshot).isEmpty)
  }

  static func selfTest(
    _ status: SelfTestStatus, failures: UInt64, runs: UInt64, errorActive: Bool? = nil, holdErrorsWhileBusy: UInt64 = 0
  ) -> EngineSnapshot {
    var active = false
    if case .failed = status { active = true }
    return EngineSnapshot(
      busy: false, wanted: false, reason: "idle",
      events: EventCounters(holdErrorEpisodes: holdErrorsWhileBusy, holdErrorsWhileBusy: holdErrorsWhileBusy),
      selfTest: status, selfTestErrorActive: errorActive ?? active, selfTestFailures: failures, selfTestRuns: runs,
      osBuild: "99Z999")
  }

  static let refused = SelfTestStatus.failed(.clamshellRefused(Int32(bitPattern: 0xE000_02C2)))

  @Test func aSelfTestFailurePostsOneKeepAwakeFailedWithTheSelfTestCopy() {
    var state = NotificationPolicyState()
    #expect(Self.step(&state, Self.selfTest(.running, failures: 0, runs: 1)).isEmpty)
    let intents = Self.step(&state, Self.selfTest(Self.refused, failures: 1, runs: 1))
    #expect(intents.count == 1)
    let intent = intents.first
    #expect(intent?.category == .keepAwakeFailed)
    #expect(intent?.title == "Keep-awake self-test failed")
    #expect(
      intent?.body
        == "Overtime's lid-close control failed its test. Until it passes, the Mac may sleep with the lid closed. Open Settings > Diagnostics for details."
    )
    #expect(intent?.sound == true)
    #expect(intent?.turnOffAction == false)
    #expect(intent?.identifier == "overtime.keepAwakeFailed")
    #expect(Self.step(&state, Self.selfTest(Self.refused, failures: 1, runs: 1), at: 700).isEmpty)
  }

  @Test func aSecondFailureBeforeAPassPostsNothingEvenAfterTheCap() {
    var state = NotificationPolicyState()
    #expect(Self.step(&state, Self.selfTest(.failed(.timedOut), failures: 1, runs: 1)).count == 1)
    #expect(Self.step(&state, Self.selfTest(.running, failures: 1, runs: 2), at: 700).isEmpty)
    #expect(Self.step(&state, Self.selfTest(Self.refused, failures: 2, runs: 2), at: 701).isEmpty)
    #expect(Self.step(&state, Self.selfTest(.failed(.watchdogNotRunning), failures: 3, runs: 3), at: 1_500).isEmpty)
    #expect(state.selfTestFailures == 3)
  }

  @Test func aPassThenANewFailurePostsAgain() {
    var state = NotificationPolicyState()
    #expect(Self.step(&state, Self.selfTest(.failed(.timedOut), failures: 1, runs: 1)).count == 1)
    #expect(Self.step(&state, Self.selfTest(.passed, failures: 1, runs: 2), at: 700).isEmpty)
    let again = Self.step(&state, Self.selfTest(Self.refused, failures: 2, runs: 3), at: 1_400)
    #expect(again.map(\.title) == ["Keep-awake self-test failed"])
    #expect(Self.step(&state, Self.selfTest(.failed(.timedOut), failures: 3, runs: 4), at: 2_100).isEmpty)
  }

  @Test(arguments: [
    SelfTestStatus.skipped(.amphetamine), .skipped(.otherTool("Keeper")), .skipped(.sleepDisabled),
  ])
  func aSkippedSelfTestPostsNothingAndDoesNotEndAFailureStreak(_ skipped: SelfTestStatus) {
    var fresh = NotificationPolicyState()
    #expect(Self.step(&fresh, Self.selfTest(skipped, failures: 0, runs: 0)).isEmpty)
    #expect(Self.step(&fresh, Self.selfTest(skipped, failures: 0, runs: 0), at: 700).isEmpty)
    #expect(fresh.lastPosted.isEmpty)
    var state = NotificationPolicyState()
    #expect(Self.step(&state, Self.selfTest(.failed(.timedOut), failures: 1, runs: 1)).count == 1)
    #expect(Self.step(&state, Self.selfTest(skipped, failures: 1, runs: 1, errorActive: true), at: 700).isEmpty)
    #expect(Self.step(&state, Self.selfTest(.failed(.timedOut), failures: 2, runs: 2), at: 1_400).isEmpty)
  }

  @Test func aSuccessfulLidCloseEngageDoesNotEndTheStreak() {
    var state = NotificationPolicyState()
    #expect(Self.step(&state, Self.selfTest(.failed(.timedOut), failures: 1, runs: 1)).count == 1)
    #expect(
      Self.step(&state, Self.selfTest(.failed(.timedOut), failures: 1, runs: 1, errorActive: false), at: 700).isEmpty)
    #expect(Self.step(&state, Self.selfTest(.failed(.timedOut), failures: 2, runs: 2), at: 1_400).isEmpty)
  }

  @Test func aFailureAlreadyFollowedByAPassPostsNothing() {
    var state = NotificationPolicyState()
    #expect(Self.step(&state, Self.selfTest(.passed, failures: 1, runs: 2)).isEmpty)
    #expect(state.selfTestFailures == 1)
    #expect(Self.step(&state, Self.selfTest(.passed, failures: 1, runs: 2), at: 700).isEmpty)
    #expect(Self.step(&state, Self.selfTest(Self.refused, failures: 2, runs: 3), at: 1_400).count == 1)
  }

  @Test func aSelfTestFailureSharesTheKeepAwakeFailedSwitchAndCap() {
    var off = NotificationPolicyState()
    var preferences = AppPreferences()
    preferences.notifications["keepAwakeFailed"] = false
    #expect(Self.step(&off, Self.selfTest(Self.refused, failures: 1, runs: 1), preferences: preferences).isEmpty)
    #expect(off.lastPosted.isEmpty)
    #expect(Self.step(&off, Self.selfTest(Self.refused, failures: 1, runs: 1), at: 700).isEmpty)

    var capped = NotificationPolicyState()
    #expect(Self.step(&capped, Self.snapshot(holdErrorsWhileBusy: 1)).map(\.title) == ["Keep-awake failed"])
    let failed = Self.selfTest(Self.refused, failures: 1, runs: 1, holdErrorsWhileBusy: 1)
    #expect(Self.step(&capped, failed, at: 599).isEmpty)
    #expect(Self.step(&capped, failed, at: 1_300).isEmpty)
  }

  @Test func aHoldFailureAndASelfTestFailureInOneSnapshotPostTheHoldFailureOnly() {
    var state = NotificationPolicyState()
    let both = Self.selfTest(Self.refused, failures: 1, runs: 1, holdErrorsWhileBusy: 1)
    #expect(Self.step(&state, both).map(\.title) == ["Keep-awake failed"])
    #expect(Self.step(&state, both, at: 700).isEmpty)
  }

  @Test func aReplayedOlderSelfTestSnapshotPostsNothing() {
    var state = NotificationPolicyState()
    #expect(Self.step(&state, Self.selfTest(.failed(.timedOut), failures: 2, runs: 2)).count == 1)
    #expect(Self.step(&state, Self.selfTest(.passed, failures: 2, runs: 3), at: 700).isEmpty)
    #expect(Self.step(&state, Self.selfTest(.failed(.timedOut), failures: 1, runs: 1), at: 1_400).isEmpty)
    #expect(Self.step(&state, Self.selfTest(.failed(.timedOut), failures: 2, runs: 2), at: 2_100).isEmpty)
  }

  @Test func theCoordinatorPostsASelfTestFailureOncePerStreakAndNeverForASkip() async {
    let port = FakeNotificationPort()
    let clock = FakeClock()
    let host = ScriptedSnapshotHost(clock: clock)
    let log = DecisionRecorder()
    let coordinator = NotificationCoordinator(
      port: port, preferences: { AppPreferences() }, log: { log.record($0) })
    defer { coordinator.stop() }
    coordinator.start(host: host)
    host.yield(Self.selfTest(.skipped(.sleepDisabled), failures: 0, runs: 0))
    host.yield(Self.selfTest(.running, failures: 0, runs: 1))
    host.yield(Self.selfTest(Self.refused, failures: 1, runs: 1))
    #expect(await port.wait { $0.posted.count == 1 })
    #expect(port.posted.map(\.title) == ["Keep-awake self-test failed"])
    clock.advance(seconds: NotificationPolicy.capSeconds)
    host.yield(Self.selfTest(.failed(.timedOut), failures: 2, runs: 2))
    host.yield(Self.selfTest(.passed, failures: 2, runs: 3))
    host.yield(Self.selfTest(.failed(.timedOut), failures: 3, runs: 4))
    #expect(await port.wait { $0.posted.count == 2 })
    #expect(port.posted.map(\.title) == ["Keep-awake self-test failed", "Keep-awake self-test failed"])
    #expect(port.authorizationReads == 2)
    #expect(!port.requestedAuthorization)
    let logged = await Self.waitFor { log.decisions.count == 2 }
    #expect(logged)
    #expect(
      log.decisions.map { Self.text($0) }
        == ["WARN notify category=keepAwakeFailed", "WARN notify category=keepAwakeFailed"])
  }

  static func battery(
    releases: UInt64 = 0, belowStarts: UInt64 = 0, power: PowerReading? = .battery(percent: 9),
    lidClosed: Bool? = false, busy: Bool? = true, low: Int = 10, resume: Int = 20
  ) -> EngineSnapshot {
    EngineSnapshot(
      busy: busy, batteryBlocked: true, lidClosed: lidClosed, batteryLowPercent: low, batteryResumePercent: resume,
      power: power, events: EventCounters(batteryReleases: releases, busyStartsBelowFloor: belowStarts))
  }

  @Test func aBatteryReleaseWithTheLidOpenPostsBatteryFloorOncePerCycle() {
    var state = NotificationPolicyState()
    let intents = Self.step(&state, Self.battery(releases: 1, low: 15, resume: 30))
    #expect(Self.categories(intents) == [.batteryFloor])
    #expect(intents.first?.title == "Battery low")
    #expect(
      intents.first?.body
        == "Battery at 15%. Overtime stopped keeping the Mac awake. Plug in to keep working with the lid closed.")
    #expect(intents.first?.sound == true)
    #expect(intents.first?.identifier == "overtime.batteryFloor")
    #expect(Self.step(&state, Self.battery(releases: 2, low: 15, resume: 30), at: 700).isEmpty)
    #expect(Self.step(&state, Self.battery(releases: 3, low: 15, resume: 30), at: 1_400).isEmpty)
  }

  @Test(arguments: [
    PowerReading.ac(percent: 50), .ac(percent: nil), .noBattery, .battery(percent: 20), .battery(percent: 35),
  ])
  func aResetReadingStartsANewDischargeCycle(_ reset: PowerReading) {
    var state = NotificationPolicyState()
    #expect(Self.step(&state, Self.battery(releases: 1)).count == 1)
    #expect(Self.step(&state, Self.battery(releases: 1, power: reset), at: 10).isEmpty)
    #expect(Self.categories(Self.step(&state, Self.battery(releases: 2), at: 700)) == [.batteryFloor])
  }

  @Test(arguments: [PowerReading.battery(percent: 19), .battery(percent: nil)])
  func aReadingBelowTheResumeLevelKeepsTheCycle(_ reading: PowerReading) {
    var state = NotificationPolicyState()
    #expect(Self.step(&state, Self.battery(releases: 1)).count == 1)
    #expect(Self.step(&state, Self.battery(releases: 1, power: reading), at: 10).isEmpty)
    #expect(Self.step(&state, Self.battery(releases: 2), at: 700).isEmpty)
  }

  @Test func aBatteryReleaseWithTheLidClosedPostsNoBatteryFloor() {
    var state = NotificationPolicyState()
    #expect(Self.step(&state, Self.battery(releases: 1, lidClosed: true)).isEmpty)
    #expect(Self.step(&state, Self.battery(releases: 1, lidClosed: false), at: 10).isEmpty)
    #expect(state.lastPosted.isEmpty)
  }

  @Test func aReleaseSeenTogetherWithAResetReadingPostsNothing() {
    var state = NotificationPolicyState()
    #expect(Self.step(&state, Self.battery(releases: 1, power: .ac(percent: 9))).isEmpty)
    #expect(Self.step(&state, Self.battery(releases: 1), at: 10).isEmpty)
    #expect(Self.categories(Self.step(&state, Self.battery(releases: 2), at: 20)) == [.batteryFloor])
  }

  @Test func claudeStartingBelowTheFloorPostsBelowFloorAtStartOncePerCycle() {
    var state = NotificationPolicyState()
    let intents = Self.step(&state, Self.battery(belowStarts: 1, power: .battery(percent: 8)))
    #expect(Self.categories(intents) == [.belowFloorAtStart])
    #expect(intents.first?.title == "Battery too low to keep awake")
    #expect(
      intents.first?.body
        == "Claude started with the battery at 8%. Overtime won't keep the Mac awake below 10%. Plug in to keep working with the lid closed."
    )
    #expect(intents.first?.sound == true)
    #expect(Self.step(&state, Self.battery(belowStarts: 2, power: .battery(percent: 7)), at: 700).isEmpty)
    #expect(Self.step(&state, Self.battery(belowStarts: 2, power: .ac(percent: 7)), at: 710).isEmpty)
    let next = Self.step(&state, Self.battery(belowStarts: 3, power: .battery(percent: 6), low: 12), at: 1_400)
    #expect(
      next.first?.body
        == "Claude started with the battery at 6%. Overtime won't keep the Mac awake below 12%. Plug in to keep working with the lid closed."
    )
  }

  @Test func anUnknownPercentSaysBelowTheFloor() {
    var state = NotificationPolicyState()
    let intents = Self.step(&state, Self.battery(belowStarts: 1, power: .battery(percent: nil)))
    #expect(
      intents.first?.body
        == "Claude started with the battery below 10%. Overtime won't keep the Mac awake below 10%. Plug in to keep working with the lid closed."
    )
  }

  @Test func theTwoBatteryCyclesAreIndependent() {
    var state = NotificationPolicyState()
    #expect(Self.categories(Self.step(&state, Self.battery(releases: 1))) == [.batteryFloor])
    #expect(
      Self.categories(Self.step(&state, Self.battery(releases: 1, belowStarts: 1), at: 5)) == [.belowFloorAtStart])
    #expect(Self.step(&state, Self.battery(releases: 2, belowStarts: 2), at: 700).isEmpty)
  }

  @Test func lidEventsPausesStopsAndAFinishPostNothing() {
    var state = NotificationPolicyState()
    let counters = EventCounters(
      holdErrorEpisodes: 2, holdErrorsWhileBusy: 1, batteryReleases: 1, busyStartsBelowFloor: 1)
    #expect(Self.step(&state, EngineSnapshot(busy: true, wanted: true, events: counters)).count == 3)
    let quiet: [EngineSnapshot] = [
      EngineSnapshot(busy: true, wanted: true, lidClosed: true, events: counters),
      EngineSnapshot(busy: true, wanted: true, lidClosed: false, events: counters),
      EngineSnapshot(busy: true, wanted: false, reason: "paused", pause: .indefinite, events: counters),
      EngineSnapshot(busy: true, wanted: true, reason: "busy", events: counters),
      EngineSnapshot(busy: false, wanted: true, reason: "busy", events: counters),
      EngineSnapshot(busy: false, wanted: false, reason: "idle", events: counters),
      EngineSnapshot(busy: nil, wanted: nil, events: counters),
      EngineSnapshot(busy: false, wanted: true, reason: "force", force: .indefinite, events: counters),
    ]
    for (index, snapshot) in quiet.enumerated() {
      #expect(Self.step(&state, snapshot, at: Double(index + 1) * 700).isEmpty)
    }
  }

  static func lid(
    _ closed: Bool?, hold: UInt64 = 0, stuck: UInt64 = 0, battery: UInt64 = 0, sleeps: UInt64 = 0
  ) -> EngineSnapshot {
    LidClosedJournalTests.snapshot(lid: closed, hold: hold, stuck: stuck, battery: battery, sleeps: sleeps)
  }

  @Test func aQuietLidCloseAndOpenPostsNothing() {
    var state = NotificationPolicyState()
    let snapshots = [Self.lid(false), Self.lid(true), Self.lid(nil), Self.lid(true), Self.lid(false)]
    for (index, snapshot) in snapshots.enumerated() {
      #expect(Self.step(&state, snapshot, at: Double(index) * 700).isEmpty)
    }
    #expect(state.journal == nil)
  }

  @Test func aBatteryReleaseAndTwoHoldErrorsWhileClosedPostOneSummaryAtLidOpen() {
    var state = NotificationPolicyState()
    let closed = [
      Self.lid(false), Self.lid(true), Self.lid(true, battery: 1), Self.lid(true, hold: 1, battery: 1),
      Self.lid(true, hold: 2, battery: 1),
    ]
    for (index, snapshot) in closed.enumerated() {
      #expect(Self.step(&state, snapshot, at: Double(index)).isEmpty)
    }
    let intents = Self.step(&state, Self.lid(false, hold: 2, battery: 1), at: 10)
    #expect(Self.categories(intents) == [.lidClosedSummary])
    #expect(intents.first?.title == "While the lid was closed")
    #expect(
      intents.first?.body
        == "Battery reached 10%, so Overtime let the Mac sleep.\nKeep-awake failed 2 times and was retried.")
    #expect(intents.first?.identifier == "overtime.lidClosedSummary")
    #expect(intents.first?.sound == false)
    #expect(state.journal == nil)
    #expect(Self.step(&state, Self.lid(false, hold: 2, battery: 1), at: 700).isEmpty)
    #expect(Self.step(&state, Self.lid(true, hold: 2, battery: 1), at: 800).isEmpty)
    #expect(Self.step(&state, Self.lid(false, hold: 2, battery: 1), at: 900).isEmpty)
  }

  @Test func eventsInTheClosingOrOpeningSnapshotCount() {
    var state = NotificationPolicyState()
    #expect(Self.step(&state, Self.lid(false)).isEmpty)
    #expect(Self.step(&state, Self.lid(true, stuck: 1), at: 1).isEmpty)
    let intents = Self.step(&state, Self.lid(false, stuck: 1, sleeps: 1), at: 2)
    #expect(
      intents.first?.body
        == "A Claude session looked stuck, so Overtime stopped counting it.\nThe Mac slept while Claude was working.")
  }

  @Test func moreThanThreeEventsShowThreeLinesAndTheMoreLine() {
    var state = NotificationPolicyState(sentinelClearPending: true)
    let closed = [
      Self.lid(true), Self.lid(true, battery: 1), Self.lid(true, stuck: 1, battery: 1),
      Self.lid(true, hold: 1, stuck: 1, battery: 1), Self.lid(true, hold: 1, stuck: 1, battery: 1, sleeps: 1),
    ]
    for (index, snapshot) in closed.enumerated() {
      #expect(Self.step(&state, snapshot, at: Double(index)).isEmpty)
    }
    let intents = Self.step(&state, Self.lid(false, hold: 1, stuck: 1, battery: 1, sleeps: 1), at: 10)
    #expect(
      intents.first?.body.components(separatedBy: "\n") == [
        "Overtime stopped unexpectedly. Its watchdog restored normal sleep.",
        "Battery reached 10%, so Overtime let the Mac sleep.",
        "A Claude session looked stuck, so Overtime stopped counting it.",
        "And 2 more. Details are in the log.",
      ])
  }

  @Test(arguments: [true, false])
  func aDroppedSummaryStillDropsTheJournal(_ switchedOff: Bool) {
    var state = NotificationPolicyState()
    var preferences = AppPreferences()
    preferences.notifications["lidClosedSummary"] = !switchedOff
    let authorization: NotificationAuthorization = switchedOff ? .authorized : .denied
    for (index, snapshot) in [Self.lid(false), Self.lid(true), Self.lid(true, battery: 1)].enumerated() {
      #expect(Self.step(&state, snapshot, at: Double(index)).isEmpty)
    }
    let dropped = Self.step(
      &state, Self.lid(false, battery: 1), at: 5, preferences: preferences, authorization: authorization)
    #expect(dropped.isEmpty)
    #expect(state.journal == nil)
    #expect(state.lastPosted.isEmpty)
    #expect(Self.step(&state, Self.lid(true, battery: 1), at: 10).isEmpty)
    #expect(Self.step(&state, Self.lid(false, battery: 1), at: 20).isEmpty)
  }

  @Test func theLidClosedSummaryRespectsTheCap() {
    var state = NotificationPolicyState()
    #expect(Self.step(&state, Self.lid(true), at: 0).isEmpty)
    #expect(Self.step(&state, Self.lid(false, stuck: 1), at: 1).count == 1)
    #expect(Self.step(&state, Self.lid(true, stuck: 1), at: 2).isEmpty)
    #expect(Self.step(&state, Self.lid(false, stuck: 2), at: 600).isEmpty)
    #expect(Self.step(&state, Self.lid(true, stuck: 2), at: 602).isEmpty)
    #expect(Self.categories(Self.step(&state, Self.lid(false, stuck: 3), at: 603)) == [.lidClosedSummary])
  }

  static func forced(
    since: Double? = 0, busy: Bool? = false, busyEndedAt: Double? = nil, force: ForceState? = .indefinite,
    power: PowerReading? = nil
  ) -> EngineSnapshot {
    EngineSnapshot(
      busy: busy, wanted: true, reason: "force", force: force, power: power,
      events: EventCounters(
        forceSince: since.map { start.adding(seconds: $0) }, busyEndedAt: busyEndedAt.map { start.adding(seconds: $0) })
    )
  }

  static func reminderPreferences(hours: Int = 3, enabled: Bool = true) -> AppPreferences {
    var preferences = AppPreferences()
    preferences.forceReminderHours = hours
    preferences.notifications["forceReminder"] = enabled
    return preferences
  }

  static func remind(
    _ state: inout NotificationPolicyState, _ snapshot: EngineSnapshot, at seconds: Double, hours: Int = 3,
    enabled: Bool = true
  ) -> [NotificationIntent] {
    step(&state, snapshot, at: seconds, preferences: reminderPreferences(hours: hours, enabled: enabled))
  }

  static func deadline(_ state: NotificationPolicyState, hours: Int = 3) -> Double? {
    NotificationPolicy.nextDeadline(state, hours: hours).map { Double($0.nanoseconds(since: start)) / 1e9 }
  }

  @Test func theReminderPostsAtExactlyTheIntervalAndNotASecondEarlier() {
    var state = NotificationPolicyState()
    #expect(Self.remind(&state, Self.forced(), at: 0).isEmpty)
    #expect(Self.deadline(state) == 10_800)
    #expect(Self.remind(&state, Self.forced(), at: 10_799).isEmpty)
    #expect(Self.deadline(state) == 10_800)
    let intents = Self.remind(&state, Self.forced(), at: 10_800)
    #expect(Self.categories(intents) == [.forceReminder])
    #expect(intents.first?.title == "Keep Awake is still on")
    #expect(intents.first?.body == "Keep Awake has been on for 3 hours with no Claude activity.")
    #expect(intents.first?.turnOffAction == true)
    #expect(intents.first?.sound == false)
    #expect(intents.first?.identifier == "overtime.forceReminder")
    #expect(Self.deadline(state) == nil)
    #expect(Self.remind(&state, Self.forced(), at: 20_000).isEmpty)
    #expect(Self.remind(&state, Self.forced(power: .ac(percent: 90)), at: 40_000).isEmpty)
  }

  @Test(arguments: [1, 2, 12])
  func theIntervalComesFromThePreferences(_ hours: Int) {
    var state = NotificationPolicyState()
    let interval = Double(hours) * 3_600
    #expect(Self.remind(&state, Self.forced(), at: 0, hours: hours).isEmpty)
    #expect(Self.deadline(state, hours: hours) == interval)
    #expect(Self.remind(&state, Self.forced(), at: interval - 1, hours: hours).isEmpty)
    let body = Self.remind(&state, Self.forced(), at: interval, hours: hours).first?.body
    let expected = hours == 1 ? "1 hour" : "\(hours) hours"
    #expect(body == "Keep Awake has been on for \(expected) with no Claude activity.")
  }

  @Test func claudeActivityStartsANewQuietStretch() {
    var state = NotificationPolicyState()
    #expect(Self.remind(&state, Self.forced(), at: 10_800).count == 1)
    #expect(Self.remind(&state, Self.forced(busy: true), at: 11_000).isEmpty)
    #expect(Self.deadline(state) == nil)
    #expect(Self.remind(&state, Self.forced(busyEndedAt: 12_000), at: 12_001).isEmpty)
    #expect(Self.deadline(state) == 22_800)
    #expect(Self.remind(&state, Self.forced(busyEndedAt: 12_000), at: 22_799).isEmpty)
    #expect(Self.categories(Self.remind(&state, Self.forced(busyEndedAt: 12_000), at: 22_800)) == [.forceReminder])
  }

  @Test func aNewForceStartsANewQuietStretch() {
    var state = NotificationPolicyState()
    #expect(Self.remind(&state, Self.forced(), at: 10_800).count == 1)
    #expect(Self.remind(&state, Self.forced(since: nil, force: nil), at: 11_000).isEmpty)
    #expect(Self.deadline(state) == nil)
    #expect(Self.remind(&state, Self.forced(since: 20_000), at: 20_000).isEmpty)
    #expect(Self.deadline(state) == 30_800)
    #expect(Self.categories(Self.remind(&state, Self.forced(since: 20_000), at: 30_800)) == [.forceReminder])
  }

  @Test func theQuietStretchStartsAtTheLaterOfTheForceAndTheLastBusyEnd() {
    var state = NotificationPolicyState()
    #expect(Self.remind(&state, Self.forced(since: 100, busyEndedAt: 50), at: 100).isEmpty)
    #expect(Self.deadline(state) == 10_900)
    #expect(Self.remind(&state, Self.forced(since: 100, busyEndedAt: 400), at: 400).isEmpty)
    #expect(Self.deadline(state) == 11_200)
    #expect(Self.remind(&state, Self.forced(since: 100, busyEndedAt: 400), at: 11_199).isEmpty)
    #expect(Self.remind(&state, Self.forced(since: 100, busyEndedAt: 400), at: 11_200).count == 1)
  }

  @Test func noReminderWhileClaudeIsBusyOrWithoutAForce() {
    var state = NotificationPolicyState()
    let quiet = [
      Self.forced(busy: true), Self.forced(busy: true, busyEndedAt: 5), Self.forced(since: nil, force: nil),
      Self.forced(since: nil), Self.forced(since: 0, force: nil),
    ]
    for snapshot in quiet {
      #expect(Self.remind(&state, snapshot, at: 50_000).isEmpty)
      #expect(Self.deadline(state) == nil)
    }
  }

  @Test(arguments: [NotificationAuthorization.denied, .authorized])
  func aDroppedReminderIsNotRetriedInTheSameStretch(_ authorization: NotificationAuthorization) {
    var state = NotificationPolicyState()
    let enabled = authorization == .denied
    #expect(
      Self.step(
        &state, Self.forced(), at: 10_800, preferences: Self.reminderPreferences(enabled: enabled),
        authorization: authorization
      ).isEmpty)
    #expect(Self.deadline(state) == nil)
    #expect(Self.remind(&state, Self.forced(), at: 20_000).isEmpty)
    #expect(Self.remind(&state, Self.forced(since: 30_000), at: 40_800).count == 1)
  }

  final class DeadlineSleeper: Sendable {
    private let state = OSAllocatedUnfairLock<(starts: [Double], cancellations: Int)>(initialState: ([], 0))

    var starts: [Double] {
      state.withLock { $0.starts }
    }

    var cancellations: Int {
      state.withLock { $0.cancellations }
    }

    func advancing(_ clock: FakeClock) -> @Sendable (Double) async -> Void {
      { seconds in
        self.state.withLock { $0.starts.append(seconds) }
        clock.advance(seconds: seconds)
      }
    }

    func blocking() -> @Sendable (Double) async -> Void {
      { seconds in
        self.state.withLock { $0.starts.append(seconds) }
        try? await Task.sleep(for: .seconds(3_600))
        if Task.isCancelled {
          self.state.withLock { $0.cancellations += 1 }
        }
      }
    }
  }

  @Test(arguments: [3, 2])
  func theCoordinatorWakesOnceAtTheDeadlineAndPostsTheReminder(_ hours: Int) async {
    let port = FakeNotificationPort()
    let clock = FakeClock(mono: Self.start)
    let host = ScriptedSnapshotHost(clock: clock)
    let sleeper = DeadlineSleeper()
    let log = DecisionRecorder()
    let coordinator = NotificationCoordinator(
      port: port, preferences: { Self.reminderPreferences(hours: hours) }, log: { log.record($0) },
      sleep: sleeper.advancing(clock))
    defer { coordinator.stop() }
    coordinator.start(host: host)
    host.yield(Self.forced())
    #expect(await port.wait { $0.posted.count == 1 })
    #expect(port.posted.first?.category == .forceReminder)
    #expect(port.posted.first?.body.contains("\(hours) hours") == true)
    #expect(sleeper.starts == [Double(hours) * 3_600])
    let logged = await Self.waitFor { log.decisions.count == 1 }
    #expect(logged)
    #expect(log.decisions.map { Self.text($0) } == ["WARN notify category=forceReminder"])
    try? await Task.sleep(for: .milliseconds(50))
    #expect(sleeper.starts.count == 1)
  }

  @Test func theDeadlineTaskExistsOnlyWhileAForceIsOnInAQuietStretch() async {
    let port = FakeNotificationPort()
    let clock = FakeClock(mono: Self.start)
    let host = ScriptedSnapshotHost(clock: clock)
    let sleeper = DeadlineSleeper()
    let coordinator = NotificationCoordinator(
      port: port, preferences: { AppPreferences() }, log: { _ in }, sleep: sleeper.blocking())
    coordinator.start(host: host)
    host.yield(Self.snapshot(busy: false))
    host.yield(Self.snapshot(holdErrorsWhileBusy: 1))
    #expect(await port.wait { $0.posted.count == 1 })
    #expect(sleeper.starts.isEmpty)
    host.yield(Self.forced())
    #expect(await Self.waitFor { sleeper.starts.count == 1 })
    #expect(sleeper.starts == [10_800])
    host.yield(Self.forced(power: .ac(percent: 80)))
    host.yield(Self.forced(busy: true))
    #expect(await Self.waitFor { sleeper.cancellations >= 1 })
    #expect(sleeper.starts.count == 1)
    host.yield(Self.forced(since: nil, force: nil))
    host.yield(Self.forced(since: 100))
    #expect(await Self.waitFor { sleeper.starts.count == 2 })
    #expect(sleeper.starts.last == 10_900)
    coordinator.stop()
    #expect(await Self.waitFor { sleeper.cancellations == 2 })
    #expect(port.posted.map(\.category) == [.keepAwakeFailed])
  }

  final class PreferencesBox: Sendable {
    private let stored: OSAllocatedUnfairLock<AppPreferences>

    init(hours: Int) {
      stored = OSAllocatedUnfairLock(initialState: NotificationPolicyTests.reminderPreferences(hours: hours))
    }

    var value: AppPreferences {
      stored.withLock { $0 }
    }

    func set(hours: Int) {
      stored.withLock { $0.forceReminderHours = hours }
    }
  }

  struct ReminderRun {
    let port = FakeNotificationPort()
    let clock = FakeClock(mono: NotificationPolicyTests.start)
    let host: ScriptedSnapshotHost
    let sleeper = DeadlineSleeper()
    let preferences: PreferencesBox
    let coordinator: NotificationCoordinator

    init(hours: Int) {
      host = ScriptedSnapshotHost(clock: clock)
      let preferences = PreferencesBox(hours: hours)
      self.preferences = preferences
      coordinator = NotificationCoordinator(
        port: port, preferences: { preferences.value }, log: { _ in }, sleep: sleeper.blocking())
    }

    func startQuietStretch() async -> Bool {
      coordinator.start(host: host)
      host.yield(NotificationPolicyTests.forced())
      let sleeper = sleeper
      return await NotificationPolicyTests.waitFor { sleeper.starts.count == 1 }
    }

    func change(hours: Int, after seconds: Double) {
      clock.advance(seconds: seconds)
      preferences.set(hours: hours)
      coordinator.preferencesChanged()
    }
  }

  @Test func aShorterIntervalReschedulesThePendingDeadlineAndNeverPostsEarly() async {
    let run = ReminderRun(hours: 3)
    defer { run.coordinator.stop() }
    run.coordinator.preferencesChanged()
    #expect(await run.startQuietStretch())
    #expect(run.sleeper.starts == [10_800])
    run.change(hours: 1, after: 1_800)
    let sleeper = run.sleeper
    #expect(await Self.waitFor { sleeper.starts.count == 2 })
    #expect(run.sleeper.starts == [10_800, 1_800])
    #expect(await Self.waitFor { sleeper.cancellations == 1 })
    #expect(run.port.posted.isEmpty)
  }

  @Test func aShorterIntervalThatHasAlreadyPassedPostsTheReminderAtOnce() async {
    let run = ReminderRun(hours: 3)
    defer { run.coordinator.stop() }
    #expect(await run.startQuietStretch())
    run.change(hours: 1, after: 7_200)
    #expect(await run.port.wait { $0.posted.count == 1 })
    #expect(run.port.posted.first?.category == .forceReminder)
    #expect(run.port.posted.first?.body == "Keep Awake has been on for 1 hour with no Claude activity.")
    let sleeper = run.sleeper
    #expect(await Self.waitFor { sleeper.cancellations == 1 })
    #expect(run.sleeper.starts == [10_800])
    run.change(hours: 2, after: 60)
    run.host.yield(Self.forced(power: .ac(percent: 80)))
    try? await Task.sleep(for: .milliseconds(50))
    #expect(run.port.posted.count == 1)
    #expect(run.sleeper.starts == [10_800])
  }

  @Test func aLongerIntervalMovesTheDeadlineLaterAndPostsNothing() async {
    let run = ReminderRun(hours: 3)
    defer { run.coordinator.stop() }
    #expect(await run.startQuietStretch())
    run.change(hours: 6, after: 1_800)
    let sleeper = run.sleeper
    #expect(await Self.waitFor { sleeper.starts.count == 2 })
    #expect(run.sleeper.starts == [10_800, 19_800])
    #expect(run.port.posted.isEmpty)
  }

  @Test func aPreferenceChangeThatKeepsTheIntervalKeepsTheDeadlineTask() async {
    let run = ReminderRun(hours: 3)
    defer { run.coordinator.stop() }
    #expect(await run.startQuietStretch())
    run.change(hours: 3, after: 0)
    run.host.yield(
      EngineSnapshot(
        busy: false, wanted: true, reason: "force", force: .indefinite,
        events: EventCounters(holdErrorEpisodes: 1, holdErrorsWhileBusy: 1, forceSince: Self.start)))
    #expect(await run.port.wait { $0.posted.count == 1 })
    #expect(run.port.posted.map(\.category) == [.keepAwakeFailed])
    #expect(run.sleeper.starts == [10_800])
    #expect(run.sleeper.cancellations == 0)
  }

  @Test func categoriesMapToTheirPreferenceKeysAndIdentifiers() {
    #expect(NotificationCategory.allCases.map(\.preferenceKey) == AppPreferences.categoryKeys)
    for category in NotificationCategory.allCases {
      #expect(category.identifier == "overtime." + category.rawValue)
      #expect(NotificationCategory(identifier: category.identifier) == category)
    }
    #expect(NotificationCategory(identifier: "keepAwakeFailed") == nil)
  }

  @Test func theCoordinatorPostsOnceThroughThePortAndLogsIt() async {
    let port = FakeNotificationPort()
    let clock = FakeClock()
    let host = ScriptedSnapshotHost(clock: clock)
    let log = DecisionRecorder()
    let coordinator = NotificationCoordinator(
      port: port, preferences: { AppPreferences() }, log: { log.record($0) })
    defer { coordinator.stop() }
    coordinator.start(host: host)
    host.yield(Self.snapshot())
    host.yield(Self.snapshot(holdErrorsWhileBusy: 1))
    host.yield(Self.snapshot(holdErrorsWhileBusy: 1))
    #expect(await port.wait { $0.posted.count == 1 })
    host.yield(Self.snapshot(holdErrorsWhileBusy: 1, holdErrorEpisodes: 2))
    host.yield(Self.snapshot(holdErrorsWhileBusy: 1, busy: false))
    clock.advance(seconds: NotificationPolicy.capSeconds)
    host.yield(Self.snapshot(holdErrorsWhileBusy: 2))
    #expect(await port.wait { $0.posted.count == 2 })
    #expect(port.posted.map(\.category) == [.keepAwakeFailed, .keepAwakeFailed])
    #expect(port.authorizationReads == 2)
    #expect(!port.requestedAuthorization)
    let logged = await Self.waitFor { log.decisions.count == 2 }
    #expect(logged)
    let lines = log.decisions.map { Self.text($0) }
    #expect(lines == ["WARN notify category=keepAwakeFailed", "WARN notify category=keepAwakeFailed"])
  }

  @Test func aDeniedAuthorizationDropsTheIntentWithoutARetryOrAPrompt() async {
    let port = FakeNotificationPort(authorization: .denied)
    let host = ScriptedSnapshotHost()
    let coordinator = NotificationCoordinator(port: port, preferences: { AppPreferences() }, log: { _ in })
    defer { coordinator.stop() }
    coordinator.start(host: host)
    host.yield(Self.snapshot(holdErrorsWhileBusy: 1))
    #expect(await port.wait { $0.authorizationReads == 1 })
    host.yield(Self.snapshot(holdErrorsWhileBusy: 1))
    host.yield(Self.snapshot(holdErrorsWhileBusy: 2))
    #expect(await port.wait { $0.authorizationReads == 2 })
    try? await Task.sleep(for: .milliseconds(50))
    #expect(port.calls == ["authorization", "authorization"])
    #expect(port.posted.isEmpty)
  }

  @Test func aFailedPostIsLoggedAsAnError() async {
    let port = FakeNotificationPort()
    port.setPostResult(false)
    let host = ScriptedSnapshotHost()
    let log = DecisionRecorder()
    let coordinator = NotificationCoordinator(
      port: port, preferences: { AppPreferences() }, log: { log.record($0) })
    defer { coordinator.stop() }
    coordinator.start(host: host)
    host.yield(Self.snapshot(holdErrorsWhileBusy: 1))
    let recorded = await Self.waitFor { !log.decisions.isEmpty }
    #expect(recorded)
    #expect(log.decisions.map { Self.text($0) } == ["ERROR notify failed category=keepAwakeFailed"])
  }

  static let keptAcrossRebind: Comment =
    "S-WR-04: a host restart keeps the 600 s cap and the once-per-cycle and once-per-streak rules; only the engine's counters start again"

  static func barrier(belowStarts: UInt64 = 0, holdErrors: UInt64 = 0) -> EngineSnapshot {
    EngineSnapshot(
      busy: true, batteryBlocked: true, lidClosed: false, batteryLowPercent: 10, batteryResumePercent: 20,
      power: .battery(percent: 9),
      events: EventCounters(
        holdErrorEpisodes: holdErrors, holdErrorsWhileBusy: holdErrors, busyStartsBelowFloor: belowStarts))
  }

  struct Rebound {
    let clock = FakeClock()
    let port = FakeNotificationPort()
    let first: ScriptedSnapshotHost
    let second: ScriptedSnapshotHost
    let coordinator: NotificationCoordinator

    init() {
      first = ScriptedSnapshotHost(clock: clock)
      second = ScriptedSnapshotHost(clock: clock)
      coordinator = NotificationCoordinator(port: port, preferences: { AppPreferences() }, log: { _ in })
      coordinator.start(host: first)
    }

    func rebind() async -> Bool {
      coordinator.rebind(to: second)
      let first = first
      let second = second
      return await NotificationPolicyTests.waitFor { first.terminated == 1 && second.subscriptions == 1 }
    }
  }

  @Test func aRebindReleasesTheOldStreamKeepsTheCapAndStartsFromTheNewEnginesCounters() async {
    let fixture = Rebound()
    defer { fixture.coordinator.stop() }
    fixture.first.yield(Self.snapshot(holdErrorsWhileBusy: 3))
    #expect(await fixture.port.wait { $0.posted.count == 1 })
    #expect(await fixture.rebind())
    fixture.second.yield(Self.snapshot(holdErrorsWhileBusy: 1))
    fixture.second.yield(Self.barrier(belowStarts: 1, holdErrors: 1))
    #expect(await fixture.port.wait { $0.posted.contains { $0.category == .belowFloorAtStart } })
    #expect(fixture.port.posted.map(\.category) == [.keepAwakeFailed, .belowFloorAtStart], Self.keptAcrossRebind)
    fixture.clock.advance(seconds: NotificationPolicy.capSeconds + 1)
    fixture.second.yield(Self.barrier(belowStarts: 1, holdErrors: 2))
    #expect(await fixture.port.wait { $0.posted.count == 3 }, "the new engine's counters start from zero")
    #expect(fixture.port.posted.map(\.category) == [.keepAwakeFailed, .belowFloorAtStart, .keepAwakeFailed])
    #expect(fixture.coordinator.isRunning)
  }

  @Test func aRebindKeepsTheDischargeCycleRule() async {
    let fixture = Rebound()
    defer { fixture.coordinator.stop() }
    fixture.first.yield(Self.battery(belowStarts: 1))
    #expect(await fixture.port.wait { $0.posted.count == 1 })
    #expect(await fixture.rebind())
    fixture.clock.advance(seconds: NotificationPolicy.capSeconds + 1)
    fixture.second.yield(Self.battery(belowStarts: 1))
    fixture.second.yield(Self.barrier(belowStarts: 1, holdErrors: 1))
    #expect(await fixture.port.wait { $0.posted.contains { $0.category == .keepAwakeFailed } })
    #expect(fixture.port.posted.map(\.category) == [.belowFloorAtStart, .keepAwakeFailed], Self.keptAcrossRebind)
  }

  @Test func aRebindKeepsTheSelfTestStreak() async {
    let fixture = Rebound()
    defer { fixture.coordinator.stop() }
    fixture.first.yield(Self.selfTest(Self.refused, failures: 1, runs: 1))
    #expect(await fixture.port.wait { $0.posted.count == 1 })
    #expect(await fixture.rebind())
    fixture.clock.advance(seconds: NotificationPolicy.capSeconds + 1)
    fixture.second.yield(Self.selfTest(Self.refused, failures: 1, runs: 1))
    fixture.second.yield(Self.barrier(belowStarts: 1))
    #expect(await fixture.port.wait { $0.posted.contains { $0.category == .belowFloorAtStart } })
    #expect(fixture.port.posted.map(\.category) == [.keepAwakeFailed, .belowFloorAtStart], Self.keptAcrossRebind)
  }

  @Test func aStopThenARebindStillKeepsTheCap() async {
    let fixture = Rebound()
    defer { fixture.coordinator.stop() }
    fixture.first.yield(Self.snapshot(holdErrorsWhileBusy: 1))
    #expect(await fixture.port.wait { $0.posted.count == 1 })
    fixture.coordinator.stop()
    #expect(await fixture.rebind())
    fixture.second.yield(Self.snapshot(holdErrorsWhileBusy: 1))
    fixture.second.yield(Self.barrier(belowStarts: 1, holdErrors: 1))
    #expect(await fixture.port.wait { $0.posted.contains { $0.category == .belowFloorAtStart } })
    #expect(fixture.port.posted.map(\.category) == [.keepAwakeFailed, .belowFloorAtStart], Self.keptAcrossRebind)
  }

  @Test func aRebindCarriesOnlyThePolicyRulesAndNotTheEnginesCounters() {
    var state = NotificationPolicyState(
      counters: EventCounters(holdErrorsWhileBusy: 4), lastPosted: [.batteryFloor: Instant(nanoseconds: 9)],
      batteryFloorCycleUsed: true, belowFloorCycleUsed: true, sentinelClearPending: true)
    state.lastEvents = EventCounters(holdErrorsWhileBusy: 4)
    state.selfTestFailures = 2
    state.selfTestStreakNotified = true
    state.reminderAnchor = Instant(nanoseconds: 5)
    state.reminderPostedAnchor = Instant(nanoseconds: 5)
    let carried = state.carriedToNewEngine()
    var expected = NotificationPolicyState(
      lastPosted: [.batteryFloor: Instant(nanoseconds: 9)], batteryFloorCycleUsed: true, belowFloorCycleUsed: true,
      sentinelClearPending: true)
    expected.selfTestStreakNotified = true
    #expect(carried == expected)
  }

  @Test func aHoldErrorWhileBusyInTheRealEngineReachesThePortThroughTheHub() async throws {
    let harness = try SnapshotHubTests.LiveHarness()
    let engine = try harness.engine()
    let host = LiveEngineHost(engine: engine, clock: harness.clock)
    let panel = SnapshotRecorder(await host.snapshots())
    defer { panel.cancel() }
    let port = FakeNotificationPort()
    let log = DecisionRecorder()
    let coordinator = NotificationCoordinator(
      port: port, preferences: { AppPreferences() }, log: { log.record($0) })
    defer { coordinator.stop() }
    coordinator.start(host: host)
    let subscribed = await Self.waitFor { host.hub.subscriberCount == 2 }
    #expect(subscribed)

    harness.port.queueAcquireOutcomes([.failed(code: 1)])
    let now = harness.clock.mono()
    let finished = await Engine.bounded(seconds: 5) {
      await engine.step(.transcriptActivity(TranscriptActivity(at: now)))
      await engine.step(.tick(TickFacts()))
    }
    #expect(finished)
    #expect(await port.wait { $0.posted.count == 1 })
    #expect(port.posted.first?.category == .keepAwakeFailed)
    #expect(!port.requestedAuthorization)
    let logged = await Self.waitFor { !log.decisions.isEmpty }
    #expect(logged)
    #expect(log.decisions.map { Self.text($0) } == ["WARN notify category=keepAwakeFailed"])
    #expect(await panel.wait { $0.last?.events.holdErrorsWhileBusy == 1 })
    #expect(!panel.isFinished)
  }

  static func text(_ decision: Decision) -> String {
    let line = DecisionFormatter.line(decision, wall: Date(timeIntervalSince1970: 0), timeZone: .gmt)
    return String(line.split(separator: " ", maxSplits: 1).last ?? "")
  }

  static func waitFor(seconds: Double = 5, _ predicate: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
      if predicate() { return true }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return predicate()
  }
}
