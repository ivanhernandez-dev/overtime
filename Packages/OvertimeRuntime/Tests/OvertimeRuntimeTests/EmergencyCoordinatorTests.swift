import Foundation
import OvertimeAppSupport
import OvertimeClamshell
import OvertimeCore
import OvertimeEngine
import OvertimeHelperClient
import OvertimeHelperCore
import OvertimeSystem
import Testing
import os

final class ScriptedEmergencyReset: EmergencyResetting {
  private let outcome: EmergencyOutcome

  init(_ outcome: EmergencyOutcome) {
    self.outcome = outcome
  }

  func run() async -> EmergencyOutcome {
    outcome
  }
}

final class FollowUpRecorder: Sendable {
  private let state = OSAllocatedUnfairLock<(calls: Int, shown: [RestoreResult], shownBeforeFollowUp: Bool?)>(
    initialState: (0, [], nil))

  var calls: Int { state.withLock { $0.calls } }
  var shown: [RestoreResult] { state.withLock { $0.shown } }
  var shownBeforeFollowUp: Bool? { state.withLock { $0.shownBeforeFollowUp } }

  func show(_ result: RestoreResult) {
    state.withLock { $0.shown.append(result) }
  }

  func called() {
    state.withLock { state in
      state.calls += 1
      state.shownBeforeFollowUp = !state.shown.isEmpty
    }
  }
}

struct EmergencyCoordinatorTests {
  static let cutSeconds: Double = 0.2

  static func coordinator(
    _ outcome: EmergencyOutcome, recorder: FollowUpRecorder, answer: Bool?, delaySeconds: Double = 0,
    followUpBoundSeconds: Double = Timing.systemCallTimeoutSeconds
  ) -> EmergencyCoordinator {
    EmergencyCoordinator(
      reset: ScriptedEmergencyReset(outcome),
      releaseUntilIdle: {
        recorder.called()
        if delaySeconds > 0 { try? await Task.sleep(for: .seconds(delaySeconds)) }
        return answer
      },
      followUpBoundSeconds: followUpBoundSeconds
    )
  }

  @Test func aRestoredResetSendsReleaseUntilIdleOnceAfterShowingTheResult() async {
    let recorder = FollowUpRecorder()
    let coordinator = Self.coordinator(.restored(released: 1, helperCleared: true), recorder: recorder, answer: true)
    let result = await coordinator.restore { recorder.show($0) }
    #expect(recorder.calls == 1)
    #expect(recorder.shownBeforeFollowUp == true)
    #expect(recorder.shown == [RestoreResult(kind: .restored, copy: "Normal sleep restored.")])
    #expect(result == RestoreResult(kind: .restored, copy: "Normal sleep restored.", engineUnresponsive: false))
  }

  static let helperNotClaimed: Comment =
    "S-CR-01: a restore whose helper clear did not succeed never reads \"Normal sleep restored.\"; it says the helper didn't confirm and offers Turn sleep back on…"

  @Test func aRestoreWhoseHelperDidNotClearHasItsOwnCopyAndStillSendsReleaseUntilIdle() async {
    let recorder = FollowUpRecorder()
    let coordinator = Self.coordinator(.restored(released: 1, helperCleared: false), recorder: recorder, answer: true)
    let result = await coordinator.restore { recorder.show($0) }
    #expect(recorder.calls == 1)
    #expect(recorder.shownBeforeFollowUp == true)
    #expect(result.kind == .helperNotCleared, Self.helperNotClaimed)
    #expect(
      result.copy
        == "Overtime released its own hold, but unplug protection didn't confirm that system sleep is back on.",
      Self.helperNotClaimed)
    #expect(result.copy != EmergencyCoordinator.restoredCopy, Self.helperNotClaimed)
    #expect(!result.engineUnresponsive)
    #expect(recorder.shown == [result])
  }

  @Test func aRestoreWhoseHelperDidNotClearWithAWedgedEngineReportsItUnresponsive() async {
    let recorder = FollowUpRecorder()
    let coordinator = Self.coordinator(.restored(released: 0, helperCleared: false), recorder: recorder, answer: nil)
    let result = await coordinator.restore()
    #expect(result.kind == .helperNotCleared)
    #expect(result.engineUnresponsive)
    #expect(result.copy == EmergencyCoordinator.helperNotClearedCopy)
  }

  @Test func aFailedClearStillSendsReleaseUntilIdleAndKeepsTheFailureCopy() async {
    let recorder = FollowUpRecorder()
    let coordinator = Self.coordinator(.clearFailed("timedOut", helperCleared: true), recorder: recorder, answer: true)
    let result = await coordinator.restore { recorder.show($0) }
    #expect(recorder.calls == 1)
    #expect(recorder.shownBeforeFollowUp == true)
    #expect(result.kind == .failed)
    #expect(
      result.copy == "Couldn't restore normal sleep. Run Overtime.app/Contents/MacOS/Overtime --reset in Terminal.")
    #expect(!result.engineUnresponsive)
    #expect(recorder.shown == [result])
  }

  @Test func aFailedClearWhoseHelperDidNotClearNamesSleepDisabled() async {
    let recorder = FollowUpRecorder()
    let coordinator = Self.coordinator(.clearFailed("-1", helperCleared: false), recorder: recorder, answer: true)
    let result = await coordinator.restore { recorder.show($0) }
    #expect(recorder.calls == 1)
    #expect(result.kind == .failed)
    #expect(
      result.copy
        == "Couldn't restore normal sleep, and unplug protection didn't confirm that SleepDisabled is off. "
        + "Run Overtime.app/Contents/MacOS/Overtime --reset in Terminal.",
      "R2-WR-03: when the helper did not clear either, the failure copy names SleepDisabled")
    #expect(recorder.shown == [result])
  }

  @Test func aTimedOutFollowUpMarksTheEngineUnresponsive() async {
    let recorder = FollowUpRecorder()
    let coordinator = Self.coordinator(
      .restored(released: 0, helperCleared: true), recorder: recorder, answer: nil,
      followUpBoundSeconds: Self.cutSeconds)
    let result = await coordinator.restore()
    #expect(recorder.calls == 1)
    #expect(result.engineUnresponsive)
    #expect(result.copy == "Normal sleep restored.")
  }

  @Test func aHungFollowUpIsCutAtItsBound() async {
    let recorder = FollowUpRecorder()
    let coordinator = Self.coordinator(
      .restored(released: 0, helperCleared: true), recorder: recorder, answer: true, delaySeconds: 5,
      followUpBoundSeconds: Self.cutSeconds)
    let result = await coordinator.restore { recorder.show($0) }
    #expect(result.engineUnresponsive)
    #expect(recorder.shown.count == 1)
  }

  @Test func aRefusedFollowUpIsNotUnresponsive() async {
    let recorder = FollowUpRecorder()
    let coordinator = Self.coordinator(.restored(released: 0, helperCleared: true), recorder: recorder, answer: false)
    #expect(await coordinator.restore().engineUnresponsive == false)
    #expect(recorder.calls == 1)
  }

  @Test func aFailedClearWithAWedgedEngineReportsItUnresponsive() async {
    let recorder = FollowUpRecorder()
    let coordinator = Self.coordinator(.clearFailed("-1", helperCleared: true), recorder: recorder, answer: nil)
    let result = await coordinator.restore()
    #expect(recorder.calls == 1)
    #expect(result.kind == .failed)
    #expect(result.engineUnresponsive)
    #expect(result.copy == EmergencyCoordinator.failedCopy)
  }

  @Test func anOverlappingRestoreSendsNothing() async {
    let recorder = FollowUpRecorder()
    let coordinator = Self.coordinator(.inProgress, recorder: recorder, answer: true)
    let result = await coordinator.restore { recorder.show($0) }
    #expect(recorder.calls == 0)
    #expect(result == RestoreResult(kind: .inProgress, copy: nil))
  }

  static let testLog = Logger(subsystem: "io.github.ivanhernandez-dev.overtime.tests", category: "emergency")
  static let owned = HelperCallResult.success(HelperReply(code: .owned, message: "owned"))

  final class ClientCount: Sendable {
    private let made = OSAllocatedUnfairLock(initialState: 0)

    var value: Int { made.withLock { $0 } }

    func note() {
      made.withLock { $0 += 1 }
    }
  }

  struct AppFixture {
    let temp: TempDirectory
    let recorder = EmergencyRecorder()
    let selector: FakeEmergencySelector

    init() throws {
      temp = try TempDirectory()
      selector = FakeEmergencySelector(recorder: recorder, stateFile: temp.url.appendingPathComponent("state.json"))
    }

    func coordinator(helperClear: (@Sendable () -> Bool)?) -> EmergencyCoordinator {
      let selector = selector
      return AppHost.makeEmergencyCoordinator(
        host: { nil }, log: EmergencyCoordinatorTests.testLog, helperClear: helperClear, opener: { selector },
        registry: AssertionRegistry(), release: { _ in 0 })
    }
  }

  @Test func theAppsCoordinatorHandsItsHelperClearToTheResetAheadOfItsOwnClear() async throws {
    let fixture = try AppFixture()
    let helper = FakeHelperClear(recorder: fixture.recorder)
    let result = await fixture.coordinator(helperClear: { helper.run() }).restore()
    #expect(result.kind == .restored)
    #expect(result.copy == "Normal sleep restored.")
    #expect(fixture.recorder.actions == [FakeHelperClear.entry, "clear"], EmergencyResetTests.helperFirst)
    #expect(helper.calls == 1)
  }

  @Test func theAppsCoordinatorStillClearsItsOwnHoldButDoesNotClaimARestoreWhenItsHelperClearFails() async throws {
    let fixture = try AppFixture()
    let helper = FakeHelperClear(recorder: fixture.recorder, result: false)
    let result = await fixture.coordinator(helperClear: { helper.run() }).restore()
    #expect(result.kind == .helperNotCleared, Self.helperNotClaimed)
    #expect(result.copy == EmergencyCoordinator.helperNotClearedCopy, Self.helperNotClaimed)
    #expect(fixture.recorder.actions == [FakeHelperClear.entry, "clear"], EmergencyResetTests.helperNeverBlocks)
  }

  @Test func withoutAHelperClearTheAppsCoordinatorOnlyClearsItsOwnHold() async throws {
    let fixture = try AppFixture()
    let result = await fixture.coordinator(helperClear: nil).restore()
    #expect(result.kind == .restored)
    #expect(fixture.recorder.actions == ["clear"])
  }

  @Test func withTheHelperEnabledTheClearSendsOneClearOverAConnectionOfItsOwnAndNeverAsksForStatus() async {
    let helper = InProcessHelper()
    defer { helper.stop() }
    let holder = helper.client()
    #expect(await OffPool.run { holder.set(true) } == Self.owned)
    #expect(helper.fake.sleepDisabled == true)
    #expect(await OffPool.eventually { helper.connections == 1 })
    helper.fake.forget()
    let installer = FakeHelperInstaller(status: .enabled)
    let clients = ClientCount()
    let short = helper.client()
    let clear = AppHost.emergencyHelperClear(installer: installer) {
      clients.note()
      return short
    }
    #expect(clients.value == 0)
    #expect(helper.connectionsMade == 1)
    #expect(await OffPool.run(clear), EmergencyResetTests.helperFirst)
    #expect(helper.fake.pmsetWrites == [false])
    #expect(helper.fake.sleepDisabled == false)
    #expect(helper.fake.storedRecord?.owns == false)
    #expect(helper.statusCalls == 0, "The emergency client must only send a clear and never call status (T-03-19)")
    #expect(clients.value == 1)
    #expect(helper.connectionsMade == 2)
    #expect(await OffPool.eventually { helper.connections == 1 })
    #expect(installer.statusReads == 1)
    #expect(installer.calls.isEmpty)
    holder.invalidate()
  }

  @Test(arguments: [HelperInstallerStatus.notRegistered, .notFound, .requiresApproval])
  func whenTheHelperIsNotEnabledNoClientIsMadeAndThereIsNothingToClear(_ status: HelperInstallerStatus) async {
    let helper = InProcessHelper()
    defer { helper.stop() }
    let installer = FakeHelperInstaller(status: status)
    let clients = ClientCount()
    let short = helper.client()
    let clear = AppHost.emergencyHelperClear(installer: installer) {
      clients.note()
      return short
    }
    #expect(await OffPool.run(clear))
    #expect(clients.value == 0)
    #expect(helper.connectionsMade == 0)
    #expect(helper.fake.calls.isEmpty)
    #expect(installer.statusReads == 1)
    #expect(installer.calls.isEmpty)
  }

  @Test func aHelperThatNeverAnswersIsAFailedClearInsideTheClientsBoundAndItsConnectionIsEnded() async {
    let silent = SilentHelper()
    defer { silent.stop() }
    let short = silent.client(timeoutSeconds: 5)
    let clear = AppHost.emergencyHelperClear(installer: FakeHelperInstaller(status: .enabled)) { short }
    #expect(await OffPool.bounded(seconds: 30, clear) == false)
    #expect(await OffPool.eventually { silent.sets == [false] })
    #expect(silent.statuses == 0)
    #expect(silent.connectionsMade == 1)
    #expect(await OffPool.eventually { silent.ended == 1 })
  }

  @Test func aHelperThatCannotCompleteItsClearIsAFailedClearAndItsConnectionIsEnded() async {
    let helper = InProcessHelper()
    defer { helper.stop() }
    let holder = helper.client()
    #expect(await OffPool.run { holder.set(true) } == Self.owned)
    helper.fake.setWriteSucceeds(false)
    let short = helper.client()
    let clear = AppHost.emergencyHelperClear(installer: FakeHelperInstaller(status: .enabled)) { short }
    #expect(await OffPool.run(clear) == false)
    #expect(helper.fake.sleepDisabled == true)
    #expect(helper.connectionsMade == 2)
    #expect(await OffPool.eventually { helper.connections == 1 })
    holder.invalidate()
  }
}
