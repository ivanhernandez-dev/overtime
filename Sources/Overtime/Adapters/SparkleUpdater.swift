import Foundation
import OvertimeAppSupport
import Sparkle

@MainActor
protocol UpdaterPort: AnyObject {
  var automaticallyChecksForUpdates: Bool { get set }
  var automaticallyDownloadsUpdates: Bool { get set }
  var allowsAutomaticUpdates: Bool { get }
  var canCheckForUpdates: Bool { get }
  var lastUpdateCheckDate: Date? { get }
  var reminder: UpdateReminder { get }
  var onChange: (() -> Void)? { get set }
  func checkForUpdates()
}

@MainActor
final class SparkleUpdater: NSObject, UpdaterPort, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
  static let errorDomain = "Overtime.update"
  static let checkRefusedCode = 1
  static let installRefusedCode = 2
  static let installRefusedDescription = "Overtime won't install updates while it uninstalls."

  private let refuseChecks: () -> (terminating: Bool, uninstalling: Bool)
  private let removeStagedUpdate: () -> Void
  private var controller: SPUStandardUpdaterController?
  private var observations: [NSKeyValueObservation] = []
  private(set) var reminder = UpdateReminder()
  var onChange: (() -> Void)?

  init(
    refuseChecks: @escaping () -> (terminating: Bool, uninstalling: Bool),
    removeStagedUpdate: @escaping () -> Void = {}
  ) {
    self.refuseChecks = refuseChecks
    self.removeStagedUpdate = removeStagedUpdate
    super.init()
  }

  var isStarted: Bool {
    controller != nil
  }

  func start() {
    guard controller == nil else { return }
    let controller = SPUStandardUpdaterController(
      startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
    self.controller = controller
    observe(controller.updater)
  }

  private func observe(_ updater: SPUUpdater) {
    let changed: @Sendable (SPUUpdater) -> Void = { [weak self] _ in
      let owner = self
      Task { @MainActor in owner?.onChange?() }
    }
    observations = [
      updater.observe(\.canCheckForUpdates) { @Sendable updater, _ in changed(updater) },
      updater.observe(\.automaticallyChecksForUpdates) { @Sendable updater, _ in changed(updater) },
      updater.observe(\.automaticallyDownloadsUpdates) { @Sendable updater, _ in changed(updater) },
    ]
  }

  var automaticallyChecksForUpdates: Bool {
    get { controller?.updater.automaticallyChecksForUpdates ?? false }
    set { controller?.updater.automaticallyChecksForUpdates = newValue }
  }

  var automaticallyDownloadsUpdates: Bool {
    get { controller?.updater.automaticallyDownloadsUpdates ?? false }
    set { controller?.updater.automaticallyDownloadsUpdates = newValue }
  }

  var allowsAutomaticUpdates: Bool {
    controller?.updater.allowsAutomaticUpdates ?? false
  }

  var canCheckForUpdates: Bool {
    controller?.updater.canCheckForUpdates ?? false
  }

  var lastUpdateCheckDate: Date? {
    controller?.updater.lastUpdateCheckDate
  }

  func checkForUpdates() {
    controller?.updater.checkForUpdates()
  }

  func permitCheck() throws {
    let state = refuseChecks()
    guard UpdateCheckGate.allowsCheck(terminating: state.terminating, uninstalling: state.uninstalling) else {
      throw NSError(domain: Self.errorDomain, code: Self.checkRefusedCode)
    }
  }

  func permitInstall() throws {
    guard relaunchAllowed else {
      throw NSError(
        domain: Self.errorDomain, code: Self.installRefusedCode,
        userInfo: [NSLocalizedDescriptionKey: Self.installRefusedDescription])
    }
  }

  var relaunchAllowed: Bool {
    UpdateCheckGate.allowsInstall(uninstalling: refuseChecks().uninstalling)
  }

  var postponesRelaunchForever: Bool {
    !relaunchAllowed
  }

  func reminderWillShow(handledBySparkle: Bool, version: String) {
    reminder.willShowUpdate(handledBySparkle: handledBySparkle, version: version)
    onChange?()
  }

  func reminderAttended() {
    reminder.userAttended()
    onChange?()
  }

  func reminderSessionFinished() {
    reminder.sessionFinished()
    onChange?()
  }

  func stageForQuit() {
    reminder.noteStagedForQuit()
    onChange?()
  }

  func installOnQuit() -> Bool {
    guard refuseChecks().uninstalling else {
      stageForQuit()
      return false
    }
    removeStagedUpdate()
    return true
  }

  func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
    try permitCheck()
  }

  func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem, updateCheck: SPUUpdateCheck)
    throws
  {
    try permitInstall()
  }

  func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
    relaunchAllowed
  }

  func updater(
    _ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
    untilInvokingBlock installHandler: @escaping () -> Void
  ) -> Bool {
    postponesRelaunchForever
  }

  func updater(
    _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
    immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
  ) -> Bool {
    installOnQuit()
  }

  func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
    onChange?()
  }

  var supportsGentleScheduledUpdateReminders: Bool {
    true
  }

  func standardUserDriverShouldHandleShowingScheduledUpdate(
    _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
  ) -> Bool {
    UpdateReminder.sparkleShowsScheduledUpdate(immediateFocus: immediateFocus)
  }

  func standardUserDriverWillHandleShowingUpdate(
    _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
  ) {
    reminderWillShow(handledBySparkle: handleShowingUpdate, version: update.displayVersionString)
  }

  func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
    reminderAttended()
  }

  func standardUserDriverWillFinishUpdateSession() {
    reminderSessionFinished()
  }
}
