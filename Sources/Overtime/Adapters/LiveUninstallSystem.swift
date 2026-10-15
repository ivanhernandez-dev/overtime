import Darwin
import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeHelperClient
import OvertimeHelperCore
import OvertimeSystem

nonisolated struct LiveUninstallSystem: UninstallSystem {
  static let launchctl = "/bin/launchctl"

  let table: PurgeTable
  var stop: @Sendable () async -> UninstallEngineStop
  var status: @Sendable () -> HelperInstallerStatus
  var ownership: @Sendable () -> HelperOwnership
  var record: @Sendable () -> HelperOwnership
  var clear: @Sendable () -> Bool
  var unregister: @Sendable () -> Bool
  var sleepDisabled: @Sendable () -> Bool?
  var admin: @Sendable (UninstallAdminCommand) -> AdminOutcome
  var loginItem: @Sendable () -> Bool
  var defaults: @Sendable (String) -> Void
  var remove: @Sendable (String) throws -> Void
  var staged: @Sendable () -> Bool
  var tools: any ToolPort
  var bundleIdentifier: String?
  var bundleURL: URL
  var trash: @Sendable (URL) throws -> Void
  var homeDirectory: String

  init(
    table: PurgeTable,
    stop: @escaping @Sendable () async -> UninstallEngineStop,
    status: @escaping @Sendable () -> HelperInstallerStatus,
    ownership: @escaping @Sendable () -> HelperOwnership,
    record: @escaping @Sendable () -> HelperOwnership,
    clear: @escaping @Sendable () -> Bool,
    unregister: @escaping @Sendable () -> Bool,
    sleepDisabled: @escaping @Sendable () -> Bool?,
    admin: @escaping @Sendable (UninstallAdminCommand) -> AdminOutcome,
    loginItem: @escaping @Sendable () -> Bool,
    defaults: @escaping @Sendable (String) -> Void,
    remove: @escaping @Sendable (String) throws -> Void,
    staged: @escaping @Sendable () -> Bool,
    tools: any ToolPort,
    bundleIdentifier: String?,
    bundleURL: URL,
    trash: @escaping @Sendable (URL) throws -> Void,
    homeDirectory: String
  ) {
    self.table = table
    self.stop = stop
    self.status = status
    self.ownership = ownership
    self.record = record
    self.clear = clear
    self.unregister = unregister
    self.sleepDisabled = sleepDisabled
    self.admin = admin
    self.loginItem = loginItem
    self.defaults = defaults
    self.remove = remove
    self.staged = staged
    self.tools = tools
    self.bundleIdentifier = bundleIdentifier
    self.bundleURL = bundleURL
    self.trash = trash
    self.homeDirectory = homeDirectory
  }

  static func app(
    table: PurgeTable, identity: HelperIdentity, stop: @escaping @Sendable () async -> UninstallEngineStop,
    staged: @escaping @Sendable () -> Bool, cancellation: ToolCancellation
  ) -> LiveUninstallSystem {
    LiveUninstallSystem(
      table: table,
      stop: stop,
      status: { SMAppServiceDaemon(identity: identity).status },
      ownership: { liveOwnership(identity: identity) },
      record: { recordOwnership(directory: URL(fileURLWithPath: identity.supportDirectory, isDirectory: true)) },
      clear: { liveClear(identity: identity) },
      unregister: {
        SMAppServiceDaemon(identity: identity).unregisterAndWait(timeoutSeconds: Timing.systemCallTimeoutSeconds)
      },
      sleepDisabled: { SleepDisabledReader.read(tools: ToolRunner()) },
      admin: { command in AppleScriptAdminPrompt(cancellation: cancellation, identity: identity).run(command) },
      loginItem: { liveLoginItemUnregister() },
      defaults: { domain in UserDefaults.standard.removePersistentDomain(forName: domain) },
      remove: { path in try FileManager.default.removeItem(atPath: path) },
      staged: staged,
      tools: ToolRunner(),
      bundleIdentifier: Bundle.main.bundleIdentifier,
      bundleURL: Bundle.main.bundleURL,
      trash: { url in try FileManager.default.trashItem(at: url, resultingItemURL: nil) },
      homeDirectory: NSHomeDirectory())
  }

  static func headless(table: PurgeTable, identity: HelperIdentity, instanceQuit: Bool) -> LiveUninstallSystem {
    app(table: table, identity: identity, stop: { .notRunning }, staged: { false }, cancellation: ToolCancellation())
      .headless(instanceQuit: instanceQuit)
  }

  func headless(instanceQuit: Bool) -> LiveUninstallSystem {
    var system = self
    system.stop = { instanceQuit ? .stopped : .notRunning }
    system.staged = { false }
    return system
  }

  static func ownership(from result: HelperCallResult<HelperStatus>) -> HelperOwnership {
    switch result {
    case .success(let status): status.owns ? .owned : .notOwned
    case .failed, .timedOut: .unknown
    }
  }

  static func ownership(from read: HelperRecordRead) -> HelperOwnership {
    switch read {
    case .missing: .notOwned
    case .loaded(let record): record.owns ? .owned : .notOwned
    case .unreadable: .unknown
    }
  }

  static func recordOwnership(directory: URL, requiredOwner: uid_t = 0) -> HelperOwnership {
    ownership(from: HelperRecordStore(directory: directory, requiredOwner: requiredOwner).read())
  }

  private static func liveOwnership(identity: HelperIdentity) -> HelperOwnership {
    let client = HelperXPCClient.privileged(identity: identity)
    defer { client.invalidate() }
    return ownership(from: client.status(appVersion: HelperIdentity.version))
  }

  private static func liveClear(identity: HelperIdentity) -> Bool {
    let client = HelperXPCClient.privileged(identity: identity)
    defer { client.invalidate() }
    guard case .success(let reply) = client.set(false) else { return false }
    return reply.code == .cleared
  }

  private static func liveLoginItemUnregister() -> Bool {
    do {
      try SMAppServiceLoginItem().unregister()
      return true
    } catch {
      return SMAppServiceDaemon.unregisterSucceeded(errorCode: (error as NSError).code)
    }
  }

  func stopKeepAwake() async -> UninstallEngineStop {
    await stop()
  }

  func helperStatus() -> HelperInstallerStatus {
    status()
  }

  func helperOwnership() -> HelperOwnership {
    ownership()
  }

  func recordOwnership() -> HelperOwnership {
    record()
  }

  func helperClear() -> Bool {
    clear()
  }

  func unregisterHelper() -> Bool {
    unregister()
  }

  func readSleepDisabled() -> Bool? {
    sleepDisabled()
  }

  func runAdmin(_ command: UninstallAdminCommand) -> AdminOutcome {
    admin(command)
  }

  func unregisterLoginItem() -> Bool {
    loginItem()
  }

  func purgeDefaults(appIdentifier: String) {
    guard appIdentifier == table.appIdentifier else { return }
    defaults(appIdentifier)
  }

  func removeUserItems(_ items: [PurgeItem]) -> Bool {
    guard Self.isUsableHome(homeDirectory) else { return false }
    var removedAll = true
    for item in items where table.userItems.contains(item) {
      if !removeIfPresent(item) {
        removedAll = false
      }
    }
    return removedAll
  }

  func updateStagedForQuit() -> Bool {
    staged()
  }

  func removeStagedUpdate(labels: [String], cache: PurgeItem) -> Bool {
    var removedAll = true
    for label in labels where table.sparkleJobLabels.contains(label) {
      switch tools.run(Self.launchctl, ["remove", label]) {
      case .finished: break
      case .timedOut, .launchFailed: removedAll = false
      }
    }
    guard cache == table.sparkleCache, Self.isUsableHome(homeDirectory) else { return false }
    return removeIfPresent(cache) && removedAll
  }

  func trashApp(expectedIdentifier: String) -> UninstallTrashResult {
    guard expectedIdentifier == table.appIdentifier, bundleIdentifier == expectedIdentifier else { return .refused }
    do {
      try trash(bundleURL)
      return .trashed
    } catch {
      return .failed
    }
  }

  private func removeIfPresent(_ item: PurgeItem) -> Bool {
    guard let path = item.absolutePath(homeDirectory: homeDirectory) else { return false }
    guard Self.exists(path) else { return true }
    do {
      try remove(path)
      return true
    } catch {
      return false
    }
  }

  static func isUsableHome(_ path: String) -> Bool {
    PurgeItem.usableHome(path) != nil
  }

  static func exists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
  }
}
