import Foundation
import Observation
import OvertimeAppSupport
import OvertimeCore
import OvertimeSystem
import os

@Observable
final class UninstallModel {
  static let statusTimeoutSeconds = Timing.systemCallTimeoutSeconds
  static let quitSettleSeconds = TerminationCoordinator.defaultOuterBoundSeconds
  static let quitPromptSeconds = UninstallCoordinator.adminTimeoutSeconds

  private(set) var session: UninstallSession?
  private(set) var isPresented = false
  private(set) var isActive = false

  let table: PurgeTable
  let panel: PanelModel?
  @ObservationIgnored private let coordinator: UninstallCoordinator
  @ObservationIgnored private let readHelperStatus: @Sendable () -> HelperInstallerStatus
  @ObservationIgnored private let quitApp: () -> Void
  @ObservationIgnored private let statusTimeoutSeconds: Double
  @ObservationIgnored private var helperStatus: HelperInstallerStatus? = .notRegistered
  private var opening = false
  @ObservationIgnored private var preferencesPurgedAtQuit = false
  @ObservationIgnored private let quitRequested = OSAllocatedUnfairLock(initialState: false)
  @ObservationIgnored private(set) var runTask: Task<Void, Never>?
  private(set) var clearing = false
  private(set) var sleepDisabledCleared = false
  private(set) var clearOutcome: SleepDisabledClearOutcome?
  @ObservationIgnored private let openLoginItemsAction: () -> Void
  @ObservationIgnored private let revealAppAction: () -> Void
  @ObservationIgnored private let readSleepDisabled: (@Sendable () -> Bool?)?
  @ObservationIgnored private let adminPrompt: (any AdminPrompt)?
  @ObservationIgnored private let copyToPasteboard: (String) -> Void
  @ObservationIgnored private let cancelAdminPrompt: () -> Void

  init(
    coordinator: UninstallCoordinator,
    table: PurgeTable,
    helperStatus: @escaping @Sendable () -> HelperInstallerStatus,
    panel: PanelModel?,
    quit: @escaping () -> Void,
    openLoginItems: @escaping () -> Void = {},
    revealApp: @escaping () -> Void = {},
    readSleepDisabled: (@Sendable () -> Bool?)? = nil,
    adminPrompt: (any AdminPrompt)? = nil,
    copyToPasteboard: @escaping (String) -> Void = { _ in },
    cancelAdminPrompt: @escaping () -> Void = {},
    statusTimeoutSeconds: Double = UninstallModel.statusTimeoutSeconds
  ) {
    self.coordinator = coordinator
    self.table = table
    self.readHelperStatus = helperStatus
    self.panel = panel
    self.quitApp = quit
    self.openLoginItemsAction = openLoginItems
    self.revealAppAction = revealApp
    self.readSleepDisabled = readSleepDisabled
    self.adminPrompt = adminPrompt
    self.copyToPasteboard = copyToPasteboard
    self.cancelAdminPrompt = cancelAdminPrompt
    self.statusTimeoutSeconds = statusTimeoutSeconds
  }

  var showsSleepDisabledRow: Bool {
    session?.sleepDisabledCaption != nil && !sleepDisabledCleared
  }

  var clearCaption: String? {
    clearOutcome?.caption
  }

  func retry() {
    guard isActive, session?.retryFromHelper() == true, let session else { return }
    run(resumingAt: session.resumeStep, earlier: session.report)
  }

  func turnSleepBackOn() async {
    guard showsSleepDisabledRow, !clearing, let read = readSleepDisabled, let prompt = adminPrompt else { return }
    clearing = true
    let outcome = await Self.offMain { SleepDisabledClearing.run(read: read, prompt: prompt) }
    clearing = false
    if outcome.isClear {
      sleepDisabledCleared = true
      clearOutcome = nil
      session?.noteSleepDisabledCleared()
    } else {
      clearOutcome = outcome
    }
  }

  func copyCommand() {
    copyToPasteboard(Hints.sleepDisabledCommand)
  }

  func openLoginItems() {
    openLoginItemsAction()
  }

  func followLink(for step: UninstallManualStep) {
    switch step {
    case .loginItem: openLoginItemsAction()
    case .trash: revealAppAction()
    case .rootFolders, .userFiles, .restart: break
    }
  }

  nonisolated private static func offMain<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(returning: work())
      }
    }
  }

  var phase: UninstallSession.Phase? {
    session?.phase
  }

  var isOpenOrActive: Bool {
    isPresented || isActive || opening
  }

  func present() async {
    if session != nil {
      isPresented = true
      return
    }
    guard !opening else { return }
    opening = true
    let read = readHelperStatus
    let status: HelperInstallerStatus?
    switch await DeadlineRunner().perform(timeout: statusTimeoutSeconds, { read() }) {
    case .value(let value): status = value
    case .timedOut: status = nil
    }
    opening = false
    helperStatus = status
    session = UninstallSession(helperInstalled: UninstallCoordinator.attemptsHelper(status), table: table)
    isPresented = true
  }

  func setPurge(_ purge: Bool) {
    session?.purge = purge
  }

  func keep() {
    guard !isActive, session?.phase == .confirm else { return }
    isPresented = false
    session = nil
  }

  func confirm() {
    guard !isActive, session?.begin() == true else { return }
    isActive = true
    panel?.uninstalling = true
    run(resumingAt: .stopKeepAwake, earlier: nil)
  }

  func quit() {
    quitApp()
  }

  func requestStopForQuit() {
    guard session?.phase == .running else { return }
    quitRequested.withLock { $0 = true }
    session?.noteQuitRequested()
  }

  @discardableResult
  func settleForQuit(
    forced readForced: () -> Bool = { false }, seconds: Double = UninstallModel.quitSettleSeconds,
    promptSeconds: Double = UninstallModel.quitPromptSeconds
  ) async -> Bool {
    guard quitRequested.withLock({ $0 }) else { return true }
    let start = ContinuousClock.now
    var forced = false
    var sawRestorePrompt = false
    var sawHelperUnit = false
    var settled = true
    while session?.phase == .running {
      if !forced, readForced() {
        forced = true
        cancelAdminPrompt()
      }
      if session?.waitingStep == .restoreSleep {
        sawRestorePrompt = true
      } else if session?.waitingStep != nil {
        cancelAdminPrompt()
      }
      if session?.statuses[.removeHelper] == .running || session?.statuses[.restoreSleep] == .running {
        sawHelperUnit = true
      }
      let bound = sawHelperUnit || (sawRestorePrompt && !forced) ? promptSeconds + seconds : seconds
      guard ContinuousClock.now < start + .milliseconds(Int(max(0, bound) * 1000)) else {
        settled = false
        break
      }
      try? await Task.sleep(for: .milliseconds(20))
    }
    if !settled {
      cancelAdminPrompt()
    }
    let prompt: UninstallQuitPrompt =
      !sawRestorePrompt ? .none : (forced || !settled) ? .cancelled : .held
    var left = session?.phase == .running ? nil : session?.report?.sleepDisabledLeft
    if prompt == .cancelled, left == nil {
      left = .owned
    }
    coordinator.noteQuit(settled: settled, prompt: prompt, sleepDisabledLeft: left)
    return settled
  }

  @discardableResult
  func removeStagedUpdate(at moment: StagedUpdateMoment) -> Bool {
    guard isActive else { return false }
    return coordinator.removeStagedUpdate(at: moment)
  }

  @discardableResult
  func purgePreferencesAtQuit() -> Bool {
    guard !preferencesPurgedAtQuit, let session, session.purge, let report = session.report,
      report.outcome != .stopped, let status = report.status(of: .purge), status != .pending
    else { return false }
    preferencesPurgedAtQuit = true
    return coordinator.purgePreferencesAtQuit()
  }

  func press(_ action: UninstallSheetButton.Action) {
    switch action {
    case .keep: keep()
    case .uninstall: confirm()
    case .quit: quit()
    case .openLoginItems: openLoginItems()
    case .retry: retry()
    }
  }

  func settled(seconds: Double) async -> Bool {
    let deadline = ContinuousClock.now + .milliseconds(Int(max(0, seconds) * 1000))
    while session?.phase == .running {
      guard ContinuousClock.now < deadline else { return false }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return true
  }

  private func run(resumingAt step: UninstallStep, earlier: UninstallReport?) {
    guard let purge = session?.purge else { return }
    let coordinator = coordinator
    let status = helperStatus
    let quitRequested = quitRequested
    let (events, continuation) = AsyncStream.makeStream(of: UninstallProgress.self)
    runTask = Task { [weak self] in
      let consumer = Task { [weak self] in
        for await event in events {
          self?.session?.apply(event)
        }
      }
      let report = await coordinator.run(
        helperStatus: status, purge: purge, resumingAt: step, earlier: earlier,
        progress: { event in continuation.yield(event) },
        continuing: { !quitRequested.withLock { $0 } })
      continuation.finish()
      await consumer.value
      self?.session?.finish(report)
    }
  }
}
