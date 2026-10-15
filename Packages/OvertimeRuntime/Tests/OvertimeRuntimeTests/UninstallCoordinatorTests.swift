import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import Testing
import os

struct UninstallCoordinatorTests {
  struct Outcome {
    let report: UninstallReport
    let progress: [UninstallProgress]
    let decisions: [Decision]
  }

  final class Recorder: Sendable {
    private let progressLog = OSAllocatedUnfairLock<[UninstallProgress]>(initialState: [])
    private let decisionLog = OSAllocatedUnfairLock<[Decision]>(initialState: [])

    var progress: [UninstallProgress] { progressLog.withLock { $0 } }
    var decisions: [Decision] { decisionLog.withLock { $0 } }

    func note(_ event: UninstallProgress) {
      progressLog.withLock { $0.append(event) }
    }

    func log(_ decision: Decision) {
      decisionLog.withLock { $0.append(decision) }
    }
  }

  static let boundSeconds: Double = 20

  static func coordinator(
    _ system: FakeUninstallSystem, recorder: Recorder, table: PurgeTable = .release,
    mode: UninstallCoordinator.Mode = .app, stepTimeout: Double = 10, timingOut: [String: Double] = [:],
    stopTimeout: Double = 10, adminTimeout: Double = 10
  ) -> UninstallCoordinator {
    UninstallCoordinator(
      system: system, table: table, mode: mode, stepTimeoutSeconds: stepTimeout, stepTimeoutOverrides: timingOut,
      stopTimeoutSeconds: stopTimeout, adminTimeoutSeconds: adminTimeout, log: { recorder.log($0) })
  }

  static func run(
    _ coordinator: UninstallCoordinator, recorder: Recorder, helper: HelperInstallerStatus, purge: Bool,
    resumingAt: UninstallStep = .stopKeepAwake, earlier: UninstallReport? = nil
  ) async throws -> Outcome {
    let box = OSAllocatedUnfairLock<UninstallReport?>(initialState: nil)
    let finished = await Engine.bounded(seconds: boundSeconds) {
      let report = await coordinator.run(
        helperStatus: helper, purge: purge, resumingAt: resumingAt, earlier: earlier,
        progress: { recorder.note($0) })
      box.withLock { $0 = report }
    }
    #expect(finished)
    let report = try #require(box.withLock { $0 })
    return Outcome(report: report, progress: recorder.progress, decisions: recorder.decisions)
  }

  @Test func aFullInAppUninstallWithAnOwningHelperAndPurgeRunsTheStepsInOrderWithOnePrompt() async throws {
    let system = FakeUninstallSystem {
      $0.status = .enabled
      $0.ownership = .owned
      $0.sleepDisabled = [true, false]
    }
    let recorder = Recorder()
    let result = try await Self.run(
      Self.coordinator(system, recorder: recorder), recorder: recorder, helper: .enabled, purge: true)

    let id = "io.github.ivanhernandez-dev.overtime"
    #expect(
      system.calls == [
        .stop, .ownership, .clear, .unregister, .readSleepDisabled, .admin(.clearAndPurge), .readSleepDisabled,
        .unregisterLoginItem, .removeUserItems(PurgeTable.release.userItems),
        .updateStagedForQuit,
        .removeStagedUpdate(PurgeTable.release.sparkleJobLabels, PurgeTable.release.sparkleCache), .trashApp(id),
      ])
    #expect(result.report.steps == UninstallStep.allCases)
    #expect(result.report.steps.allSatisfy { result.report.statuses[$0] == .done })
    #expect(result.report.outcome == .uninstalled)
    #expect(result.report.adminPrompts == 1)
    #expect(system.adminCalls == 1)
    #expect(result.report.manualSteps.isEmpty)
    #expect(result.report.sleepDisabledLeft == nil)
    #expect(
      result.progress == [
        .started(.stopKeepAwake), .finished(.stopKeepAwake, .done),
        .started(.removeHelper), .finished(.removeHelper, .done),
        .started(.restoreSleep), .waitingForAdministrator(.restoreSleep), .finished(.restoreSleep, .done),
        .started(.removeLoginItem), .finished(.removeLoginItem, .done),
        .started(.purge), .finished(.purge, .done, note: UninstallCopy.preferencesAtQuitCaption),
        .started(.trashApp), .finished(.trashApp, .done),
      ])
    #expect(result.decisions.allSatisfy { $0.keyword == .uninstall })
    #expect(
      result.decisions.map(\.verb) == [
        "stop", "helper", "sleepDisabled", "loginItem", "purge", "stagedUpdate", "trash", "run",
      ])
  }

  static let releaseID = PurgeTable.release.appIdentifier

  static func admins(_ calls: [FakeUninstallSystem.Call]) -> [UninstallAdminCommand] {
    calls.compactMap { call in
      if case .admin(let command) = call { return command }
      return nil
    }
  }

  static func index(of call: FakeUninstallSystem.Call, in calls: [FakeUninstallSystem.Call]) -> Int? {
    calls.firstIndex(of: call)
  }

  static func quick(
    helper: HelperInstallerStatus, purge: Bool, mode: UninstallCoordinator.Mode = .app, table: PurgeTable = .release,
    _ configure: (inout FakeUninstallSystem.Answers) -> Void = { _ in }
  ) async throws -> (Outcome, FakeUninstallSystem) {
    let system = FakeUninstallSystem {
      $0.status = helper
      configure(&$0)
    }
    let recorder = Recorder()
    let coordinator = coordinator(system, recorder: recorder, table: table, mode: mode)
    let result = try await run(coordinator, recorder: recorder, helper: helper, purge: purge)
    return (result, system)
  }

  @Test func withNoHelperSleepDisabledOffAndNoPurgeOnlyTheAlwaysStepsRunWithNoPrompt() async throws {
    let (result, system) = try await Self.quick(helper: .notRegistered, purge: false)
    let table = PurgeTable.release
    let expected: [FakeUninstallSystem.Call] = [
      .stop, .readSleepDisabled, .unregisterLoginItem, .updateStagedForQuit,
      .removeStagedUpdate(table.sparkleJobLabels, table.sparkleCache), .trashApp(Self.releaseID),
    ]
    #expect(system.calls == expected)
    #expect(result.report.steps == [.stopKeepAwake, .removeLoginItem, .trashApp])
    #expect(result.report.outcome == .uninstalled)
    #expect(result.report.adminPrompts == 0)
    #expect(result.report.sleepDisabledLeft == nil)
  }

  @Test func aHelperWhoseSleepDisabledIsAlreadyOffPurgesTheRootFoldersAloneAtThePurgeStep() async throws {
    let (result, system) = try await Self.quick(helper: .enabled, purge: true) { $0.sleepDisabled = [false] }
    #expect(Self.admins(system.calls) == [.purgeRootFolders])
    #expect(result.report.adminPrompts == 1)
    let waiting = try #require(result.progress.firstIndex(of: .waitingForAdministrator(.purge)))
    #expect(result.progress[waiting - 1] == .started(.purge))
    #expect(result.progress[waiting + 1] == .finished(.purge, .done, note: UninstallCopy.preferencesAtQuitCaption))
    #expect(!result.progress.contains(.waitingForAdministrator(.restoreSleep)))
    #expect(result.report.status(of: .restoreSleep) == .done)
    #expect(result.report.status(of: .purge) == .done)
    #expect(result.report.outcome == .uninstalled)
    let rootPrompt = try #require(Self.index(of: .admin(.purgeRootFolders), in: system.calls))
    let userItems = try #require(
      Self.index(of: .removeUserItems(PurgeTable.release.userItems), in: system.calls))
    #expect(userItems < rootPrompt)
  }

  @Test func aFailedHelperUnregisterStopsBeforeAnythingElseAndARetryResumesAtTheHelper() async throws {
    let system = FakeUninstallSystem {
      $0.status = .enabled
      $0.unregister = false
      $0.sleepDisabled = [true, false]
    }
    let recorder = Recorder()
    let coordinator = Self.coordinator(system, recorder: recorder)
    let first = try await Self.run(coordinator, recorder: recorder, helper: .enabled, purge: true)

    #expect(first.report.outcome == .stopped)
    #expect(system.calls == [.stop, .ownership, .clear, .unregister])
    #expect(first.report.status(of: .stopKeepAwake) == .done)
    #expect(first.report.status(of: .removeHelper) == .failed(UninstallCopy.helperNotRemovedCaption))
    for step in [UninstallStep.restoreSleep, .removeLoginItem, .purge, .trashApp] {
      #expect(first.report.status(of: step) == .pending)
    }
    #expect(first.report.adminPrompts == 0)
    #expect(first.report.manualSteps.isEmpty)
    #expect(first.progress.last == .finished(.removeHelper, .failed(UninstallCopy.helperNotRemovedCaption)))
    #expect(first.decisions.last?.verb == "run")
    #expect(first.decisions.last?.fields.first?.value == "stopped")

    system.update { $0.unregister = true }
    let retryRecorder = Recorder()
    let retried = try await Self.run(
      Self.coordinator(system, recorder: retryRecorder), recorder: retryRecorder, helper: .enabled, purge: true,
      resumingAt: .removeHelper, earlier: first.report)

    #expect(system.calls.filter { $0 == .stop }.count == 1)
    #expect(Array(system.calls.dropFirst(4).prefix(2)) == [.clear, .unregister])
    #expect(retried.report.helperOwnership == .owned)
    #expect(retried.progress.first == .started(.removeHelper))
    #expect(!retried.progress.contains(.started(.stopKeepAwake)))
    #expect(retried.report.status(of: .stopKeepAwake) == .done)
    #expect(retried.report.steps.allSatisfy { retried.report.statuses[$0] == .done })
    #expect(retried.report.outcome == .uninstalled)
    #expect(retried.report.adminPrompts == 1)
    #expect(system.calls.last == .trashApp(Self.releaseID))
  }

  @Test func aRetryKeepsTheOwnershipReadBeforeTheFirstUnregisterAndNeverClearsANotOwnedValue() async throws {
    let system = FakeUninstallSystem {
      $0.status = .enabled
      $0.ownership = .notOwned
      $0.unregister = false
      $0.sleepDisabled = [true]
    }
    let recorder = Recorder()
    let first = try await Self.run(
      Self.coordinator(system, recorder: recorder), recorder: recorder, helper: .enabled, purge: true)
    #expect(first.report.outcome == .stopped)
    #expect(first.report.helperOwnership == .notOwned)
    #expect(system.calls == [.stop, .ownership, .clear, .unregister])

    system.update {
      $0.ownership = .unknown
      $0.record = .unknown
      $0.unregister = true
    }
    let retryRecorder = Recorder()
    let retried = try await Self.run(
      Self.coordinator(system, recorder: retryRecorder), recorder: retryRecorder, helper: .enabled, purge: true,
      resumingAt: .removeHelper, earlier: first.report)
    let retryCalls = Array(system.calls.dropFirst(4))
    #expect(!retryCalls.contains(.ownership))
    #expect(!retryCalls.contains(.record))
    #expect(Self.admins(system.calls) == [.purgeRootFolders])
    #expect(retried.report.helperOwnership == .notOwned)
    #expect(retried.report.sleepDisabledLeft == .notOwned)
    #expect(retried.report.status(of: .restoreSleep) == .done)
    #expect(retried.report.notes[.restoreSleep] == UninstallCopy.sleepDisabledNotOwnedCaption)
  }

  @Test(arguments: [HelperOwnership.owned, .notOwned, .unknown])
  func aRetryNeverReDerivesTheFirstOwnershipWhateverTheHelperAnswersLater(_ firstAnswer: HelperOwnership)
    async throws
  {
    for laterAnswer in [HelperOwnership.owned, .notOwned, .unknown] {
      let system = FakeUninstallSystem {
        $0.status = .enabled
        $0.ownership = firstAnswer
        $0.record = .unknown
        $0.unregister = false
        $0.sleepDisabled = [true, false]
      }
      let recorder = Recorder()
      let first = try await Self.run(
        Self.coordinator(system, recorder: recorder), recorder: recorder, helper: .enabled, purge: false)
      system.update {
        $0.ownership = laterAnswer
        $0.record = laterAnswer
        $0.unregister = true
      }
      let retryRecorder = Recorder()
      let retried = try await Self.run(
        Self.coordinator(system, recorder: retryRecorder), recorder: retryRecorder, helper: .enabled, purge: false,
        resumingAt: .removeHelper, earlier: first.report)
      let label = "first \(firstAnswer) later \(laterAnswer)"
      #expect(first.report.helperOwnership == firstAnswer, "\(label)")
      #expect(retried.report.helperOwnership == firstAnswer, "\(label)")
      #expect(Self.admins(system.calls) == (firstAnswer == .owned ? [.clearSleepDisabled] : []), "\(label)")
      #expect(system.calls.filter { $0 == .ownership }.count == 1, "\(label)")
    }
  }

  @Test(arguments: [false, true])
  func anOwnershipNobodyCanTellIsNeverClearedAndKeepsTheLibraryFolders(_ purge: Bool) async throws {
    let (result, system) = try await Self.quick(helper: .enabled, purge: purge) {
      $0.ownership = .unknown
      $0.record = .unknown
      $0.sleepDisabled = [true]
    }
    #expect(Self.admins(system.calls).isEmpty)
    #expect(result.report.adminPrompts == 0)
    #expect(result.report.status(of: .restoreSleep) == .skipped(UninstallCopy.sleepDisabledUnknownCaption))
    #expect(result.report.sleepDisabledLeft == .unknown)
    #expect(result.report.helperOwnership == .unknown)
    #expect(result.report.outcome == .finishedWithProblems)
    #expect(system.calls.contains(.removeUserItems(PurgeTable.release.userItems)) == purge)
    if purge {
      #expect(result.report.status(of: .purge) == .skipped(UninstallCopy.rootFoldersLeftCaption))
      #expect(result.report.manualSteps == [.rootFolders])
    }
  }

  @Test(arguments: [(HelperOwnership.notOwned, false), (.owned, true)])
  func aHelperThatDoesNotAnswerFallsBackToItsRecordBeforeTheUnregister(record: HelperOwnership, clears: Bool)
    async throws
  {
    let (result, system) = try await Self.quick(helper: .enabled, purge: false) {
      $0.ownership = .unknown
      $0.record = record
      $0.sleepDisabled = [true, false]
    }
    #expect(Array(system.calls.prefix(5)) == [.stop, .ownership, .record, .clear, .unregister])
    #expect(Self.admins(system.calls) == (clears ? [.clearSleepDisabled] : []))
    #expect(result.report.helperOwnership == record)
    #expect(result.report.sleepDisabledLeft == (clears ? nil : .notOwned))
  }

  static func runQuitting(
    _ system: FakeUninstallSystem, recorder: Recorder, purge: Bool,
    when quit: @escaping @Sendable ([FakeUninstallSystem.Call]) -> Bool
  ) async throws -> UninstallReport {
    let coordinator = Self.coordinator(system, recorder: recorder, stepTimeout: 10, stopTimeout: 10, adminTimeout: 10)
    let box = OSAllocatedUnfairLock<UninstallReport?>(initialState: nil)
    let finished = await Engine.bounded(seconds: Self.boundSeconds) {
      let report = await coordinator.run(
        helperStatus: .enabled, purge: purge, progress: { recorder.note($0) },
        continuing: { !quit(system.calls) })
      box.withLock { $0 = report }
    }
    #expect(finished)
    return try #require(box.withLock { $0 })
  }

  @Test func aQuitDuringTheRestoreStepLetsItFinishAndStartsNoLaterStep() async throws {
    let system = FakeUninstallSystem {
      $0.status = .enabled
      $0.sleepDisabled = [false]
    }
    let recorder = Recorder()
    let report = try await Self.runQuitting(system, recorder: recorder, purge: true) {
      $0.contains(.readSleepDisabled)
    }
    #expect(system.calls == [.stop, .ownership, .clear, .unregister, .readSleepDisabled])
    #expect(report.status(of: .removeHelper) == .done)
    #expect(report.status(of: .restoreSleep) == .done)
    for step in [UninstallStep.removeLoginItem, .purge, .trashApp] {
      #expect(report.status(of: step) == .pending)
    }
    #expect(report.outcome == .finishedWithProblems)
    #expect(report.helperOwnership == .owned)
    let last = try #require(recorder.decisions.last)
    #expect(last.verb == "run")
    #expect(last.fields == [DecisionField(key: "result", value: "interrupted")])
  }

  @Test func aQuitDuringTheHelperStepStillRestoresAnOwnedSleepDisabledThenStartsNoLaterStep() async throws {
    let system = FakeUninstallSystem {
      $0.status = .enabled
      $0.ownership = .owned
      $0.clear = false
      $0.sleepDisabled = [true, false]
    }
    let recorder = Recorder()
    let report = try await Self.runQuitting(system, recorder: recorder, purge: false) {
      $0.contains(.unregister)
    }
    #expect(
      system.calls == [
        .stop, .ownership, .clear, .unregister, .readSleepDisabled, .admin(.clearSleepDisabled), .readSleepDisabled,
      ])
    #expect(report.status(of: .removeHelper) == .done)
    #expect(report.status(of: .restoreSleep) == .done)
    #expect(report.sleepDisabledLeft == nil)
    #expect(report.adminPrompts == 1)
    for step in [UninstallStep.removeLoginItem, .trashApp] {
      #expect(report.status(of: step) == .pending)
    }
    #expect(report.outcome == .finishedWithProblems)
    let last = try #require(recorder.decisions.last)
    #expect(last.fields == [DecisionField(key: "result", value: "interrupted")])
  }

  @Test func aQuitDuringTheHelperStepWhoseRestorePromptIsCancelledLeavesTheValueOwnedAndSaysSo() async throws {
    let system = FakeUninstallSystem {
      $0.status = .enabled
      $0.ownership = .owned
      $0.clear = false
      $0.sleepDisabled = [true]
      $0.admin = .cancelled
    }
    let recorder = Recorder()
    let report = try await Self.runQuitting(system, recorder: recorder, purge: false) {
      $0.contains(.unregister)
    }
    #expect(Self.admins(system.calls) == [.clearSleepDisabled])
    #expect(report.status(of: .restoreSleep) == .skipped(SleepDisabledClearing.cancelledCaption))
    #expect(report.sleepDisabledLeft == .owned)
    #expect(report.leavesSleepUnresolved)
    #expect(!system.calls.contains(.unregisterLoginItem))
  }

  @Test func aQuitBeforeTheHelperStepLeavesTheHelperAndEverythingElseInPlace() async throws {
    let system = FakeUninstallSystem { $0.status = .enabled }
    let recorder = Recorder()
    let coordinator = Self.coordinator(system, recorder: recorder, stepTimeout: 10, stopTimeout: 10, adminTimeout: 10)
    let box = OSAllocatedUnfairLock<UninstallReport?>(initialState: nil)
    let finished = await Engine.bounded(seconds: Self.boundSeconds) {
      let report = await coordinator.run(
        helperStatus: .enabled, purge: false, progress: { recorder.note($0) }, continuing: { false })
      box.withLock { $0 = report }
    }
    #expect(finished)
    let report = try #require(box.withLock { $0 })
    #expect(system.calls == [.stop])
    #expect(report.status(of: .removeHelper) == .pending)
    #expect(report.outcome == .finishedWithProblems)
  }

  @Test(arguments: [true, false])
  func aQuitIsLoggedWithWhetherTheRunSettled(_ settled: Bool) {
    let recorder = Recorder()
    let coordinator = Self.coordinator(FakeUninstallSystem(), recorder: recorder)
    coordinator.noteQuit(settled: settled)
    #expect(
      recorder.decisions == [
        Decision(
          keyword: .uninstall, verb: "quit",
          fields: [DecisionField(key: "result", value: settled ? "settled" : "unsettled")])
      ])
  }

  @Test func aQuitLogNamesThePromptAndGivesTheCommandWhenSleepIsLeftOff() {
    let recorder = Recorder()
    let coordinator = Self.coordinator(FakeUninstallSystem(), recorder: recorder)
    coordinator.noteQuit(settled: true, prompt: .held, sleepDisabledLeft: nil)
    coordinator.noteQuit(settled: true, prompt: .cancelled, sleepDisabledLeft: .owned)
    coordinator.noteQuit(settled: false, prompt: .cancelled, sleepDisabledLeft: .unknown)
    coordinator.noteQuit(settled: true, prompt: .none, sleepDisabledLeft: .notOwned)
    let command = DecisionField(key: "command", value: "sudo pmset -a disablesleep 0")
    #expect(
      recorder.decisions.map(\.fields) == [
        [DecisionField(key: "result", value: "settled"), DecisionField(key: "prompt", value: "held")],
        [
          DecisionField(key: "result", value: "settled"), DecisionField(key: "prompt", value: "cancelled"),
          DecisionField(key: "sleepDisabled", value: "owned"), command,
        ],
        [
          DecisionField(key: "result", value: "unsettled"), DecisionField(key: "prompt", value: "cancelled"),
          DecisionField(key: "sleepDisabled", value: "unknown"), command,
        ],
        [DecisionField(key: "result", value: "settled")],
      ])
    #expect(recorder.decisions.allSatisfy { $0.verb == "quit" && $0.keyword == .uninstall })
  }

  @Test func aNotFoundStatusStillGoesThroughTheUnregisterAndAFailureStopsBeforeTheTrash() async throws {
    let (stopped, failing) = try await Self.quick(helper: .notFound, purge: true) { $0.unregister = false }
    #expect(stopped.report.steps.contains(.removeHelper))
    #expect(stopped.report.outcome == .stopped)
    #expect(failing.calls == [.stop, .record, .unregister])
    let (done, passing) = try await Self.quick(helper: .notFound, purge: false)
    #expect(passing.calls.contains(.unregister))
    #expect(!passing.calls.contains(.ownership))
    #expect(done.report.status(of: .removeHelper) == .done)
    #expect(UninstallCoordinator.attemptsHelper(.notFound))
  }

  static func unreadStatusRun(
    ownership: HelperOwnership, record: HelperOwnership
  ) async throws -> (UninstallReport, FakeUninstallSystem) {
    let system = FakeUninstallSystem {
      $0.ownership = ownership
      $0.record = record
      $0.sleepDisabled = [true, false]
    }
    let recorder = Recorder()
    let coordinator = Self.coordinator(system, recorder: recorder, stepTimeout: 10, stopTimeout: 10, adminTimeout: 10)
    let box = OSAllocatedUnfairLock<UninstallReport?>(initialState: nil)
    let finished = await Engine.bounded(seconds: Self.boundSeconds) {
      let report = await coordinator.run(helperStatus: nil, purge: true) { recorder.note($0) }
      box.withLock { $0 = report }
    }
    #expect(finished)
    return (try #require(box.withLock { $0 }), system)
  }

  @Test func anUnreadStatusStillAsksTheHelperThenItsRecordBeforeTheUnregister() async throws {
    let (owned, ownedSystem) = try await Self.unreadStatusRun(ownership: .owned, record: .unknown)
    #expect(Array(ownedSystem.calls.prefix(3)) == [.stop, .ownership, .unregister])
    #expect(owned.helperOwnership == .owned)
    #expect(Self.admins(ownedSystem.calls) == [.clearAndPurge])
    #expect(owned.status(of: .restoreSleep) == .done)

    let (missing, missingSystem) = try await Self.unreadStatusRun(ownership: .unknown, record: .notOwned)
    #expect(Array(missingSystem.calls.prefix(4)) == [.stop, .ownership, .record, .unregister])
    #expect(missing.helperOwnership == .notOwned)
    #expect(Self.admins(missingSystem.calls) == [.purgeRootFolders])
    #expect(missing.sleepDisabledLeft == .notOwned)
    #expect(missing.status(of: .restoreSleep) == .done)

    let (helperSays, helperSaysSystem) = try await Self.unreadStatusRun(ownership: .notOwned, record: .owned)
    #expect(!helperSaysSystem.calls.contains(.record))
    #expect(helperSays.helperOwnership == .notOwned)
    #expect(!Self.admins(helperSaysSystem.calls).contains(.clearAndPurge))
  }

  @Test func anInstallerStatusNobodyCouldReadStillTriesTheUnregisterAndNeverClears() async throws {
    let (report, system) = try await Self.unreadStatusRun(ownership: .unknown, record: .unknown)
    #expect(report.steps == UninstallStep.allCases)
    #expect(Array(system.calls.prefix(5)) == [.stop, .ownership, .record, .unregister, .readSleepDisabled])
    #expect(!system.calls.contains(.clear))
    #expect(Self.admins(system.calls).isEmpty)
    #expect(report.helperOwnership == .unknown)
    #expect(report.status(of: .restoreSleep) == .skipped(UninstallCopy.sleepDisabledUnknownCaption))
    #expect(report.status(of: .purge) == .skipped(UninstallCopy.rootFoldersLeftCaption))
    #expect(report.outcome == .finishedWithProblems)
    #expect(UninstallCoordinator.attemptsHelper(nil))
    #expect(UninstallCoordinator.attemptsHelper(.enabled))
    #expect(UninstallCoordinator.attemptsHelper(.requiresApproval))
    #expect(!UninstallCoordinator.attemptsHelper(.notRegistered))
  }

  @Test func aDefaultsPurgeThatTimesOutIsLoggedAndThePurgeStillRemovesTheFiles() async throws {
    let system = FakeUninstallSystem { $0.delays = [.defaults: 3] }
    let recorder = Recorder()
    let coordinator = Self.coordinator(system, recorder: recorder, mode: .headless, timingOut: ["defaults": 0.5])
    let result = try await Self.run(coordinator, recorder: recorder, helper: .notRegistered, purge: true)
    #expect(system.calls.contains(.removeUserItems(PurgeTable.release.userItems)))
    #expect(result.report.status(of: .purge) == .done)
    let purge = try #require(result.decisions.first { $0.verb == "purge" })
    #expect(purge.fields.contains(DecisionField(key: "defaults", value: "timedOut")))
  }

  @Test func withoutTheHelperAnUnreadableRecordLeavesAnUnknownValueAndFinishesWithProblems() async throws {
    let (result, system) = try await Self.quick(helper: .notRegistered, purge: false) {
      $0.record = .unknown
      $0.sleepDisabled = [true]
    }
    #expect(Self.admins(system.calls).isEmpty)
    #expect(system.calls.contains(.record))
    #expect(!system.calls.contains(.ownership))
    #expect(result.report.sleepDisabledLeft == .unknown)
    #expect(result.report.outcome == .finishedWithProblems)
  }

  @Test func aRetryKeepsAnUnconfirmedStopAndItsRestartStep() async throws {
    let system = FakeUninstallSystem {
      $0.status = .requiresApproval
      $0.stop = .unconfirmed
      $0.unregister = false
    }
    let recorder = Recorder()
    let first = try await Self.run(
      Self.coordinator(system, recorder: recorder), recorder: recorder, helper: .requiresApproval, purge: false)
    #expect(first.report.outcome == .stopped)
    #expect(first.report.manualSteps == [.restart])

    system.update { $0.unregister = true }
    let retryRecorder = Recorder()
    let retried = try await Self.run(
      Self.coordinator(system, recorder: retryRecorder), recorder: retryRecorder, helper: .requiresApproval,
      purge: false, resumingAt: .removeHelper, earlier: first.report)
    #expect(retried.report.status(of: .stopKeepAwake) == .failed(UninstallCopy.stopUnconfirmedCaption))
    #expect(retried.report.manualSteps == [.restart])
    #expect(retried.report.outcome == .finishedWithProblems)
    #expect(system.calls.filter { $0 == .stop }.count == 1)
  }

  @Test func anUnregisterThatTimesOutStopsTheRun() async throws {
    let system = FakeUninstallSystem {
      $0.status = .enabled
      $0.delays = [.unregister: 1.5]
    }
    let recorder = Recorder()
    let coordinator = Self.coordinator(system, recorder: recorder, timingOut: ["unregister": 0.2])
    let result = try await Self.run(coordinator, recorder: recorder, helper: .enabled, purge: true)
    #expect(result.report.outcome == .stopped)
    #expect(result.report.status(of: .removeHelper) == .failed(UninstallCopy.helperNotRemovedCaption))
    #expect(system.calls == [.stop, .ownership, .clear, .unregister])
    #expect(result.decisions.first { $0.verb == "helper" }?.fields.first?.value == "timedOut")
  }

  @Test func aSleepDisabledTheHelperDidNotSetIsLeftAloneWithNoPrompt() async throws {
    let (result, system) = try await Self.quick(helper: .enabled, purge: false) {
      $0.ownership = .notOwned
      $0.sleepDisabled = [true]
    }
    #expect(Self.admins(system.calls).isEmpty)
    #expect(result.report.adminPrompts == 0)
    #expect(result.report.status(of: .restoreSleep) == .done)
    #expect(result.report.notes[.restoreSleep] == UninstallCopy.sleepDisabledNotOwnedCaption)
    #expect(
      result.progress.contains(.finished(.restoreSleep, .done, note: UninstallCopy.sleepDisabledNotOwnedCaption)))
    #expect(result.report.sleepDisabledLeft == .notOwned)
    #expect(system.calls.filter { $0 == .readSleepDisabled }.count == 1)
  }

  @Test func aNotOwnedSleepDisabledWithPurgeRunsOnlyTheRootPurgePrompt() async throws {
    let (result, system) = try await Self.quick(helper: .enabled, purge: true) {
      $0.ownership = .notOwned
      $0.sleepDisabled = [true]
    }
    #expect(Self.admins(system.calls) == [.purgeRootFolders])
    #expect(result.report.adminPrompts == 1)
    #expect(result.report.sleepDisabledLeft == .notOwned)
    #expect(result.report.status(of: .purge) == .done)
  }

  @Test func anOwnershipCallThatTimesOutFallsBackToTheRecordAndAnUnreadableOneIsNeverCleared() async throws {
    let system = FakeUninstallSystem {
      $0.status = .enabled
      $0.ownership = .owned
      $0.record = .unknown
      $0.delays = [.ownership: 1.5]
      $0.sleepDisabled = [true, false]
    }
    let recorder = Recorder()
    let coordinator = Self.coordinator(system, recorder: recorder, timingOut: ["ownership": 0.2])
    let result = try await Self.run(coordinator, recorder: recorder, helper: .enabled, purge: false)
    #expect(Self.admins(system.calls).isEmpty)
    #expect(result.report.status(of: .restoreSleep) == .skipped(UninstallCopy.sleepDisabledUnknownCaption))
    #expect(result.report.sleepDisabledLeft == .unknown)
    let helperLine = try #require(result.decisions.first { $0.verb == "helper" })
    #expect(helperLine.fields.contains(DecisionField(key: "ownership", value: "unknown")))
  }

  @Test(arguments: [(HelperOwnership.owned, true), (.notOwned, false), (.unknown, false)])
  func aHelperAwaitingApprovalGetsNoXPCCallAndItsRecordDecidesTheClear(record: HelperOwnership, clears: Bool)
    async throws
  {
    let (result, system) = try await Self.quick(helper: .requiresApproval, purge: false) {
      $0.record = record
      $0.sleepDisabled = [true, false]
    }
    #expect(!system.calls.contains(.ownership))
    #expect(!system.calls.contains(.clear))
    #expect(system.calls.contains(.record))
    #expect(system.calls.contains(.unregister))
    #expect(Self.admins(system.calls) == (clears ? [.clearSleepDisabled] : []))
    let unknown = record == .unknown
    let expected: StepStatus = unknown ? .skipped(UninstallCopy.sleepDisabledUnknownCaption) : .done
    #expect(result.report.status(of: .restoreSleep) == expected)
    #expect(result.report.outcome == (unknown ? .finishedWithProblems : .uninstalled))
  }

  @Test func withoutTheHelperASleepDisabledOfOneHasNoRowAndNoPrompt() async throws {
    let (result, system) = try await Self.quick(helper: .notRegistered, purge: true) { $0.sleepDisabled = [true] }
    #expect(!result.report.steps.contains(.restoreSleep))
    #expect(result.report.status(of: .restoreSleep) == nil)
    #expect(Self.admins(system.calls).isEmpty)
    #expect(result.report.sleepDisabledLeft == .notOwned)
    #expect(!system.calls.contains(.ownership))
    #expect(!system.calls.contains(.unregister))
    #expect(result.report.outcome == .uninstalled)
  }

  @Test func aCancelledPromptSkipsTheClearAndTheRootPurgeAndLeavesTheValueOwned() async throws {
    let (result, system) = try await Self.quick(helper: .enabled, purge: true) {
      $0.sleepDisabled = [true]
      $0.admin = .cancelled
    }
    #expect(Self.admins(system.calls) == [.clearAndPurge])
    #expect(result.report.status(of: .restoreSleep) == .skipped(SleepDisabledClearing.cancelledCaption))
    #expect(result.report.status(of: .purge) == .skipped(UninstallCopy.rootFoldersLeftCaption))
    #expect(result.report.manualSteps == [.rootFolders])
    #expect(result.report.sleepDisabledLeft == .owned)
    #expect(result.report.outcome == .finishedWithProblems)
    #expect(result.report.adminPrompts == 1)
    #expect(system.calls.contains(.removeUserItems(PurgeTable.release.userItems)))
  }

  @Test func aFailedPromptFailsTheClearWithTheTerminalCommand() async throws {
    let (result, system) = try await Self.quick(helper: .enabled, purge: false) {
      $0.sleepDisabled = [true]
      $0.admin = .failed("exit 1")
    }
    #expect(Self.admins(system.calls) == [.clearSleepDisabled])
    #expect(result.report.status(of: .restoreSleep) == .failed(SleepDisabledClearing.failedCaption))
    #expect(result.report.sleepDisabledLeft == .owned)
    #expect(result.report.outcome == .finishedWithProblems)
  }

  @Test func aPromptThatSucceedsWhileTheValueStaysSetFails() async throws {
    let (result, system) = try await Self.quick(helper: .enabled, purge: true) { $0.sleepDisabled = [true, true] }
    #expect(Self.admins(system.calls) == [.clearAndPurge])
    #expect(result.report.status(of: .restoreSleep) == .failed(SleepDisabledClearing.failedCaption))
    #expect(result.report.status(of: .purge) == .done)
    #expect(result.report.sleepDisabledLeft == .owned)
    #expect(result.report.outcome == .finishedWithProblems)
  }

  @Test func anAdministratorPromptThatTimesOutFailsTheClear() async throws {
    let system = FakeUninstallSystem {
      $0.status = .enabled
      $0.sleepDisabled = [true]
      $0.delays = [.admin: 1.5]
    }
    let recorder = Recorder()
    let coordinator = Self.coordinator(system, recorder: recorder, adminTimeout: 0.2)
    let result = try await Self.run(coordinator, recorder: recorder, helper: .enabled, purge: true)
    #expect(result.report.status(of: .restoreSleep) == .failed(SleepDisabledClearing.failedCaption))
    #expect(result.report.status(of: .purge) == .skipped(UninstallCopy.rootFoldersLeftCaption))
    #expect(result.report.adminPrompts == 1)
    #expect(system.adminCalls == 1)
  }

  @Test func anUnreadableSleepDisabledFailsTheStepWithNoPrompt() async throws {
    let (result, system) = try await Self.quick(helper: .enabled, purge: false) { $0.sleepDisabled = [nil] }
    #expect(result.report.status(of: .restoreSleep) == .failed(SleepDisabledClearing.failedCaption))
    #expect(Self.admins(system.calls).isEmpty)
    #expect(result.report.sleepDisabledLeft == nil)
    #expect(result.report.outcome == .finishedWithProblems)
  }

  @Test(arguments: [UninstallEngineStop.unconfirmed, .stopped])
  func aStopThatIsNotConfirmedFailsRowOneAddsTheRestartStepAndContinues(_ answer: UninstallEngineStop) async throws {
    let system = FakeUninstallSystem {
      $0.stop = answer
      if answer == .stopped {
        $0.delays = [.stop: 1.5]
      }
    }
    let recorder = Recorder()
    let coordinator = Self.coordinator(system, recorder: recorder, stopTimeout: 0.2)
    let result = try await Self.run(coordinator, recorder: recorder, helper: .notRegistered, purge: false)
    #expect(result.report.status(of: .stopKeepAwake) == .failed(UninstallCopy.stopUnconfirmedCaption))
    #expect(result.report.manualSteps == [.restart])
    #expect(system.calls.last == .trashApp(Self.releaseID))
    #expect(result.report.status(of: .trashApp) == .done)
    #expect(result.report.outcome == .finishedWithProblems)
  }

  @Test func aStopWithNoEngineRunningIsDoneWithItsCaption() async throws {
    let (result, _) = try await Self.quick(helper: .notRegistered, purge: false) { $0.stop = .notRunning }
    #expect(result.report.status(of: .stopKeepAwake) == .done)
    #expect(result.report.notes[.stopKeepAwake] == UninstallCopy.keepAwakeNotRunningCaption)
    #expect(result.progress[1] == .finished(.stopKeepAwake, .done, note: UninstallCopy.keepAwakeNotRunningCaption))
    #expect(result.report.outcome == .uninstalled)
  }

  @Test func aLoginItemThatCannotBeRemovedFailsAddsTheManualStepAndTheTrashStillRuns() async throws {
    let (result, system) = try await Self.quick(helper: .notRegistered, purge: false) { $0.loginItem = false }
    #expect(result.report.status(of: .removeLoginItem) == .failed(UninstallCopy.loginItemFailedCaption))
    #expect(result.report.manualSteps == [.loginItem])
    #expect(system.calls.last == .trashApp(Self.releaseID))
    #expect(result.report.outcome == .finishedWithProblems)
  }

  @Test func aLoginItemCallThatTimesOutFails() async throws {
    let system = FakeUninstallSystem { $0.delays = [.loginItem: 1.5] }
    let recorder = Recorder()
    let coordinator = Self.coordinator(system, recorder: recorder, timingOut: ["loginItem": 0.2])
    let result = try await Self.run(coordinator, recorder: recorder, helper: .notRegistered, purge: false)
    #expect(result.report.status(of: .removeLoginItem) == .failed(UninstallCopy.loginItemFailedCaption))
    #expect(result.report.manualSteps == [.loginItem])
  }

  @Test func aShortBoundOnOneCallLeavesEveryOtherCallAtTheStepBound() async throws {
    let system = FakeUninstallSystem { $0.delays = [.loginItem: 1.5, .trash: 0.6, .staged: 0.6] }
    let recorder = Recorder()
    let coordinator = Self.coordinator(system, recorder: recorder, timingOut: ["loginItem": 0.2])
    let result = try await Self.run(coordinator, recorder: recorder, helper: .notRegistered, purge: false)
    #expect(result.report.status(of: .removeLoginItem) == .failed(UninstallCopy.loginItemFailedCaption))
    #expect(result.report.status(of: .trashApp) == .done)
    #expect(result.report.manualSteps == [.loginItem])
    let staged = try #require(result.decisions.first { $0.verb == "stagedUpdate" })
    #expect(staged.fields.contains(DecisionField(key: "staged", value: "no")))
  }

  @Test func aUserItemRemovalFailureFailsThePurgeWithItsManualStep() async throws {
    let (result, _) = try await Self.quick(helper: .notRegistered, purge: true) { $0.userItems = false }
    #expect(result.report.status(of: .purge) == .failed(UninstallCopy.userFilesFailedCaption))
    #expect(result.report.manualSteps == [.userFiles])
    #expect(result.report.outcome == .finishedWithProblems)
  }

  @Test func aUserRemovalFailureAndALibraryFolderLeftKeepBothManualSteps() async throws {
    let (result, _) = try await Self.quick(helper: .enabled, purge: true) {
      $0.sleepDisabled = [false]
      $0.userItems = false
      $0.admin = .cancelled
    }
    #expect(result.report.status(of: .purge) == .failed(UninstallCopy.userFilesFailedCaption))
    #expect(result.report.manualSteps == [.rootFolders, .userFiles])
  }

  @Test(arguments: [UninstallTrashResult.refused, .failed])
  func aTrashThatDoesNotHappenFailsWithItsManualStep(_ answer: UninstallTrashResult) async throws {
    let (result, _) = try await Self.quick(helper: .notRegistered, purge: false) { $0.trash = answer }
    #expect(result.report.status(of: .trashApp) == .failed(UninstallCopy.trashFailedCaption))
    #expect(result.report.manualSteps == [.trash])
    #expect(result.report.outcome == .finishedWithProblems)
  }

  @Test(arguments: [false, true])
  func aStagedUpdateIsRemovedFromTheTableBeforeTheTrash(_ purge: Bool) async throws {
    let (result, system) = try await Self.quick(helper: .notRegistered, purge: purge) { $0.staged = true }
    let table = PurgeTable.release
    let removal = try #require(
      Self.index(of: .removeStagedUpdate(table.sparkleJobLabels, table.sparkleCache), in: system.calls))
    let trash = try #require(Self.index(of: .trashApp(Self.releaseID), in: system.calls))
    #expect(removal < trash)
    #expect(result.decisions.contains { $0.verb == "stagedUpdate" && $0.fields.first?.value == "removed" })
  }

  @Test(arguments: [StagedUpdateMoment.quit, .installOnQuit])
  func anUpdateStagedAfterTheRunsCleanupIsRemovedAgainAndLogged(_ moment: StagedUpdateMoment) async throws {
    let system = FakeUninstallSystem { $0.status = .notRegistered }
    let recorder = Recorder()
    let coordinator = Self.coordinator(system, recorder: recorder)
    _ = try await Self.run(coordinator, recorder: recorder, helper: .notRegistered, purge: false)
    let table = PurgeTable.release
    let removal = FakeUninstallSystem.Call.removeStagedUpdate(table.sparkleJobLabels, table.sparkleCache)
    #expect(system.calls.filter { $0 == removal }.count == 1)
    system.update { $0.staged = true }
    #expect(await OffPool.bounded(seconds: 10) { coordinator.removeStagedUpdate(at: moment) } == true)
    #expect(system.calls.filter { $0 == removal }.count == 2)
    #expect(system.calls.last == removal)
    let line = try #require(recorder.decisions.last)
    #expect(line.verb == "stagedUpdate")
    #expect(
      line.fields == [
        DecisionField(key: "result", value: "removed"),
        DecisionField(key: "at", value: moment == .quit ? "quit" : "installOnQuit"),
      ])
  }

  @Test func aStagedRemovalAtQuitThatHangsIsBoundedAndLogged() async {
    let system = FakeUninstallSystem { $0.delays = [.stagedRemove: 20] }
    let recorder = Recorder()
    let coordinator = Self.coordinator(system, recorder: recorder, timingOut: ["stagedAtQuit": 0.3])
    let start = ContinuousClock.now
    #expect(await OffPool.bounded(seconds: 30) { coordinator.removeStagedUpdate(at: .quit) } == false)
    #expect(ContinuousClock.now - start < .seconds(10))
    #expect(
      recorder.decisions.last?.fields == [
        DecisionField(key: "result", value: "timedOut"), DecisionField(key: "at", value: "quit"),
      ])
  }

  @Test(arguments: [UninstallCoordinator.Mode.app, .headless])
  func theStagedUpdateCleanupRunsOnEveryRunEvenWhenNothingLooksStaged(_ mode: UninstallCoordinator.Mode)
    async throws
  {
    let (result, system) = try await Self.quick(helper: .notRegistered, purge: false, mode: mode)
    let table = PurgeTable.release
    let staged = try #require(Self.index(of: .updateStagedForQuit, in: system.calls))
    let removal = try #require(
      Self.index(of: .removeStagedUpdate(table.sparkleJobLabels, table.sparkleCache), in: system.calls))
    #expect(staged < removal)
    let line = try #require(result.decisions.first { $0.verb == "stagedUpdate" })
    #expect(line.fields == [DecisionField(key: "result", value: "removed"), DecisionField(key: "staged", value: "no")])
  }

  @Test func aStagedReadThatTimesOutStillRemovesTheJobsAndARemovalThatTimesOutStillTrashes() async throws {
    let slowRead = FakeUninstallSystem { $0.delays = [.staged: 3] }
    let recorder = Recorder()
    let read = try await Self.run(
      Self.coordinator(slowRead, recorder: recorder, timingOut: ["staged": 0.5]),
      recorder: recorder, helper: .notRegistered, purge: false)
    #expect(slowRead.calls.contains { if case .removeStagedUpdate = $0 { true } else { false } })
    let readLine = try #require(read.decisions.first { $0.verb == "stagedUpdate" })
    #expect(readLine.fields.contains(DecisionField(key: "staged", value: "timedOut")))

    let slowRemoval = FakeUninstallSystem { $0.delays = [.stagedRemove: 3] }
    let removalRecorder = Recorder()
    let removal = try await Self.run(
      Self.coordinator(slowRemoval, recorder: removalRecorder, timingOut: ["stagedRemove": 0.5]),
      recorder: removalRecorder, helper: .notRegistered, purge: false)
    let removalLine = try #require(removal.decisions.first { $0.verb == "stagedUpdate" })
    #expect(removalLine.fields.first == DecisionField(key: "result", value: "timedOut"))
    #expect(slowRemoval.calls.last == .trashApp(Self.releaseID))
  }

  @Test func headlessModeNeverTrashesAndHasNoTrashRow() async throws {
    let (result, system) = try await Self.quick(helper: .enabled, purge: true, mode: .headless) {
      $0.sleepDisabled = [true, false]
      $0.staged = true
    }
    #expect(!result.report.steps.contains(.trashApp))
    #expect(!system.calls.contains { if case .trashApp = $0 { true } else { false } })
    #expect(system.calls.contains { if case .removeStagedUpdate = $0 { true } else { false } })
    #expect(result.report.outcome == .uninstalled)
    #expect(
      UninstallCoordinator(system: system, table: .release, mode: .headless).steps(helperInstalled: true, purge: true)
        == [.stopKeepAwake, .removeHelper, .restoreSleep, .removeLoginItem, .purge])
  }

  @Test func theDevTablePassesTheDevIdentifierAndFolders() async throws {
    let (_, system) = try await Self.quick(helper: .notRegistered, purge: true, table: .dev) { $0.staged = true }
    let dev = PurgeTable.dev
    #expect(system.calls.contains(.removeUserItems(dev.userItems)))
    #expect(dev.userItems.first?.relativePath == "Library/Application Support/Overtime Dev")
    #expect(system.calls.contains(.removeStagedUpdate(dev.sparkleJobLabels, dev.sparkleCache)))
    #expect(system.calls.last == .trashApp("io.github.ivanhernandez-dev.overtime.dev"))
    let (_, headless) = try await Self.quick(helper: .notRegistered, purge: true, mode: .headless, table: .dev)
    #expect(headless.calls.contains(.purgeDefaults("io.github.ivanhernandez-dev.overtime.dev")))
  }

  @Test func theAppLeavesItsPreferencesToTheQuitAndTheRowSaysSo() async throws {
    let system = FakeUninstallSystem()
    let recorder = Recorder()
    let coordinator = Self.coordinator(system, recorder: recorder, stepTimeout: 10, stopTimeout: 10, adminTimeout: 10)
    let result = try await Self.run(coordinator, recorder: recorder, helper: .notRegistered, purge: true)
    #expect(!system.calls.contains { if case .purgeDefaults = $0 { true } else { false } })
    #expect(result.report.status(of: .purge) == .done)
    #expect(result.report.notes[.purge] == UninstallCopy.preferencesAtQuitCaption)
    let purge = try #require(result.decisions.first { $0.verb == "purge" })
    #expect(purge.fields.contains(DecisionField(key: "defaults", value: "atQuit")))

    let before = system.calls.count
    let purged = await OffPool.run { coordinator.purgePreferencesAtQuit() }
    #expect(purged)
    let table = PurgeTable.release
    #expect(
      Array(system.calls.dropFirst(before)) == [
        .purgeDefaults(table.appIdentifier), .removeUserItems([table.preferencesItem]),
      ])
    #expect(table.preferencesItem.relativePath == "Library/Preferences/\(table.appIdentifier).plist")
    #expect(table.userItems.contains(table.preferencesItem))
    let line = try #require(recorder.decisions.last)
    #expect(line.verb == "preferences")
    #expect(line.fields == [DecisionField(key: "result", value: "done")])
  }

  @Test func aPreferencesPurgeAtQuitThatHangsIsBoundedAndLogged() async throws {
    let system = FakeUninstallSystem { $0.delays = [.defaults: 3] }
    let recorder = Recorder()
    let coordinator = Self.coordinator(system, recorder: recorder, timingOut: ["preferences": 0.5])
    let purged = await OffPool.bounded(seconds: 10) { coordinator.purgePreferencesAtQuit() }
    #expect(purged == false)
    #expect(recorder.decisions.last?.fields == [DecisionField(key: "result", value: "timedOut")])
  }

  @Test func theStepListFollowsTheHelperThePurgeAndTheMode() {
    let app = UninstallCoordinator(system: FakeUninstallSystem(), table: .release, mode: .app)
    #expect(app.steps(helperInstalled: false, purge: false) == [.stopKeepAwake, .removeLoginItem, .trashApp])
    #expect(
      app.steps(helperInstalled: true, purge: false)
        == [.stopKeepAwake, .removeHelper, .restoreSleep, .removeLoginItem, .trashApp])
    #expect(app.steps(helperInstalled: false, purge: true) == [.stopKeepAwake, .removeLoginItem, .purge, .trashApp])
    #expect(app.steps(helperInstalled: true, purge: true) == UninstallStep.allCases)
    #expect(UninstallCoordinator.adminTimeoutSeconds == 605)
  }

  @Test func acrossEveryCombinationThereIsAtMostOnePromptAndOnlyAnOwnedValueIsCleared() async throws {
    let statuses: [HelperInstallerStatus] = [.enabled, .requiresApproval, .notRegistered, .notFound]
    let ownerships: [HelperOwnership] = [.owned, .notOwned, .unknown]
    let readings: [[Bool?]] = [[false], [true, false], [true, true], [true, nil], [nil]]
    let prompts: [AdminOutcome] = [.succeeded, .cancelled, .failed("x")]
    var runs = 0
    for status in statuses {
      for ownership in ownerships {
        for record in ownerships {
          for reading in readings {
            for prompt in prompts {
              for purge in [false, true] {
                for unregister in [true, false] {
                  let (result, system) = try await Self.quick(helper: status, purge: purge) {
                    $0.ownership = ownership
                    $0.record = record
                    $0.sleepDisabled = reading
                    $0.admin = prompt
                    $0.unregister = unregister
                    $0.staged = true
                  }
                  runs += 1
                  let label =
                    "\(status) \(ownership) record=\(record) \(reading) \(prompt) "
                    + "purge=\(purge) unregister=\(unregister)"
                  let effective = status == .enabled && ownership != .unknown ? ownership : record
                  Self.expectSweepInvariants(
                    result, system, status: status, effective: effective, unregister: unregister, label: label)
                }
              }
            }
          }
        }
      }
    }
    #expect(runs == 2_160)
  }

  static func expectSweepInvariants(
    _ result: Outcome, _ system: FakeUninstallSystem, status: HelperInstallerStatus, effective: HelperOwnership,
    unregister: Bool, label: String
  ) {
    let commands = Self.admins(system.calls)
    #expect(commands.count <= 1, "\(label)")
    #expect(result.report.adminPrompts == commands.count, "\(label)")
    if effective != .owned {
      #expect(!commands.contains(.clearSleepDisabled), "\(label)")
      #expect(!commands.contains(.clearAndPurge), "\(label)")
    }
    if result.report.sleepDisabledLeft == .unknown || result.report.sleepDisabledLeft == .owned {
      #expect(result.report.outcome != .uninstalled, "\(label)")
    }
    if commands.contains(.purgeRootFolders) {
      #expect(result.report.sleepDisabledLeft != .unknown, "\(label)")
    }
    let installed = UninstallCoordinator.attemptsHelper(status)
    #expect(installed == (status != .notRegistered), "\(label)")
    if !installed {
      #expect(commands.isEmpty, "\(label)")
    }
    if installed, !unregister {
      #expect(result.report.outcome == .stopped, "\(label)")
      #expect(system.calls.last == .unregister, "\(label)")
    }
    for decision in result.decisions {
      #expect(decision.keyword == .uninstall, "\(label)")
      #expect(!decision.verb.contains("/"), "\(label)")
      for field in decision.fields {
        #expect(!field.key.contains("/") && !field.value.contains("/"), "\(label) \(field)")
      }
    }
  }
}
