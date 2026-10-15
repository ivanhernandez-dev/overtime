import Foundation
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import os

public enum UninstallEngineStop: Sendable, Equatable {
  case stopped
  case notRunning
  case unconfirmed
}

public enum HelperOwnership: Sendable, Equatable {
  case owned
  case notOwned
  case unknown
}

public enum UninstallAdminCommand: Sendable, Equatable, CaseIterable {
  case clearSleepDisabled
  case purgeRootFolders
  case clearAndPurge
}

public enum UninstallTrashResult: Sendable, Equatable {
  case trashed
  case refused
  case failed
}

public protocol UninstallSystem: Sendable {
  func stopKeepAwake() async -> UninstallEngineStop
  func helperStatus() -> HelperInstallerStatus
  func helperOwnership() -> HelperOwnership
  func recordOwnership() -> HelperOwnership
  func helperClear() -> Bool
  func unregisterHelper() -> Bool
  func readSleepDisabled() -> Bool?
  func runAdmin(_ command: UninstallAdminCommand) -> AdminOutcome
  func unregisterLoginItem() -> Bool
  func purgeDefaults(appIdentifier: String)
  func removeUserItems(_ items: [PurgeItem]) -> Bool
  func updateStagedForQuit() -> Bool
  func removeStagedUpdate(labels: [String], cache: PurgeItem) -> Bool
  func trashApp(expectedIdentifier: String) -> UninstallTrashResult
}

public enum UninstallStep: Int, Sendable, Equatable, Hashable, CaseIterable, Comparable {
  case stopKeepAwake = 1
  case removeHelper
  case restoreSleep
  case removeLoginItem
  case purge
  case trashApp

  public static func < (lhs: UninstallStep, rhs: UninstallStep) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  public var title: String {
    switch self {
    case .stopKeepAwake: UninstallCopy.stopKeepAwakeTitle
    case .removeHelper: UninstallCopy.removeHelperTitle
    case .restoreSleep: UninstallCopy.restoreSleepTitle
    case .removeLoginItem: UninstallCopy.removeLoginItemTitle
    case .purge: UninstallCopy.purgeTitle
    case .trashApp: UninstallCopy.trashAppTitle
    }
  }

  public var logName: String {
    switch self {
    case .stopKeepAwake: "stop"
    case .removeHelper: "helper"
    case .restoreSleep: "sleepDisabled"
    case .removeLoginItem: "loginItem"
    case .purge: "purge"
    case .trashApp: "trash"
    }
  }
}

public enum UninstallProgress: Sendable, Equatable {
  case started(UninstallStep)
  case waitingForAdministrator(UninstallStep)
  case finished(UninstallStep, StepStatus, note: String? = nil)
}

public enum UninstallOutcome: Sendable, Equatable {
  case uninstalled
  case finishedWithProblems
  case stopped
}

public enum SleepDisabledLeft: Sendable, Equatable {
  case owned
  case notOwned
  case unknown
}

public enum StagedUpdateMoment: Sendable, Equatable {
  case quit
  case installOnQuit
}

public enum UninstallQuitPrompt: Sendable, Equatable {
  case none
  case held
  case cancelled
}

public enum UninstallManualStep: Sendable, Equatable, Hashable, CaseIterable {
  case loginItem
  case trash
  case rootFolders
  case userFiles
  case restart

  var step: UninstallStep {
    switch self {
    case .loginItem: .removeLoginItem
    case .trash: .trashApp
    case .rootFolders, .userFiles: .purge
    case .restart: .stopKeepAwake
    }
  }
}

public struct UninstallReport: Sendable, Equatable {
  public var outcome: UninstallOutcome
  public var steps: [UninstallStep]
  public var statuses: [UninstallStep: StepStatus]
  public var notes: [UninstallStep: String]
  public var sleepDisabledLeft: SleepDisabledLeft?
  public var manualSteps: [UninstallManualStep]
  public var adminPrompts: Int
  public var helperOwnership: HelperOwnership?

  public init(
    outcome: UninstallOutcome, steps: [UninstallStep], statuses: [UninstallStep: StepStatus],
    notes: [UninstallStep: String] = [:], sleepDisabledLeft: SleepDisabledLeft? = nil,
    manualSteps: [UninstallManualStep] = [], adminPrompts: Int = 0, helperOwnership: HelperOwnership? = nil
  ) {
    self.outcome = outcome
    self.steps = steps
    self.statuses = statuses
    self.notes = notes
    self.sleepDisabledLeft = sleepDisabledLeft
    self.manualSteps = manualSteps
    self.adminPrompts = adminPrompts
    self.helperOwnership = helperOwnership
  }

  public var leavesSleepUnresolved: Bool {
    sleepDisabledLeft == .owned || sleepDisabledLeft == .unknown
  }

  public func status(of step: UninstallStep) -> StepStatus? {
    statuses[step]
  }
}

public struct UninstallCoordinator: Sendable {
  public enum Mode: Sendable, Equatable {
    case app
    case headless
  }

  public static let adminTimeoutSeconds: Double = 605

  public let table: PurgeTable
  public let mode: Mode
  private let system: any UninstallSystem
  private let stepTimeoutSeconds: Double
  private let stepTimeoutOverrides: [String: Double]
  private let stopTimeoutSeconds: Double
  private let adminTimeoutSeconds: Double
  private let log: @Sendable (Decision) -> Void
  private let runner = DeadlineRunner()

  public init(
    system: any UninstallSystem,
    table: PurgeTable,
    mode: Mode,
    stepTimeoutSeconds: Double = Timing.systemCallTimeoutSeconds,
    stepTimeoutOverrides: [String: Double] = [:],
    stopTimeoutSeconds: Double = TerminationCoordinator.defaultOuterBoundSeconds,
    adminTimeoutSeconds: Double = UninstallCoordinator.adminTimeoutSeconds,
    log: @escaping @Sendable (Decision) -> Void = { _ in }
  ) {
    self.system = system
    self.table = table
    self.mode = mode
    self.stepTimeoutSeconds = stepTimeoutSeconds
    self.stepTimeoutOverrides = stepTimeoutOverrides
    self.stopTimeoutSeconds = stopTimeoutSeconds
    self.adminTimeoutSeconds = adminTimeoutSeconds
    self.log = log
  }

  public func steps(helperInstalled: Bool, purge: Bool) -> [UninstallStep] {
    Self.steps(helperInstalled: helperInstalled, purge: purge, mode: mode)
  }

  public static func attemptsHelper(_ status: HelperInstallerStatus?) -> Bool {
    status != .notRegistered
  }

  public static func steps(helperInstalled: Bool, purge: Bool, mode: Mode) -> [UninstallStep] {
    UninstallStep.allCases.filter { step in
      switch step {
      case .stopKeepAwake, .removeLoginItem: true
      case .removeHelper, .restoreSleep: helperInstalled
      case .purge: purge
      case .trashApp: mode == .app
      }
    }
  }

  func inMode(_ other: Mode) -> UninstallCoordinator {
    guard other != mode else { return self }
    return UninstallCoordinator(
      system: system, table: table, mode: other, stepTimeoutSeconds: stepTimeoutSeconds,
      stepTimeoutOverrides: stepTimeoutOverrides, stopTimeoutSeconds: stopTimeoutSeconds,
      adminTimeoutSeconds: adminTimeoutSeconds, log: log)
  }

  public func run(
    helperStatus: HelperInstallerStatus?,
    purge: Bool,
    resumingAt: UninstallStep = .stopKeepAwake,
    earlier: UninstallReport? = nil,
    progress: @escaping @Sendable (UninstallProgress) -> Void = { _ in },
    continuing: @escaping @Sendable () -> Bool = { true }
  ) async -> UninstallReport {
    let helperInstalled = Self.attemptsHelper(helperStatus)
    var run = Run(steps: steps(helperInstalled: helperInstalled, purge: purge), progress: progress)
    run.carry(earlier, before: resumingAt)

    if resumingAt <= .stopKeepAwake {
      await stopKeepAwake(&run)
    }

    let removesHelperNow = helperInstalled && resumingAt <= .removeHelper
    if removesHelperNow {
      guard continuing() else { return interrupted(run) }
      guard await removeHelper(&run, status: helperStatus) else {
        log(Decision(keyword: .uninstall, verb: "run", fields: [field("result", "stopped")]))
        return run.report(.stopped)
      }
    }

    var restore = Restore()
    if resumingAt <= .restoreSleep {
      if !removesHelperNow {
        guard continuing() else { return interrupted(run) }
      }
      restore = await restoreSleep(&run, helperInstalled: helperInstalled, status: helperStatus, purge: purge)
    }

    if resumingAt <= .removeLoginItem {
      guard continuing() else { return interrupted(run) }
      await removeLoginItem(&run)
    }

    if purge, resumingAt <= .purge {
      guard continuing() else { return interrupted(run) }
      await purgeItems(&run, helperInstalled: helperInstalled, restore: restore)
    }

    if resumingAt <= .trashApp {
      guard continuing() else { return interrupted(run) }
      await removeStagedUpdate()
      if mode == .app {
        await trashApp(&run)
      }
    }

    let outcome: UninstallOutcome = run.isClean ? .uninstalled : .finishedWithProblems
    log(
      Decision(
        keyword: .uninstall, verb: "run",
        fields: [field("result", outcome == .uninstalled ? "uninstalled" : "problems")]))
    return run.report(outcome)
  }

  private func interrupted(_ run: Run) -> UninstallReport {
    log(Decision(keyword: .uninstall, verb: "run", fields: [field("result", "interrupted")]))
    return run.report(.finishedWithProblems)
  }

  public func noteQuit(
    settled: Bool, prompt: UninstallQuitPrompt = .none, sleepDisabledLeft: SleepDisabledLeft? = nil
  ) {
    var fields = [field("result", settled ? "settled" : "unsettled")]
    switch prompt {
    case .none: break
    case .held: fields.append(field("prompt", "held"))
    case .cancelled: fields.append(field("prompt", "cancelled"))
    }
    switch sleepDisabledLeft {
    case .owned?:
      fields += [field("sleepDisabled", "owned"), field("command", Hints.sleepDisabledCommand)]
    case .unknown?:
      fields += [field("sleepDisabled", "unknown"), field("command", Hints.sleepDisabledCommand)]
    case .notOwned?, nil:
      break
    }
    log(Decision(keyword: .uninstall, verb: "quit", fields: fields))
  }

  private func stopKeepAwake(_ run: inout Run) async {
    run.start(.stopKeepAwake)
    let system = system
    let box = OSAllocatedUnfairLock<UninstallEngineStop?>(initialState: nil)
    let finished = await Engine.bounded(seconds: stopTimeoutSeconds) {
      let result = await system.stopKeepAwake()
      box.withLock { $0 = result }
    }
    let result = finished ? box.withLock { $0 } : nil
    switch result {
    case .stopped?:
      run.finish(.stopKeepAwake, .done)
    case .notRunning?:
      run.finish(.stopKeepAwake, .done, note: UninstallCopy.keepAwakeNotRunningCaption)
    case .unconfirmed?, nil:
      run.finish(.stopKeepAwake, .failed(UninstallCopy.stopUnconfirmedCaption))
      run.manual.insert(.restart)
    }
    let word: String =
      switch result {
      case .stopped?: "stopped"
      case .notRunning?: "notRunning"
      case .unconfirmed?: "unconfirmed"
      case nil: "timedOut"
      }
    log(step: .stopKeepAwake, result: word)
  }

  private func removeHelper(_ run: inout Run, status: HelperInstallerStatus?) async -> Bool {
    run.start(.removeHelper)
    let system = system
    if run.ownership == nil {
      run.ownership = await ownership(for: status)
    }
    var clearWord = "notRun"
    if status == .enabled {
      let cleared = await call("clear") { system.helperClear() }
      clearWord = cleared == true ? "succeeded" : cleared == false ? "failed" : "timedOut"
    }
    let unregistered = await call("unregister") { system.unregisterHelper() }
    let fields = [field("ownership", Self.word(run.ownership ?? .unknown)), field("clear", clearWord)]
    guard unregistered == true else {
      run.finish(.removeHelper, .failed(UninstallCopy.helperNotRemovedCaption))
      log(step: .removeHelper, result: unregistered == false ? "failed" : "timedOut", extra: fields)
      return false
    }
    run.finish(.removeHelper, .done)
    log(step: .removeHelper, result: "done", extra: fields)
    return true
  }

  private func ownership(for status: HelperInstallerStatus?) async -> HelperOwnership {
    let system = system
    if status == .enabled || status == nil {
      let answer = await call("ownership") { system.helperOwnership() } ?? .unknown
      if answer != .unknown {
        return answer
      }
    }
    return await call("record") { system.recordOwnership() } ?? .unknown
  }

  private static func word(_ ownership: HelperOwnership) -> String {
    switch ownership {
    case .owned: "owned"
    case .notOwned: "notOwned"
    case .unknown: "unknown"
    }
  }

  private func restoreSleep(
    _ run: inout Run, helperInstalled: Bool, status: HelperInstallerStatus?, purge: Bool
  ) async -> Restore {
    let system = system
    if helperInstalled {
      run.start(.restoreSleep)
    }
    let reading = await call("sleepDisabled") { system.readSleepDisabled() } ?? nil
    switch reading {
    case nil:
      if helperInstalled {
        run.finish(.restoreSleep, .failed(SleepDisabledClearing.failedCaption))
      }
      log(step: .restoreSleep, result: helperInstalled ? "failed" : "unreadable", extra: [field("read", "unreadable")])
      return Restore()
    case false?:
      if helperInstalled {
        run.finish(.restoreSleep, .done)
      }
      log(step: .restoreSleep, result: "done", extra: [field("read", "0")])
      return Restore(rootAllowed: true)
    case true?:
      break
    }
    if run.ownership == nil {
      run.ownership = await ownership(for: status)
    }
    let ownership = run.ownership ?? .unknown
    let owner = field("owner", Self.word(ownership))
    guard helperInstalled, ownership == .owned else {
      return leaveAlone(&run, ownership: ownership, helperInstalled: helperInstalled, owner: owner)
    }
    let command: UninstallAdminCommand = purge ? .clearAndPurge : .clearSleepDisabled
    run.waiting(.restoreSleep)
    let outcome = await admin(command, run: &run)
    var restore = Restore(ran: command == .clearAndPurge)
    switch outcome {
    case .succeeded:
      restore.rootPurged = command == .clearAndPurge
      let after = await call("sleepDisabled") { system.readSleepDisabled() } ?? nil
      if after == false {
        restore.rootAllowed = true
        run.finish(.restoreSleep, .done)
        log(step: .restoreSleep, result: "done", extra: [field("read", "1"), owner, field("prompt", "succeeded")])
      } else {
        run.sleepDisabledLeft = .owned
        run.finish(.restoreSleep, .failed(SleepDisabledClearing.failedCaption))
        log(step: .restoreSleep, result: "failed", extra: [field("read", "1"), owner, field("prompt", "stillSet")])
      }
    case .cancelled:
      run.sleepDisabledLeft = .owned
      run.finish(.restoreSleep, .skipped(SleepDisabledClearing.cancelledCaption))
      log(step: .restoreSleep, result: "skipped", extra: [field("read", "1"), owner, field("prompt", "cancelled")])
    case .failed:
      run.sleepDisabledLeft = .owned
      run.finish(.restoreSleep, .failed(SleepDisabledClearing.failedCaption))
      log(step: .restoreSleep, result: "failed", extra: [field("read", "1"), owner, field("prompt", "failed")])
    }
    return restore
  }

  private func leaveAlone(
    _ run: inout Run, ownership: HelperOwnership, helperInstalled: Bool, owner: DecisionField
  ) -> Restore {
    switch ownership {
    case .notOwned:
      run.sleepDisabledLeft = .notOwned
      if helperInstalled {
        run.finish(.restoreSleep, .done, note: UninstallCopy.sleepDisabledNotOwnedCaption)
      }
    case .unknown:
      run.sleepDisabledLeft = .unknown
      if helperInstalled {
        run.finish(.restoreSleep, .skipped(UninstallCopy.sleepDisabledUnknownCaption))
      }
    case .owned:
      run.sleepDisabledLeft = .owned
    }
    log(step: .restoreSleep, result: "leftAlone", extra: [field("read", "1"), owner])
    return Restore(rootAllowed: ownership == .notOwned)
  }

  private func removeLoginItem(_ run: inout Run) async {
    let system = system
    run.start(.removeLoginItem)
    let removed = await call("loginItem") { system.unregisterLoginItem() }
    if removed == true {
      run.finish(.removeLoginItem, .done)
      log(step: .removeLoginItem, result: "done")
    } else {
      run.finish(.removeLoginItem, .failed(UninstallCopy.loginItemFailedCaption))
      run.manual.insert(.loginItem)
      log(step: .removeLoginItem, result: removed == false ? "failed" : "timedOut")
    }
  }

  private func purgeItems(_ run: inout Run, helperInstalled: Bool, restore: Restore) async {
    let system = system
    let table = table
    run.start(.purge)
    var defaultsWord = "atQuit"
    if mode == .headless {
      let defaults: Void? = await call("defaults") { system.purgeDefaults(appIdentifier: table.appIdentifier) }
      defaultsWord = defaults == nil ? "timedOut" : "done"
    }
    let userRemoved = await call("userItems") { system.removeUserItems(table.userItems) } == true
    var rootDone = true
    var rootWord = "none"
    if helperInstalled {
      if restore.rootPurged {
        rootWord = "done"
      } else if restore.ran || run.adminPrompts > 0 {
        rootDone = false
        rootWord = "notRun"
      } else if !restore.rootAllowed {
        rootDone = false
        rootWord = "kept"
      } else {
        run.waiting(.purge)
        let outcome = await admin(.purgeRootFolders, run: &run)
        rootDone = outcome == .succeeded
        rootWord =
          switch outcome {
          case .succeeded: "done"
          case .cancelled: "cancelled"
          case .failed: "failed"
          }
      }
    }
    if !rootDone {
      run.manual.insert(.rootFolders)
    }
    let result: String
    if !userRemoved {
      run.manual.insert(.userFiles)
      run.finish(.purge, .failed(UninstallCopy.userFilesFailedCaption))
      result = "failed"
    } else if !rootDone {
      run.finish(.purge, .skipped(UninstallCopy.rootFoldersLeftCaption))
      result = "skipped"
    } else {
      run.finish(.purge, .done, note: mode == .app ? UninstallCopy.preferencesAtQuitCaption : nil)
      result = "done"
    }
    log(
      step: .purge, result: result,
      extra: [
        field("defaults", defaultsWord), field("user", userRemoved ? "done" : "failed"),
        field("root", rootWord),
      ])
  }

  private func removeStagedUpdate() async {
    let system = system
    let table = table
    let staged = await call("staged") { system.updateStagedForQuit() }
    let removed = await call("stagedRemove") {
      system.removeStagedUpdate(labels: table.sparkleJobLabels, cache: table.sparkleCache)
    }
    log(
      Decision(
        keyword: .uninstall, verb: "stagedUpdate",
        fields: [
          field("result", removed == true ? "removed" : removed == false ? "failed" : "timedOut"),
          field("staged", staged == true ? "yes" : staged == false ? "no" : "timedOut"),
        ]))
  }

  @discardableResult
  public func removeStagedUpdate(at moment: StagedUpdateMoment) -> Bool {
    let system = system
    let table = table
    let outcome = runner.run(timeout: stepTimeout("stagedAtQuit"), key: "uninstall.stagedAtQuit") {
      system.removeStagedUpdate(labels: table.sparkleJobLabels, cache: table.sparkleCache)
    }
    let word: String =
      switch outcome {
      case .value(true): "removed"
      case .value(false): "failed"
      case .timedOut: "timedOut"
      }
    let at: String =
      switch moment {
      case .quit: "quit"
      case .installOnQuit: "installOnQuit"
      }
    log(Decision(keyword: .uninstall, verb: "stagedUpdate", fields: [field("result", word), field("at", at)]))
    return word == "removed"
  }

  @discardableResult
  public func purgePreferencesAtQuit() -> Bool {
    let system = system
    let table = table
    let outcome = runner.run(timeout: stepTimeout("preferences"), key: "uninstall.preferences") {
      system.purgeDefaults(appIdentifier: table.appIdentifier)
      return system.removeUserItems([table.preferencesItem])
    }
    let word: String =
      switch outcome {
      case .value(true): "done"
      case .value(false): "failed"
      case .timedOut: "timedOut"
      }
    log(Decision(keyword: .uninstall, verb: "preferences", fields: [field("result", word)]))
    return word == "done"
  }

  private func trashApp(_ run: inout Run) async {
    let system = system
    let identifier = table.appIdentifier
    run.start(.trashApp)
    let result = await call("trash") { system.trashApp(expectedIdentifier: identifier) }
    if result == .trashed {
      run.finish(.trashApp, .done)
      log(step: .trashApp, result: "done")
      return
    }
    run.finish(.trashApp, .failed(UninstallCopy.trashFailedCaption))
    run.manual.insert(.trash)
    let word: String =
      switch result {
      case .refused?: "refused"
      case .failed?: "failed"
      case .trashed?, nil: "timedOut"
      }
    log(step: .trashApp, result: word)
  }

  private func admin(_ command: UninstallAdminCommand, run: inout Run) async -> AdminOutcome {
    let system = system
    run.adminPrompts += 1
    let outcome = await runner.perform(timeout: adminTimeoutSeconds, key: "uninstall.admin") {
      system.runAdmin(command)
    }
    switch outcome {
    case .value(let value): return value
    case .timedOut: return .failed("timedOut")
    }
  }

  private func stepTimeout(_ name: String) -> Double {
    stepTimeoutOverrides[name] ?? stepTimeoutSeconds
  }

  private func call<T: Sendable>(_ name: String, _ body: @escaping @Sendable () -> T) async -> T? {
    switch await runner.perform(timeout: stepTimeout(name), key: "uninstall." + name, body) {
    case .value(let value): value
    case .timedOut: nil
    }
  }

  private func log(step: UninstallStep, result: String, extra: [DecisionField] = []) {
    log(Decision(keyword: .uninstall, verb: step.logName, fields: [field("result", result)] + extra))
  }

  private func field(_ key: String, _ value: String) -> DecisionField {
    DecisionField(key: key, value: value)
  }
}

extension UninstallCoordinator {
  fileprivate struct Restore {
    var ran = false
    var rootPurged = false
    var rootAllowed = false
  }

  fileprivate struct Run {
    let steps: [UninstallStep]
    let progress: @Sendable (UninstallProgress) -> Void
    var statuses: [UninstallStep: StepStatus]
    var notes: [UninstallStep: String] = [:]
    var manual: Set<UninstallManualStep> = []
    var sleepDisabledLeft: SleepDisabledLeft?
    var adminPrompts = 0
    var ownership: HelperOwnership?

    init(steps: [UninstallStep], progress: @escaping @Sendable (UninstallProgress) -> Void) {
      self.steps = steps
      self.progress = progress
      statuses = Dictionary(uniqueKeysWithValues: steps.map { ($0, StepStatus.pending) })
    }

    mutating func carry(_ earlier: UninstallReport?, before resumingAt: UninstallStep) {
      for step in steps where step < resumingAt {
        statuses[step] = earlier?.statuses[step] ?? .done
        if let note = earlier?.notes[step] {
          notes[step] = note
        }
      }
      for item in earlier?.manualSteps ?? [] where item.step < resumingAt {
        manual.insert(item)
      }
      ownership = earlier?.helperOwnership
    }

    func start(_ step: UninstallStep) {
      guard steps.contains(step) else { return }
      progress(.started(step))
    }

    func waiting(_ step: UninstallStep) {
      guard steps.contains(step) else { return }
      progress(.waitingForAdministrator(step))
    }

    mutating func finish(_ step: UninstallStep, _ status: StepStatus, note: String? = nil) {
      guard steps.contains(step) else { return }
      statuses[step] = status
      notes[step] = note
      progress(.finished(step, status, note: note))
    }

    var isClean: Bool {
      manual.isEmpty && steps.allSatisfy { statuses[$0] == .done } && sleepDisabledLeft != .owned
        && sleepDisabledLeft != .unknown
    }

    func report(_ outcome: UninstallOutcome) -> UninstallReport {
      UninstallReport(
        outcome: outcome, steps: steps, statuses: statuses, notes: notes, sleepDisabledLeft: sleepDisabledLeft,
        manualSteps: UninstallManualStep.allCases.filter { manual.contains($0) }, adminPrompts: adminPrompts,
        helperOwnership: ownership)
    }
  }
}
