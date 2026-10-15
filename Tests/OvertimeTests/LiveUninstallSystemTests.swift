import Foundation
import OvertimeAppSupport
import OvertimeHelperClient
import OvertimeHelperCore
import OvertimeSystem
import ServiceManagement
import Testing
import os

@testable import Overtime

struct LiveUninstallSystemTests {
  struct Removal: Error {}

  final class Recorder: Sendable {
    private let state = OSAllocatedUnfairLock<[String]>(initialState: [])

    func record(_ entry: String) {
      state.withLock { $0.append(entry) }
    }

    var entries: [String] {
      state.withLock { $0 }
    }
  }

  final class RecordingTools: ToolPort {
    struct Call: Equatable {
      let executable: String
      let arguments: [String]
    }

    private let result: ToolOutcome
    private let recorded = OSAllocatedUnfairLock<[Call]>(initialState: [])

    init(result: ToolOutcome = .finished(exitCode: 0, stdout: "", stderr: "")) {
      self.result = result
    }

    var calls: [Call] {
      recorded.withLock { $0 }
    }

    func run(_ executable: String, _ arguments: [String]) -> ToolOutcome {
      recorded.withLock { $0.append(Call(executable: executable, arguments: arguments)) }
      return result
    }
  }

  final class Sandbox {
    let home: String

    init() throws {
      let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("overtime-live-uninstall-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
      let raw = base.path(percentEncoded: false)
      home = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }

    func path(_ item: PurgeItem) -> String {
      item.absolutePath(homeDirectory: home) ?? home + "/unusable-home"
    }

    func makeFile(_ item: PurgeItem) throws {
      let url = URL(fileURLWithPath: path(item))
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("x".utf8).write(to: url)
    }

    func makeFolder(_ item: PurgeItem) throws {
      try FileManager.default.createDirectory(atPath: path(item), withIntermediateDirectories: true)
      try Data("x".utf8).write(to: URL(fileURLWithPath: path(item) + "/inner"))
    }

    func exists(_ path: String) -> Bool {
      LiveUninstallSystem.exists(path)
    }

    deinit {
      try? FileManager.default.removeItem(atPath: home)
    }
  }

  static let table = PurgeTable.dev
  static let bundleURL = URL(fileURLWithPath: "/nonexistent/Overtime Dev.app", isDirectory: true)

  static func sandboxRemove(home: String, recorder: Recorder, failing: Set<String> = [])
    -> @Sendable (String) throws -> Void
  {
    { path in
      guard path.hasPrefix(home + "/") else {
        recorder.record("outside " + path)
        throw Removal()
      }
      recorder.record("remove " + path)
      if failing.contains(path) {
        throw Removal()
      }
      try FileManager.default.removeItem(atPath: path)
    }
  }

  static func fake(
    recorder: Recorder,
    home: String = "/nonexistent-home",
    status: HelperInstallerStatus = .enabled,
    sleepDisabled: Bool? = false,
    bundleIdentifier: String? = PurgeTable.dev.appIdentifier,
    tools: any ToolPort = RecordingTools(),
    remove: (@Sendable (String) throws -> Void)? = nil,
    trash: @escaping @Sendable (URL) throws -> Void = { _ in }
  ) -> LiveUninstallSystem {
    LiveUninstallSystem(
      table: table,
      stop: {
        recorder.record("stop")
        return .stopped
      },
      status: {
        recorder.record("status")
        return status
      },
      ownership: {
        recorder.record("ownership")
        return .owned
      },
      record: {
        recorder.record("record")
        return .notOwned
      },
      clear: {
        recorder.record("clear")
        return true
      },
      unregister: {
        recorder.record("unregister")
        return true
      },
      sleepDisabled: {
        recorder.record("sleepDisabled")
        return sleepDisabled
      },
      admin: { command in
        recorder.record("admin \(command)")
        return .succeeded
      },
      loginItem: {
        recorder.record("loginItem")
        return true
      },
      defaults: { domain in recorder.record("defaults " + domain) },
      remove: remove ?? { path in
        recorder.record("remove " + path)
        throw Removal()
      },
      staged: {
        recorder.record("staged")
        return false
      },
      tools: tools,
      bundleIdentifier: bundleIdentifier,
      bundleURL: bundleURL,
      trash: { url in
        recorder.record("trash " + url.path(percentEncoded: false))
        try trash(url)
      },
      homeDirectory: home)
  }

  static func status(owns: Bool) -> HelperStatus {
    HelperStatus(helperVersion: HelperIdentity.version, sleepDisabled: true, owns: owns, engaged: false)
  }

  @Test(arguments: [
    (HelperCallResult<HelperStatus>.success(status(owns: true)), HelperOwnership.owned),
    (.success(status(owns: false)), .notOwned),
    (.failed("noProxy"), .unknown),
    (.timedOut, .unknown),
  ])
  func ownershipComesFromTheHelpersOwnsFlagAndAnUnansweredCallIsUnknown(
    result: HelperCallResult<HelperStatus>, expected: HelperOwnership
  ) {
    #expect(LiveUninstallSystem.ownership(from: result) == expected)
  }

  @Test(arguments: [
    (HelperRecordRead.missing, HelperOwnership.notOwned),
    (.loaded(HelperRecord(owns: true, prior: false, at: 1)), .owned),
    (.loaded(HelperRecord(owns: false, prior: true, at: 1)), .notOwned),
    (.unreadable, .unknown),
  ])
  func theRecordSaysOwnedOnlyWhenItSaysSoAndAnUnreadableOneIsUnknown(
    read: HelperRecordRead, expected: HelperOwnership
  ) {
    #expect(LiveUninstallSystem.ownership(from: read) == expected)
  }

  @Test func theRecordIsReadFromTheHelperFolderAndACorruptOneIsUnknown() throws {
    let sandbox = try Sandbox()
    let folder = URL(fileURLWithPath: sandbox.home + "/helper", isDirectory: true)
    #expect(LiveUninstallSystem.recordOwnership(directory: folder, requiredOwner: getuid()) == .notOwned)
    let store = HelperRecordStore(directory: folder, requiredOwner: getuid())
    #expect(store.write(HelperRecord(owns: true, prior: false, at: 1)))
    #expect(LiveUninstallSystem.recordOwnership(directory: folder, requiredOwner: getuid()) == .owned)
    #expect(store.write(HelperRecord(owns: false, prior: false, at: 2)))
    #expect(LiveUninstallSystem.recordOwnership(directory: folder, requiredOwner: getuid()) == .notOwned)
    try Data("not json {".utf8).write(to: folder.appendingPathComponent(HelperRecordStore.fileName))
    #expect(LiveUninstallSystem.recordOwnership(directory: folder, requiredOwner: getuid()) == .unknown)
    #expect(LiveUninstallSystem.recordOwnership(directory: folder, requiredOwner: 0) == .unknown)
  }

  @Test func theTrashTakesTheRunningBundleOnlyWhenItsIdentifierIsTheTables() {
    let recorder = Recorder()
    let system = Self.fake(recorder: recorder)
    #expect(system.trashApp(expectedIdentifier: Self.table.appIdentifier) == .trashed)
    #expect(recorder.entries == ["trash " + Self.bundleURL.path(percentEncoded: false)])
  }

  @Test(arguments: [
    (String?.some(PurgeTable.release.appIdentifier), PurgeTable.dev.appIdentifier),
    (nil, PurgeTable.dev.appIdentifier),
    (PurgeTable.dev.appIdentifier, PurgeTable.release.appIdentifier),
    (PurgeTable.release.appIdentifier, PurgeTable.release.appIdentifier),
  ])
  func anyOtherBundleIsRefusedWithoutTouchingTheTrash(running: String?, expected: String) {
    let recorder = Recorder()
    let system = Self.fake(recorder: recorder, bundleIdentifier: running)
    #expect(system.trashApp(expectedIdentifier: expected) == .refused)
    #expect(recorder.entries.isEmpty)
  }

  @Test func aTrashThatThrowsIsAFailure() {
    let recorder = Recorder()
    let system = Self.fake(recorder: recorder, trash: { _ in throw Removal() })
    #expect(system.trashApp(expectedIdentifier: Self.table.appIdentifier) == .failed)
    #expect(recorder.entries.count == 1)
  }

  @Test func theUserPurgeRemovesTheTableItemsThatExistAndSkipsTheRest() throws {
    let sandbox = try Sandbox()
    let recorder = Recorder()
    let items = Self.table.userItems
    try sandbox.makeFolder(items[0])
    try sandbox.makeFolder(items[1])
    try sandbox.makeFile(items[2])
    try sandbox.makeFile(items[5])
    let system = Self.fake(
      recorder: recorder, home: sandbox.home, remove: Self.sandboxRemove(home: sandbox.home, recorder: recorder))
    #expect(system.removeUserItems(items))
    #expect(recorder.entries == [0, 1, 2, 5].map { "remove " + sandbox.path(items[$0]) })
    #expect(items.allSatisfy { !sandbox.exists(sandbox.path($0)) })
  }

  @Test func aFailedRemovalIsReportedAndTheOtherItemsAreStillRemoved() throws {
    let sandbox = try Sandbox()
    let recorder = Recorder()
    let items = Self.table.userItems
    for item in items {
      try sandbox.makeFile(item)
    }
    let stuck = sandbox.path(items[2])
    let system = Self.fake(
      recorder: recorder, home: sandbox.home,
      remove: Self.sandboxRemove(home: sandbox.home, recorder: recorder, failing: [stuck]))
    #expect(!system.removeUserItems(items))
    #expect(recorder.entries == items.map { "remove " + sandbox.path($0) })
    #expect(sandbox.exists(stuck))
    #expect(items.filter { sandbox.exists(sandbox.path($0)) }.map { sandbox.path($0) } == [stuck])
  }

  @Test func theUserPurgeTouchesNoItemOutsideTheTableAndNeverFollowsALink() throws {
    let sandbox = try Sandbox()
    let recorder = Recorder()
    let foreign = PurgeItem(scope: .user, relativePath: ".config/other-tool/config")
    let rootItem = Self.table.rootItems[0]
    try sandbox.makeFile(foreign)
    let target = sandbox.home + "/kept-target"
    try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: URL(fileURLWithPath: target + "/inner"))
    let linked = Self.table.userItems[1]
    try FileManager.default.createDirectory(
      atPath: (sandbox.path(linked) as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: sandbox.path(linked), withDestinationPath: target)
    let system = Self.fake(
      recorder: recorder, home: sandbox.home, remove: Self.sandboxRemove(home: sandbox.home, recorder: recorder))
    #expect(system.removeUserItems([foreign, rootItem, linked]))
    #expect(recorder.entries == ["remove " + sandbox.path(linked)])
    #expect(sandbox.exists(sandbox.path(foreign)))
    #expect(!sandbox.exists(sandbox.path(linked)))
    #expect(FileManager.default.fileExists(atPath: target + "/inner"))
  }

  @Test(arguments: ["", "/", "relative/home", "//", "/.", "/./", "/..", "~"])
  func anUnusableHomeFolderRemovesNothing(home: String) {
    #expect(!LiveUninstallSystem.isUsableHome(home))
    let recorder = Recorder()
    let system = Self.fake(recorder: recorder, home: home)
    #expect(!system.removeUserItems(Self.table.userItems))
    #expect(!system.removeStagedUpdate(labels: Self.table.sparkleJobLabels, cache: Self.table.sparkleCache))
    #expect(recorder.entries.allSatisfy { !$0.hasPrefix("remove") })
  }

  @Test func theDefaultsPurgeGetsTheTablesIdentifierOnly() {
    let recorder = Recorder()
    let system = Self.fake(recorder: recorder)
    system.purgeDefaults(appIdentifier: Self.table.appIdentifier)
    system.purgeDefaults(appIdentifier: "com.apple.finder")
    #expect(recorder.entries == ["defaults " + Self.table.appIdentifier])
  }

  @Test func aStagedUpdateLosesBothSparkleJobsAndItsCache() throws {
    let sandbox = try Sandbox()
    let recorder = Recorder()
    let tools = RecordingTools()
    try sandbox.makeFolder(Self.table.sparkleCache)
    let system = Self.fake(
      recorder: recorder, home: sandbox.home, tools: tools,
      remove: Self.sandboxRemove(home: sandbox.home, recorder: recorder))
    #expect(system.removeStagedUpdate(labels: Self.table.sparkleJobLabels, cache: Self.table.sparkleCache))
    let expected = [
      "io.github.ivanhernandez-dev.overtime.dev-sparkle-updater",
      "io.github.ivanhernandez-dev.overtime.dev-sparkle-progress",
    ].map { RecordingTools.Call(executable: "/bin/launchctl", arguments: ["remove", $0]) }
    #expect(tools.calls == expected)
    #expect(recorder.entries == ["remove " + sandbox.path(Self.table.sparkleCache)])
    #expect(!sandbox.exists(sandbox.path(Self.table.sparkleCache)))
  }

  @Test func aJobThatIsAlreadyGoneStillCountsAndALaunchctlThatHangsDoesNot() throws {
    let sandbox = try Sandbox()
    let recorder = Recorder()
    let gone = Self.fake(
      recorder: recorder, home: sandbox.home,
      tools: RecordingTools(result: .finished(exitCode: 3, stdout: "", stderr: "No such process")))
    #expect(gone.removeStagedUpdate(labels: Self.table.sparkleJobLabels, cache: Self.table.sparkleCache))
    let hung = Self.fake(recorder: recorder, home: sandbox.home, tools: RecordingTools(result: .timedOut))
    #expect(!hung.removeStagedUpdate(labels: Self.table.sparkleJobLabels, cache: Self.table.sparkleCache))
    #expect(recorder.entries.isEmpty)
  }

  @Test func onlyTheTablesJobLabelsAndCacheAreTouched() throws {
    let sandbox = try Sandbox()
    let recorder = Recorder()
    let tools = RecordingTools()
    let other = PurgeItem(scope: .user, relativePath: "Library/Caches/com.example.other")
    try sandbox.makeFolder(other)
    let system = Self.fake(
      recorder: recorder, home: sandbox.home, tools: tools,
      remove: Self.sandboxRemove(home: sandbox.home, recorder: recorder))
    #expect(!system.removeStagedUpdate(labels: ["com.example.other-job"], cache: other))
    #expect(tools.calls.isEmpty)
    #expect(recorder.entries.isEmpty)
    #expect(sandbox.exists(sandbox.path(other)))
  }

  @Test func anUnregisterThatReportedNoErrorOrAnAlreadyRemovedJobSucceeded() {
    #expect(SMAppServiceDaemon.unregisterSucceeded(errorCode: nil))
    #expect(SMAppServiceDaemon.unregisterSucceeded(errorCode: kSMErrorJobNotFound))
    #expect(kSMErrorJobNotFound == 6)
  }

  @Test(arguments: [
    kSMErrorInternalFailure, kSMErrorInvalidSignature, kSMErrorAuthorizationFailure, kSMErrorToolNotValid,
    kSMErrorServiceUnavailable, kSMErrorJobPlistNotFound, kSMErrorJobMustBeEnabled, kSMErrorInvalidPlist,
    kSMErrorLaunchDeniedByUser, kSMErrorAlreadyRegistered, 0, 1, -1, 3, 1_000,
  ])
  func anyOtherUnregisterErrorIsAFailure(code: Int) {
    #expect(!SMAppServiceDaemon.unregisterSucceeded(errorCode: code))
  }

  @Test(arguments: [true, false])
  func theHeadlessFactoryStopsOnlyWhatTheQuitStoppedAndNeverHasAStagedUpdate(instanceQuit: Bool) async {
    let system = LiveUninstallSystem.headless(table: Self.table, identity: .dev, instanceQuit: instanceQuit)
    #expect(await system.stopKeepAwake() == (instanceQuit ? .stopped : .notRunning))
    #expect(!system.updateStagedForQuit())
    #expect(system.table == Self.table)
  }

  @Test(arguments: [UninstallCoordinator.Mode.headless, .app])
  func theHeadlessRunPrintsOneLinePerStepNeverTrashesAndExitsZero(mode: UninstallCoordinator.Mode) async throws {
    let sandbox = try Sandbox()
    let recorder = Recorder()
    let system = Self.fake(
      recorder: recorder, home: sandbox.home, remove: Self.sandboxRemove(home: sandbox.home, recorder: recorder)
    ).headless(instanceQuit: true)
    let coordinator = UninstallCoordinator(system: system, table: Self.table, mode: mode)
    let lines = Recorder()
    let code = await HeadlessUninstall.run(
      coordinator: coordinator, system: system, purge: true, write: { lines.record($0) })
    #expect(code == 0)
    #expect(
      lines.entries == [
        "Stop keeping the Mac awake: done",
        "Remove unplug protection: done",
        "Turn system sleep back on if unplug protection turned it off: done",
        "Remove Overtime from your login items: done",
        "Remove settings, state and logs: done",
        "Overtime is uninstalled.",
      ])
    #expect(!recorder.entries.contains { $0.hasPrefix("trash") })
    #expect(!recorder.entries.contains("stop"))
    #expect(!recorder.entries.contains("staged"))
    #expect(recorder.entries.contains("admin purgeRootFolders"))
    #expect(recorder.entries.contains("defaults " + Self.table.appIdentifier))
  }
}
