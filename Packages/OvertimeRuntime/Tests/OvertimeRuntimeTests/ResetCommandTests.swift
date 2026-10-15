import Foundation
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing
import os

struct ResetCommandTests {
  final class Output: Sendable {
    private let lines = OSAllocatedUnfairLock<[String]>(initialState: [])

    var all: [String] { lines.withLock { $0 } }

    func append(_ line: String) {
      lines.withLock { $0.append(line) }
    }
  }

  struct Harness {
    let temp: TempDirectory
    let stateFile: URL
    let lockFile: URL
    let recorder: HoldRecorder
    let clamshell: FakeClamshellPort
    let output = Output()
    let errors = Output()

    init() throws {
      temp = try TempDirectory()
      stateFile = URL(fileURLWithPath: temp.path).appendingPathComponent("state.json")
      lockFile = URL(fileURLWithPath: temp.path).appendingPathComponent("live.lock")
      recorder = HoldRecorder(stateFile: stateFile)
      clamshell = FakeClamshellPort(recorder: recorder)
    }

    func run(instanceName: String, followUp: (@Sendable () -> Bool)?) -> Int32 {
      let output = output
      return ResetCommand.run(
        clamshell: clamshell, stateFile: stateFile, lockFile: lockFile, out: { output.append($0) },
        instanceName: instanceName, followUp: followUp)
    }

    func run(timeoutSeconds: Double = Timing.systemCallTimeoutSeconds) -> Int32 {
      let output = output
      return ResetCommand.run(
        clamshell: clamshell, stateFile: stateFile, lockFile: lockFile, timeoutSeconds: timeoutSeconds,
        out: { output.append($0) })
    }

    func run(
      helper: HelperClears, timeoutSeconds: Double = Timing.systemCallTimeoutSeconds,
      followUp: (@Sendable () -> Bool)? = nil
    ) async -> Int32 {
      let clamshell = clamshell
      let stateFile = stateFile
      let lockFile = lockFile
      let output = output
      let recorder = recorder
      return await OffPool.run {
        ResetCommand.run(
          clamshell: clamshell, stateFile: stateFile, lockFile: lockFile, timeoutSeconds: timeoutSeconds,
          out: { output.append($0) }, instanceName: Paths.releaseAppName, followUp: followUp,
          helperClear: { helper.run(clamshellWritesSoFar: recorder.all.count) })
      }
    }

    func run(helper: HelperClears, opener: @escaping @Sendable () throws -> any ClamshellPort) async -> Int32 {
      let stateFile = stateFile
      let lockFile = lockFile
      let output = output
      let errors = errors
      let recorder = recorder
      return await OffPool.run {
        ResetCommand.run(
          openClamshell: opener, stateFile: stateFile, lockFile: lockFile, out: { output.append($0) },
          err: { errors.append($0) }, instanceName: Paths.releaseAppName,
          helperClear: { helper.run(clamshellWritesSoFar: recorder.all.count) })
      }
    }
  }

  struct WriterUnavailable: Error {}

  static let helperEvenWithoutAWriter: Comment =
    "R2-WR-03: Overtime --reset asks the helper before it opens the clamshell writer, and still asks it when the writer can't be opened"

  @Test func whenTheClamshellWriterCannotBeOpenedTheHelperIsStillAskedAndItsResultPrinted() async throws {
    let harness = try Harness()
    let helper = HelperClears(answer: false)
    let code = await harness.run(helper: helper, opener: { throw WriterUnavailable() })
    #expect(code == ResetCommand.clamshellUnavailableExitCode)
    #expect(ResetCommand.clamshellUnavailableExitCode == 71)
    #expect(helper.calls == 1, Self.helperEvenWithoutAWriter)
    #expect(harness.output.all == [Self.helperUnconfirmed], Self.helperEvenWithoutAWriter)
    #expect(harness.errors.all.count == 1)
    #expect(harness.errors.all.first?.hasPrefix("cannot open the clamshell writer: ") == true)
    #expect(harness.recorder.all.isEmpty)
  }

  @Test func theHelperIsAskedBeforeTheClamshellWriterIsOpened() async throws {
    let harness = try Harness()
    let helper = HelperClears()
    let callsAtOpen = OSAllocatedUnfairLock<[Int]>(initialState: [])
    let clamshell = harness.clamshell
    let code = await harness.run(
      helper: helper,
      opener: {
        callsAtOpen.withLock { $0.append(helper.calls) }
        return clamshell
      })
    #expect(code == 0)
    #expect(callsAtOpen.withLock { $0 } == [1], Self.helperEvenWithoutAWriter)
    #expect(harness.output.all == ["reset: clamshell cleared"])
    #expect(harness.errors.all.isEmpty)
  }

  final class HelperClears: Sendable {
    private struct Seen: Sendable {
      var calls = 0
      var returned = 0
      var clamshellWritesBefore: [Int] = []
    }

    let answer: Bool
    let blocks: Bool
    let unblock = DispatchSemaphore(value: 0)
    private let seen = OSAllocatedUnfairLock(initialState: Seen())

    init(answer: Bool = true, blocks: Bool = false) {
      self.answer = answer
      self.blocks = blocks
    }

    var calls: Int { seen.withLock { $0.calls } }
    var returned: Int { seen.withLock { $0.returned } }
    var clamshellWritesBefore: [Int] { seen.withLock { $0.clamshellWritesBefore } }

    func run(clamshellWritesSoFar: Int) -> Bool {
      seen.withLock { seen in
        seen.calls += 1
        seen.clamshellWritesBefore.append(clamshellWritesSoFar)
      }
      if blocks {
        _ = unblock.wait(timeout: .now() + FakeHelperClear.heldSeconds)
      }
      seen.withLock { $0.returned += 1 }
      return answer
    }
  }

  static let helperFirst: Comment =
    "Overtime --reset sends the clear-only helper clear before the app's own clear, because the restore failure copy sends the user to it (decision 03-20 c)"
  static let ownClearAlways: Comment =
    "a failed or timed-out helper clear never blocks the app's own clear or the state file update"
  static let helperUnconfirmed =
    "reset: unplug protection didn't confirm that system sleep is back on. If the Mac won't sleep, run: sudo pmset -a disablesleep 0"

  @Test func resetAsksTheHelperOnceBeforeItsOwnClearAndSaysNothingMoreWhenItCleared() async throws {
    let harness = try Harness()
    try StateStore.write(Self.owned, to: harness.stateFile)
    let helper = HelperClears()
    #expect(await harness.run(helper: helper) == 0)
    #expect(helper.calls == 1, Self.helperFirst)
    #expect(helper.clamshellWritesBefore == [0], Self.helperFirst)
    #expect(harness.recorder.all == [.clamshell(on: false, fileOwnsHold: true)])
    #expect(harness.output.all == ["reset: clamshell cleared"])
    guard case .state(let stored) = StateStore.read(at: harness.stateFile) else {
      Issue.record("no state file")
      return
    }
    #expect(!stored.ownsHold)
  }

  @Test func aHelperClearThatFailsStillClearsTheAppsOwnHoldSaysSoAndReturnsOne() async throws {
    let harness = try Harness()
    try StateStore.write(Self.owned, to: harness.stateFile)
    let helper = HelperClears(answer: false)
    #expect(await harness.run(helper: helper) == 1)
    #expect(harness.recorder.all == [.clamshell(on: false, fileOwnsHold: true)], Self.ownClearAlways)
    #expect(harness.output.all == [Self.helperUnconfirmed, "reset: clamshell cleared"])
    guard case .state(let stored) = StateStore.read(at: harness.stateFile) else {
      Issue.record("no state file")
      return
    }
    #expect(!stored.ownsHold, Self.ownClearAlways)
  }

  @Test func aHelperClearThatHangsIsCutAtTheBoundAndTheAppsOwnClearStillRuns() async throws {
    let harness = try Harness()
    let helper = HelperClears(blocks: true)
    let code = await harness.run(helper: helper, timeoutSeconds: 5)
    #expect(helper.returned == 0, Self.ownClearAlways)
    helper.unblock.signal()
    #expect(code == 1)
    #expect(harness.recorder.all == [.clamshell(on: false, fileOwnsHold: nil)], Self.ownClearAlways)
    #expect(harness.output.all == [Self.helperUnconfirmed, "reset: clamshell cleared"])
    #expect(await OffPool.eventually { helper.returned == 1 })
  }

  @Test func aFailedOwnClearAfterAConfirmedHelperClearStillReturnsOne() async throws {
    let harness = try Harness()
    harness.clamshell.queueOutcomes([.failed(code: 5)])
    let helper = HelperClears()
    #expect(await harness.run(helper: helper) == 1)
    #expect(helper.calls == 1)
    #expect(harness.output.all == ["reset: clear failed (code 5)"])
  }

  @Test func aLiveInstanceStillGetsTheHelperClearAndAnUnconfirmedClearExitsOneAheadOfTheLiveCode() async throws {
    let harness = try Harness()
    let live = try InstanceLock.acquire(at: harness.lockFile)
    defer { live.release() }
    let helper = HelperClears(answer: false)
    let followUps = FollowUps(answer: true)
    #expect(
      await harness.run(helper: helper, followUp: followUps.closure) == 1,
      "R2-IN-05: an unconfirmed helper clear exits 1 even with a live instance")
    #expect(helper.calls == 1)
    #expect(followUps.calls == 1)
    #expect(harness.output.all.first == Self.helperUnconfirmed)
    #expect(harness.output.all.dropFirst().first == "reset: clamshell cleared")
  }

  @Test func aLiveInstanceWithAConfirmedHelperClearKeepsItsExitCode() async throws {
    let harness = try Harness()
    let live = try InstanceLock.acquire(at: harness.lockFile)
    defer { live.release() }
    let helper = HelperClears()
    let followUps = FollowUps(answer: true)
    #expect(await harness.run(helper: helper, followUp: followUps.closure) == ResetCommand.liveInstanceExitCode)
    #expect(helper.calls == 1)
    #expect(harness.output.all.first == "reset: clamshell cleared")
  }

  static let owned = PersistedState(
    bootSessionUUID: "boot", ownsHold: true, sentinelArmed: true, switchedToHotspot: true,
    pause: PersistedPause(kind: PersistedPause.indefinite), releaseUntilIdle: true)

  @Test func resetClearsTheBitAndDropsOwnershipKeepingOverrides() throws {
    let harness = try Harness()
    try StateStore.write(Self.owned, to: harness.stateFile)
    #expect(harness.run() == 0)
    #expect(harness.recorder.all == [.clamshell(on: false, fileOwnsHold: true)])
    #expect(harness.output.all == ["reset: clamshell cleared"])
    guard case .state(let stored) = StateStore.read(at: harness.stateFile) else {
      Issue.record("no state file")
      return
    }
    var expected = Self.owned
    expected.ownsHold = false
    expected.sentinelArmed = false
    #expect(stored == expected)
  }

  @Test func resetWithoutAStateFileClearsAndCreatesNothing() throws {
    let harness = try Harness()
    #expect(harness.run() == 0)
    #expect(harness.recorder.all == [.clamshell(on: false, fileOwnsHold: nil)])
    #expect(StateStore.read(at: harness.stateFile) == .missing)
  }

  @Test func resetLeavesACorruptStateFileAlone() throws {
    let harness = try Harness()
    try Data("{not json".utf8).write(to: harness.stateFile)
    #expect(harness.run() == 0)
    #expect(try Data(contentsOf: harness.stateFile) == Data("{not json".utf8))
  }

  @Test(arguments: [EffectOutcome.failed(code: 5), .timedOut])
  func aFailedClearReturnsOneAndLeavesTheFileUnchanged(_ outcome: EffectOutcome) throws {
    let harness = try Harness()
    try StateStore.write(Self.owned, to: harness.stateFile)
    let before = try Data(contentsOf: harness.stateFile)
    harness.clamshell.queueOutcomes([outcome])
    #expect(harness.run() == 1)
    #expect(try Data(contentsOf: harness.stateFile) == before)
    #expect(harness.output.all.count == 1)
    #expect(harness.output.all.first?.hasPrefix("reset: clear failed") == true)
  }

  @Test func aHungClearTimesOutAndReturnsOne() throws {
    let harness = try Harness()
    try StateStore.write(Self.owned, to: harness.stateFile)
    harness.clamshell.blockNextWrite(seconds: 10)
    let started = ContinuousClock.now
    #expect(harness.run(timeoutSeconds: 0.2) == 1)
    #expect(ContinuousClock.now - started < .seconds(5))
    #expect(harness.output.all == ["reset: clear failed (timed out)"])
    guard case .state(let stored) = StateStore.read(at: harness.stateFile) else {
      Issue.record("no state file")
      return
    }
    #expect(stored.ownsHold)
  }

  @Test func aLiveInstanceKeepsItsStateFileAndIsReported() throws {
    let harness = try Harness()
    try StateStore.write(Self.owned, to: harness.stateFile)
    let before = try Data(contentsOf: harness.stateFile)
    let live = try InstanceLock.acquire(at: harness.lockFile)
    defer { live.release() }
    #expect(harness.run() == ResetCommand.liveInstanceExitCode)
    #expect(harness.recorder.all == [.clamshell(on: false, fileOwnsHold: true)])
    #expect(try Data(contentsOf: harness.stateFile) == before)
    #expect(harness.output.all.first == "reset: clamshell cleared")
    #expect(harness.output.all.last?.contains("overtimed ctl pause") == true)
  }

  final class FollowUps: Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)
    let answer: Bool

    init(answer: Bool) {
      self.answer = answer
    }

    var calls: Int { count.withLock { $0 } }

    var closure: @Sendable () -> Bool {
      { [self] in
        count.withLock { $0 += 1 }
        return answer
      }
    }
  }

  @Test func aLiveInstanceThatTookReleaseUntilIdleIsReportedAsSent() throws {
    let harness = try Harness()
    try StateStore.write(Self.owned, to: harness.stateFile)
    let before = try Data(contentsOf: harness.stateFile)
    let live = try InstanceLock.acquire(at: harness.lockFile)
    defer { live.release() }
    let followUps = FollowUps(answer: true)
    #expect(harness.run(instanceName: "overtimed", followUp: followUps.closure) == 75)
    #expect(followUps.calls == 1)
    #expect(try Data(contentsOf: harness.stateFile) == before)
    #expect(
      harness.output.all == [
        "reset: clamshell cleared",
        "reset: a live overtimed is running; it was sent Release until idle, so it will not re-assert its hold "
          + "until Claude goes idle. The state file was left alone.",
      ])
  }

  @Test func aRefusedFollowUpKeepsTheOvertimedAdvice() throws {
    let harness = try Harness()
    let live = try InstanceLock.acquire(at: harness.lockFile)
    defer { live.release() }
    let followUps = FollowUps(answer: false)
    #expect(harness.run(instanceName: "overtimed", followUp: followUps.closure) == 75)
    #expect(followUps.calls == 1)
    #expect(harness.output.all.last?.contains("overtimed ctl pause") == true)
  }

  @Test func theAppVariantNamesOvertimeAndItsMenu() throws {
    let harness = try Harness()
    let live = try InstanceLock.acquire(at: harness.lockFile)
    defer { live.release() }
    #expect(harness.run(instanceName: "Overtime", followUp: FollowUps(answer: false).closure) == 75)
    let refused = try #require(harness.output.all.last)
    #expect(refused.contains("a live Overtime is running"))
    #expect(refused.contains("Choose Pause in its menu or quit it first."))
    #expect(!refused.contains("overtimed"))
    #expect(harness.run(instanceName: "Overtime", followUp: FollowUps(answer: true).closure) == 75)
    let sent = try #require(harness.output.all.last)
    #expect(sent.hasPrefix("reset: a live Overtime is running; it was sent Release until idle"))
  }

  @Test func withoutALiveInstanceTheFollowUpIsNeverCalled() throws {
    let harness = try Harness()
    try StateStore.write(Self.owned, to: harness.stateFile)
    let followUps = FollowUps(answer: true)
    #expect(harness.run(instanceName: "Overtime", followUp: followUps.closure) == 0)
    #expect(followUps.calls == 0)
    #expect(harness.output.all == ["reset: clamshell cleared"])
  }

  @Test func aFailedClearNeverCallsTheFollowUp() throws {
    let harness = try Harness()
    let live = try InstanceLock.acquire(at: harness.lockFile)
    defer { live.release() }
    harness.clamshell.queueOutcomes([.failed(code: 5)])
    let followUps = FollowUps(answer: true)
    #expect(harness.run(instanceName: "Overtime", followUp: followUps.closure) == 1)
    #expect(followUps.calls == 0)
  }

  @Test func resetHoldsTheInstanceLockOnlyWhileItRuns() throws {
    let harness = try Harness()
    try StateStore.write(Self.owned, to: harness.stateFile)
    #expect(harness.run() == 0)
    let after = try InstanceLock.acquire(at: harness.lockFile)
    after.release()
  }

  @Test func resetParsesAloneAndRejectsOtherArguments() throws {
    #expect(try CommandLineOptions.parseInvocation(["--reset"]) == .reset)
    for arguments in [["--reset", "--live"], ["--reset", "--shadow"], ["--live", "--reset"], ["--reset", "--once"]] {
      #expect(throws: CommandLineError.self) {
        try CommandLineOptions.parseInvocation(arguments)
      }
    }
    #expect(CommandLineOptions.usageMessage.contains("overtimed --reset"))
  }
}
