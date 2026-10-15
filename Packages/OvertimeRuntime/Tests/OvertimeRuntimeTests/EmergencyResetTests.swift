import Foundation
import OvertimeClamshell
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing
import os

final class EmergencyRecorder: Sendable {
  private let entries = OSAllocatedUnfairLock<[String]>(initialState: [])
  private let decisions = OSAllocatedUnfairLock<[Decision]>(initialState: [])

  var actions: [String] { entries.withLock { $0 } }
  var logged: [Decision] { decisions.withLock { $0 } }

  func append(_ entry: String) {
    entries.withLock { $0.append(entry) }
  }

  func log(_ decision: Decision) {
    decisions.withLock { $0.append(decision) }
  }
}

final class FakeEmergencySelector: ClamshellSelector {
  let recorder: EmergencyRecorder
  let stateFile: URL
  let result: kern_return_t
  let blocks: Bool
  let entered = DispatchSemaphore(value: 0)
  let unblock = DispatchSemaphore(value: 0)
  private let writes = OSAllocatedUnfairLock(initialState: 0)

  init(recorder: EmergencyRecorder, stateFile: URL, result: kern_return_t = KERN_SUCCESS, blocks: Bool = false) {
    self.recorder = recorder
    self.stateFile = stateFile
    self.result = result
    self.blocks = blocks
  }

  var writeCount: Int { writes.withLock { $0 } }

  func waitUntilEntered(seconds: Double = 2) -> Bool {
    entered.wait(timeout: .now() + seconds) == .success
  }

  func write(on: Bool) -> kern_return_t {
    writes.withLock { $0 += 1 }
    recorder.append((on ? "set" : "clear") + EmergencyResetTests.ownership(stateFile))
    if blocks {
      entered.signal()
      _ = unblock.wait(timeout: .now() + FakeHelperClear.heldSeconds)
    }
    return result
  }
}

final class FakeHelperClear: Sendable {
  static let entry = "helper clear"
  static let heldSeconds: Double = 10

  private struct Counts: Sendable {
    var started = 0
    var returned = 0
  }

  let recorder: EmergencyRecorder
  let result: Bool
  let blocks: Bool
  let unblock = DispatchSemaphore(value: 0)
  private let counts = OSAllocatedUnfairLock(initialState: Counts())

  init(recorder: EmergencyRecorder, result: Bool = true, blocks: Bool = false) {
    self.recorder = recorder
    self.result = result
    self.blocks = blocks
  }

  var calls: Int { counts.withLock { $0.started } }
  var returned: Int { counts.withLock { $0.returned } }

  func run() -> Bool {
    counts.withLock { $0.started += 1 }
    recorder.append(Self.entry)
    if blocks {
      _ = unblock.wait(timeout: .now() + Self.heldSeconds)
    }
    counts.withLock { $0.returned += 1 }
    return result
  }
}

struct EmergencyResetTests {
  static let cutSeconds: Double = 5
  static let helperFirst: Comment =
    "Restore normal sleep now also asks the helper to clear through its own short-lived, bounded call when the helper is installed, before the app's own emergency clear"
  static let helperNeverBlocks: Comment =
    "a failed or timed-out helper clear never blocks the clamshell clear or the assertion release"
  static let helperNotClaimed: Comment =
    "S-CR-01: the outcome carries whether the helper cleared, so a failed or timed-out helper clear is never reported as a full restore"
  static let touchesNothing: Comment = "the path never touches the sentinel, the interpreter or the engine"
  static let prohibition: Comment =
    "MUST NOT let the emergency path disarm, close or retire the sentinel, reuse the holder's clamshell runner key, or wait on a hung helper before clearing the app's own bit"

  static let helperFailed = Decision(
    keyword: .error, verb: "emergency helper", fields: [DecisionField(key: "clear", value: "failed")])
  static let helperTimedOut = Decision(
    keyword: .error, verb: "emergency helper", fields: [DecisionField(key: "clear", value: "timedOut")])

  static func restored(_ released: Int) -> Decision {
    Decision(
      keyword: .hold, verb: "emergency",
      fields: [
        DecisionField(key: "clear", value: "succeeded"), DecisionField(key: "released", value: String(released)),
      ])
  }

  static let owned = PersistedState(
    bootSessionUUID: "boot", ownsHold: true, sentinelArmed: true, switchedToHotspot: true,
    pause: PersistedPause(kind: PersistedPause.indefinite), releaseUntilIdle: true, forceActive: true)

  static func ownership(_ stateFile: URL) -> String {
    guard case .state(let state) = StateStore.read(at: stateFile) else { return "" }
    return state.ownsHold ? " owned" : " released"
  }

  struct Harness {
    let temp: TempDirectory
    let stateFile: URL
    let recorder = EmergencyRecorder()
    let registry = AssertionRegistry()
    let selector: FakeEmergencySelector

    init(result: kern_return_t = KERN_SUCCESS, blocks: Bool = false) throws {
      temp = try TempDirectory()
      stateFile = temp.url.appendingPathComponent("state.json")
      selector = FakeEmergencySelector(recorder: recorder, stateFile: stateFile, result: result, blocks: blocks)
    }

    func helper(result: Bool = true, blocks: Bool = false) -> FakeHelperClear {
      FakeHelperClear(recorder: recorder, result: result, blocks: blocks)
    }

    func reset(
      opener: (@Sendable () throws -> any ClamshellSelector)? = nil, releaseResult: Int32 = 0,
      timeoutSeconds: Double = 2, helper: FakeHelperClear? = nil, runner: DeadlineRunner = DeadlineRunner()
    ) -> EmergencyReset {
      let selector = selector
      let recorder = recorder
      let stateFile = stateFile
      var helperClear: (@Sendable () -> Bool)?
      if let helper {
        helperClear = { helper.run() }
      }
      return EmergencyReset(
        opener: opener ?? { selector },
        registry: registry,
        release: { id in
          recorder.append("release \(id)" + EmergencyResetTests.ownership(stateFile))
          return releaseResult
        },
        log: { recorder.log($0) },
        runner: runner,
        timeoutSeconds: timeoutSeconds,
        helperClear: helperClear
      )
    }
  }

  @Test func clearsThenReleasesAndLeavesTheOwnedStateFileByteIdentical() async throws {
    let harness = try Harness()
    try StateStore.write(Self.owned, to: harness.stateFile)
    let before = FileManager.default.contents(atPath: harness.stateFile.path(percentEncoded: false))
    harness.registry.record(.preventUserIdleSystemSleep, id: 11)
    harness.registry.record(.preventUserIdleDisplaySleep, id: 12)
    let outcome = await harness.reset().run()
    #expect(outcome == .restored(released: 2, helperCleared: true))
    #expect(harness.recorder.actions == ["clear owned", "release 11 owned", "release 12 owned"])
    #expect(StateStore.read(at: harness.stateFile) == .state(Self.owned))
    #expect(FileManager.default.contents(atPath: harness.stateFile.path(percentEncoded: false)) == before)
    #expect(harness.registry.snapshot().isEmpty)
    #expect(
      harness.recorder.logged == [
        Decision(
          keyword: .hold, verb: "emergency",
          fields: [
            DecisionField(key: "clear", value: "succeeded"), DecisionField(key: "released", value: "2"),
          ])
      ])
  }

  @Test func withNothingRegisteredAndNoStateFileItStillClearsAndCreatesNoStateFile() async throws {
    let harness = try Harness()
    let outcome = await harness.reset().run()
    #expect(outcome == .restored(released: 0, helperCleared: true))
    #expect(harness.recorder.actions == ["clear"])
    #expect(!FileManager.default.fileExists(atPath: harness.stateFile.path(percentEncoded: false)))
  }

  @Test func aCorruptStateFileIsLeftByteIdentical() async throws {
    let harness = try Harness()
    let garbage = Data("{\"ownsHold\": tru".utf8)
    try garbage.write(to: harness.stateFile)
    let outcome = await harness.reset().run()
    #expect(outcome == .restored(released: 0, helperCleared: true))
    #expect(FileManager.default.contents(atPath: harness.stateFile.path(percentEncoded: false)) == garbage)
  }

  @Test func aStateFileThatNoLongerOwnsTheHoldIsNotRewritten() async throws {
    let harness = try Harness()
    var released = Self.owned
    released.ownsHold = false
    try StateStore.write(released, to: harness.stateFile)
    let before = FileManager.default.contents(atPath: harness.stateFile.path(percentEncoded: false))
    #expect(await harness.reset().run() == .restored(released: 0, helperCleared: true))
    #expect(FileManager.default.contents(atPath: harness.stateFile.path(percentEncoded: false)) == before)
  }

  @Test func anOpenerThatThrowsFailsTheClearKeepsOwnershipAndStillReleases() async throws {
    let harness = try Harness()
    try StateStore.write(Self.owned, to: harness.stateFile)
    harness.registry.record(.preventUserIdleSystemSleep, id: 21)
    let reset = harness.reset(opener: { throw ClamshellWriterError.openFailed(-536_870_201) })
    #expect(await reset.run() == .clearFailed("-536870201", helperCleared: true))
    #expect(harness.recorder.actions == ["release 21 owned"])
    #expect(StateStore.read(at: harness.stateFile) == .state(Self.owned))
    #expect(harness.registry.snapshot().isEmpty)
    #expect(
      harness.recorder.logged == [
        Decision(
          keyword: .error, verb: "emergency",
          fields: [
            DecisionField(key: "clear", value: "failed"), DecisionField(key: "code", value: "-536870201"),
            DecisionField(key: "released", value: "1"),
          ])
      ])
  }

  @Test func aServiceThatCannotBeFoundFailsTheClear() async throws {
    let harness = try Harness()
    let reset = harness.reset(opener: { throw ClamshellWriterError.serviceNotFound })
    #expect(await reset.run() == .clearFailed(String(EmergencyReset.openFailedCode), helperCleared: true))
  }

  @Test func aFailedWriteKeepsOwnership() async throws {
    let harness = try Harness(result: -536_870_212)
    try StateStore.write(Self.owned, to: harness.stateFile)
    harness.registry.record(.preventUserIdleDisplaySleep, id: 31)
    #expect(await harness.reset().run() == .clearFailed("-536870212", helperCleared: true))
    #expect(harness.recorder.actions == ["clear owned", "release 31 owned"])
    #expect(StateStore.read(at: harness.stateFile) == .state(Self.owned))
  }

  @Test func aReleaseThatFailsKeepsItsIDRegistered() async throws {
    let harness = try Harness()
    harness.registry.record(.preventUserIdleSystemSleep, id: 41)
    #expect(await harness.reset(releaseResult: -536_870_160).run() == .restored(released: 0, helperCleared: true))
    #expect(harness.registry.current(.preventUserIdleSystemSleep) == 41)
  }

  @Test func aHungWriteFailsWithinTheBoundAndKeepsOwnership() async throws {
    let harness = try Harness(blocks: true)
    try StateStore.write(Self.owned, to: harness.stateFile)
    harness.registry.record(.preventUserIdleSystemSleep, id: 51)
    let outcome = await harness.reset(timeoutSeconds: Self.cutSeconds).run()
    harness.selector.unblock.signal()
    #expect(outcome == .clearFailed("timedOut", helperCleared: true))
    #expect(StateStore.read(at: harness.stateFile) == .state(Self.owned))
    #expect(harness.registry.snapshot().isEmpty)
    #expect(harness.recorder.logged.first?.fields.first == DecisionField(key: "clear", value: "timedOut"))
  }

  @Test func twoOverlappingRunsClearOnce() async throws {
    let harness = try Harness(blocks: true)
    let reset = harness.reset()
    let first = Task { await reset.run() }
    let selector = harness.selector
    #expect(await OffPool.run { selector.waitUntilEntered(seconds: 5) })
    #expect(await reset.run() == .inProgress)
    harness.selector.unblock.signal()
    #expect(await first.value == .restored(released: 0, helperCleared: true))
    #expect(harness.selector.writeCount == 1)
    harness.selector.unblock.signal()
    #expect(await reset.run() == .restored(released: 0, helperCleared: true))
    #expect(harness.selector.writeCount == 2)
  }

  @Test func theResetHoldsNoSentinelInterpreterOrEngine() throws {
    let harness = try Harness()
    for reset in [harness.reset(), harness.reset(helper: harness.helper())] {
      for child in Mirror(reflecting: reset).children {
        #expect(!(child.value is any SentinelPort), Self.touchesNothing)
        #expect(!(child.value is LiveInterpreter), Self.touchesNothing)
        #expect(!(child.value is Engine), Self.touchesNothing)
        #expect(!(child.value is any EffectInterpreter), Self.touchesNothing)
        #expect(!(child.value is any HelperPort), Self.touchesNothing)
      }
    }
  }

  @Test func withAHelperClearTheResetAsksTheHelperOnceBeforeItsOwnClearAndTheRelease() async throws {
    let harness = try Harness()
    try StateStore.write(Self.owned, to: harness.stateFile)
    let before = FileManager.default.contents(atPath: harness.stateFile.path(percentEncoded: false))
    harness.registry.record(.preventUserIdleSystemSleep, id: 11)
    let helper = harness.helper()
    let outcome = await harness.reset(helper: helper).run()
    #expect(outcome == .restored(released: 1, helperCleared: true))
    #expect(harness.recorder.actions == [FakeHelperClear.entry, "clear owned", "release 11 owned"], Self.helperFirst)
    #expect(helper.calls == 1, Self.helperFirst)
    #expect(harness.recorder.logged == [Self.restored(1)])
    #expect(FileManager.default.contents(atPath: harness.stateFile.path(percentEncoded: false)) == before)
    #expect(harness.registry.snapshot().isEmpty)
  }

  @Test func aHelperClearThatFailsIsLoggedAndTheClamshellClearAndTheAssertionReleaseStillRun() async throws {
    let harness = try Harness()
    try StateStore.write(Self.owned, to: harness.stateFile)
    harness.registry.record(.preventUserIdleDisplaySleep, id: 61)
    let helper = harness.helper(result: false)
    let outcome = await harness.reset(helper: helper).run()
    #expect(outcome == .restored(released: 1, helperCleared: false), Self.helperNeverBlocks)
    #expect(outcome != .restored(released: 1, helperCleared: true), Self.helperNotClaimed)
    #expect(
      harness.recorder.actions == [FakeHelperClear.entry, "clear owned", "release 61 owned"], Self.helperNeverBlocks)
    #expect(harness.recorder.logged == [Self.helperFailed, Self.restored(1)])
    #expect(harness.registry.snapshot().isEmpty, Self.helperNeverBlocks)
    #expect(StateStore.read(at: harness.stateFile) == .state(Self.owned))
  }

  @Test func aHelperClearThatHangsIsCutAtTheBoundAndTheClamshellClearAndTheAssertionReleaseStillRun() async throws {
    let harness = try Harness()
    try StateStore.write(Self.owned, to: harness.stateFile)
    harness.registry.record(.preventUserIdleSystemSleep, id: 71)
    let helper = harness.helper(blocks: true)
    let start = ContinuousClock.now
    let outcome = await harness.reset(timeoutSeconds: Self.cutSeconds, helper: helper).run()
    let elapsed = ContinuousClock.now - start
    #expect(helper.returned == 0, Self.prohibition)
    helper.unblock.signal()
    #expect(outcome == .restored(released: 1, helperCleared: false), Self.helperNotClaimed)
    #expect(elapsed >= .seconds(Self.cutSeconds))
    #expect(
      harness.recorder.actions == [FakeHelperClear.entry, "clear owned", "release 71 owned"], Self.helperNeverBlocks)
    #expect(harness.recorder.logged == [Self.helperTimedOut, Self.restored(1)])
    #expect(await OffPool.eventually { helper.returned == 1 })
  }

  @Test func whileAHelperClearThatOutlivedItsBoundStillRunsTheNextResetDoesNotAskTheHelperAgain() async throws {
    let harness = try Harness()
    let helper = harness.helper(blocks: true)
    let runner = DeadlineRunner()
    let first = harness.reset(timeoutSeconds: Self.cutSeconds, helper: helper, runner: runner)
    let next = harness.reset(timeoutSeconds: 30, helper: helper, runner: runner)
    #expect(await first.run() == .restored(released: 0, helperCleared: false), Self.helperNotClaimed)
    #expect(helper.calls == 1)
    #expect(helper.returned == 0)
    #expect(await next.run() == .restored(released: 0, helperCleared: false), Self.helperNotClaimed)
    #expect(helper.returned == 0, Self.prohibition)
    #expect(helper.calls == 1)
    #expect(harness.recorder.actions == [FakeHelperClear.entry, "clear", "clear"])
    #expect(
      harness.recorder.logged == [Self.helperTimedOut, Self.restored(0), Self.helperTimedOut, Self.restored(0)])
    helper.unblock.signal()
    #expect(await OffPool.eventually { helper.returned == 1 && runner.outstandingCount == 0 })
  }

  @Test func aFailedHelperClearAndAFailedClamshellClearStillReleaseTheAssertions() async throws {
    let harness = try Harness()
    harness.registry.record(.preventUserIdleSystemSleep, id: 81)
    let helper = harness.helper(result: false)
    let reset = harness.reset(opener: { throw ClamshellWriterError.openFailed(-536_870_201) }, helper: helper)
    #expect(
      await reset.run() == .clearFailed("-536870201", helperCleared: false),
      "R2-WR-03: a failed restore keeps the helper result")
    #expect(harness.recorder.actions == [FakeHelperClear.entry, "release 81"], Self.helperNeverBlocks)
    #expect(harness.registry.snapshot().isEmpty)
    #expect(harness.recorder.logged.first == Self.helperFailed)
    #expect(harness.recorder.logged.count == 2)
    #expect(harness.recorder.logged.last?.verb == "emergency")
    #expect(harness.recorder.logged.last?.keyword == .error)
  }

  @Test func twoOverlappingRunsAskTheHelperOnce() async throws {
    let harness = try Harness()
    let helper = harness.helper(blocks: true)
    let reset = harness.reset(helper: helper)
    let first = Task { await reset.run() }
    #expect(await OffPool.eventually { helper.calls == 1 })
    #expect(await reset.run() == .inProgress)
    helper.unblock.signal()
    #expect(await first.value == .restored(released: 0, helperCleared: true))
    #expect(helper.calls == 1)
    #expect(harness.selector.writeCount == 1)
    #expect(harness.recorder.logged == [Self.restored(0)])
  }

  @Test func theHelperClearHasARunnerKeyOfItsOwn() {
    #expect(EmergencyReset.helperRunnerKey == "emergency-helper")
    let own = [EmergencyReset.clearRunnerKey, EmergencyReset.assertionRunnerKey, EmergencyReset.helperRunnerKey]
    #expect(Set(own).count == 3)
    let holders = [
      LiveInterpreter.clamshellRunnerKey, LiveInterpreter.helperRunnerKey,
      LiveInterpreter.runnerKey(forClamshellWrite: true), LiveInterpreter.runnerKey(forClamshellWrite: false),
    ]
    #expect(Set(own).isDisjoint(with: holders), Self.prohibition)
  }

  @Test func theHelperLogLineReadsErrorEmergencyHelper() {
    let wall = Date(timeIntervalSince1970: 1_800_000_000)
    let zone = TimeZone(identifier: "UTC") ?? .current
    #expect(
      DecisionFormatter.line(Self.helperFailed, wall: wall, timeZone: zone)
        .hasSuffix(" ERROR emergency helper clear=failed"))
    #expect(
      DecisionFormatter.line(Self.helperTimedOut, wall: wall, timeZone: zone)
        .hasSuffix(" ERROR emergency helper clear=timedOut"))
  }
}
