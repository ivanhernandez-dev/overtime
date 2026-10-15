import Foundation
import OvertimeCore
import OvertimeSystem

public struct UninstallManualLine: Sendable, Equatable, Identifiable {
  public let step: UninstallManualStep
  public let text: String

  public var id: UninstallManualStep { step }
}

public struct UninstallSession: Sendable, Equatable {
  public enum Phase: Sendable, Equatable {
    case confirm
    case running
    case stopped
    case result
  }

  public let helperInstalled: Bool
  public let table: PurgeTable
  public private(set) var phase: Phase = .confirm
  public private(set) var statuses: [UninstallStep: StepStatus]
  public private(set) var notes: [UninstallStep: String] = [:]
  public private(set) var waitingStep: UninstallStep?
  public private(set) var report: UninstallReport?
  public private(set) var announcement: String?
  public private(set) var quitPending = false
  private var purgeChecked: Bool
  private var sleepCleared = false

  public init(helperInstalled: Bool, purge: Bool = false, table: PurgeTable) {
    self.helperInstalled = helperInstalled
    self.table = table
    purgeChecked = purge
    statuses = [:]
    resetStatuses()
  }

  public var purge: Bool {
    get { purgeChecked }
    set {
      guard phase == .confirm, newValue != purgeChecked else { return }
      purgeChecked = newValue
      resetStatuses()
    }
  }

  public var steps: [UninstallStep] {
    UninstallCoordinator.steps(helperInstalled: helperInstalled, purge: purgeChecked, mode: .app)
  }

  public var title: String {
    switch phase {
    case .confirm: UninstallCopy.confirmTitle
    case .running: UninstallCopy.runningTitle
    case .stopped: UninstallCopy.stoppedTitle
    case .result: isClean ? UninstallCopy.uninstalledTitle : UninstallCopy.problemsTitle
    }
  }

  public var purgeCaption: String {
    UninstallCopy.purgeCaption(folderName: table.folderName, helperInstalled: helperInstalled)
  }

  public func caption(for step: UninstallStep) -> String? {
    if phase == .running, quitPending, statuses[step] == .running {
      return UninstallCopy.quitWaitingCaption
    }
    if phase == .running, waitingStep == step {
      return UninstallCopy.waitingForAdministratorCaption
    }
    return statuses[step]?.message ?? notes[step]
  }

  public func spokenText(for step: UninstallStep) -> String {
    let word: String =
      switch statuses[step] ?? .pending {
      case .pending: "not started"
      case .running: "in progress"
      case .done: "done"
      case .skipped: "skipped"
      case .failed: "failed"
      }
    let base = step.title + ", " + word
    guard let caption = caption(for: step) else { return base }
    return base + ". " + caption
  }

  public var manualStepLines: [UninstallManualLine] {
    guard phase == .result, let report else { return [] }
    return report.manualSteps.map { item in
      let text: String =
        switch item {
        case .loginItem: UninstallCopy.manualLoginItem
        case .trash: UninstallCopy.manualTrash
        case .rootFolders: UninstallCopy.manualRootFolders(folderName: table.folderName)
        case .userFiles: UninstallCopy.manualUserFiles(folderName: table.folderName)
        case .restart: UninstallCopy.manualRestart
        }
      return UninstallManualLine(step: item, text: text)
    }
  }

  public var sleepDisabledCaption: String? {
    guard phase == .result else { return nil }
    switch report?.sleepDisabledLeft {
    case .owned?: return UninstallCopy.sleepDisabledOwnedCaption
    case .notOwned?: return UninstallCopy.sleepDisabledNotOwnedRowCaption
    case .unknown?: return UninstallCopy.sleepDisabledUnknownRowCaption
    case nil: return nil
    }
  }

  public var resumeStep: UninstallStep {
    phase == .running && report?.outcome == .stopped ? .removeHelper : .stopKeepAwake
  }

  @discardableResult
  public mutating func begin() -> Bool {
    guard phase == .confirm else { return false }
    phase = .running
    announcement = UninstallCopy.runningAnnouncement
    return true
  }

  public mutating func apply(_ progress: UninstallProgress) {
    guard phase == .running else { return }
    switch progress {
    case .started(let step):
      guard steps.contains(step) else { return }
      statuses[step] = .running
      notes[step] = nil
      waitingStep = nil
    case .waitingForAdministrator(let step):
      guard steps.contains(step) else { return }
      waitingStep = step
    case .finished(let step, let status, let note):
      guard steps.contains(step) else { return }
      statuses[step] = status
      notes[step] = note
      if waitingStep == step {
        waitingStep = nil
      }
      if case .failed = status {
        announcement = spokenText(for: step)
      }
    }
  }

  public mutating func finish(_ report: UninstallReport) {
    guard phase == .running else { return }
    self.report = report
    waitingStep = nil
    for step in steps {
      if let status = report.statuses[step] {
        statuses[step] = status
      }
      notes[step] = report.notes[step]
    }
    if report.outcome == .stopped {
      phase = .stopped
      announcement = UninstallCopy.stoppedAnnouncement
    } else {
      phase = .result
      announcement = title
    }
  }

  @discardableResult
  public mutating func retryFromHelper() -> Bool {
    guard phase == .stopped else { return false }
    for step in steps where step >= .removeHelper {
      statuses[step] = .pending
      notes[step] = nil
    }
    waitingStep = nil
    phase = .running
    announcement = UninstallCopy.runningAnnouncement
    return true
  }

  public mutating func noteQuitRequested() {
    guard phase == .running else { return }
    quitPending = true
  }

  public mutating func noteSleepDisabledCleared() {
    guard phase == .result, report?.sleepDisabledLeft != nil, !sleepCleared else { return }
    sleepCleared = true
    announcement = title
  }

  private var isClean: Bool {
    (report?.manualSteps.isEmpty ?? true) && steps.allSatisfy { statuses[$0] == .done }
      && (sleepCleared || report?.leavesSleepUnresolved != true)
  }

  private mutating func resetStatuses() {
    statuses = Dictionary(uniqueKeysWithValues: steps.map { ($0, StepStatus.pending) })
    notes = [:]
  }
}

public enum HeadlessUninstall {
  public static let notOwnedLine = UninstallCopy.headlessNotOwned
  public static let unknownOwnerLine = UninstallCopy.headlessUnknownOwner
  public static let askedToQuitLine = UninstallCopy.headlessAskedToQuit
  public static let stillRunningLine = UninstallCopy.headlessStillRunning

  public static func line(_ step: UninstallStep, _ status: StepStatus, note: String? = nil) -> String {
    switch status {
    case .done:
      guard let note else { return step.title + ": done" }
      return step.title + ": done. " + note
    case .skipped(let caption):
      return step.title + ": skipped. " + caption
    case .failed(let caption):
      return step.title + ": failed. " + caption
    case .pending, .running:
      return step.title + ": " + status.keyword
    }
  }

  public static func finalLine(_ outcome: UninstallOutcome) -> String {
    switch outcome {
    case .uninstalled: UninstallCopy.headlessUninstalled
    case .finishedWithProblems: UninstallCopy.headlessProblems
    case .stopped: UninstallCopy.headlessStopped
    }
  }

  public static func exitCode(_ outcome: UninstallOutcome) -> Int32 {
    outcome == .uninstalled ? 0 : 1
  }

  public static func rootRefusal(effectiveUserID: uid_t) -> String? {
    effectiveUserID == 0 ? UninstallCopy.headlessRefusesRoot : nil
  }

  public enum InstanceQuit: Sendable, Equatable {
    case noInstance
    case quit
    case stillRunning
  }

  public static func quitRunningInstance<Target>(
    removeStagedUpdate: () -> Void,
    findInstance: () -> Target?,
    requestQuit: (Target) -> Void,
    waitForExit: (Target) -> Bool,
    write: (String) -> Void
  ) -> InstanceQuit {
    removeStagedUpdate()
    guard let target = findInstance() else { return .noInstance }
    write(askedToQuitLine)
    requestQuit(target)
    guard waitForExit(target) else {
      write(stillRunningLine)
      return .stillRunning
    }
    return .quit
  }

  public static func run(
    coordinator: UninstallCoordinator, system: any UninstallSystem, purge: Bool,
    write: @escaping @Sendable (String) -> Void,
    statusTimeoutSeconds: Double = Timing.systemCallTimeoutSeconds
  ) async -> Int32 {
    let status: HelperInstallerStatus?
    switch await DeadlineRunner().perform(timeout: statusTimeoutSeconds, { system.helperStatus() }) {
    case .value(let value): status = value
    case .timedOut: status = nil
    }
    let report = await coordinator.inMode(.headless).run(helperStatus: status, purge: purge) { progress in
      if case .finished(let step, let stepStatus, let note) = progress {
        write(line(step, stepStatus, note: note))
      }
    }
    switch report.sleepDisabledLeft {
    case .notOwned?: write(notOwnedLine)
    case .unknown?: write(unknownOwnerLine)
    case .owned?, nil: break
    }
    write(finalLine(report.outcome))
    return exitCode(report.outcome)
  }
}

public enum UninstallCopy {
  public static let stopKeepAwakeTitle = "Stop keeping the Mac awake"
  public static let removeHelperTitle = "Remove unplug protection"
  public static let restoreSleepTitle = "Turn system sleep back on if unplug protection turned it off"
  public static let removeLoginItemTitle = "Remove Overtime from your login items"
  public static let purgeTitle = "Remove settings, state and logs"
  public static let trashAppTitle = "Move Overtime to the Trash"

  public static let confirmTitle = "Uninstall Overtime?"
  public static let runningTitle = "Uninstalling Overtime…"
  public static let stoppedTitle = "Uninstall stopped"
  public static let uninstalledTitle = "Overtime is uninstalled"
  public static let problemsTitle = "Uninstall finished with problems"

  public static let checklistLabel = "Uninstalling will:"
  public static let purgeLabel = "Also remove settings, state and logs"
  public static let untouchedCaption =
    "Overtime doesn't touch other apps, or the permissions you gave it in System Settings."
  public static let administratorOnceCaption = "macOS may ask for your administrator password once."
  public static let rootFoldersPurgeSentence = " Overtime's folders in /Library are deleted too."

  public static func purgeCaption(folderName: String, helperInstalled: Bool) -> String {
    let base =
      "Deletes ~/Library/Application Support/\(folderName), ~/Library/Logs/\(folderName), "
      + "Overtime's preferences and its update cache."
    return helperInstalled ? base + rootFoldersPurgeSentence : base
  }

  public static let keepLabel = "Keep Overtime"
  public static let uninstallLabel = "Uninstall Overtime"
  public static let quitLabel = "Quit Overtime"
  public static let retryLabel = "Try Uninstalling Again"
  public static let showInFinderLabel = "Show in Finder"
  public static let openLoginItemsLabel = LoginItemCaption.openLabel

  public static let keepAwakeNotRunningCaption = "Keep-awake wasn't running."
  public static let stopUnconfirmedCaption =
    "Overtime couldn't confirm that keep-awake stopped. Normal sleep comes back when Overtime quits."
  public static let helperNotRemovedCaption = "macOS didn't remove the helper."
  public static let sleepDisabledCancelledCaption = SleepDisabledClearing.cancelledCaption
  public static let sleepDisabledFailedCaption = SleepDisabledClearing.failedCaption
  public static let sleepDisabledNotOwnedCaption = "Overtime didn't turn sleep off, so it left the setting alone."
  public static let sleepDisabledUnknownCaption =
    "Overtime can't tell who turned sleep off, so it left the setting alone."
  public static let loginItemFailedCaption = "Couldn't remove the login item."
  public static let rootFoldersLeftCaption =
    "Removed your settings and logs. Overtime's folders in /Library are still there."
  public static let userFilesFailedCaption = "Some of Overtime's files couldn't be deleted."
  public static let preferencesAtQuitCaption = "Overtime removes its preferences when it quits."
  public static let trashFailedCaption = "Couldn't move Overtime to the Trash."
  public static let waitingForAdministratorCaption = "Waiting for your administrator password…"
  public static let quitWaitingCaption = "Overtime quits when this step finishes."

  public static let stoppedBody =
    "Overtime couldn't remove unplug protection, so it stopped before removing anything else. "
    + "Overtime is still installed, and keep-awake is off."
  public static let stoppedAdvice =
    "In System Settings > General > Login Items & Extensions, check Overtime under Allow in the Background, "
    + "then try again. To keep using Overtime instead, quit it and open it again."

  public static let stillToDoLabel = "Still to do:"
  public static let manualLoginItem = "Remove Overtime in System Settings > General > Login Items & Extensions."
  public static let manualTrash = "Drag Overtime to the Trash."
  public static let manualRestart = "If the Mac doesn't sleep after Overtime quits, restart the Mac."

  public static func manualRootFolders(folderName: String) -> String {
    "Delete /Library/Application Support/\(folderName) and /Library/Logs/\(folderName) in Finder. "
      + "macOS asks for your administrator password."
  }

  public static func manualUserFiles(folderName: String) -> String {
    "Delete the rest of ~/Library/Application Support/\(folderName) and ~/Library/Logs/\(folderName) in Finder."
  }

  public static let sleepDisabledOwnedCaption = "Until it's cleared, the Mac can't sleep at all."
  public static let sleepDisabledNotOwnedRowCaption =
    "Overtime didn't set this, so the uninstall left it alone. Until it's cleared, the Mac can't sleep at all."
  public static let sleepDisabledUnknownRowCaption =
    "Overtime can't tell who set this, so the uninstall left it alone. "
    + "Until it's cleared, the Mac can't sleep at all."

  public static let runningAnnouncement = "Uninstalling Overtime"
  public static let stoppedAnnouncement = "Uninstall stopped. Overtime is still installed."

  public static let headlessUninstalled = "Overtime is uninstalled."
  public static let headlessProblems = "Uninstall finished with problems. See the lines above."
  public static let headlessStopped = "Uninstall stopped. Overtime is still installed."
  public static let headlessNotOwned =
    "Sleep is turned off system-wide (SleepDisabled). Overtime didn't set this, so it left it alone. "
    + "To turn sleep back on, run: " + Hints.sleepDisabledCommand
  public static let headlessUnknownOwner =
    "Sleep is turned off system-wide (SleepDisabled). Overtime can't tell who set this, so it left it alone. "
    + "To turn sleep back on, run: " + Hints.sleepDisabledCommand
  public static let headlessAskedToQuit = "Asked the running Overtime to quit."
  public static let headlessStillRunning = "Overtime is still running. Quit it, then run Overtime --uninstall again."
  public static let headlessRefusesRoot = "Run Overtime --uninstall as the user who installed Overtime, not with sudo."

  public static let panelTitle = "Uninstalling"
  public static let panelReason = "Keep-awake is off while Overtime uninstalls. The Mac sleeps normally."
  public static let panelAccessibilityLabel = "Overtime, uninstalling"
}
