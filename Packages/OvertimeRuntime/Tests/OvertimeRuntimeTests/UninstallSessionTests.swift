import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import Testing
import os

struct UninstallSessionTests {
  @Test func everyFixedUninstallStringMatchesTheUISpec() {
    let pinned: [(String, String)] = [
      (UninstallStep.stopKeepAwake.title, "Stop keeping the Mac awake"),
      (UninstallStep.removeHelper.title, "Remove unplug protection"),
      (UninstallStep.restoreSleep.title, "Turn system sleep back on if unplug protection turned it off"),
      (UninstallStep.removeLoginItem.title, "Remove Overtime from your login items"),
      (UninstallStep.purge.title, "Remove settings, state and logs"),
      (UninstallStep.trashApp.title, "Move Overtime to the Trash"),
      (UninstallCopy.confirmTitle, "Uninstall Overtime?"),
      (UninstallCopy.runningTitle, "Uninstalling Overtime…"),
      (UninstallCopy.stoppedTitle, "Uninstall stopped"),
      (UninstallCopy.uninstalledTitle, "Overtime is uninstalled"),
      (UninstallCopy.problemsTitle, "Uninstall finished with problems"),
      (UninstallCopy.checklistLabel, "Uninstalling will:"),
      (UninstallCopy.purgeLabel, "Also remove settings, state and logs"),
      (
        UninstallCopy.untouchedCaption,
        "Overtime doesn't touch other apps, or the permissions you gave it in System Settings."
      ),
      (UninstallCopy.administratorOnceCaption, "macOS may ask for your administrator password once."),
      (UninstallCopy.keepLabel, "Keep Overtime"),
      (UninstallCopy.uninstallLabel, "Uninstall Overtime"),
      (UninstallCopy.quitLabel, "Quit Overtime"),
      (UninstallCopy.retryLabel, "Try Uninstalling Again"),
      (UninstallCopy.showInFinderLabel, "Show in Finder"),
      (UninstallCopy.openLoginItemsLabel, "Open Login Items"),
      (UninstallCopy.keepAwakeNotRunningCaption, "Keep-awake wasn't running."),
      (
        UninstallCopy.stopUnconfirmedCaption,
        "Overtime couldn't confirm that keep-awake stopped. Normal sleep comes back when Overtime quits."
      ),
      (UninstallCopy.helperNotRemovedCaption, "macOS didn't remove the helper."),
      (
        UninstallCopy.sleepDisabledCancelledCaption,
        "You cancelled the administrator prompt. Sleep is still turned off system-wide."
      ),
      (
        UninstallCopy.sleepDisabledFailedCaption,
        "Couldn't turn sleep back on. Run this in Terminal: " + Hints.sleepDisabledCommand
      ),
      (UninstallCopy.sleepDisabledNotOwnedCaption, "Overtime didn't turn sleep off, so it left the setting alone."),
      (
        UninstallCopy.sleepDisabledUnknownCaption,
        "Overtime can't tell who turned sleep off, so it left the setting alone."
      ),
      (
        UninstallCopy.sleepDisabledUnknownRowCaption,
        "Overtime can't tell who set this, so the uninstall left it alone. "
          + "Until it's cleared, the Mac can't sleep at all."
      ),
      (UninstallCopy.loginItemFailedCaption, "Couldn't remove the login item."),
      (
        UninstallCopy.rootFoldersLeftCaption,
        "Removed your settings and logs. Overtime's folders in /Library are still there."
      ),
      (UninstallCopy.userFilesFailedCaption, "Some of Overtime's files couldn't be deleted."),
      (UninstallCopy.preferencesAtQuitCaption, "Overtime removes its preferences when it quits."),
      (UninstallCopy.trashFailedCaption, "Couldn't move Overtime to the Trash."),
      (UninstallCopy.waitingForAdministratorCaption, "Waiting for your administrator password…"),
      (UninstallCopy.quitWaitingCaption, "Overtime quits when this step finishes."),
      (
        UninstallCopy.stoppedBody,
        "Overtime couldn't remove unplug protection, so it stopped before removing anything else. "
          + "Overtime is still installed, and keep-awake is off."
      ),
      (
        UninstallCopy.stoppedAdvice,
        "In System Settings > General > Login Items & Extensions, check Overtime under Allow in the Background, "
          + "then try again. To keep using Overtime instead, quit it and open it again."
      ),
      (UninstallCopy.stillToDoLabel, "Still to do:"),
      (UninstallCopy.manualLoginItem, "Remove Overtime in System Settings > General > Login Items & Extensions."),
      (UninstallCopy.manualTrash, "Drag Overtime to the Trash."),
      (UninstallCopy.manualRestart, "If the Mac doesn't sleep after Overtime quits, restart the Mac."),
      (UninstallCopy.sleepDisabledOwnedCaption, "Until it's cleared, the Mac can't sleep at all."),
      (
        UninstallCopy.sleepDisabledNotOwnedRowCaption,
        "Overtime didn't set this, so the uninstall left it alone. Until it's cleared, the Mac can't sleep at all."
      ),
      (UninstallCopy.runningAnnouncement, "Uninstalling Overtime"),
      (UninstallCopy.stoppedAnnouncement, "Uninstall stopped. Overtime is still installed."),
      (UninstallCopy.headlessUninstalled, "Overtime is uninstalled."),
      (UninstallCopy.headlessProblems, "Uninstall finished with problems. See the lines above."),
      (UninstallCopy.headlessStopped, "Uninstall stopped. Overtime is still installed."),
      (HeadlessUninstall.askedToQuitLine, "Asked the running Overtime to quit."),
      (
        HeadlessUninstall.stillRunningLine,
        "Overtime is still running. Quit it, then run Overtime --uninstall again."
      ),
      (UninstallCopy.panelTitle, "Uninstalling"),
      (UninstallCopy.panelReason, "Keep-awake is off while Overtime uninstalls. The Mac sleeps normally."),
      (UninstallCopy.panelAccessibilityLabel, "Overtime, uninstalling"),
    ]
    for (actual, expected) in pinned {
      #expect(actual == expected)
    }
    #expect(UninstallCopy.sleepDisabledCancelledCaption == SleepDisabledClearing.cancelledCaption)
    #expect(UninstallCopy.sleepDisabledFailedCaption == SleepDisabledClearing.failedCaption)
  }

  @Test func theNotOwnedHeadlessLineEndsWithTheSharedCommand() {
    #expect(
      HeadlessUninstall.notOwnedLine
        == "Sleep is turned off system-wide (SleepDisabled). Overtime didn't set this, so it left it alone. "
        + "To turn sleep back on, run: " + Hints.sleepDisabledCommand)
    #expect(HeadlessUninstall.notOwnedLine.hasSuffix(Hints.sleepDisabledCommand))
  }

  @Test func theUnknownOwnerHeadlessLineSaysOvertimeCannotTellAndEndsWithTheSharedCommand() {
    #expect(
      HeadlessUninstall.unknownOwnerLine
        == "Sleep is turned off system-wide (SleepDisabled). Overtime can't tell who set this, so it left it alone. "
        + "To turn sleep back on, run: " + Hints.sleepDisabledCommand)
  }

  @Test func thePurgeCaptionNamesTheFoldersAndAddsLibraryWithTheHelper() {
    let release = UninstallSession(helperInstalled: false, table: .release)
    let releaseText =
      "Deletes ~/Library/Application Support/Overtime, ~/Library/Logs/Overtime, "
      + "Overtime's preferences and its update cache."
    #expect(release.purgeCaption == releaseText)
    let withHelper = UninstallSession(helperInstalled: true, table: .release)
    #expect(withHelper.purgeCaption == releaseText + " Overtime's folders in /Library are deleted too.")
    let dev = UninstallSession(helperInstalled: true, table: .dev)
    let devText =
      "Deletes ~/Library/Application Support/Overtime Dev, ~/Library/Logs/Overtime Dev, "
      + "Overtime's preferences and its update cache. Overtime's folders in /Library are deleted too."
    #expect(dev.purgeCaption == devText)
  }

  @Test func theManualTemplatesUseTheTableFolder() {
    let password = " in Finder. macOS asks for your administrator password."
    #expect(
      UninstallCopy.manualRootFolders(folderName: "Overtime")
        == "Delete /Library/Application Support/Overtime and /Library/Logs/Overtime" + password)
    #expect(
      UninstallCopy.manualRootFolders(folderName: "Overtime Dev")
        == "Delete /Library/Application Support/Overtime Dev and /Library/Logs/Overtime Dev" + password)
    #expect(
      UninstallCopy.manualUserFiles(folderName: "Overtime")
        == "Delete the rest of ~/Library/Application Support/Overtime and ~/Library/Logs/Overtime in Finder.")
    #expect(
      UninstallCopy.manualUserFiles(folderName: "Overtime Dev")
        == "Delete the rest of ~/Library/Application Support/Overtime Dev and ~/Library/Logs/Overtime Dev"
        + " in Finder.")
  }

  @Test(arguments: [(false, false), (true, false), (false, true), (true, true)])
  func theConfirmStepsFollowTheHelperAndThePurge(_ helper: Bool, _ purge: Bool) {
    var session = UninstallSession(helperInstalled: helper, purge: purge, table: .release)
    var expected: [UninstallStep] = [.stopKeepAwake]
    if helper { expected += [.removeHelper, .restoreSleep] }
    expected.append(.removeLoginItem)
    if purge { expected.append(.purge) }
    expected.append(.trashApp)
    #expect(session.phase == .confirm)
    #expect(session.title == "Uninstall Overtime?")
    #expect(session.steps == expected)
    #expect(session.steps.allSatisfy { session.statuses[$0] == .pending })

    session.purge.toggle()
    #expect(session.steps.contains(.purge) == !purge)
    #expect(session.statuses[.purge] == (purge ? nil : .pending))
    session.purge.toggle()
    #expect(session.steps == expected)
  }

  @Test func beginMovesToRunningAndPurgeIsFixedFromThen() {
    var session = UninstallSession(helperInstalled: true, table: .release)
    #expect(session.announcement == nil)
    let began = session.begin()
    #expect(began)
    #expect(session.phase == .running)
    #expect(session.title == "Uninstalling Overtime…")
    #expect(session.announcement == "Uninstalling Overtime")
    session.purge = true
    #expect(!session.purge)
    #expect(!session.steps.contains(.purge))
    let beganTwice = session.begin()
    #expect(!beganTwice)
  }

  @Test func progressUpdatesTheRowsAndTheWaitingCaptionShowsOnlyOnTheWaitingStep() {
    var session = UninstallSession(helperInstalled: true, purge: true, table: .release)
    session.apply(.started(.stopKeepAwake))
    #expect(session.statuses[.stopKeepAwake] == .pending)
    session.begin()
    session.apply(.started(.stopKeepAwake))
    #expect(session.statuses[.stopKeepAwake] == .running)
    session.apply(.finished(.stopKeepAwake, .done, note: UninstallCopy.keepAwakeNotRunningCaption))
    #expect(session.statuses[.stopKeepAwake] == .done)
    #expect(session.caption(for: .stopKeepAwake) == "Keep-awake wasn't running.")
    session.apply(.started(.restoreSleep))
    session.apply(.waitingForAdministrator(.restoreSleep))
    #expect(session.waitingStep == .restoreSleep)
    #expect(session.caption(for: .restoreSleep) == "Waiting for your administrator password…")
    #expect(session.caption(for: .purge) == nil)
    #expect(session.caption(for: .removeHelper) == nil)
    session.apply(.finished(.restoreSleep, .skipped(SleepDisabledClearing.cancelledCaption)))
    #expect(session.waitingStep == nil)
    #expect(session.caption(for: .restoreSleep) == SleepDisabledClearing.cancelledCaption)
    #expect(session.announcement == "Uninstalling Overtime")
    session.apply(.finished(.removeLoginItem, .failed(UninstallCopy.loginItemFailedCaption)))
    #expect(
      session.announcement
        == "Remove Overtime from your login items, failed. Couldn't remove the login item.")
    #expect(
      session.spokenText(for: .stopKeepAwake) == "Stop keeping the Mac awake, done. Keep-awake wasn't running.")
    #expect(session.spokenText(for: .trashApp) == "Move Overtime to the Trash, not started")
  }

  static func report(
    _ outcome: UninstallOutcome, steps: [UninstallStep], _ statuses: [UninstallStep: StepStatus] = [:],
    manual: [UninstallManualStep] = [], left: SleepDisabledLeft? = nil
  ) -> UninstallReport {
    var all = Dictionary(uniqueKeysWithValues: steps.map { ($0, StepStatus.done) })
    all.merge(statuses) { $1 }
    return UninstallReport(
      outcome: outcome, steps: steps, statuses: all, sleepDisabledLeft: left, manualSteps: manual)
  }

  @Test func aStoppedReportMovesToStoppedAndARetryRestartsFromTheHelper() {
    var session = UninstallSession(helperInstalled: true, purge: true, table: .release)
    session.begin()
    let stopped = Self.report(
      .stopped, steps: session.steps,
      [
        .removeHelper: .failed(UninstallCopy.helperNotRemovedCaption), .restoreSleep: .pending,
        .removeLoginItem: .pending, .purge: .pending, .trashApp: .pending,
      ])
    session.finish(stopped)
    #expect(session.phase == .stopped)
    #expect(session.title == "Uninstall stopped")
    #expect(session.announcement == "Uninstall stopped. Overtime is still installed.")
    #expect(session.caption(for: .removeHelper) == "macOS didn't remove the helper.")
    #expect(session.manualStepLines.isEmpty)
    #expect(session.report == stopped)

    let retried = session.retryFromHelper()
    #expect(retried)
    #expect(session.phase == .running)
    #expect(session.resumeStep == .removeHelper)
    #expect(session.statuses[.stopKeepAwake] == .done)
    for step in [UninstallStep.removeHelper, .restoreSleep, .removeLoginItem, .purge, .trashApp] {
      #expect(session.statuses[step] == .pending)
    }
    #expect(session.announcement == "Uninstalling Overtime")
    let retriedTwice = session.retryFromHelper()
    #expect(!retriedTwice)
  }

  @Test func aCleanReportReadsUninstalled() {
    var session = UninstallSession(helperInstalled: false, table: .release)
    #expect(session.resumeStep == .stopKeepAwake)
    session.begin()
    session.finish(Self.report(.uninstalled, steps: session.steps))
    #expect(session.phase == .result)
    #expect(session.title == "Overtime is uninstalled")
    #expect(session.announcement == "Overtime is uninstalled")
    #expect(session.manualStepLines.isEmpty)
    #expect(session.sleepDisabledCaption == nil)
  }

  @Test(arguments: [
    [UninstallStep.trashApp: StepStatus.failed(UninstallCopy.trashFailedCaption)],
    [UninstallStep.purge: StepStatus.skipped(UninstallCopy.rootFoldersLeftCaption)],
    [:],
  ])
  func anySkippedFailedOrManualStepReadsFinishedWithProblems(_ statuses: [UninstallStep: StepStatus]) {
    var session = UninstallSession(helperInstalled: true, purge: true, table: .release)
    session.begin()
    let manual: [UninstallManualStep] = statuses.isEmpty ? [.restart] : []
    session.finish(Self.report(.finishedWithProblems, steps: session.steps, statuses, manual: manual))
    #expect(session.title == "Uninstall finished with problems")
    #expect(session.announcement == "Uninstall finished with problems")
  }

  @Test(arguments: [PurgeTable.release, .dev])
  func manualLinesFollowTheUISpecOrderWithTheTableFolder(_ table: PurgeTable) {
    var session = UninstallSession(helperInstalled: true, purge: true, table: table)
    session.begin()
    session.finish(
      Self.report(
        .finishedWithProblems, steps: session.steps, [.removeLoginItem: .failed(UninstallCopy.loginItemFailedCaption)],
        manual: [.loginItem, .trash, .rootFolders, .userFiles, .restart]))
    #expect(
      session.manualStepLines.map(\.text) == [
        "Remove Overtime in System Settings > General > Login Items & Extensions.",
        "Drag Overtime to the Trash.",
        UninstallCopy.manualRootFolders(folderName: table.folderName),
        UninstallCopy.manualUserFiles(folderName: table.folderName),
        "If the Mac doesn't sleep after Overtime quits, restart the Mac.",
      ])
    #expect(session.manualStepLines.map(\.step) == [.loginItem, .trash, .rootFolders, .userFiles, .restart])
    #expect(session.manualStepLines[2].text.contains("/Library/Application Support/\(table.folderName) and"))
  }

  @Test func theSleepDisabledCaptionFollowsWhoOwnsTheValue() {
    for (left, caption) in [
      (SleepDisabledLeft.owned, "Until it's cleared, the Mac can't sleep at all."),
      (
        .notOwned,
        "Overtime didn't set this, so the uninstall left it alone. Until it's cleared, the Mac can't sleep at all."
      ),
      (
        .unknown,
        "Overtime can't tell who set this, so the uninstall left it alone. "
          + "Until it's cleared, the Mac can't sleep at all."
      ),
    ] {
      var session = UninstallSession(helperInstalled: true, table: .release)
      session.begin()
      session.finish(Self.report(.finishedWithProblems, steps: session.steps, left: left))
      #expect(session.sleepDisabledCaption == caption)
    }
  }

  @Test func aValueLeftWithAnUnknownOwnerReadsFinishedWithProblemsEvenWithEveryRowDone() {
    var session = UninstallSession(helperInstalled: false, table: .release)
    session.begin()
    session.finish(Self.report(.finishedWithProblems, steps: session.steps, left: .unknown))
    #expect(session.title == UninstallCopy.problemsTitle)
    var notOwned = UninstallSession(helperInstalled: false, table: .release)
    notOwned.begin()
    notOwned.finish(Self.report(.uninstalled, steps: notOwned.steps, left: .notOwned))
    #expect(notOwned.title == UninstallCopy.uninstalledTitle)
  }

  @Test func aPendingQuitCaptionsOnlyTheRunningRowOfARunningUninstall() {
    var confirm = UninstallSession(helperInstalled: true, table: .release)
    confirm.noteQuitRequested()
    #expect(!confirm.quitPending)
    confirm.begin()
    confirm.apply(.started(.stopKeepAwake))
    #expect(confirm.caption(for: .stopKeepAwake) == nil)

    var session = UninstallSession(helperInstalled: true, table: .release)
    session.begin()
    session.apply(.started(.stopKeepAwake))
    session.noteQuitRequested()
    #expect(session.quitPending)
    #expect(session.caption(for: .stopKeepAwake) == "Overtime quits when this step finishes.")
    #expect(session.caption(for: .removeHelper) == nil)
    #expect(
      session.spokenText(for: .stopKeepAwake)
        == "Stop keeping the Mac awake, in progress. Overtime quits when this step finishes.")
    session.apply(.finished(.stopKeepAwake, .done, note: UninstallCopy.keepAwakeNotRunningCaption))
    #expect(session.caption(for: .stopKeepAwake) == "Keep-awake wasn't running.")
    session.apply(.started(.restoreSleep))
    session.apply(.waitingForAdministrator(.restoreSleep))
    #expect(session.caption(for: .restoreSleep) == "Overtime quits when this step finishes.")
    #expect(session.caption(for: .restoreSleep) != "Waiting for your administrator password…")
    session.finish(
      Self.report(
        .finishedWithProblems, steps: session.steps,
        [.restoreSleep: .skipped(SleepDisabledClearing.cancelledCaption)], left: .owned))
    #expect(session.phase == .result)
    #expect(session.caption(for: .restoreSleep) == SleepDisabledClearing.cancelledCaption)

    var finished = UninstallSession(helperInstalled: false, table: .release)
    finished.begin()
    finished.finish(Self.report(.uninstalled, steps: finished.steps))
    #expect(finished.phase == .result)
    finished.noteQuitRequested()
    #expect(!finished.quitPending)
  }

  struct ClearCase: Sendable, CustomTestStringConvertible {
    let name: String
    let helperInstalled: Bool
    let left: SleepDisabledLeft
    var statuses: [UninstallStep: StepStatus] = [:]
    var manual: [UninstallManualStep] = []
    let before: String
    let after: String

    var testDescription: String { name }
  }

  static let clearCases: [ClearCase] = [
    ClearCase(
      name: "no helper, left owned", helperInstalled: false, left: .owned, before: UninstallCopy.problemsTitle,
      after: UninstallCopy.uninstalledTitle),
    ClearCase(
      name: "no helper, left unknown", helperInstalled: false, left: .unknown, before: UninstallCopy.problemsTitle,
      after: UninstallCopy.uninstalledTitle),
    ClearCase(
      name: "helper, left unknown, row skipped", helperInstalled: true, left: .unknown,
      statuses: [.restoreSleep: .skipped(UninstallCopy.sleepDisabledUnknownCaption)],
      before: UninstallCopy.problemsTitle, after: UninstallCopy.problemsTitle),
    ClearCase(
      name: "no helper, left owned, trash failed", helperInstalled: false, left: .owned,
      statuses: [.trashApp: .failed(UninstallCopy.trashFailedCaption)], manual: [.trash],
      before: UninstallCopy.problemsTitle, after: UninstallCopy.problemsTitle),
    ClearCase(
      name: "no helper, left not owned", helperInstalled: false, left: .notOwned,
      before: UninstallCopy.uninstalledTitle, after: UninstallCopy.uninstalledTitle),
  ]

  @Test(arguments: Self.clearCases)
  func clearingALeftValueRereadsTheTitleWithoutIt(_ clearCase: ClearCase) {
    var session = UninstallSession(helperInstalled: clearCase.helperInstalled, table: .release)
    session.begin()
    session.noteSleepDisabledCleared()
    #expect(session.title == "Uninstalling Overtime…")
    #expect(session.announcement == "Uninstalling Overtime")
    let outcome: UninstallOutcome =
      clearCase.before == UninstallCopy.uninstalledTitle ? .uninstalled : .finishedWithProblems
    session.finish(
      Self.report(
        outcome, steps: session.steps, clearCase.statuses, manual: clearCase.manual, left: clearCase.left))
    #expect(session.title == clearCase.before)
    session.noteSleepDisabledCleared()
    #expect(session.title == clearCase.after)
    #expect(session.announcement == clearCase.after)
    let once = session
    session.noteSleepDisabledCleared()
    #expect(session == once)
  }

  @Test func headlessLinesReadTitleStatusAndCaption() {
    #expect(HeadlessUninstall.line(.removeLoginItem, .done) == "Remove Overtime from your login items: done")
    #expect(
      HeadlessUninstall.line(.stopKeepAwake, .done, note: UninstallCopy.keepAwakeNotRunningCaption)
        == "Stop keeping the Mac awake: done. Keep-awake wasn't running.")
    #expect(
      HeadlessUninstall.line(.purge, .skipped(UninstallCopy.rootFoldersLeftCaption))
        == "Remove settings, state and logs: skipped. Removed your settings and logs. "
        + "Overtime's folders in /Library are still there.")
    #expect(
      HeadlessUninstall.line(.removeHelper, .failed(UninstallCopy.helperNotRemovedCaption))
        == "Remove unplug protection: failed. macOS didn't remove the helper.")
    #expect(HeadlessUninstall.finalLine(.uninstalled) == "Overtime is uninstalled.")
    #expect(
      HeadlessUninstall.finalLine(.finishedWithProblems) == "Uninstall finished with problems. See the lines above.")
    #expect(HeadlessUninstall.finalLine(.stopped) == "Uninstall stopped. Overtime is still installed.")
    #expect(HeadlessUninstall.exitCode(.uninstalled) == 0)
    #expect(HeadlessUninstall.exitCode(.finishedWithProblems) == 1)
    #expect(HeadlessUninstall.exitCode(.stopped) == 1)
  }

  final class Lines: Sendable {
    private let lines = OSAllocatedUnfairLock<[String]>(initialState: [])
    var all: [String] { lines.withLock { $0 } }
    func write(_ line: String) { lines.withLock { $0.append(line) } }
  }

  static func headless(
    _ system: FakeUninstallSystem, purge: Bool, mode: UninstallCoordinator.Mode = .headless,
    statusTimeout: Double = 10
  ) async throws -> (Int32, [String]) {
    let lines = Lines()
    let coordinator = UninstallCoordinator(
      system: system, table: .release, mode: mode, stepTimeoutSeconds: 10, stopTimeoutSeconds: 10,
      adminTimeoutSeconds: 10)
    let box = OSAllocatedUnfairLock<Int32?>(initialState: nil)
    let finished = await Engine.bounded(seconds: 30) {
      let code = await HeadlessUninstall.run(
        coordinator: coordinator, system: system, purge: purge, write: { lines.write($0) },
        statusTimeoutSeconds: statusTimeout)
      box.withLock { $0 = code }
    }
    #expect(finished)
    return (try #require(box.withLock { $0 }), lines.all)
  }

  @Test func theHeadlessRunPrintsOneLinePerStepThenTheFinalLineAndExitsZero() async throws {
    let system = FakeUninstallSystem {
      $0.status = .enabled
      $0.sleepDisabled = [true, false]
      $0.stop = .notRunning
    }
    let (code, lines) = try await Self.headless(system, purge: true)
    #expect(code == 0)
    #expect(
      lines == [
        "Stop keeping the Mac awake: done. Keep-awake wasn't running.",
        "Remove unplug protection: done",
        "Turn system sleep back on if unplug protection turned it off: done",
        "Remove Overtime from your login items: done",
        "Remove settings, state and logs: done",
        "Overtime is uninstalled.",
      ])
    #expect(system.calls.filter { $0 == .status }.count == 1)
    #expect(system.calls.first == .status)
    #expect(!system.calls.contains { if case .trashApp = $0 { true } else { false } })
  }

  @Test func aHeadlessRunGivenAnAppModeCoordinatorStillNeverTrashes() async throws {
    let system = FakeUninstallSystem()
    let (code, lines) = try await Self.headless(system, purge: false, mode: .app)
    #expect(code == 0)
    #expect(!system.calls.contains { if case .trashApp = $0 { true } else { false } })
    #expect(!lines.contains { $0.hasPrefix("Move Overtime to the Trash") })
  }

  @Test func aNotOwnedSleepDisabledPrintsItsLineBeforeTheFinalLine() async throws {
    let system = FakeUninstallSystem { $0.sleepDisabled = [true] }
    let (code, lines) = try await Self.headless(system, purge: false)
    #expect(code == 0)
    #expect(
      lines == [
        "Stop keeping the Mac awake: done",
        "Remove Overtime from your login items: done",
        HeadlessUninstall.notOwnedLine,
        "Overtime is uninstalled.",
      ])
  }

  @Test func theHeadlessUninstallRefusesToRunAsRootWithOneLine() {
    #expect(
      HeadlessUninstall.rootRefusal(effectiveUserID: 0)
        == "Run Overtime --uninstall as the user who installed Overtime, not with sudo.")
    #expect(HeadlessUninstall.rootRefusal(effectiveUserID: 501) == nil)
    let own = HeadlessUninstall.rootRefusal(effectiveUserID: getuid())
    #expect(own == (getuid() == 0 ? UninstallCopy.headlessRefusesRoot : nil))
  }

  final class Steps {
    private(set) var all: [String] = []

    func note(_ step: String) {
      all.append(step)
    }
  }

  @Test(arguments: [true, false])
  func theHeadlessRunRemovesSparklesStagedJobsBeforeItAsksTheRunningAppToQuit(_ exits: Bool) {
    let steps = Steps()
    var written: [String] = []
    let result = HeadlessUninstall.quitRunningInstance(
      removeStagedUpdate: { steps.note("staged") },
      findInstance: { () -> Int? in
        steps.note("find")
        return 42
      },
      requestQuit: { steps.note("quit \($0)") },
      waitForExit: { _ in
        steps.note("wait")
        return exits
      },
      write: { written.append($0) })
    #expect(steps.all == ["staged", "find", "quit 42", "wait"])
    #expect(result == (exits ? .quit : .stillRunning))
    #expect(
      written
        == (exits
          ? [HeadlessUninstall.askedToQuitLine]
          : [HeadlessUninstall.askedToQuitLine, HeadlessUninstall.stillRunningLine]))
  }

  @Test func withNoRunningAppTheStagedJobsAreStillRemovedAndNothingIsAskedToQuit() {
    let steps = Steps()
    var written: [String] = []
    let result = HeadlessUninstall.quitRunningInstance(
      removeStagedUpdate: { steps.note("staged") },
      findInstance: { () -> Int? in
        steps.note("find")
        return nil
      },
      requestQuit: { _ in steps.note("quit") },
      waitForExit: { _ in
        steps.note("wait")
        return true
      },
      write: { written.append($0) })
    #expect(steps.all == ["staged", "find"])
    #expect(result == .noInstance)
    #expect(written.isEmpty)
  }

  @Test func aHeadlessStatusReadThatTimesOutStillRemovesTheHelperAndNeverClearsSleep() async throws {
    let system = FakeUninstallSystem {
      $0.status = .notRegistered
      $0.delays = [.status: 3]
      $0.ownership = .unknown
      $0.record = .unknown
      $0.sleepDisabled = [true]
    }
    let (code, lines) = try await Self.headless(system, purge: false, statusTimeout: 0.2)
    #expect(code == 1)
    #expect(system.calls.first == .status)
    #expect(system.calls.contains(.ownership))
    #expect(system.calls.contains(.record))
    #expect(!system.calls.contains(.clear))
    #expect(system.calls.contains(.unregister))
    #expect(!system.calls.contains { if case .admin = $0 { true } else { false } })
    #expect(
      lines == [
        "Stop keeping the Mac awake: done",
        "Remove unplug protection: done",
        "Turn system sleep back on if unplug protection turned it off: skipped. "
          + UninstallCopy.sleepDisabledUnknownCaption,
        "Remove Overtime from your login items: done",
        HeadlessUninstall.unknownOwnerLine,
        "Uninstall finished with problems. See the lines above.",
      ])
  }

  @Test func anUnknownOwnerPrintsTheCommandAndExitsOneWithoutAPrompt() async throws {
    let system = FakeUninstallSystem {
      $0.record = .unknown
      $0.sleepDisabled = [true]
    }
    let (code, lines) = try await Self.headless(system, purge: false)
    #expect(code == 1)
    #expect(
      lines == [
        "Stop keeping the Mac awake: done",
        "Remove Overtime from your login items: done",
        HeadlessUninstall.unknownOwnerLine,
        "Uninstall finished with problems. See the lines above.",
      ])
    #expect(!system.calls.contains { if case .admin = $0 { true } else { false } })
  }

  @Test func aHeadlessRunWithProblemsExitsOne() async throws {
    let system = FakeUninstallSystem { $0.loginItem = false }
    let (code, lines) = try await Self.headless(system, purge: false)
    #expect(code == 1)
    #expect(lines.last == "Uninstall finished with problems. See the lines above.")
    #expect(lines.contains("Remove Overtime from your login items: failed. Couldn't remove the login item."))
  }

  @Test func aStoppedHeadlessRunExitsOneAfterTheHelperLine() async throws {
    let system = FakeUninstallSystem {
      $0.status = .enabled
      $0.unregister = false
    }
    let (code, lines) = try await Self.headless(system, purge: true)
    #expect(code == 1)
    #expect(
      lines == [
        "Stop keeping the Mac awake: done",
        "Remove unplug protection: failed. macOS didn't remove the helper.",
        "Uninstall stopped. Overtime is still installed.",
      ])
  }
}
