import Foundation
import OvertimeAppSupport
import OvertimeCore
import Testing
import os

@testable import Overtime

@MainActor
struct UninstallSheetTests {
  final class FakeSystem: UninstallSystem {
    enum Call: Sendable, Equatable {
      case stop
      case ownership
      case record
      case clear
      case unregister
      case readSleepDisabled
      case admin(UninstallAdminCommand)
      case loginItem
      case purgeDefaults
      case removeUserItems
      case staged
      case removeStaged
      case trash
    }

    struct Answers: Sendable {
      var stop = UninstallEngineStop.stopped
      var ownership = HelperOwnership.owned
      var record = HelperOwnership.notOwned
      var clear = true
      var unregister = true
      var unregisterDelay: Double = 0
      var sleepDisabled: [Bool?] = [false]
      var admin = AdminOutcome.succeeded
      var holdsAdmin = false
      var loginItem = true
      var userItems = true
      var staged = false
      var trash = UninstallTrashResult.trashed
    }

    private struct State: Sendable {
      var answers: Answers
      var calls: [Call] = []
      var reads = 0
      var heldAnswer: AdminOutcome?
      var promptCancels = 0
    }

    static let heldAdminBoundSeconds: Double = 20

    private let state: OSAllocatedUnfairLock<State>

    init(_ configure: (inout Answers) -> Void = { _ in }) {
      var answers = Answers()
      configure(&answers)
      state = OSAllocatedUnfairLock(initialState: State(answers: answers))
    }

    var calls: [Call] {
      state.withLock { $0.calls }
    }

    func count(_ call: Call) -> Int {
      calls.filter { $0 == call }.count
    }

    func update(_ change: @Sendable (inout Answers) -> Void) {
      state.withLock { change(&$0.answers) }
    }

    private func record(_ call: Call) -> Answers {
      state.withLock { state -> Answers in
        state.calls.append(call)
        return state.answers
      }
    }

    func stopKeepAwake() async -> UninstallEngineStop {
      record(.stop).stop
    }

    func helperStatus() -> HelperInstallerStatus {
      .notRegistered
    }

    func helperOwnership() -> HelperOwnership {
      record(.ownership).ownership
    }

    func recordOwnership() -> HelperOwnership {
      record(.record).record
    }

    func helperClear() -> Bool {
      record(.clear).clear
    }

    func unregisterHelper() -> Bool {
      let answers = record(.unregister)
      if answers.unregisterDelay > 0 {
        Thread.sleep(forTimeInterval: answers.unregisterDelay)
      }
      return answers.unregister
    }

    func readSleepDisabled() -> Bool? {
      let (answers, index) = state.withLock { state -> (Answers, Int) in
        state.calls.append(.readSleepDisabled)
        defer { state.reads += 1 }
        return (state.answers, state.reads)
      }
      guard let last = answers.sleepDisabled.last else { return nil }
      return index < answers.sleepDisabled.count ? answers.sleepDisabled[index] : last
    }

    var promptCancels: Int {
      state.withLock { $0.promptCancels }
    }

    func answerHeldAdmin(_ outcome: AdminOutcome) {
      state.withLock { $0.heldAnswer = outcome }
    }

    func cancelPrompt() {
      state.withLock { state in
        state.promptCancels += 1
        if state.heldAnswer == nil {
          state.heldAnswer = .cancelled
        }
      }
    }

    func runAdmin(_ command: UninstallAdminCommand) -> AdminOutcome {
      let answers = record(.admin(command))
      guard answers.holdsAdmin else { return answers.admin }
      let deadline = Date().addingTimeInterval(Self.heldAdminBoundSeconds)
      while Date() < deadline {
        if let answer = state.withLock({ $0.heldAnswer }) {
          return answer
        }
        Thread.sleep(forTimeInterval: 0.01)
      }
      return .failed("held prompt never answered")
    }

    func unregisterLoginItem() -> Bool {
      record(.loginItem).loginItem
    }

    func purgeDefaults(appIdentifier: String) {
      _ = record(.purgeDefaults)
    }

    func removeUserItems(_ items: [PurgeItem]) -> Bool {
      record(.removeUserItems).userItems
    }

    func updateStagedForQuit() -> Bool {
      record(.staged).staged
    }

    func removeStagedUpdate(labels: [String], cache: PurgeItem) -> Bool {
      _ = record(.removeStaged)
      return true
    }

    func trashApp(expectedIdentifier: String) -> UninstallTrashResult {
      record(.trash).trash
    }
  }

  final class Counter {
    private(set) var count = 0

    func bump() {
      count += 1
    }
  }

  final class Reads: Sendable {
    private let state: OSAllocatedUnfairLock<(values: [Bool?], index: Int)>

    init(_ values: [Bool?]) {
      state = OSAllocatedUnfairLock(initialState: (values, 0))
    }

    func read() -> Bool? {
      state.withLock { state in
        defer { state.index += 1 }
        guard let last = state.values.last else { return nil }
        return state.index < state.values.count ? state.values[state.index] : last
      }
    }
  }

  final class Prompt: AdminPrompt {
    private let state: OSAllocatedUnfairLock<(outcome: AdminOutcome, calls: Int)>

    init(_ outcome: AdminOutcome) {
      state = OSAllocatedUnfairLock(initialState: (outcome, 0))
    }

    var calls: Int {
      state.withLock { $0.calls }
    }

    func clearSleepDisabled() -> AdminOutcome {
      state.withLock { state in
        state.calls += 1
        return state.outcome
      }
    }
  }

  final class Copied {
    private(set) var texts: [String] = []

    func append(_ text: String) {
      texts.append(text)
    }
  }

  final class Decisions: Sendable {
    private let state = OSAllocatedUnfairLock<[Decision]>(initialState: [])

    var all: [Decision] {
      state.withLock { $0 }
    }

    func append(_ decision: Decision) {
      state.withLock { $0.append(decision) }
    }

    func last(_ verb: String) -> Decision? {
      all.last { $0.verb == verb }
    }
  }

  @MainActor final class Fixture {
    let system: FakeSystem
    let panel = PanelModel()
    let quits = Counter()
    let loginItemsOpened = Counter()
    let reveals = Counter()
    let copied = Copied()
    let reads: Reads
    let prompt: Prompt
    let decisions = Decisions()
    let model: UninstallModel

    init(
      status: HelperInstallerStatus = .enabled, reads: [Bool?] = [false], prompt: AdminOutcome = .succeeded,
      statusDelay: Double = 0, statusTimeout: Double = UninstallModel.statusTimeoutSeconds,
      _ configure: (inout FakeSystem.Answers) -> Void = { _ in }
    ) {
      let system = FakeSystem(configure)
      self.system = system
      let reads = Reads(reads)
      self.reads = reads
      let prompt = Prompt(prompt)
      self.prompt = prompt
      let quits = quits
      let loginItemsOpened = loginItemsOpened
      let reveals = reveals
      let copied = copied
      let decisions = decisions
      let coordinator = UninstallCoordinator(
        system: system, table: .dev, mode: .app, stepTimeoutSeconds: 10, stopTimeoutSeconds: 10,
        adminTimeoutSeconds: 10, log: { decisions.append($0) })
      model = UninstallModel(
        coordinator: coordinator, table: .dev,
        helperStatus: {
          if statusDelay > 0 {
            Thread.sleep(forTimeInterval: statusDelay)
          }
          return status
        }, panel: panel, quit: { quits.bump() },
        openLoginItems: { loginItemsOpened.bump() }, revealApp: { reveals.bump() },
        readSleepDisabled: { reads.read() }, adminPrompt: prompt, copyToPasteboard: { copied.append($0) },
        cancelAdminPrompt: { system.cancelPrompt() }, statusTimeoutSeconds: statusTimeout)
    }

    func run(purge: Bool = false) async -> Bool {
      await model.present()
      model.setPurge(purge)
      model.confirm()
      return await settle()
    }

    func settle() async -> Bool {
      await model.settled(seconds: 10)
    }
  }

  @Test func presentingWithTheHelperInstalledShowsConfirmWithTheFiveApplicableRowsAndThePurgeOff() async throws {
    let fixture = Fixture(status: .enabled)
    await fixture.model.present()
    let session = try #require(fixture.model.session)
    #expect(fixture.model.isPresented)
    #expect(session.phase == .confirm)
    #expect(session.steps == [.stopKeepAwake, .removeHelper, .restoreSleep, .removeLoginItem, .trashApp])
    #expect(!session.purge)
    #expect(session.title == "Uninstall Overtime?")
    #expect(session.helperInstalled)
    #expect(fixture.system.calls.isEmpty)
  }

  @Test func presentingWithNoHelperShowsTheThreeRowsThatAlwaysApply() async {
    let fixture = Fixture(status: .notRegistered)
    await fixture.model.present()
    #expect(fixture.model.session?.steps == [.stopKeepAwake, .removeLoginItem, .trashApp])
    #expect(fixture.model.session?.helperInstalled == false)
  }

  @Test func aHelperWaitingForApprovalCountsAsInstalled() async {
    let fixture = Fixture(status: .requiresApproval)
    await fixture.model.present()
    #expect(fixture.model.session?.steps.contains(.removeHelper) == true)
  }

  @Test func aStatusReadThatTimesOutShowsTheHelperRowsAndNeverClearsSleepWithoutConsent() async throws {
    let fixture = Fixture(status: .notRegistered, statusDelay: 3, statusTimeout: 0.2) {
      $0.ownership = .unknown
      $0.record = .unknown
      $0.sleepDisabled = [true]
    }
    await fixture.model.present()
    #expect(fixture.model.session?.steps.contains(.removeHelper) == true)
    #expect(fixture.model.session?.steps.contains(.restoreSleep) == true)
    fixture.model.confirm()
    #expect(await fixture.settle())
    let session = try #require(fixture.model.session)
    #expect(fixture.system.count(.unregister) == 1)
    #expect(fixture.system.count(.ownership) == 1)
    #expect(fixture.system.count(.record) == 1)
    #expect(fixture.system.count(.admin(.clearSleepDisabled)) == 0)
    #expect(session.statuses[.restoreSleep] == .skipped(UninstallCopy.sleepDisabledUnknownCaption))
    #expect(session.sleepDisabledCaption == UninstallCopy.sleepDisabledUnknownRowCaption)
  }

  @Test func aStatusReadThatTimesOutStillTakesTheHelpersOwnAnswer() async throws {
    let fixture = Fixture(status: .notRegistered, reads: [true, false], statusDelay: 3, statusTimeout: 0.2) {
      $0.ownership = .notOwned
      $0.record = .unknown
      $0.sleepDisabled = [true]
    }
    #expect(await fixture.run())
    let session = try #require(fixture.model.session)
    #expect(fixture.system.count(.ownership) == 1)
    #expect(fixture.system.count(.record) == 0)
    #expect(fixture.system.count(.admin(.clearSleepDisabled)) == 0)
    #expect(session.caption(for: .restoreSleep) == UninstallCopy.sleepDisabledNotOwnedCaption)
    #expect(session.sleepDisabledCaption == UninstallCopy.sleepDisabledNotOwnedRowCaption)
  }

  @Test func aHelperMacOSCannotFindStillGetsTheHelperRowsAndAFailedUnregisterStops() async throws {
    let fixture = Fixture(status: .notFound) { $0.unregister = false }
    await fixture.model.present()
    #expect(fixture.model.session?.steps.contains(.removeHelper) == true)
    fixture.model.confirm()
    #expect(await fixture.settle())
    #expect(fixture.model.session?.phase == .stopped)
    #expect(fixture.system.count(.unregister) == 1)
    #expect(fixture.system.count(.trash) == 0)
  }

  @Test func checkingThePurgeBoxAddsTheRowAndItsCaptionNamesTheDebugFolders() async {
    let fixture = Fixture(status: .enabled)
    await fixture.model.present()
    fixture.model.setPurge(true)
    let expected: [UninstallStep] = [.stopKeepAwake, .removeHelper, .restoreSleep, .removeLoginItem, .purge, .trashApp]
    #expect(fixture.model.session?.steps == expected)
    #expect(
      fixture.model.session?.purgeCaption
        == "Deletes ~/Library/Application Support/Overtime Dev, ~/Library/Logs/Overtime Dev, "
        + "Overtime's preferences and its update cache. Overtime's folders in /Library are deleted too.")
    fixture.model.setPurge(false)
    #expect(fixture.model.session?.steps.contains(.purge) == false)
  }

  @Test func keepingOvertimeDismissesTheSheetAndTouchesNothing() async {
    let fixture = Fixture(status: .enabled)
    await fixture.model.present()
    fixture.model.keep()
    #expect(!fixture.model.isPresented)
    #expect(fixture.model.session == nil)
    #expect(!fixture.model.isActive)
    #expect(!fixture.panel.uninstalling)
    #expect(fixture.system.calls.isEmpty)
    #expect(fixture.quits.count == 0)
  }

  @Test func confirmingRunsEveryStepToTheResultWithThePanelReadingUninstalling() async throws {
    let fixture = Fixture(status: .enabled)
    await fixture.model.present()
    #expect(!fixture.model.isActive)
    fixture.model.confirm()
    #expect(fixture.model.isActive)
    #expect(fixture.panel.uninstalling)
    #expect(fixture.panel.presentation.state == .uninstalling)
    #expect(fixture.panel.presentation.glyph == .idle)
    #expect(fixture.panel.presentation.title == "Uninstalling")
    #expect(fixture.model.session?.phase == .running)
    #expect(fixture.model.session?.title == "Uninstalling Overtime…")
    #expect(fixture.model.session?.announcement == "Uninstalling Overtime")
    #expect(await fixture.settle())
    let session = try #require(fixture.model.session)
    #expect(session.phase == .result)
    for step in session.steps {
      #expect(session.statuses[step] == .done, "\(step) did not end done")
    }
    #expect(session.title == "Overtime is uninstalled")
    #expect(session.announcement == "Overtime is uninstalled")
    #expect(fixture.system.count(.stop) == 1)
    #expect(fixture.system.count(.trash) == 1)
    #expect(fixture.model.isActive)
    #expect(fixture.panel.uninstalling)
  }

  @Test func quitCallsTheQuitActionOnceAndTheUninstallStaysActive() async {
    let fixture = Fixture(status: .notRegistered)
    await fixture.model.present()
    fixture.model.confirm()
    #expect(await fixture.settle())
    fixture.model.press(.quit)
    #expect(fixture.quits.count == 1)
    #expect(fixture.model.isActive)
    #expect(fixture.panel.uninstalling)
  }

  @Test func aQuitDuringTheHelperStepStillRunsTheRestoreStepAndNoLaterStep() async throws {
    let fixture = Fixture(status: .enabled) { $0.unregisterDelay = 1 }
    await fixture.model.present()
    fixture.model.confirm()
    #expect(await waitUntil(timeout: 10) { fixture.system.count(.unregister) == 1 })
    fixture.model.requestStopForQuit()
    #expect(await fixture.model.settleForQuit(seconds: 10))
    let session = try #require(fixture.model.session)
    #expect(session.phase == .result)
    #expect(session.statuses[.removeHelper] == .done)
    #expect(session.statuses[.restoreSleep] == .done)
    #expect(fixture.system.count(.readSleepDisabled) == 1)
    #expect(fixture.system.count(.loginItem) == 0)
    #expect(fixture.system.count(.trash) == 0)
    #expect(fixture.system.count(.removeStaged) == 0)
    #expect(fixture.quits.count == 0)
  }

  @Test func aQuitDuringTheHelperStepOutlastsTheShortBoundAndHoldsARestorePromptThatStartsLater() async throws {
    let fixture = Fixture(status: .enabled) {
      $0.ownership = .owned
      $0.clear = false
      $0.sleepDisabled = [true, false]
      $0.holdsAdmin = true
      $0.unregisterDelay = 4
    }
    await fixture.model.present()
    fixture.model.confirm()
    #expect(await waitUntil(timeout: 10) { fixture.system.count(.unregister) == 1 })
    fixture.model.requestStopForQuit()
    let settling = Task { await fixture.model.settleForQuit(seconds: 0.3, promptSeconds: 30) }
    #expect(await waitUntil(timeout: 20) { fixture.model.session?.waitingStep == .restoreSleep })
    #expect(fixture.system.promptCancels == 0)
    fixture.system.answerHeldAdmin(.succeeded)
    #expect(await settling.value)
    let session = try #require(fixture.model.session)
    #expect(session.statuses[.removeHelper] == .done)
    #expect(session.statuses[.restoreSleep] == .done)
    #expect(session.report?.sleepDisabledLeft == nil)
    #expect(fixture.system.count(.admin(.clearSleepDisabled)) == 1)
    #expect(fixture.system.count(.loginItem) == 0)
    #expect(fixture.system.count(.trash) == 0)
    #expect(fixture.system.promptCancels == 0)
    let quit = try #require(fixture.decisions.last("quit"))
    #expect(
      quit.fields == [DecisionField(key: "result", value: "settled"), DecisionField(key: "prompt", value: "held")])
  }

  @Test func aQuitOutsideARunningUninstallChangesNothing() async {
    let fixture = Fixture(status: .notRegistered)
    #expect(await fixture.run())
    fixture.model.requestStopForQuit()
    #expect(await fixture.model.settleForQuit(seconds: 10))
    #expect(fixture.model.session?.phase == .result)
    #expect(fixture.system.count(.trash) == 1)
  }

  static func heldRestorePrompt() async -> Fixture {
    let fixture = Fixture(status: .enabled) {
      $0.ownership = .owned
      $0.clear = false
      $0.sleepDisabled = [true, false]
      $0.holdsAdmin = true
    }
    await fixture.model.present()
    fixture.model.confirm()
    #expect(await waitUntil(timeout: 10) { fixture.model.session?.waitingStep == .restoreSleep })
    return fixture
  }

  @Test func aQuitDuringTheRestorePromptWaitsForTheAnswerThenRunsNoLaterStep() async throws {
    let fixture = await Self.heldRestorePrompt()
    fixture.model.requestStopForQuit()
    let settling = Task { await fixture.model.settleForQuit(seconds: 0.3, promptSeconds: 10) }
    try await Task.sleep(for: .seconds(1))
    #expect(fixture.system.promptCancels == 0)
    #expect(fixture.model.session?.phase == .running)
    fixture.system.answerHeldAdmin(.succeeded)
    #expect(await settling.value)
    let session = try #require(fixture.model.session)
    #expect(session.statuses[.restoreSleep] == .done)
    #expect(session.report?.sleepDisabledLeft == nil)
    #expect(fixture.system.count(.loginItem) == 0)
    #expect(fixture.system.count(.trash) == 0)
    #expect(fixture.system.promptCancels == 0)
    let quit = try #require(fixture.decisions.last("quit"))
    #expect(
      quit.fields == [DecisionField(key: "result", value: "settled"), DecisionField(key: "prompt", value: "held")])
  }

  @Test func aQuitDuringTheRestorePromptCaptionsTheRowThatOvertimeQuitsWhenItFinishes() async throws {
    let fixture = await Self.heldRestorePrompt()
    #expect(fixture.model.session?.caption(for: .restoreSleep) == "Waiting for your administrator password…")
    fixture.model.requestStopForQuit()
    #expect(fixture.model.session?.caption(for: .restoreSleep) == "Overtime quits when this step finishes.")
    #expect(
      fixture.model.session?.spokenText(for: .restoreSleep)
        == "Turn system sleep back on if unplug protection turned it off, in progress. "
        + "Overtime quits when this step finishes.")
    #expect(fixture.model.session?.caption(for: .removeLoginItem) == nil)
    let settling = Task { await fixture.model.settleForQuit(seconds: 0.3, promptSeconds: 10) }
    fixture.system.answerHeldAdmin(.succeeded)
    #expect(await settling.value)
    let session = try #require(fixture.model.session)
    #expect(session.phase != .running)
    #expect(session.caption(for: .restoreSleep) != "Overtime quits when this step finishes.")
  }

  @Test func aForcedQuitCancelsTheRestorePromptAndLogsTheCommand() async throws {
    let fixture = await Self.heldRestorePrompt()
    fixture.model.requestStopForQuit()
    #expect(await fixture.model.settleForQuit(forced: { true }, seconds: 10, promptSeconds: 10))
    let session = try #require(fixture.model.session)
    #expect(fixture.system.promptCancels == 1)
    #expect(session.statuses[.restoreSleep] == .skipped(SleepDisabledClearing.cancelledCaption))
    #expect(session.report?.sleepDisabledLeft == .owned)
    #expect(fixture.system.count(.loginItem) == 0)
    let quit = try #require(fixture.decisions.last("quit"))
    #expect(
      quit.fields == [
        DecisionField(key: "result", value: "settled"), DecisionField(key: "prompt", value: "cancelled"),
        DecisionField(key: "sleepDisabled", value: "owned"),
        DecisionField(key: "command", value: Hints.sleepDisabledCommand),
      ])
  }

  final class Logout {
    private(set) var reads = 0
    private(set) var pending = false

    func read() -> Bool {
      reads += 1
      return pending
    }

    func begin() {
      pending = true
    }
  }

  @Test func aLogoutThatArrivesWhileTheQuitHoldsTheRestorePromptCancelsItAndLogsTheCommand() async throws {
    let fixture = await Self.heldRestorePrompt()
    let logout = Logout()
    fixture.model.requestStopForQuit()
    let settling = Task {
      await fixture.model.settleForQuit(forced: { logout.read() }, seconds: 10, promptSeconds: 600)
    }
    #expect(await waitUntil(timeout: 10) { logout.reads >= 1 })
    #expect(fixture.system.promptCancels == 0)
    logout.begin()
    #expect(await settling.value)
    let session = try #require(fixture.model.session)
    #expect(fixture.system.promptCancels == 1)
    #expect(session.statuses[.restoreSleep] == .skipped(SleepDisabledClearing.cancelledCaption))
    #expect(session.report?.sleepDisabledLeft == .owned)
    #expect(fixture.system.count(.loginItem) == 0)
    let quit = try #require(fixture.decisions.last("quit"))
    #expect(
      quit.fields == [
        DecisionField(key: "result", value: "settled"), DecisionField(key: "prompt", value: "cancelled"),
        DecisionField(key: "sleepDisabled", value: "owned"),
        DecisionField(key: "command", value: Hints.sleepDisabledCommand),
      ])
  }

  @Test func aRestorePromptNobodyAnswersWithinTheBoundIsCancelledAndLogged() async throws {
    let fixture = await Self.heldRestorePrompt()
    fixture.model.requestStopForQuit()
    #expect(!(await fixture.model.settleForQuit(seconds: 0.3, promptSeconds: 0.5)))
    #expect(fixture.system.promptCancels == 1)
    let quit = try #require(fixture.decisions.last("quit"))
    #expect(
      quit.fields == [
        DecisionField(key: "result", value: "unsettled"), DecisionField(key: "prompt", value: "cancelled"),
        DecisionField(key: "sleepDisabled", value: "owned"),
        DecisionField(key: "command", value: Hints.sleepDisabledCommand),
      ])
    #expect(await fixture.settle())
    #expect(fixture.model.session?.report?.sleepDisabledLeft == .owned)
  }

  @Test func aQuitOutsideThePromptStillCancelsNothingItDoesNotNeedTo() async throws {
    let fixture = Fixture(status: .enabled) { $0.unregisterDelay = 1 }
    await fixture.model.present()
    fixture.model.confirm()
    #expect(await waitUntil(timeout: 10) { fixture.system.count(.unregister) == 1 })
    fixture.model.requestStopForQuit()
    #expect(await fixture.model.settleForQuit(seconds: 10, promptSeconds: 10))
    #expect(fixture.system.promptCancels == 0)
    let quit = try #require(fixture.decisions.last("quit"))
    #expect(quit.fields == [DecisionField(key: "result", value: "settled")])
  }

  @Test(arguments: [StagedUpdateMoment.quit, .installOnQuit])
  func anUpdateStagedAfterTheCleanupIsRemovedAgainOnlyWhileAnUninstallIsOpen(_ moment: StagedUpdateMoment) async {
    let unopened = Fixture(status: .notRegistered)
    #expect(!unopened.model.removeStagedUpdate(at: moment))
    #expect(unopened.system.count(.removeStaged) == 0)
    let fixture = Fixture(status: .notRegistered)
    #expect(await fixture.run())
    #expect(fixture.system.count(.removeStaged) == 1)
    #expect(fixture.model.removeStagedUpdate(at: moment))
    #expect(fixture.system.count(.removeStaged) == 2)
    #expect(fixture.decisions.last("stagedUpdate")?.fields.last?.key == "at")
  }

  @Test func aSecondConfirmDoesNotRunTheUninstallTwice() async {
    let fixture = Fixture(status: .notRegistered)
    await fixture.model.present()
    fixture.model.confirm()
    fixture.model.confirm()
    #expect(await fixture.settle())
    #expect(fixture.system.count(.stop) == 1)
    #expect(fixture.system.count(.loginItem) == 1)
  }

  @Test func theBlockedAppReportsThatKeepAwakeWasNotRunning() async {
    let fixture = Fixture(status: .notRegistered) { $0.stop = .notRunning }
    await fixture.model.present()
    fixture.model.confirm()
    #expect(await fixture.settle())
    #expect(fixture.model.session?.statuses[.stopKeepAwake] == .done)
    #expect(fixture.model.session?.caption(for: .stopKeepAwake) == "Keep-awake wasn't running.")
  }

  @Test func theButtonsPerStateFollowTheUISpec() throws {
    let confirm = UninstallSheet.buttons(for: .confirm)
    try #require(confirm.count == 2)
    #expect(confirm.map(\.label) == ["Keep Overtime", "Uninstall Overtime"])
    #expect(confirm.map(\.action) == [.keep, .uninstall])
    #expect(confirm[0].isCancel && !confirm[0].isDefault && !confirm[0].isDestructive)
    #expect(confirm[1].isDestructive && !confirm[1].isDefault && !confirm[1].isCancel)
    #expect(confirm.allSatisfy { !$0.isDefault })
    #expect(UninstallSheet.buttons(for: .running).isEmpty)
    let result = UninstallSheet.buttons(for: .result)
    try #require(result.count == 1)
    #expect(result.map(\.label) == ["Quit Overtime"])
    #expect(result[0].isDefault && !result[0].isCancel && !result[0].isDestructive)
  }

  @Test func theSheetKeepsTheUISpecGeometry() {
    #expect(UninstallSheet.width == 480)
    #expect(UninstallSheet.maxHeight == 480)
    #expect(UninstallSheet.padding == 24)
    #expect(UninstallSheet.sectionGap == 16)
    #expect(UninstallSheet.rowGap == 8)
    #expect(UninstallSheet.buttonGap == 8)
  }

  @Test func theCheckboxCaptionInsetIsItsOwnTwentyPoints() {
    #expect(UninstallSheet.checkboxTextInset == 20)
    #expect(UninstallSheet.checkboxTextInset != StatusRowLayout.textInset)
  }

  @Test func theScrollHeightKeepsTheTitleAndFooterInsideTheMaximum() {
    #expect(UninstallSheet.scrollHeight(body: 120, title: 20, footer: 36) == 120)
    #expect(UninstallSheet.scrollHeight(body: 900, title: 20, footer: 36) == 360)
    #expect(UninstallSheet.scrollHeight(body: 900, title: 500, footer: 36) == 0)
    for body: CGFloat in [0, 50, 200, 360, 361, 2000] {
      for title: CGFloat in [0, 20, 40] {
        for footer: CGFloat in [0, 36, 52] {
          let height = UninstallSheet.scrollHeight(body: body, title: title, footer: footer)
          #expect(height >= 0)
          #expect(height <= body)
          #expect(
            2 * UninstallSheet.padding + title + UninstallSheet.sectionGap + height + footer
              <= UninstallSheet.maxHeight)
        }
      }
    }
  }

  @Test func theStepRowReadsTitleStatusWordAndCaption() {
    #expect(StepRow.statusWord(.pending) == "not started")
    #expect(StepRow.statusWord(.running) == "in progress")
    #expect(StepRow.statusWord(.done) == "done")
    #expect(StepRow.statusWord(.skipped("x")) == "skipped")
    #expect(StepRow.statusWord(.failed("x")) == "failed")
    let failed = StepStatus.failed("macOS didn't remove the helper.")
    #expect(
      StepRow.spokenText(title: "Remove unplug protection", status: failed, caption: nil)
        == "Remove unplug protection, failed. macOS didn't remove the helper.")
    #expect(
      StepRow.spokenText(title: "Stop keeping the Mac awake", status: .done, caption: "Keep-awake wasn't running.")
        == "Stop keeping the Mac awake, done. Keep-awake wasn't running.")
    #expect(
      StepRow.spokenText(title: "Move Overtime to the Trash", status: .pending, caption: nil)
        == "Move Overtime to the Trash, not started")
    #expect(StepRow.shownCaption(status: .skipped("left"), caption: nil) == "left")
    #expect(StepRow.shownCaption(status: .done, caption: nil) == nil)
    #expect(StepRow.captionGap == 4)
  }

  @Test func aFailedHelperUnregisterStopsWithNothingElseRemoved() async throws {
    let fixture = Fixture(status: .enabled) { $0.unregister = false }
    #expect(await fixture.run())
    let session = try #require(fixture.model.session)
    #expect(session.phase == .stopped)
    #expect(session.title == "Uninstall stopped")
    #expect(session.statuses[.stopKeepAwake] == .done)
    #expect(session.statuses[.removeHelper] == .failed("macOS didn't remove the helper."))
    #expect(session.caption(for: .removeHelper) == "macOS didn't remove the helper.")
    for step in [UninstallStep.restoreSleep, .removeLoginItem, .trashApp] {
      #expect(session.statuses[step] == .pending, "\(step) is not pending")
    }
    #expect(session.announcement == "Uninstall stopped. Overtime is still installed.")
    #expect(fixture.system.count(.loginItem) == 0)
    #expect(fixture.system.count(.trash) == 0)
    #expect(fixture.model.isActive)
    #expect(fixture.panel.uninstalling)
    #expect(fixture.panel.presentation.state == .uninstalling)
  }

  @Test func theStoppedCopyMatchesTheUISpec() {
    #expect(
      UninstallCopy.stoppedBody
        == "Overtime couldn't remove unplug protection, so it stopped before removing anything else. "
        + "Overtime is still installed, and keep-awake is off.")
    #expect(
      UninstallCopy.stoppedAdvice
        == "In System Settings > General > Login Items & Extensions, check Overtime under Allow in the Background, "
        + "then try again. To keep using Overtime instead, quit it and open it again.")
  }

  @Test func theStoppedButtonsHaveNoDefaultAndNoCancel() throws {
    let stopped = UninstallSheet.buttons(for: .stopped)
    try #require(stopped.count == 3)
    #expect(stopped.map(\.label) == ["Open Login Items", "Quit Overtime", "Try Uninstalling Again"])
    #expect(stopped.map(\.action) == [.openLoginItems, .quit, .retry])
    #expect(stopped[0].isLink && !stopped[0].isDestructive)
    #expect(!stopped[1].isLink && !stopped[1].isDestructive)
    #expect(stopped[2].isDestructive && !stopped[2].isLink)
    #expect(stopped.allSatisfy { !$0.isDefault && !$0.isCancel })
  }

  @Test func openLoginItemsInTheStoppedStateOpensLoginItems() async {
    let fixture = Fixture(status: .enabled) { $0.unregister = false }
    #expect(await fixture.run())
    fixture.model.press(.openLoginItems)
    #expect(fixture.loginItemsOpened.count == 1)
    #expect(fixture.model.session?.phase == .stopped)
    fixture.model.press(.quit)
    #expect(fixture.quits.count == 1)
  }

  @Test func tryingAgainResumesAtTheHelperAndNeverStopsTheEngineAgain() async throws {
    let fixture = Fixture(status: .enabled) { $0.unregister = false }
    #expect(await fixture.run())
    #expect(fixture.model.session?.phase == .stopped)
    fixture.system.update { $0.unregister = true }
    fixture.model.press(.retry)
    #expect(fixture.model.session?.phase == .running)
    #expect(fixture.model.session?.statuses[.stopKeepAwake] == .done)
    #expect(fixture.model.session?.announcement == "Uninstalling Overtime")
    #expect(await fixture.settle())
    let session = try #require(fixture.model.session)
    #expect(session.phase == .result)
    #expect(session.title == "Overtime is uninstalled")
    #expect(session.statuses[.stopKeepAwake] == .done)
    #expect(session.statuses[.removeHelper] == .done)
    #expect(fixture.system.count(.stop) == 1)
    #expect(fixture.system.count(.unregister) == 2)
    #expect(fixture.system.count(.trash) == 1)
    #expect(fixture.panel.uninstalling)
  }

  @Test func retryOutsideTheStoppedStateDoesNothing() async {
    let fixture = Fixture(status: .notRegistered)
    #expect(await fixture.run())
    fixture.model.retry()
    #expect(fixture.model.session?.phase == .result)
    #expect(fixture.system.count(.stop) == 1)
  }

  @Test func aSleepDisabledTheHelperDoesNotOwnShowsTheRowWithTheNotOwnedCaption() async {
    let fixture = Fixture(status: .enabled, reads: [true, false]) {
      $0.ownership = .notOwned
      $0.sleepDisabled = [true]
    }
    #expect(await fixture.run())
    #expect(fixture.model.session?.statuses[.restoreSleep] == .done)
    #expect(
      fixture.model.session?.caption(for: .restoreSleep)
        == "Overtime didn't turn sleep off, so it left the setting alone.")
    #expect(fixture.model.showsSleepDisabledRow)
    #expect(
      fixture.model.session?.sleepDisabledCaption
        == "Overtime didn't set this, so the uninstall left it alone. Until it's cleared, the Mac can't sleep at all.")
    #expect(fixture.system.count(.admin(.clearSleepDisabled)) == 0)
    #expect(fixture.prompt.calls == 0)
    await fixture.model.turnSleepBackOn()
    #expect(fixture.prompt.calls == 1)
    #expect(!fixture.model.showsSleepDisabledRow)
    #expect(fixture.model.clearCaption == nil)
    await fixture.model.turnSleepBackOn()
    #expect(fixture.prompt.calls == 1)
  }

  @Test func anOwnerNobodyCanTellIsLeftForTheConsentRowWithTheCannotTellCaption() async throws {
    let fixture = Fixture(status: .enabled, reads: [true, false]) {
      $0.ownership = .unknown
      $0.record = .unknown
      $0.sleepDisabled = [true]
    }
    #expect(await fixture.run())
    let session = try #require(fixture.model.session)
    #expect(session.statuses[.restoreSleep] == .skipped(UninstallCopy.sleepDisabledUnknownCaption))
    #expect(session.title == "Uninstall finished with problems")
    #expect(fixture.model.showsSleepDisabledRow)
    #expect(
      session.sleepDisabledCaption
        == "Overtime can't tell who set this, so the uninstall left it alone. "
        + "Until it's cleared, the Mac can't sleep at all.")
    #expect(fixture.system.count(.admin(.clearSleepDisabled)) == 0)
    #expect(fixture.prompt.calls == 0)
    await fixture.model.turnSleepBackOn()
    #expect(fixture.prompt.calls == 1)
    #expect(!fixture.model.showsSleepDisabledRow)
  }

  @Test func aRetryKeepsTheFirstOwnershipAndLeavesANotOwnedValueAlone() async throws {
    let fixture = Fixture(status: .enabled, reads: [true]) {
      $0.ownership = .notOwned
      $0.unregister = false
      $0.sleepDisabled = [true]
    }
    #expect(await fixture.run())
    #expect(fixture.model.session?.phase == .stopped)
    fixture.system.update {
      $0.ownership = .unknown
      $0.record = .unknown
      $0.unregister = true
    }
    fixture.model.press(.retry)
    #expect(await fixture.settle())
    let session = try #require(fixture.model.session)
    #expect(session.phase == .result)
    #expect(fixture.system.count(.ownership) == 1)
    #expect(fixture.system.count(.record) == 0)
    #expect(fixture.system.count(.admin(.clearSleepDisabled)) == 0)
    #expect(session.caption(for: .restoreSleep) == UninstallCopy.sleepDisabledNotOwnedCaption)
  }

  @Test func aCancelledConsentPromptKeepsTheRowAndPromptsOncePerPress() async {
    let fixture = Fixture(status: .notRegistered, reads: [true], prompt: .cancelled) {
      $0.sleepDisabled = [true]
    }
    #expect(await fixture.run())
    #expect(fixture.model.showsSleepDisabledRow)
    await fixture.model.turnSleepBackOn()
    #expect(fixture.prompt.calls == 1)
    #expect(fixture.model.showsSleepDisabledRow)
    #expect(fixture.model.clearCaption == SleepDisabledClearing.cancelledCaption)
    #expect(!fixture.model.clearing)
    await fixture.model.turnSleepBackOn()
    #expect(fixture.prompt.calls == 2)
  }

  @Test func clearingALeftValueFromTheConsentRowRetitlesTheResultAndAnnouncesIt() async {
    let cancelled = Fixture(status: .notRegistered, reads: [true], prompt: .cancelled) {
      $0.sleepDisabled = [true]
      $0.record = .unknown
    }
    #expect(await cancelled.run())
    #expect(cancelled.model.session?.title == "Uninstall finished with problems")
    await cancelled.model.turnSleepBackOn()
    #expect(cancelled.model.showsSleepDisabledRow)
    #expect(cancelled.model.session?.title == "Uninstall finished with problems")
    #expect(cancelled.model.session?.announcement == "Uninstall finished with problems")

    let cleared = Fixture(status: .notRegistered, reads: [true, false]) {
      $0.sleepDisabled = [true]
      $0.record = .unknown
    }
    #expect(await cleared.run())
    #expect(cleared.model.session?.title == "Uninstall finished with problems")
    #expect(cleared.model.showsSleepDisabledRow)
    await cleared.model.turnSleepBackOn()
    #expect(cleared.prompt.calls == 1)
    #expect(!cleared.model.showsSleepDisabledRow)
    #expect(cleared.model.session?.title == "Overtime is uninstalled")
    #expect(cleared.model.session?.announcement == "Overtime is uninstalled")
  }

  @Test func copyCommandCopiesTheTerminalCommand() async {
    let fixture = Fixture(status: .notRegistered) { $0.sleepDisabled = [true] }
    #expect(await fixture.run())
    fixture.model.copyCommand()
    #expect(fixture.copied.texts == [Hints.sleepDisabledCommand])
    #expect(fixture.prompt.calls == 0)
  }

  @Test func aCancelledAdministratorPromptFinishesWithProblemsAndListsTheLibraryFolders() async throws {
    let fixture = Fixture(status: .enabled) {
      $0.sleepDisabled = [true]
      $0.admin = .cancelled
    }
    #expect(await fixture.run(purge: true))
    let session = try #require(fixture.model.session)
    #expect(session.phase == .result)
    #expect(session.title == "Uninstall finished with problems")
    #expect(session.statuses[.restoreSleep] == .skipped(SleepDisabledClearing.cancelledCaption))
    #expect(session.manualStepLines.map(\.step) == [.rootFolders])
    #expect(
      session.manualStepLines.map(\.text) == [
        "Delete /Library/Application Support/Overtime Dev and /Library/Logs/Overtime Dev in Finder. "
          + "macOS asks for your administrator password."
      ])
    #expect(UninstallSheet.linkLabel(for: .rootFolders) == nil)
    #expect(fixture.model.showsSleepDisabledRow)
    #expect(session.sleepDisabledCaption == "Until it's cleared, the Mac can't sleep at all.")
    #expect(fixture.system.count(.admin(.clearAndPurge)) == 1)
  }

  @Test func aFailedTrashListsTheDragLineAndShowInFinderRevealsTheApp() async throws {
    let fixture = Fixture(status: .notRegistered) { $0.trash = .failed }
    #expect(await fixture.run())
    let session = try #require(fixture.model.session)
    #expect(session.title == "Uninstall finished with problems")
    #expect(session.statuses[.trashApp] == .failed("Couldn't move Overtime to the Trash."))
    #expect(session.manualStepLines.map(\.text) == ["Drag Overtime to the Trash."])
    #expect(UninstallSheet.linkLabel(for: .trash) == "Show in Finder")
    fixture.model.followLink(for: .trash)
    #expect(fixture.reveals.count == 1)
    #expect(fixture.loginItemsOpened.count == 0)
  }

  @Test func aFailedLoginItemListsTheLoginItemsLineWithItsLink() async throws {
    let fixture = Fixture(status: .notRegistered) { $0.loginItem = false }
    #expect(await fixture.run())
    let session = try #require(fixture.model.session)
    #expect(session.title == "Uninstall finished with problems")
    #expect(
      session.manualStepLines.map(\.text) == [
        "Remove Overtime in System Settings > General > Login Items & Extensions."
      ])
    #expect(UninstallSheet.linkLabel(for: .loginItem) == "Open Login Items")
    fixture.model.followLink(for: .loginItem)
    #expect(fixture.loginItemsOpened.count == 1)
    #expect(fixture.reveals.count == 0)
    #expect(fixture.system.count(.trash) == 1)
  }

  @Test func anUnconfirmedStopContinuesAndAsksForARestartIfTheMacStaysAwake() async throws {
    let fixture = Fixture(status: .notRegistered) { $0.stop = .unconfirmed }
    #expect(await fixture.run())
    let session = try #require(fixture.model.session)
    #expect(session.phase == .result)
    #expect(
      session.statuses[.stopKeepAwake]
        == .failed("Overtime couldn't confirm that keep-awake stopped. Normal sleep comes back when Overtime quits."))
    #expect(
      session.manualStepLines.map(\.text) == ["If the Mac doesn't sleep after Overtime quits, restart the Mac."])
    #expect(UninstallSheet.linkLabel(for: .restart) == nil)
    #expect(fixture.system.count(.trash) == 1)
  }

  @Test func theTestHostBuildsNoLiveUninstall() throws {
    let delegate = try #require(AppDelegate.shared)
    delegate.showSettings(pane: .about)
    #expect(delegate.uninstallModel == nil)
    #expect(delegate.settingsModel == nil)
    #expect(!delegate.model.uninstalling)
  }

  @Test func thePreferencesArePurgedOnceAtQuitAfterAPurgeAndTheRowSaysSo() async throws {
    let fixture = Fixture(status: .notRegistered)
    #expect(await fixture.run(purge: true))
    let session = try #require(fixture.model.session)
    #expect(session.caption(for: .purge) == "Overtime removes its preferences when it quits.")
    #expect(fixture.system.count(.purgeDefaults) == 0)
    let removalsBefore = fixture.system.count(.removeUserItems)
    #expect(fixture.model.purgePreferencesAtQuit())
    #expect(fixture.system.count(.purgeDefaults) == 1)
    #expect(fixture.system.count(.removeUserItems) == removalsBefore + 1)
    #expect(!fixture.model.purgePreferencesAtQuit())
    #expect(fixture.system.count(.purgeDefaults) == 1)
  }

  @Test func noPreferencesArePurgedAtQuitWithoutThePurgeOrAfterAStop() async {
    let plain = Fixture(status: .notRegistered)
    #expect(await plain.run(purge: false))
    #expect(!plain.model.purgePreferencesAtQuit())
    #expect(plain.system.count(.purgeDefaults) == 0)
    let stopped = Fixture(status: .enabled) { $0.unregister = false }
    #expect(await stopped.run(purge: true))
    #expect(stopped.model.session?.phase == .stopped)
    #expect(!stopped.model.purgePreferencesAtQuit())
    #expect(stopped.system.count(.purgeDefaults) == 0)
    let unopened = Fixture(status: .notRegistered)
    #expect(!unopened.model.purgePreferencesAtQuit())
  }

  @Test func aCleanResultShowsNoSleepDisabledRowAndNoManualLines() async {
    let fixture = Fixture(status: .enabled)
    #expect(await fixture.run())
    #expect(!fixture.model.showsSleepDisabledRow)
    #expect(fixture.model.session?.manualStepLines.isEmpty == true)
  }
}
