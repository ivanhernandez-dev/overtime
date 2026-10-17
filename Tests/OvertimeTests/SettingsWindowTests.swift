import AppKit
import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing
import os

import struct SwiftUI.Color

@testable import Overtime

@MainActor
struct SettingsWindowTests {
  @MainActor struct Fixture {
    let folder: TestFolder
    let host = FakeEngineHost()
    let model: SettingsModel
    let logged = LoggedDecisions()

    init() throws {
      folder = try TestFolder()
      model = SettingsModel(settingsFile: folder.url.appendingPathComponent("settings.json"), host: host)
      let logged = logged
      model.logError = { logged.append($0) }
    }

    var fileSettings: Settings? {
      guard case .loaded(let settings) = SettingsStore.load(from: model.settingsFile) else { return nil }
      return settings
    }
  }

  final class FakeFolderPicker: FolderPickerPort {
    private var picks: [URL?]
    private(set) var calls = 0

    init(_ picks: [URL?]) {
      self.picks = picks
    }

    func chooseFolder() async -> URL? {
      calls += 1
      return picks.isEmpty ? nil : picks.removeFirst()
    }
  }

  static let testHome = "/Users/someone"

  @MainActor struct FolderFixture {
    let folder: TestFolder
    let host = FakeEngineHost()
    let picker: FakeFolderPicker
    let model: SettingsModel

    init(picks: [URL?], settings: Settings? = nil) throws {
      folder = try TestFolder()
      let file = folder.url.appendingPathComponent("settings.json")
      if let settings {
        try SettingsStore.save(settings, to: file)
      }
      picker = FakeFolderPicker(picks)
      model = SettingsModel(
        settingsFile: file, host: host, folderPicker: picker, environment: [:],
        homeDirectory: SettingsWindowTests.testHome)
    }
  }

  final class LoggedDecisions {
    private(set) var decisions: [Decision] = []

    func append(_ decision: Decision) {
      decisions.append(decision)
    }
  }

  final class FakeWiFi: WiFiInfoPort {
    private let reads = OSAllocatedUnfairLock(initialState: 0)
    let networks: [String]?

    init(networks: [String]?) {
      self.networks = networks
    }

    var readCount: Int {
      reads.withLock { $0 }
    }

    func interfaceName() -> String? {
      "en0"
    }

    func knownNetworkNames() -> [String]? {
      reads.withLock { $0 += 1 }
      return networks
    }
  }

  @MainActor struct NetworkFixture {
    let folder: TestFolder
    let host = FakeEngineHost()
    let wifi: FakeWiFi
    let model: SettingsModel

    init(networks: [String]?, settings: Settings? = nil) throws {
      folder = try TestFolder()
      let file = folder.url.appendingPathComponent("settings.json")
      if let settings {
        try SettingsStore.save(settings, to: file)
      }
      wifi = FakeWiFi(networks: networks)
      model = SettingsModel(settingsFile: file, host: host, wifi: wifi)
    }

    var fileSettings: Settings? {
      guard case .loaded(let settings) = SettingsStore.load(from: model.settingsFile) else { return nil }
      return settings
    }
  }

  @MainActor final class FakeLocationStatus: LocationStatusPort {
    var current: LocationAuthorization
    private(set) var statusReads = 0
    private(set) var requests = 0

    init(_ current: LocationAuthorization) {
      self.current = current
    }

    func status() -> LocationAuthorization {
      statusReads += 1
      return current
    }

    func request() {
      requests += 1
    }
  }

  @MainActor struct GeneralFixture {
    let folder: TestFolder
    let host = FakeEngineHost()
    let location: FakeLocationStatus
    let panel = PanelModel()
    let model: SettingsModel
    let opened = OpenedURLs()

    init(settings: Settings? = nil, location status: LocationAuthorization = .notDetermined) throws {
      folder = try TestFolder()
      let file = folder.url.appendingPathComponent("settings.json")
      if let settings {
        try SettingsStore.save(settings, to: file)
      }
      location = FakeLocationStatus(status)
      model = SettingsModel(
        settingsFile: file, host: host, wifi: FakeWiFi(networks: []), location: location, panel: panel)
      let opened = opened
      model.openURL = { opened.append($0) }
    }

    var fileSettings: Settings? {
      guard case .loaded(let settings) = SettingsStore.load(from: model.settingsFile) else { return nil }
      return settings
    }
  }

  @MainActor struct DiagnosticsFixture {
    let folder: TestFolder
    let host = FakeEngineHost()
    let panel = PanelModel()
    let model: SettingsModel

    init(settings: Settings? = nil) throws {
      folder = try TestFolder()
      let file = folder.url.appendingPathComponent("settings.json")
      if let settings {
        try SettingsStore.save(settings, to: file)
      }
      panel.homeDirectory = SettingsWindowTests.testHome
      panel.amphetamineLocator = .absent
      panel.bind(to: host)
      model = SettingsModel(
        settingsFile: file, host: host, panel: panel, environment: [:], homeDirectory: SettingsWindowTests.testHome)
    }

    func publish(_ snapshot: EngineSnapshot) async -> Bool {
      host.publish(snapshot)
      return await waitUntil { panel.snapshot == snapshot }
    }

    func publish(_ warnings: [DetectionWarning]) async -> Bool {
      host.publish(EngineSnapshot(wanted: false, reason: "idle", detectionWarnings: warnings))
      return await waitUntil { model.detectionWarnings == warnings }
    }
  }

  static let defaultRoot = "/Users/someone/.claude/projects"
  static let workRoot = "/Volumes/Work/claude projects"

  final class OpenedURLs {
    private(set) var urls: [URL] = []

    func append(_ url: URL) {
      urls.append(url)
    }
  }

  final class FakeNotificationPort: NotificationPort {
    private struct State {
      var authorization: NotificationAuthorization
      var afterRequest: NotificationAuthorization?
      var reads = 0
      var requests = 0
      var posted: [NotificationIntent] = []
      var heldRead: AsyncStream<Void>?
      var release: AsyncStream<Void>.Continuation?
      var heldRequest: AsyncStream<Void>?
      var requestRelease: AsyncStream<Void>.Continuation?
    }

    private let state: OSAllocatedUnfairLock<State>

    init(_ authorization: NotificationAuthorization = .authorized, afterRequest: NotificationAuthorization? = nil) {
      state = OSAllocatedUnfairLock(initialState: State(authorization: authorization, afterRequest: afterRequest))
    }

    var reads: Int {
      state.withLock { $0.reads }
    }

    var requests: Int {
      state.withLock { $0.requests }
    }

    var posted: [NotificationIntent] {
      state.withLock { $0.posted }
    }

    func set(_ authorization: NotificationAuthorization) {
      state.withLock { $0.authorization = authorization }
    }

    func holdNextRead() {
      let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
      state.withLock { state in
        state.heldRead = stream
        state.release = continuation
      }
    }

    func releaseRead() {
      state.withLock { $0.release }?.finish()
    }

    func authorization() async -> NotificationAuthorization {
      let (sampled, gate) = state.withLock { state -> (NotificationAuthorization, AsyncStream<Void>?) in
        state.reads += 1
        defer { state.heldRead = nil }
        return (state.authorization, state.heldRead)
      }
      if let gate {
        for await _ in gate {}
      }
      return sampled
    }

    func holdRequests() {
      let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
      state.withLock { state in
        state.heldRequest = stream
        state.requestRelease = continuation
      }
    }

    func releaseRequests() {
      state.withLock { $0.requestRelease }?.finish()
    }

    func requestAuthorization() async -> NotificationAuthorization {
      let gate = state.withLock { state -> AsyncStream<Void>? in
        state.requests += 1
        return state.heldRequest
      }
      if let gate {
        for await _ in gate {}
      }
      return state.withLock { state in
        if let afterRequest = state.afterRequest {
          state.authorization = afterRequest
        }
        return state.authorization
      }
    }

    func post(_ intent: NotificationIntent) async -> Bool {
      state.withLock { $0.posted.append(intent) }
      return true
    }
  }

  final class ChangeCounter {
    private(set) var count = 0

    func increment() {
      count += 1
    }
  }

  @MainActor struct NotificationsFixture {
    let folder: TestFolder
    let host = FakeEngineHost()
    let port: FakeNotificationPort
    let model: SettingsModel
    let opened = OpenedURLs()
    let changes = ChangeCounter()

    init(
      _ authorization: NotificationAuthorization = .authorized, afterRequest: NotificationAuthorization? = nil,
      settings: Settings? = nil, preferences: AppPreferences? = nil
    ) throws {
      folder = try TestFolder()
      let file = folder.url.appendingPathComponent("settings.json")
      if let settings {
        try SettingsStore.save(settings, to: file)
      }
      let preferencesFile = folder.url.appendingPathComponent("preferences.json")
      if let preferences {
        try AppPreferencesStore.write(preferences, to: preferencesFile)
      }
      port = FakeNotificationPort(authorization, afterRequest: afterRequest)
      model = SettingsModel(settingsFile: file, host: host, preferencesFile: preferencesFile, notifications: port)
      let opened = opened
      model.openURL = { opened.append($0) }
      let changes = changes
      model.onPreferencesChanged = { changes.increment() }
    }

    var filePreferences: AppPreferences? {
      guard case .loaded(let preferences) = AppPreferencesStore.read(at: model.preferencesFile) else { return nil }
      return preferences
    }
  }

  @MainActor struct AttentionFixture {
    let folder: TestFolder
    let host = FakeEngineHost()
    let panel = PanelModel()
    let location: FakeLocationStatus
    let port: FakeNotificationPort
    let model: SettingsModel

    init(
      settings: Settings? = nil, location status: LocationAuthorization = .authorized,
      notifications: NotificationAuthorization = .authorized
    ) throws {
      folder = try TestFolder()
      let file = folder.url.appendingPathComponent("settings.json")
      if let settings {
        try SettingsStore.save(settings, to: file)
      }
      location = FakeLocationStatus(status)
      port = FakeNotificationPort(notifications)
      panel.amphetamineLocator = .absent
      panel.bind(to: host)
      model = SettingsModel(
        settingsFile: file, host: host, wifi: FakeWiFi(networks: []), location: location, panel: panel,
        notifications: port)
    }

    func open() async {
      model.open(pane: nil)
      await model.refreshNotificationAuthorization()
    }

    var badgedPanes: [SettingsPane] {
      SettingsPane.allCases.filter { model.sidebarBadge(for: $0) != nil }
    }
  }

  @Test func committingReleaseAtAppliesOnceAndWritesTheFile() async throws {
    let fixture = try Fixture()
    let result = await fixture.model.commit(.batteryLowPercent, text: "15")
    #expect(result == .applied)
    #expect(fixture.host.appliedSettings.map(\.batteryLowPercent) == [15])
    #expect(fixture.fileSettings?.batteryLowPercent == 15)
    #expect(fixture.model.settings.batteryLowPercent == 15)
    #expect(fixture.model.message(for: .batteryLowPercent) == nil)
    #expect(fixture.model.text(for: .batteryLowPercent) == "15")
  }

  @Test func anUnparsableValueKeepsTheTextAndShowsTheLine() async throws {
    let fixture = try Fixture()
    let result = await fixture.model.commit(.batteryLowPercent, text: "abc")
    #expect(result == .invalid(SettingsValidationError(message: SettingsEditor.releaseAtRangeMessage)))
    #expect(fixture.model.message(for: .batteryLowPercent) == "Enter a whole percentage from 1 to 50.")
    #expect(fixture.model.text(for: .batteryLowPercent) == "abc")
    #expect(fixture.host.appliedSettings.isEmpty)
    #expect(fixture.fileSettings == nil)
    #expect(fixture.model.settings.batteryLowPercent == 10)
  }

  @Test func anOutOfRangeValueIsRejectedNotClamped() async throws {
    let fixture = try Fixture()
    await fixture.model.commit(.batteryLowPercent, text: "60")
    #expect(fixture.model.message(for: .batteryLowPercent) == SettingsEditor.releaseAtRangeMessage)
    #expect(fixture.model.text(for: .batteryLowPercent) == "60")
    #expect(fixture.host.appliedSettings.isEmpty)
    #expect(fixture.model.settings.batteryLowPercent == 10)
  }

  @Test func aValidEditHidesTheLine() async throws {
    let fixture = try Fixture()
    await fixture.model.commit(.batteryLowPercent, text: "abc")
    await fixture.model.commit(.batteryLowPercent, text: "12")
    #expect(fixture.model.message(for: .batteryLowPercent) == nil)
    #expect(fixture.host.appliedSettings.map(\.batteryLowPercent) == [12])
  }

  @Test func aReadOnlySettingsFolderShowsTheSaveErrorAndAppliesNothing() async throws {
    let folder = try TestFolder()
    let locked = folder.url.appendingPathComponent("locked", isDirectory: true)
    try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path(percentEncoded: false))
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: locked.path(percentEncoded: false))
    }
    let host = FakeEngineHost()
    let model = SettingsModel(settingsFile: locked.appendingPathComponent("settings.json"), host: host)
    let logged = LoggedDecisions()
    model.logError = { logged.append($0) }
    let result = await model.commit(.batteryLowPercent, text: "15")
    #expect(result == .saveFailed)
    #expect(model.saveError == SettingsEditor.saveFailedMessage)
    #expect(host.appliedSettings.isEmpty)
    #expect(model.settings.batteryLowPercent == 10)
    #expect(model.text(for: .batteryLowPercent) == "15")
    #expect(logged.decisions == [Decision(keyword: .error, verb: "settings save failed")])
  }

  @Test func aSuccessfulSaveClearsTheSaveErrorLine() async throws {
    let folder = try TestFolder()
    let settingsFolder = folder.url.appendingPathComponent("settings", isDirectory: true)
    try FileManager.default.createDirectory(at: settingsFolder, withIntermediateDirectories: true)
    let path = settingsFolder.path(percentEncoded: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: path)
    let host = FakeEngineHost()
    let model = SettingsModel(settingsFile: settingsFolder.appendingPathComponent("settings.json"), host: host)
    await model.commit(.batteryLowPercent, text: "15")
    #expect(model.saveError != nil)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
    await model.commit(.batteryLowPercent, text: "15")
    #expect(model.saveError == nil)
    #expect(host.appliedSettings.map(\.batteryLowPercent) == [15])
  }

  @Test func theResumeFieldAppliesThroughTheSameCommitter() async throws {
    let fixture = try Fixture()
    await fixture.model.commit(.batteryResumePercent, text: "35")
    #expect(fixture.host.appliedSettings.map(\.batteryResumePercent) == [35])
    await fixture.model.commit(.batteryResumePercent, text: "10")
    #expect(fixture.model.message(for: .batteryResumePercent) == "Enter a whole percentage from 11 to 100.")
    #expect(fixture.host.appliedSettings.count == 1)
  }

  @Test func withoutARunningEngineNothingIsSavedOrApplied() async throws {
    let folder = try TestFolder()
    let model = SettingsModel(settingsFile: folder.url.appendingPathComponent("settings.json"))
    #expect(!model.canEdit)
    let result = await model.commit(.batteryLowPercent, text: "15")
    #expect(result == nil)
    #expect(!FileManager.default.fileExists(atPath: model.settingsFile.path(percentEncoded: false)))
  }

  @Test func theModelReadsTheEffectiveSettingsFromTheFile() throws {
    let folder = try TestFolder()
    let file = folder.url.appendingPathComponent("settings.json")
    try SettingsStore.save(Settings(batteryLowPercent: 25, batteryResumePercent: 40), to: file)
    let model = SettingsModel(settingsFile: file, host: FakeEngineHost())
    #expect(model.text(for: .batteryLowPercent) == "25")
    #expect(model.text(for: .batteryResumePercent) == "40")
  }

  @Test func theSidebarListsTheSevenPanesInOrder() {
    #expect(
      SettingsPane.allCases.map(\.title) == [
        "General", "Detection", "Battery", "Network", "Unplug Protection", "Diagnostics", "About",
      ])
    #expect(
      SettingsPane.allCases.map(\.symbol) == [
        "gearshape", "waveform.path.ecg", "battery.75percent", "wifi", "powerplug", "stethoscope", "info.circle",
      ])
  }

  @Test func selectingAboutSetsTheWindowTitleToAbout() throws {
    let fixture = try Fixture()
    let controller = SettingsWindow.controller(model: fixture.model)
    fixture.model.select(.about)
    #expect(fixture.model.selectedPane == .about)
    #expect(controller.title == "About")
    #expect(controller.window == nil)
  }

  @Test func aSettingsModelStartsWithADevelopmentAboutModel() throws {
    let fixture = try Fixture()
    #expect(AboutPaneTests.isDevelopment(fixture.model.about.mode))
    #expect(fixture.model.about.noteRow?.title == "Updates are off in development builds.")
  }

  @Test func theModelOpensOnGeneralFirstAndThenOnTheLastPane() throws {
    let fixture = try Fixture()
    fixture.model.open(pane: nil)
    #expect(fixture.model.selectedPane == .general)
    fixture.model.open(pane: .battery)
    #expect(fixture.model.selectedPane == .battery)
    fixture.model.open(pane: nil)
    #expect(fixture.model.selectedPane == .battery)
  }

  @Test(arguments: [SettingsPane?.some(.unplugProtection), .diagnostics, .general, nil])
  func whileAnUninstallIsOpenEveryOpenKeepsAboutAndItsSheetInFront(_ pane: SettingsPane?) async throws {
    let fixture = try Fixture()
    let uninstall = AboutPaneTests.uninstallModel()
    fixture.model.about.uninstall = uninstall
    fixture.model.open(pane: .battery)
    #expect(fixture.model.selectedPane == .battery)
    await uninstall.present()
    #expect(uninstall.isOpenOrActive)
    fixture.model.open(pane: .about)
    fixture.model.open(pane: pane)
    #expect(fixture.model.selectedPane == .about)
    uninstall.keep()
    #expect(!uninstall.isOpenOrActive)
    fixture.model.open(pane: .diagnostics)
    #expect(fixture.model.selectedPane == .diagnostics)
  }

  @Test func whileAnUninstallIsOpenAPaneOpenedFromElsewhereStillLandsOnAbout() async throws {
    let fixture = try Fixture()
    let uninstall = AboutPaneTests.uninstallModel()
    fixture.model.about.uninstall = uninstall
    fixture.model.open(pane: .battery)
    await uninstall.present()
    fixture.model.open(pane: .unplugProtection)
    #expect(fixture.model.selectedPane == .about)
  }

  @Test func thePanelSettingsActionCallsTheOpenSettingsClosureOnce() {
    let model = PanelModel()
    var opened: [SettingsPane?] = []
    model.onOpenSettings = { opened.append($0) }
    model.openSettings()
    #expect(opened == [nil])
  }

  @Test func theWindowTitleFollowsTheSelectedPaneWithoutShowingTheWindow() throws {
    let fixture = try Fixture()
    let controller = SettingsWindow.controller(model: fixture.model)
    #expect(controller.title == "General")
    fixture.model.select(.battery)
    #expect(controller.title == "Battery")
    #expect(controller.window == nil)
  }

  @Test func showSettingsInTheTestHostOpensNoWindow() throws {
    let delegate = try #require(AppDelegate.shared)
    let before = NSApp.windows.count
    delegate.showSettings(pane: .battery)
    #expect(delegate.settingsModel == nil)
    #expect(NSApp.windows.count == before)
  }

  @Test func revertingAFocusedFieldRestoresTheSavedValueAndClearsItsMessage() async throws {
    let fixture = try Fixture()
    await fixture.model.commit(.batteryLowPercent, text: "abc")
    fixture.model.revert(.batteryLowPercent)
    #expect(fixture.model.text(for: .batteryLowPercent) == "10")
    #expect(fixture.model.message(for: .batteryLowPercent) == nil)
    #expect(fixture.host.appliedSettings.isEmpty)
  }

  @Test func revertingAfterASaveRestoresTheNewSavedValue() async throws {
    let fixture = try Fixture()
    await fixture.model.commit(.batteryLowPercent, text: "15")
    fixture.model.setText("4", for: .batteryLowPercent)
    fixture.model.revert(.batteryLowPercent)
    #expect(fixture.model.text(for: .batteryLowPercent) == "15")
    #expect(fixture.host.appliedSettings.count == 1)
  }

  @Test func leavingTheFieldCommitsAnEditOnce() async throws {
    let fixture = try Fixture()
    fixture.model.setText("18", for: .batteryResumePercent)
    let result = await fixture.model.commitIfEdited(.batteryResumePercent)
    #expect(result == .applied)
    #expect(fixture.host.appliedSettings.map(\.batteryResumePercent) == [18])
    #expect(await fixture.model.commitIfEdited(.batteryResumePercent) == nil)
    #expect(fixture.host.appliedSettings.count == 1)
  }

  @Test func leavingAnUneditedFieldCommitsNothing() async throws {
    let fixture = try Fixture()
    #expect(await fixture.model.commitIfEdited(.batteryLowPercent) == nil)
    #expect(fixture.host.appliedSettings.isEmpty)
    #expect(fixture.fileSettings == nil)
  }

  @Test func aStepperClickCommitsOnce() async throws {
    let fixture = try Fixture()
    let result = await fixture.model.step(.batteryLowPercent, by: 1)
    #expect(result == .applied)
    #expect(fixture.host.appliedSettings.map(\.batteryLowPercent) == [11])
    #expect(fixture.fileSettings?.batteryLowPercent == 11)
    #expect(fixture.model.text(for: .batteryLowPercent) == "11")
  }

  @Test func rapidStepperClicksEachCommitFromTheLastSavedValue() async throws {
    let fixture = try Fixture()
    async let first = fixture.model.step(.batteryResumePercent, by: 1)
    async let second = fixture.model.step(.batteryResumePercent, by: 1)
    _ = await (first, second)
    #expect(fixture.host.appliedSettings.map(\.batteryResumePercent) == [21, 22])
    #expect(fixture.model.settings.batteryResumePercent == 22)
  }

  @Test func aStepperClickPastTheBoundCommitsNothing() async throws {
    let fixture = try Fixture()
    await fixture.model.commit(.batteryResumePercent, text: "100")
    #expect(await fixture.model.step(.batteryResumePercent, by: 1) == nil)
    #expect(fixture.host.appliedSettings.count == 1)
  }

  @Test(arguments: SettingsPane.allCases)
  func selectingAPaneSetsTheWindowTitleToItsName(_ pane: SettingsPane) throws {
    let fixture = try Fixture()
    let controller = SettingsWindow.controller(model: fixture.model)
    if pane == .general {
      fixture.model.select(.battery)
    }
    fixture.model.select(pane)
    #expect(controller.title == pane.title)
    #expect(controller.window == nil)
  }

  @Test func leavingAPaneWithAnInvalidFieldDiscardsTheEdit() async throws {
    let fixture = try Fixture()
    fixture.model.select(.battery)
    await fixture.model.commit(.batteryLowPercent, text: "abc")
    fixture.model.select(.general)
    #expect(fixture.model.text(for: .batteryLowPercent) == "10")
    #expect(fixture.model.message(for: .batteryLowPercent) == nil)
  }

  @Test func showingSettingsOnAnOpenWindowSelectsTheDeepLinkedPane() throws {
    let fixture = try Fixture()
    var presented = 0
    let presenter = SettingsPresenter(model: fixture.model) { _ in presented += 1 }
    presenter.show(pane: nil)
    #expect(fixture.model.selectedPane == .general)
    #expect(presenter.controller.title == "General")
    presenter.show(pane: .battery)
    #expect(fixture.model.selectedPane == .battery)
    #expect(presenter.controller.title == "Battery")
    #expect(presented == 2)
    #expect(presenter.controller.window == nil)
  }

  @Test func closingTheWindowCallsTheCloseRouteAndDiscardsEdits() async throws {
    let fixture = try Fixture()
    var closed = 0
    fixture.model.onClose = { closed += 1 }
    await fixture.model.commit(.batteryLowPercent, text: "abc")
    fixture.model.close()
    #expect(closed == 1)
    #expect(fixture.model.message(for: .batteryLowPercent) == nil)
    #expect(fixture.model.text(for: .batteryLowPercent) == "10")
  }

  @Test func addFolderAppendsThePickedPathAndAppliesOnce() async throws {
    let folder = try TestFolder()
    let picked = folder.url.appendingPathComponent("transcripts", isDirectory: true)
    try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
    let fixture = try FolderFixture(picks: [picked])
    let result = await fixture.model.addFolder()
    #expect(result == .applied)
    #expect(fixture.picker.calls == 1)
    let expected = folder.path.hasSuffix("/") ? folder.path + "transcripts" : folder.path + "/transcripts"
    #expect(fixture.host.appliedSettings.map(\.transcriptRoots) == [[expected]])
    #expect(fixture.model.folderRows.map(\.path) == [expected])
    #expect(fixture.model.folderRows.allSatisfy { !$0.isDefault })
    #expect(fixture.model.showsUseDefaultFolder)
    #expect(fixture.model.folderMessage == nil)
  }

  @Test func aCancelledFolderPickChangesNothing() async throws {
    let fixture = try FolderFixture(picks: [nil])
    #expect(await fixture.model.addFolder() == nil)
    #expect(fixture.picker.calls == 1)
    #expect(fixture.host.appliedSettings.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fixture.model.settingsFile.path(percentEncoded: false)))
    #expect(fixture.model.settings.transcriptRoots == nil)
  }

  @Test func removingTheOnlyCustomFolderAppliesTheDefault() async throws {
    let fixture = try FolderFixture(
      picks: [], settings: Settings(transcriptRoots: ["/Users/someone/work/projects"]))
    #expect(await fixture.model.removeFolder("/Users/someone/work/projects") == .applied)
    #expect(fixture.host.appliedSettings.count == 1)
    #expect(fixture.host.appliedSettings.first?.transcriptRoots == nil)
    #expect(fixture.model.settings.transcriptRoots == nil)
    #expect(!fixture.model.showsUseDefaultFolder)
  }

  @Test func useDefaultFolderClearsTheCustomFoldersOnce() async throws {
    let fixture = try FolderFixture(
      picks: [], settings: Settings(transcriptRoots: ["/Users/someone/a", "/Users/someone/b"]))
    #expect(await fixture.model.useDefaultFolder() == .applied)
    #expect(fixture.host.appliedSettings.map(\.transcriptRoots) == [nil])
    #expect(await fixture.model.useDefaultFolder() == nil)
    #expect(fixture.host.appliedSettings.count == 1)
  }

  @Test func withNoCustomFoldersTheListShowsTheResolvedDefaultWithoutARemoveButton() throws {
    let fixture = try FolderFixture(picks: [])
    #expect(
      fixture.model.folderRows == [
        TranscriptFolderRow(
          path: "/Users/someone/.claude/projects", displayPath: "~/.claude/projects", isDefault: true)
      ])
    #expect(!fixture.model.showsUseDefaultFolder)
    #expect(DetectionPane.defaultFolderCaption == "Default folder.")
    #expect(
      DetectionPane.foldersCaption
        == "Overtime watches these folders for Claude transcripts. The default is ~/.claude/projects, plus the projects folder of CLAUDE_CONFIG_DIR when it is set. A running Claude Code session that sets its own CLAUDE_CONFIG_DIR is always watched too."
    )
  }

  @Test func theDefaultFoldersAreTheHomeFolderAndTheClaudeConfigDirFolder() throws {
    let folder = try TestFolder()
    let model = SettingsModel(
      settingsFile: folder.url.appendingPathComponent("settings.json"), host: FakeEngineHost(),
      environment: ["CLAUDE_CONFIG_DIR": "/Users/someone/claude-config"], homeDirectory: Self.testHome)
    #expect(model.folderRows.map(\.displayPath) == ["~/.claude/projects", "~/claude-config/projects"])
    #expect(model.folderRows.map(\.isDefault) == [true, true])
  }

  @Test func aLongFolderPathKeepsTheFullPathForHelpAndVoiceOver() throws {
    let long = "/Users/someone/Documents/Workspace/clients/a-very-long-client-name/transcripts/projects"
    let fixture = try FolderFixture(picks: [], settings: Settings(transcriptRoots: [long]))
    let row = try #require(fixture.model.folderRows.first)
    #expect(row.path == long)
    #expect(row.displayPath == "~/Documents/Workspace/clients/a-very-long-client-name/transcripts/projects")
    #expect(row.removeLabel == "Remove \(long)")
  }

  @Test func pickingAFolderAlreadyInTheListShowsTheLineAndAppliesNothing() async throws {
    let folder = try TestFolder()
    let fixture = try FolderFixture(
      picks: [folder.url], settings: Settings(transcriptRoots: [folder.path]))
    let result = await fixture.model.addFolder()
    #expect(result == .invalid(SettingsValidationError(message: "That folder is already in the list.")))
    #expect(fixture.model.folderMessage == "That folder is already in the list.")
    #expect(fixture.host.appliedSettings.isEmpty)
    fixture.model.select(.battery)
    #expect(fixture.model.folderMessage == nil)
  }

  @Test func theStuckSessionLimitShowsMinutesAndCommitsSeconds() async throws {
    let fixture = try Fixture()
    #expect(fixture.model.text(for: .stuckWindowMinutes) == "30")
    #expect(await fixture.model.commit(.stuckWindowMinutes, text: "45") == .applied)
    #expect(fixture.host.appliedSettings.map(\.stuckWindowSeconds) == [2700])
    #expect(fixture.fileSettings?.stuckWindowSeconds == 2700)
    #expect(fixture.model.text(for: .stuckWindowMinutes) == "45")
  }

  @Test func theTimingFieldsCommitTheirSecondsOnce() async throws {
    let fixture = try Fixture()
    #expect(fixture.model.text(for: .transcriptWindowSeconds) == "120")
    #expect(fixture.model.text(for: .releaseGraceSeconds) == "60")
    #expect(await fixture.model.commit(.transcriptWindowSeconds, text: "300") == .applied)
    #expect(await fixture.model.commit(.releaseGraceSeconds, text: "90") == .applied)
    #expect(fixture.host.appliedSettings.map(\.transcriptWindowSeconds) == [300, 300])
    #expect(fixture.host.appliedSettings.map(\.releaseGraceSeconds) == [60, 90])
  }

  @Test func theTimingSteppersMoveByTheUISpecSteps() async throws {
    #expect(SettingsModel.stepSize(for: .transcriptWindowSeconds) == 10)
    #expect(SettingsModel.stepSize(for: .releaseGraceSeconds) == 5)
    #expect(SettingsModel.stepSize(for: .stuckWindowMinutes) == 5)
    #expect(SettingsModel.stepSize(for: .batteryLowPercent) == 1)
    #expect(SettingsModel.stepSize(for: .batteryResumePercent) == 1)
    let fixture = try Fixture()
    let step = SettingsModel.stepSize(for: .stuckWindowMinutes)
    #expect(await fixture.model.step(.stuckWindowMinutes, by: step) == .applied)
    #expect(fixture.host.appliedSettings.map(\.stuckWindowSeconds) == [2100])
    #expect(fixture.model.text(for: .stuckWindowMinutes) == "35")
  }

  @Test func aTimingStepperNearItsBoundStopsAtTheBound() async throws {
    let fixture = try Fixture()
    #expect(await fixture.model.commit(.releaseGraceSeconds, text: "3598") == .applied)
    #expect(await fixture.model.step(.releaseGraceSeconds, by: 5) == .applied)
    #expect(fixture.model.settings.releaseGraceSeconds == 3600)
    #expect(await fixture.model.step(.releaseGraceSeconds, by: 5) == nil)
    #expect(fixture.host.appliedSettings.count == 2)
  }

  @Test func anEntrypointAddsOnReturnAndAppliesOnce() async throws {
    let fixture = try Fixture()
    fixture.model.setEntrypointDraft("claude-vscode")
    #expect(await fixture.model.addEntrypoint() == .applied)
    #expect(fixture.host.appliedSettings.map(\.ignoredEntrypoints) == [["sdk-*", "claude-vscode"]])
    #expect(fixture.fileSettings?.ignoredEntrypoints == ["sdk-*", "claude-vscode"])
    #expect(fixture.model.entrypointDraft == "")
    #expect(fixture.model.entrypointMessage == nil)
    #expect(fixture.model.showsRestoreDefaultEntrypoints)
  }

  @Test func aDuplicateEntrypointKeepsTheTextAndShowsTheLine() async throws {
    let fixture = try Fixture()
    fixture.model.setEntrypointDraft("sdk-*")
    #expect(
      await fixture.model.addEntrypoint()
        == .invalid(SettingsValidationError(message: "sdk-* is already in the list.")))
    #expect(fixture.model.entrypointMessage == "sdk-* is already in the list.")
    #expect(fixture.model.entrypointDraft == "sdk-*")
    #expect(fixture.host.appliedSettings.isEmpty)
    fixture.model.setEntrypointDraft("bad pattern!")
    await fixture.model.addEntrypoint()
    #expect(fixture.model.entrypointMessage == "Use only letters, digits, and - _ . * (up to 64 characters).")
    fixture.model.setEntrypointDraft("  ")
    await fixture.model.addEntrypoint()
    #expect(fixture.model.entrypointMessage == "Enter a pattern, such as sdk-*.")
    #expect(fixture.host.appliedSettings.isEmpty)
    fixture.model.select(.battery)
    #expect(fixture.model.entrypointMessage == nil)
    #expect(fixture.model.entrypointDraft == "")
  }

  @Test func removingTheLastEntrypointShowsTheEmptyStateAndRestoreDefault() async throws {
    let fixture = try Fixture()
    #expect(!fixture.model.showsNoIgnoredEntrypoints)
    #expect(!fixture.model.showsRestoreDefaultEntrypoints)
    #expect(await fixture.model.removeEntrypoint("sdk-*") == .applied)
    #expect(fixture.host.appliedSettings.map(\.ignoredEntrypoints) == [[]])
    #expect(fixture.model.showsNoIgnoredEntrypoints)
    #expect(fixture.model.showsRestoreDefaultEntrypoints)
    #expect(DetectionPane.noEntrypointsTitle == "No ignored entrypoints.")
    #expect(
      DetectionPane.noEntrypointsBody
        == "Every Claude transcript counts, including claude -p and Agent SDK automations.")
  }

  @Test func theIgnoredEntrypointsEmptyStateHasAHeadingAndASeparateBody() {
    #expect(DetectionPane.noEntrypoints.heading == "No ignored entrypoints.")
    #expect(
      DetectionPane.noEntrypoints.detail
        == "Every Claude transcript counts, including claude -p and Agent SDK automations.")
    #expect(!DetectionPane.noEntrypoints.heading.contains(DetectionPane.noEntrypoints.detail))
  }

  @Test func restoreDefaultBringsBackSdkAndAppliesOnce() async throws {
    let folder = try TestFolder()
    let file = folder.url.appendingPathComponent("settings.json")
    try SettingsStore.save(Settings(ignoredEntrypoints: ["sdk-*", "claude-vscode"]), to: file)
    let host = FakeEngineHost()
    let model = SettingsModel(settingsFile: file, host: host)
    #expect(model.showsRestoreDefaultEntrypoints)
    #expect(await model.restoreDefaultEntrypoints() == .applied)
    #expect(host.appliedSettings.map(\.ignoredEntrypoints) == [["sdk-*"]])
    #expect(!model.showsRestoreDefaultEntrypoints)
    #expect(await model.restoreDefaultEntrypoints() == nil)
    #expect(host.appliedSettings.count == 1)
  }

  @Test func theDetectionCopyMatchesTheUISpec() {
    #expect(
      DetectionPane.transcriptWindowCaption
        == "Claude counts as working if a transcript changed within this time.")
    #expect(
      DetectionPane.releaseGraceCaption
        == "How long Overtime waits after Claude goes quiet before letting the Mac sleep.")
    #expect(
      DetectionPane.stuckLimitCaption == "A terminal session with no transcript activity for this long is ignored.")
    #expect(
      DetectionPane.entrypointsCaption
        == "Transcripts whose entrypoint matches are not counted as Claude working. The default, sdk-*, ignores claude -p and Agent SDK automations."
    )
    #expect(DetectionPane.entrypointPlaceholder == "sdk-*")
  }

  @Test func choosingAutoDetectSavesAndAppliesTheFlagWithAnEmptyHotspot() async throws {
    let fixture = try NetworkFixture(networks: ["alpha"], settings: Settings(hotspot: "alpha"))
    await fixture.model.readKnownNetworks()
    #expect(fixture.model.hotspotChoice == .named("alpha"))
    let result = await fixture.model.selectHotspot(.autoDetect)
    #expect(result == .applied)
    #expect(fixture.host.appliedSettings.count == 1)
    #expect(fixture.host.appliedSettings.first?.hotspotAutoDetect == true)
    #expect(fixture.host.appliedSettings.first?.hotspot == "")
    #expect(fixture.fileSettings?.hotspotAutoDetect == true)
    #expect(fixture.fileSettings?.hotspot == "")
    #expect(fixture.model.hotspotChoice == .autoDetect)
  }

  @Test func choosingANamedNetworkThenNoneSavesEachEncoding() async throws {
    let fixture = try NetworkFixture(networks: ["Ivan’s iPhone"], settings: Settings(hotspotAutoDetect: true))
    await fixture.model.readKnownNetworks()
    #expect(await fixture.model.selectHotspot(.named("Ivan’s iPhone")) == .applied)
    #expect(fixture.fileSettings?.hotspot == "Ivan’s iPhone")
    #expect(fixture.fileSettings?.hotspotAutoDetect == false)
    #expect(await fixture.model.selectHotspot(.none) == .applied)
    #expect(fixture.fileSettings?.hotspot == "")
    #expect(fixture.fileSettings?.hotspotAutoDetect == false)
    #expect(fixture.host.appliedSettings.count == 2)
  }

  @Test func choosingTheCurrentHotspotSavesAndAppliesNothing() async throws {
    let fixture = try NetworkFixture(networks: [], settings: Settings(hotspotAutoDetect: true))
    #expect(await fixture.model.selectHotspot(.autoDetect) == nil)
    #expect(fixture.host.appliedSettings.isEmpty)
  }

  @Test func withoutARunningEngineAHotspotChoiceIsNotSaved() async throws {
    let folder = try TestFolder()
    let model = SettingsModel(
      settingsFile: folder.url.appendingPathComponent("settings.json"), wifi: FakeWiFi(networks: []))
    #expect(await model.selectHotspot(.autoDetect) == nil)
    #expect(!FileManager.default.fileExists(atPath: model.settingsFile.path(percentEncoded: false)))
  }

  @Test func knownNetworksAreReadOnceWhenThePaneAppearsAndNeverOnATimer() async throws {
    let fixture = try NetworkFixture(networks: ["gamma", "Beta", "alpha"])
    #expect(fixture.wifi.readCount == 0)
    #expect(!fixture.model.knownNetworksRead)
    await fixture.model.readKnownNetworks()
    #expect(fixture.wifi.readCount == 1)
    try await Task.sleep(for: .milliseconds(300))
    #expect(fixture.wifi.readCount == 1)
    #expect(
      fixture.model.hotspotEntries == [
        .choice(.none), .choice(.autoDetect), .divider, .choice(.named("alpha")), .choice(.named("Beta")),
        .choice(.named("gamma")),
      ])
    #expect(fixture.model.hotspotCaption == nil)
  }

  @Test func theNetworkPaneCaptionDescribesWhatFailoverDoesNow() {
    #expect(
      HotspotPicker.sectionCaption
        == "If the network stops working while the lid is closed and Claude is working, Overtime switches the Mac to this hotspot, and back to your usual network when you open the lid."
    )
    #expect(!HotspotPicker.sectionCaption.contains("later version"))
  }

  @Test func aKnownNetworkNameThatFailsTheSSIDRuleIsNeverOfferedInThePicker() async throws {
    let invalid = ["Bell\u{0007}phone", String(repeating: "a", count: 33), ""]
    let fixture = try NetworkFixture(networks: ["gamma"] + invalid + ["alpha"])
    await fixture.model.readKnownNetworks()
    #expect(fixture.model.knownNetworks == ["alpha", "gamma"])
    #expect(
      fixture.model.hotspotEntries == [
        .choice(.none), .choice(.autoDetect), .divider, .choice(.named("alpha")), .choice(.named("gamma")),
      ])
    #expect(fixture.model.hotspotCaption == nil)
  }

  final class HangingWiFi: WiFiInfoPort {
    private let reads = OSAllocatedUnfairLock(initialState: (started: 0, ended: 0))
    private let gate = DispatchSemaphore(value: 0)

    var readCount: Int {
      reads.withLock { $0.started }
    }

    var readsEnded: Int {
      reads.withLock { $0.ended }
    }

    func interfaceName() -> String? {
      "en0"
    }

    func knownNetworkNames() -> [String]? {
      reads.withLock { $0.started += 1 }
      _ = gate.wait(timeout: .now() + 10)
      reads.withLock { $0.ended += 1 }
      return ["Lorem Net"]
    }

    func release() {
      for _ in 0..<4 { gate.signal() }
    }
  }

  static let boundedNetworks: Comment =
    "A-WR-05: the CoreWLAN known-networks read is bounded at 5 s on a thread of its own, and a hung read is not stacked by the next visit"

  @Test func aKnownNetworksReadThatHangsEndsAtItsBoundAndTheNextVisitDoesNotStackAnother() async throws {
    let folder = try TestFolder()
    let wifi = HangingWiFi()
    defer { wifi.release() }
    let model = SettingsModel(settingsFile: folder.url.appendingPathComponent("settings.json"), wifi: wifi)
    model.knownNetworksTimeoutSeconds = 0.2
    await model.readKnownNetworks()
    #expect(wifi.readsEnded == 0, Self.boundedNetworks)
    #expect(model.knownNetworksRead)
    #expect(model.knownNetworks == nil)
    #expect(model.hotspotCaption == "Couldn't read your known Wi-Fi networks.")
    await model.readKnownNetworks()
    #expect(wifi.readsEnded == 0, Self.boundedNetworks)
    #expect(wifi.readCount == 1, Self.boundedNetworks)
  }

  @Test func theKnownNetworksBoundIsTheProjectsSystemCallBound() throws {
    let folder = try TestFolder()
    let model = SettingsModel(settingsFile: folder.url.appendingPathComponent("settings.json"))
    #expect(model.knownNetworksTimeoutSeconds == Timing.systemCallTimeoutSeconds)
  }

  @Test func unreadableKnownNetworksShowTheCaptionAndOnlyTwoChoices() async throws {
    let fixture = try NetworkFixture(networks: nil)
    #expect(fixture.model.hotspotCaption == nil)
    await fixture.model.readKnownNetworks()
    #expect(fixture.model.hotspotEntries == [.choice(.none), .choice(.autoDetect)])
    #expect(fixture.model.hotspotCaption == "Couldn't read your known Wi-Fi networks.")
  }

  @Test func aStoredNameThatIsNoLongerKnownStaysSelectable() async throws {
    let fixture = try NetworkFixture(networks: ["alpha"], settings: Settings(hotspot: "Old phone"))
    await fixture.model.readKnownNetworks()
    #expect(fixture.model.hotspotChoice == .unknown("Old phone"))
    #expect(fixture.model.hotspotChoice.label == "Old phone (not in known networks)")
    #expect(fixture.model.hotspotEntries.last == .choice(.unknown("Old phone")))
  }

  @Test func beforeTheReadAStoredNameIsNotLabelledUnknown() throws {
    let fixture = try NetworkFixture(networks: ["alpha"], settings: Settings(hotspot: "Old phone"))
    #expect(fixture.model.hotspotChoice == .named("Old phone"))
    #expect(fixture.wifi.readCount == 0)
  }

  @Test func withTheHotspotChoiceNoneTheLocationRowIsAbsent() throws {
    let fixture = try GeneralFixture(location: .notDetermined)
    fixture.model.refreshLocationStatus()
    #expect(fixture.model.hotspotChoice == .none)
    #expect(fixture.model.locationRow == nil)
    #expect(fixture.location.requests == 0)
  }

  @Test func withAHotspotChosenTheNotDeterminedRowOffersAllowLocationAccess() throws {
    let fixture = try GeneralFixture(settings: Settings(hotspotAutoDetect: true), location: .notDetermined)
    fixture.model.refreshLocationStatus()
    let row = try #require(fixture.model.locationRow)
    #expect(row.title == "Location access lets Overtime join your iPhone hotspot directly.")
    #expect(row.actionLabel == "Allow Location Access")
  }

  @Test func pressingAllowLocationAccessRequestsExactlyOnce() throws {
    let fixture = try GeneralFixture(settings: Settings(hotspotAutoDetect: true), location: .notDetermined)
    fixture.model.refreshLocationStatus()
    fixture.model.allowLocationAccess()
    #expect(fixture.location.requests == 1)
  }

  @Test func readingTheLocationStatusNeverRequests() throws {
    let fixture = try GeneralFixture(settings: Settings(hotspot: "alpha"), location: .notDetermined)
    fixture.model.refreshLocationStatus()
    fixture.model.refreshLocationStatus()
    fixture.model.open(pane: .network)
    #expect(fixture.location.statusReads >= 2)
    #expect(fixture.location.requests == 0)
  }

  @Test func aStatusChangeReachesTheRow() throws {
    let fixture = try GeneralFixture(settings: Settings(hotspotAutoDetect: true), location: .notDetermined)
    fixture.model.refreshLocationStatus()
    fixture.location.current = .authorized
    fixture.model.refreshLocationStatus()
    #expect(fixture.model.locationRow?.title == "Location access is on.")
    #expect(fixture.model.locationRow?.action == nil)
    fixture.location.current = .denied
    fixture.model.refreshLocationStatus()
    #expect(fixture.model.locationRow?.actionLabel == "Open Location Services")
  }

  @Test func openLocationServicesOpensThePinnedLinkAndRequestsNothing() throws {
    let fixture = try GeneralFixture(settings: Settings(hotspotAutoDetect: true), location: .denied)
    fixture.model.refreshLocationStatus()
    fixture.model.openLocationServices()
    #expect(fixture.opened.urls == [SystemSettingsLinks.locationServices])
    #expect(fixture.location.requests == 0)
  }

  @Test func choosingAHotspotShowsTheLocationRowAndNoneHidesIt() async throws {
    let fixture = try GeneralFixture(location: .denied)
    fixture.model.refreshLocationStatus()
    #expect(fixture.model.locationRow == nil)
    #expect(await fixture.model.selectHotspot(.autoDetect) == .applied)
    #expect(fixture.model.locationRow?.title == "Location access is off for Overtime.")
    #expect(await fixture.model.selectHotspot(.none) == .applied)
    #expect(fixture.model.locationRow == nil)
    #expect(fixture.location.requests == 0)
  }

  @Test func keepDisplayOnIsOffByDefaultAndItsSwitchApplies() async throws {
    let fixture = try GeneralFixture()
    #expect(!fixture.model.keepDisplayOn)
    #expect(await fixture.model.setKeepDisplayOn(true) == .applied)
    #expect(fixture.host.appliedSettings.map(\.keepDisplayOn) == [true])
    #expect(fixture.fileSettings?.keepDisplayOn == true)
    #expect(fixture.model.keepDisplayOn)
    #expect(await fixture.model.setKeepDisplayOn(true) == nil)
    #expect(fixture.host.appliedSettings.count == 1)
  }

  @Test func launchAtLoginReadsAndWritesThePanelLoginItemState() throws {
    let fixture = try GeneralFixture()
    #expect(!fixture.model.canChangeLaunchAtLogin)
    let service = PanelModelTests.FakeLoginItem(status: .enabled)
    fixture.panel.attachLoginItem(service)
    #expect(fixture.model.canChangeLaunchAtLogin)
    #expect(fixture.model.launchAtLogin == fixture.panel.launchAtLogin)
    #expect(fixture.model.launchAtLogin)
    fixture.model.setLaunchAtLogin(false)
    #expect(service.calls == ["unregister"])
    #expect(!fixture.panel.launchAtLogin)
    #expect(!fixture.model.launchAtLogin)
  }

  @Test func launchAtLoginShowsThePanelCaptionAndOpensLoginItems() throws {
    let fixture = try GeneralFixture()
    let service = PanelModelTests.FakeLoginItem(status: .requiresApproval)
    fixture.panel.attachLoginItem(service)
    #expect(fixture.model.loginItemCaption == fixture.panel.loginItemCaption)
    #expect(
      fixture.model.loginItemCaption?.text == "Needs your approval in System Settings > General > Login Items.")
    fixture.model.openLoginItems()
    #expect(service.calls == ["openSystemSettings"])
  }

  @Test func theSettingsLoginRowIsTheSharedLoginSectionWithTheSettingsInputs() throws {
    let fixture = try GeneralFixture()
    let detached = LoginItemSection(model: fixture.model)
    #expect(!detached.canToggle)
    #expect(detached.caption == nil)
    #expect(!detached.isOn)
    let service = PanelModelTests.FakeLoginItem(status: .requiresApproval)
    fixture.panel.attachLoginItem(service)
    let section = LoginItemSection(model: fixture.model)
    #expect(section.canToggle)
    #expect(section.caption == fixture.panel.loginItemCaption)
    #expect(section.caption?.text == "Needs your approval in System Settings > General > Login Items.")
    #expect(section.isOn == fixture.panel.launchAtLogin)
    section.openLoginItems()
    #expect(service.calls == ["openSystemSettings"])
  }

  @Test func thePanelLoginSectionKeepsItsSwitchEnabled() throws {
    let fixture = try GeneralFixture()
    let service = PanelModelTests.FakeLoginItem(status: .enabled)
    fixture.panel.attachLoginItem(service)
    let section = LoginItemSection(model: fixture.panel)
    #expect(section.canToggle)
    #expect(section.isOn)
    section.setLaunchAtLogin(false)
    #expect(service.calls == ["unregister"])
  }

  @Test func openingSettingsRefreshesTheLoginItemStatus() throws {
    let fixture = try GeneralFixture()
    let service = PanelModelTests.FakeLoginItem(status: .enabled)
    fixture.panel.attachLoginItem(service)
    service.status = .notRegistered
    fixture.model.open(pane: .general)
    #expect(!fixture.model.launchAtLogin)
  }

  @Test func theGeneralCopyMatchesTheUISpec() {
    #expect(GeneralPane.startupTitle == "Startup")
    #expect(GeneralPane.displayTitle == "Display")
    #expect(GeneralPane.keepDisplayOnLabel == "Keep display on while Claude works")
    #expect(
      GeneralPane.keepDisplayOnCaption
        == "With the lid closed and no external display, the display still turns off so the screen locks.")
  }

  @Test func withNoWarningsDetectionHealthShowsTheGreenEmptyRow() async throws {
    let fixture = try DiagnosticsFixture()
    #expect(await fixture.publish([]))
    #expect(fixture.model.detectionHealthRows.isEmpty)
    #expect(DiagnosticsPane.noProblemsTitle == "No detection problems found.")
    #expect(DiagnosticsPane.noProblemsSymbol == "checkmark.circle.fill")
    #expect(DiagnosticsPane.detectionHealthTitle == "Detection health")
  }

  @Test func withoutASnapshotDetectionHealthIsEmpty() throws {
    let fixture = try Fixture()
    #expect(fixture.model.detectionWarnings.isEmpty)
    #expect(fixture.model.detectionHealthRows.isEmpty)
  }

  @Test func eachScriptedWarningBecomesOneDiagnosticsRowWithTheUISpecCopy() async throws {
    let fixture = try DiagnosticsFixture()
    #expect(
      await fixture.publish([.rootMissing(Self.defaultRoot), .rootUnreadable(Self.workRoot), .terminalSilence]))
    let rows = fixture.model.detectionHealthRows
    #expect(
      rows.map(\.title) == [
        "Transcript folder not found: ~/.claude/projects",
        "Can't read the transcript folder /Volumes/Work/claude projects",
        "Claude has run in a terminal for 10 minutes with no transcript activity.",
      ])
    #expect(
      rows.map(\.caption) == [
        "Overtime can't see Claude activity there.",
        "Check the folder's permissions, or remove it from the list.",
        "Claude Code may have moved its transcripts. Check the transcript folders, or export diagnostics and report it.",
      ])
    #expect(rows.map(\.fullPath) == [Self.defaultRoot, Self.workRoot, nil])
    #expect(rows.map(\.symbol) == Array(repeating: "exclamationmark.triangle.fill", count: 3))
    #expect(rows.map(\.actionTitle) == Array(repeating: "Open Detection Settings", count: 3))
    #expect(Set(rows.map(\.id)).count == 3)
  }

  @Test func aLongFlaggedPathIsHomeAbbreviatedAndKeepsTheFullPathForHelp() async throws {
    let long = "/Users/someone/Documents/Workspace/clients/a-very-long-client-name/transcripts/projects"
    let fixture = try DiagnosticsFixture()
    #expect(await fixture.publish([.rootMissing(long)]))
    let row = try #require(fixture.model.detectionHealthRows.first)
    #expect(
      row.title
        == "Transcript folder not found: ~/Documents/Workspace/clients/a-very-long-client-name/transcripts/projects")
    #expect(row.fullPath == long)
  }

  @Test func aFlaggedFolderRowKeepsItsSentenceWholeAndTruncatesOnlyThePath() async throws {
    let fixture = try DiagnosticsFixture()
    #expect(
      await fixture.publish([.rootMissing(Self.defaultRoot), .rootUnreadable(Self.workRoot), .terminalSilence]))
    let rows = fixture.model.detectionHealthRows
    #expect(
      rows.map(\.titlePrefix) == [
        "Transcript folder not found:",
        "Can't read the transcript folder",
        "Claude has run in a terminal for 10 minutes with no transcript activity.",
      ])
    #expect(rows.map(\.displayPath) == ["~/.claude/projects", "/Volumes/Work/claude projects", nil])
    #expect(
      rows.map(\.title) == [
        "Transcript folder not found: ~/.claude/projects",
        "Can't read the transcript folder /Volumes/Work/claude projects",
        "Claude has run in a terminal for 10 minutes with no transcript activity.",
      ])
  }

  @Test func openDetectionSettingsSelectsTheDetectionPane() throws {
    let fixture = try Fixture()
    let controller = SettingsWindow.controller(model: fixture.model)
    fixture.model.select(.diagnostics)
    #expect(controller.title == "Diagnostics")
    fixture.model.openDetectionSettings()
    #expect(fixture.model.selectedPane == .detection)
    #expect(controller.title == "Detection")
    #expect(controller.window == nil)
  }

  @Test func aFlaggedFolderShowsTheOrangeWarningWithItsHelpText() async throws {
    let other = "/Users/someone/other"
    let fixture = try DiagnosticsFixture(
      settings: Settings(transcriptRoots: [Self.defaultRoot, Self.workRoot, other]))
    #expect(fixture.model.folderRows.map(\.warning) == [nil, nil, nil])
    #expect(await fixture.publish([.rootMissing(Self.defaultRoot), .rootUnreadable(Self.workRoot), .terminalSilence]))
    #expect(
      fixture.model.folderRows.map(\.warning) == [
        "This folder wasn't found. Overtime can't see Claude activity there.",
        "Overtime can't read this folder. Check the folder's permissions, or remove it from the list.",
        nil,
      ])
    #expect(DetectionPane.folderWarningSymbol == "exclamationmark.triangle.fill")
  }

  @Test func theFlaggedDefaultFolderShowsTheWarning() async throws {
    let fixture = try DiagnosticsFixture()
    #expect(await fixture.publish([.rootMissing(Self.defaultRoot)]))
    let row = try #require(fixture.model.folderRows.first)
    #expect(row.isDefault)
    #expect(row.warning == DetectionPane.folderMissingHelp)
  }

  @Test func aClearedWarningRemovesTheRowAndTheFolderIcon() async throws {
    let fixture = try DiagnosticsFixture(settings: Settings(transcriptRoots: [Self.workRoot]))
    #expect(await fixture.publish([.rootUnreadable(Self.workRoot)]))
    #expect(fixture.model.detectionHealthRows.count == 1)
    #expect(fixture.model.folderRows.first?.warning == DetectionPane.folderUnreadableHelp)
    #expect(await fixture.publish([]))
    #expect(fixture.model.detectionHealthRows.isEmpty)
    #expect(fixture.model.folderRows.first?.warning == nil)
  }

  @Test func withNoSelfTestResultTheRowReadsNotRunYet() async throws {
    let bare = try Fixture()
    let notRun = SelfTestRow(
      icon: .symbol("circle"), tone: .secondary, title: "Not run yet",
      caption: "It runs at launch once the lid is open and Claude isn't working.")
    #expect(bare.model.selfTestRow == notRun)
    #expect(!bare.model.canRunSelfTest)
    let fixture = try DiagnosticsFixture()
    #expect(await fixture.publish([]))
    #expect(fixture.model.selfTestRow == notRun)
    #expect(SelfTestPresentation.sectionTitle == "Self-test")
    #expect(SelfTestPresentation.runButtonTitle == "Run Self-Test")
  }

  @Test func runSelfTestAsksTheEngineExactlyOnce() async throws {
    let fixture = try DiagnosticsFixture()
    #expect(await fixture.publish(Self.idleLidOpen()))
    #expect(fixture.model.canRunSelfTest)
    #expect(fixture.model.selfTestHelp == nil)
    await fixture.model.runSelfTest()
    #expect(fixture.host.selfTestRequests == 1)
    #expect(fixture.host.requests.isEmpty)
    #expect(fixture.host.appliedSettings.isEmpty)
  }

  @Test func aPassedSnapshotShowsThePassedRow() async throws {
    let fixture = try DiagnosticsFixture()
    fixture.host.publish(
      EngineSnapshot(
        wanted: false, reason: "idle", lidClosed: false, selfTest: .passed, selfTestRuns: 1, osBuild: "26A428"))
    #expect(await waitUntil { fixture.model.selfTestStatus == .passed })
    #expect(
      fixture.model.selfTestRow
        == SelfTestRow(icon: .symbol("checkmark.circle.fill"), tone: .success, title: "Passed", caption: nil))
    #expect(fixture.model.canRunSelfTest)
    #expect(fixture.host.selfTestRequests == 0)
  }

  @Test func aPassedSnapshotWithAStoredRecordShowsItsLastRunLine() async throws {
    let fixture = try DiagnosticsFixture()
    let ranAt = Date(timeIntervalSince1970: 1_790_505_720)
    var stored = AppPreferences()
    stored.selfTest = SelfTestRecord(outcome: .passed, reason: nil, at: ranAt, osBuild: "26A428", osVersion: "27.0")
    try AppPreferencesStore.write(stored, to: fixture.model.preferencesFile)
    fixture.model.reloadPreferences()
    fixture.host.publish(EngineSnapshot(wanted: false, reason: "idle", selfTest: .passed, osBuild: "26A428"))
    #expect(await waitUntil { fixture.model.selfTestStatus == .passed })
    #expect(
      fixture.model.selfTestRow.caption
        == "Last run \(UIDateText.string(ranAt)) on macOS 27.0 (26A428).")
  }

  @Test func whileATestRunsTheRowShowsProgressAndTheButtonAsksNothing() async throws {
    let fixture = try DiagnosticsFixture()
    #expect(await fixture.publish(Self.idleLidOpen(.running, runs: 1)))
    #expect(fixture.model.selfTestRow == SelfTestRow(icon: .progress, tone: .secondary, title: "Running…"))
    #expect(!fixture.model.canRunSelfTest)
    #expect(fixture.model.selfTestHelp == "Available when the current test finishes.")
    await fixture.model.runSelfTest()
    #expect(fixture.host.selfTestRequests == 0)
  }

  @Test func aWaitingSnapshotWithTheLidClosedShowsWaitingToRunAndTurnsTheButtonOff() async throws {
    let fixture = try DiagnosticsFixture()
    fixture.host.publish(EngineSnapshot(wanted: false, reason: "idle", lidClosed: true, selfTest: .waiting))
    #expect(await waitUntil { fixture.model.selfTestStatus == .waiting })
    #expect(fixture.model.selfTestRow.title == "Waiting to run")
    #expect(fixture.model.selfTestRow.icon == .symbol("clock"))
    #expect(fixture.model.selfTestRow.caption == "It runs when the lid is open and Claude isn't working.")
    #expect(!fixture.model.canRunSelfTest)
    #expect(fixture.model.selfTestHelp == "Available when the lid is open.")
    await fixture.model.runSelfTest()
    #expect(fixture.host.selfTestRequests == 0)
  }

  static func idleLidOpen(
    _ status: SelfTestStatus = .notRun, runs: UInt64 = 0, wanted: Bool? = false, lidClosed: Bool? = false,
    osBuild: String? = nil
  ) -> EngineSnapshot {
    EngineSnapshot(
      busy: wanted == true, wanted: wanted, reason: wanted == true ? "busy" : "idle", lidClosed: lidClosed,
      selfTest: status, selfTestRuns: runs, osBuild: osBuild)
  }

  static let storedRunAt = Date(timeIntervalSince1970: 1_790_505_720)

  static func storedPass(in fixture: DiagnosticsFixture) throws -> String {
    var stored = AppPreferences()
    stored.selfTest = SelfTestRecord(
      outcome: .passed, reason: nil, at: storedRunAt, osBuild: "26A428", osVersion: "27.0")
    try AppPreferencesStore.write(stored, to: fixture.model.preferencesFile)
    fixture.model.reloadPreferences()
    return "Last run \(UIDateText.string(storedRunAt)) on macOS 27.0 (26A428)."
  }

  @Test func theStoredRecordShowsItsPassedCaptionBeforeThisLaunchsTestFinishes() async throws {
    let fixture = try DiagnosticsFixture()
    let lastRun = try Self.storedPass(in: fixture)
    let passed = SelfTestRow(icon: .symbol("checkmark.circle.fill"), tone: .success, title: "Passed", caption: lastRun)
    #expect(fixture.model.selfTestRow == passed)
    #expect(await fixture.publish(Self.idleLidOpen()))
    #expect(fixture.model.selfTestStatus == .notRun)
    #expect(fixture.model.selfTestRow == passed)
    #expect(await fixture.publish(Self.idleLidOpen(.waiting, lidClosed: true, osBuild: "26A428")))
    #expect(fixture.model.selfTestRow.title == "Waiting to run")
    #expect(fixture.model.selfTestRow.caption == "It runs when the lid is open and Claude isn't working.")
    #expect(await fixture.publish(Self.idleLidOpen(.running, runs: 1, osBuild: "26A428")))
    #expect(fixture.model.selfTestRow == SelfTestRow(icon: .progress, tone: .secondary, title: "Running…"))
  }

  @Test func aBuildChangeSinceTheStoredRunShowsInTheWaitingCaption() async throws {
    let fixture = try DiagnosticsFixture()
    _ = try Self.storedPass(in: fixture)
    #expect(await fixture.publish(Self.idleLidOpen(.waiting, lidClosed: true, osBuild: "26A430")))
    #expect(fixture.model.selfTestRow.title == "Waiting to run")
    #expect(
      fixture.model.selfTestRow.caption
        == "macOS changed to 26A430. The test runs again when the lid is open and Claude isn't working.")
  }

  @Test func theButtonIsOffWithItsHelpWhileOvertimeKeepsTheMacAwake() async throws {
    let fixture = try DiagnosticsFixture()
    #expect(await fixture.publish(Self.idleLidOpen(wanted: true)))
    #expect(!fixture.model.canRunSelfTest)
    #expect(fixture.model.selfTestHelp == "Available when Overtime isn't keeping the Mac awake.")
    await fixture.model.runSelfTest()
    #expect(fixture.host.selfTestRequests == 0)
    #expect(await fixture.publish(Self.idleLidOpen(lidClosed: nil)))
    #expect(!fixture.model.canRunSelfTest)
    #expect(fixture.model.selfTestHelp == "Available when the lid is open.")
    #expect(await fixture.publish(Self.idleLidOpen()))
    #expect(fixture.model.canRunSelfTest)
    #expect(fixture.model.selfTestHelp == nil)
    await fixture.model.runSelfTest()
    #expect(fixture.host.selfTestRequests == 1)
  }

  @Test func theStatusChangeAnnouncementFollowsTheSnapshot() async throws {
    let fixture = try DiagnosticsFixture()
    #expect(fixture.model.selfTestAnnouncement == nil)
    #expect(await fixture.publish(Self.idleLidOpen(.running, runs: 1)))
    #expect(fixture.model.selfTestAnnouncement == nil)
    #expect(await fixture.publish(Self.idleLidOpen(.passed, runs: 1)))
    #expect(fixture.model.selfTestAnnouncement == "Self-test passed.")
    #expect(await fixture.publish(Self.idleLidOpen(.failed(.timedOut), runs: 2)))
    #expect(fixture.model.selfTestAnnouncement == "Self-test failed")
    #expect(await fixture.publish(Self.idleLidOpen(.skipped(.sleepDisabled), runs: 2)))
    #expect(fixture.model.selfTestAnnouncement == "Self-test skipped.")
  }

  @Test func theLaunchSelfTestIsRequestedOnceAndItsResultReachesTheDiagnosticsRow() async throws {
    let fixture = try DiagnosticsFixture()
    fixture.model.setNotification(.batteryFloor, enabled: false)
    let clock = TestClock(wall: Self.storedRunAt)
    let engine = FakeEngineHost(clock: clock)
    let model = fixture.model
    let recorder = SelfTestRecorder(
      preferencesFile: model.preferencesFile, osVersion: { "99.9" }, log: { _ in },
      onRecord: { _ in Task { @MainActor in model.reloadPreferences() } })
    defer { recorder.stop() }
    await AppDelegate.beginLaunchSelfTest(on: engine, recorder: recorder)
    #expect(engine.selfTestRequests == 1)
    #expect(engine.requests.isEmpty)
    #expect(fixture.host.selfTestRequests == 0)
    #expect(recorder.isRunning)
    let passed = Self.idleLidOpen(.passed, runs: 1, osBuild: "99Z999")
    engine.publish(passed)
    #expect(await fixture.publish(passed))
    let lastRun = "Last run \(UIDateText.string(Self.storedRunAt)) on macOS 99.9 (99Z999)."
    #expect(await waitUntil { fixture.model.selfTestRow.caption == lastRun })
    #expect(
      fixture.model.selfTestRow
        == SelfTestRow(icon: .symbol("checkmark.circle.fill"), tone: .success, title: "Passed", caption: lastRun))
    let stored = AppPreferencesStore.read(at: model.preferencesFile).preferences
    #expect(
      stored.selfTest
        == SelfTestRecord(outcome: .passed, reason: nil, at: Self.storedRunAt, osBuild: "99Z999", osVersion: "99.9"))
    #expect(stored.notifications["batteryFloor"] == false)
    #expect(engine.selfTestRequests == 1)
  }

  static let restartedSelfTest: Comment =
    "A-WR-03: the self-test is requested again on every engine the app binds after a restart, and the recorder follows it"

  @Test func aRestartedEngineIsAskedForTheSelfTestAgainAndTheRecorderFollowsIt() async throws {
    let folder = try TestFolder()
    let clock = TestClock(wall: Self.storedRunAt)
    let first = FakeEngineHost(clock: clock)
    let second = FakeEngineHost(clock: clock)
    let recorder = SelfTestRecorder(
      preferencesFile: folder.url.appendingPathComponent("preferences.json"), osVersion: { "99.9" }, log: { _ in })
    defer { recorder.stop() }
    await AppDelegate.beginLaunchSelfTest(on: first, recorder: recorder)
    #expect(first.selfTestRequests == 1)
    await AppDelegate.bindRestarted(second, notifications: nil, recorder: recorder, helper: nil)?.value
    #expect(second.selfTestRequests == 1, Self.restartedSelfTest)
    #expect(first.selfTestRequests == 1)
    #expect(recorder.isRunning)
    #expect(second.requests.isEmpty)
  }

  @Test func withoutARecorderARestartedEngineIsNotAskedForASelfTest() async {
    let host = FakeEngineHost(clock: TestClock())
    #expect(AppDelegate.bindRestarted(host, notifications: nil, recorder: nil, helper: nil) == nil)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(host.selfTestRequests == 0)
  }

  @Test func aFailedSnapshotShowsTheRedRowWithItsReason() async throws {
    let fixture = try DiagnosticsFixture()
    let refusal = Int32(bitPattern: 0xE000_02C2)
    fixture.host.publish(
      EngineSnapshot(
        wanted: false, reason: "idle", lidClosed: false, selfTest: .failed(.clamshellRefused(refusal)),
        selfTestErrorActive: true, selfTestFailures: 1, selfTestRuns: 1))
    #expect(await waitUntil { fixture.model.selfTestStatus == .failed(.clamshellRefused(refusal)) })
    #expect(
      fixture.model.selfTestRow
        == SelfTestRow(
          icon: .symbol("xmark.circle.fill"), tone: .error, title: "Failed",
          caption: "macOS refused the lid-close control (error 0xE00002C2)."))
    #expect(fixture.model.canRunSelfTest)
  }

  @Test func aSkippedSnapshotShowsTheOrangeRowNamingTheOtherApp() async throws {
    let fixture = try DiagnosticsFixture()
    fixture.host.publish(
      EngineSnapshot(wanted: false, reason: "idle", lidClosed: false, selfTest: .skipped(.otherTool("Keeper"))))
    #expect(await waitUntil { fixture.model.selfTestStatus == .skipped(.otherTool("Keeper")) })
    #expect(
      fixture.model.selfTestRow
        == SelfTestRow(
          icon: .symbol("minus.circle.fill"), tone: .warning, title: "Skipped",
          caption: "Keeper is managing sleep, so Overtime didn't touch it."))
    #expect(fixture.model.canRunSelfTest)
  }

  @Test func withoutARunningEngineRunSelfTestIsOff() async throws {
    let folder = try TestFolder()
    let model = SettingsModel(settingsFile: folder.url.appendingPathComponent("settings.json"))
    #expect(!model.canRunSelfTest)
    #expect(model.selfTestHelp == nil)
    await model.runSelfTest()
    #expect(model.selfTestRow.title == "Not run yet")
  }

  @Test func theSelfTestIconColoursFollowTheUISpec() {
    #expect(SelfTestRowView.tint(for: .secondary) == .secondary)
    #expect(SelfTestRowView.tint(for: .success) == .green)
    #expect(SelfTestRowView.tint(for: .warning) == .orange)
    #expect(SelfTestRowView.tint(for: .error) == .red)
  }

  @Test func theSelfTestRowFoldsIntoTheSharedStatusRowIcon() {
    let running = SelfTestRow(icon: .progress, tone: .secondary, title: "Running…")
    #expect(SelfTestRowView.statusIcon(for: running) == .progress)
    let symbols: [(String, SelfTestRow.Tone, Color)] = [
      ("checkmark.circle.fill", .success, .green),
      ("xmark.circle.fill", .error, .red),
      ("minus.circle.fill", .warning, .orange),
      ("circle", .secondary, .secondary),
    ]
    for (name, tone, color) in symbols {
      let row = SelfTestRow(icon: .symbol(name), tone: tone, title: "Title")
      #expect(SelfTestRowView.statusIcon(for: row) == .symbol(name, color))
    }
  }

  @Test func theStatusRowTextInsetIsTheIconColumnPlusItsGap() {
    #expect(StatusRowLayout.iconWidth == 24)
    #expect(StatusRowLayout.iconGap == 4)
    #expect(StatusRowLayout.textInset == 28)
    #expect(StatusRowLayout.textInset == StatusRowLayout.iconWidth + StatusRowLayout.iconGap)
  }

  @Test func thePaneIsPinnedTo500PointsBesideA200PointSidebarColumn() {
    #expect(SettingsWindow.paneWidth == 500)
    #expect(SettingsWindow.sidebarWidth == 199)
    #expect(SettingsWindow.dividerWidth == 1)
    #expect(SettingsWindow.sidebarWidth + SettingsWindow.dividerWidth == 200)
    #expect(
      SettingsWindow.sidebarWidth + SettingsWindow.dividerWidth + SettingsWindow.paneWidth
        == SettingsWindow.contentSize.width)
    #expect(SettingsWindow.contentSize.width == 700)
    #expect(SettingsWindow.contentSize.height == 520)
  }

  @Test func everyTileColourIsASystemColour() {
    let colours: [(PaneTileColor, NSColor)] = [
      (.gray, .systemGray), (.purple, .systemPurple), (.green, .systemGreen), (.blue, .systemBlue),
      (.orange, .systemOrange), (.red, .systemRed),
    ]
    #expect(colours.map { $0.0 } == PaneTileColor.allCases)
    for (tileColour, systemColour) in colours {
      #expect(tileColour.nsColor == systemColour, "\(tileColour)")
    }
    #expect(
      SettingsPane.allCases.map { $0.tileColor.nsColor } == [
        .systemGray, .systemPurple, .systemGreen, .systemBlue, .systemOrange, .systemRed, .systemGray,
      ])
  }

  @Test func theHeaderInsetsAreTheContractOnes() {
    #expect(SettingsPaneHeader.horizontalInset == 20)
    #expect(SettingsPaneHeader.topInset == 16)
  }

  @Test func theHeaderCardHugsItsTileConcentrically() {
    let tilePadding = CGFloat(CornerGeometry.paneHeaderTilePadding)
    let padding = SettingsPaneHeader.cardPadding
    #expect(tilePadding == 4)
    #expect(padding.top == tilePadding)
    #expect(padding.leading == tilePadding)
    #expect(padding.bottom == tilePadding)
    #expect(padding.trailing == CGFloat(PrismLayout.cardPadding))
    #expect(padding.trailing == 12)
    let atLeast26 = ProcessInfo.processInfo.isOperatingSystemAtLeast(
      OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
    #expect(CornerShapes.platform == (atLeast26 ? .macOS26AndLater : .macOS14To25))
    #expect(
      CornerShapes.paneHeaderCard.cornerSize.width
        == CornerShapes.paneHeaderCard(for: CornerShapes.platform).cornerSize.width)
  }

  @Test(arguments: [true, false])
  func aCoordinatorReadingThePreferencesFilePostsBatteryFloorOnlyWhileItsSwitchIsOn(_ enabled: Bool) async throws {
    let fixture = try NotificationsFixture()
    if !enabled {
      fixture.model.setNotification(.batteryFloor, enabled: false)
    }
    #expect(fixture.filePreferences?.notifications["batteryFloor"] == (enabled ? nil : false))
    let file = fixture.model.preferencesFile
    let port = fixture.port
    let coordinator = NotificationCoordinator(
      port: port, preferences: { AppPreferencesStore.read(at: file).preferences }, log: { _ in })
    defer { coordinator.stop() }
    coordinator.start(host: fixture.host)
    fixture.host.publish(
      EngineSnapshot(
        busy: true, wanted: false, reason: "battery", lidClosed: false, power: .battery(percent: 9),
        events: EventCounters(
          holdErrorEpisodes: 1, holdErrorsWhileBusy: 1, batteryReleases: 1, busyStartsBelowFloor: 1)))
    #expect(await waitUntil { port.posted.last?.category == .belowFloorAtStart })
    let expected: [NotificationCategory] =
      enabled ? [.keepAwakeFailed, .batteryFloor, .belowFloorAtStart] : [.keepAwakeFailed, .belowFloorAtStart]
    #expect(port.posted.map(\.category) == expected)
    #expect(port.requests == 0)
  }

  @Test func everyCategoryIsOnByDefault() throws {
    let fixture = try NotificationsFixture()
    #expect(NotificationCategory.allCases.allSatisfy { fixture.model.isNotificationEnabled($0) })
    #expect(fixture.filePreferences == nil)
    #expect(fixture.changes.count == 0)
  }

  @Test(arguments: NotificationCategory.allCases)
  func eachSwitchWritesOnlyItsOwnCategory(_ category: NotificationCategory) throws {
    let fixture = try NotificationsFixture()
    fixture.model.setNotification(category, enabled: false)
    #expect(!fixture.model.isNotificationEnabled(category))
    let stored = try #require(fixture.filePreferences)
    for other in NotificationCategory.allCases {
      #expect(stored.isEnabled(other.preferenceKey) == (other != category))
    }
    #expect(fixture.changes.count == 1)
    fixture.model.setNotification(category, enabled: false)
    #expect(fixture.changes.count == 1)
    fixture.model.setNotification(category, enabled: true)
    #expect(fixture.filePreferences == AppPreferences())
    #expect(fixture.changes.count == 2)
    #expect(fixture.host.appliedSettings.isEmpty)
    #expect(fixture.port.requests == 0)
  }

  @Test func thePreferencesFileIsPrivate() throws {
    let fixture = try NotificationsFixture()
    fixture.model.setNotification(.lidClosedSummary, enabled: false)
    let attributes = try FileManager.default.attributesOfItem(
      atPath: fixture.model.preferencesFile.path(percentEncoded: false))
    #expect(attributes[.posixPermissions] as? Int == 0o600)
  }

  @Test func aSwitchKeepsTheRecordsOtherWritersStored() throws {
    var stored = AppPreferences()
    stored.onboarding = OnboardingRecord(
      version: 1, outcome: .completed, steps: ["notifications": "skipped"],
      at: Date(timeIntervalSince1970: 1_800_000_000))
    let fixture = try NotificationsFixture(preferences: stored)
    var later = stored
    later.selfTest = SelfTestRecord(
      outcome: .passed, reason: nil, at: Date(timeIntervalSince1970: 1_800_000_100), osBuild: "26A428",
      osVersion: "27.0")
    try AppPreferencesStore.write(later, to: fixture.model.preferencesFile)
    fixture.model.setNotification(.batteryFloor, enabled: false)
    later.notifications["batteryFloor"] = false
    #expect(fixture.filePreferences == later)
    #expect(fixture.model.preferences == later)
  }

  @Test func aSwitchedOffCategoryIsReadBackWhenSettingsOpens() throws {
    var stored = AppPreferences()
    stored.notifications["forceReminder"] = false
    stored.forceReminderHours = 6
    let fixture = try NotificationsFixture(preferences: stored)
    #expect(!fixture.model.isNotificationEnabled(.forceReminder))
    #expect(fixture.model.forceReminderHours == 6)
    stored.forceReminderHours = 2
    try AppPreferencesStore.write(stored, to: fixture.model.preferencesFile)
    fixture.model.open(pane: .general)
    #expect(fixture.model.forceReminderHours == 2)
    #expect(fixture.changes.count == 0)
  }

  @Test func aFailedPreferencesWriteShowsTheSaveErrorAndKeepsTheSwitch() throws {
    let folder = try TestFolder()
    let locked = folder.url.appendingPathComponent("locked", isDirectory: true)
    try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path(percentEncoded: false))
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: locked.path(percentEncoded: false))
    }
    let model = SettingsModel(settingsFile: locked.appendingPathComponent("settings.json"), host: FakeEngineHost())
    let logged = LoggedDecisions()
    model.logError = { logged.append($0) }
    let changes = ChangeCounter()
    model.onPreferencesChanged = { changes.increment() }
    model.setNotification(.batteryFloor, enabled: false)
    #expect(model.isNotificationEnabled(.batteryFloor))
    #expect(model.saveError == SettingsEditor.saveFailedMessage)
    #expect(logged.decisions == [Decision(keyword: .error, verb: "preferences save failed")])
    #expect(changes.count == 0)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path(percentEncoded: false))
    model.setNotification(.batteryFloor, enabled: false)
    #expect(!model.isNotificationEnabled(.batteryFloor))
    #expect(model.saveError == nil)
    #expect(changes.count == 1)
  }

  @Test(arguments: [NotificationAuthorization.authorized, .provisional])
  func allowedNotificationsShowTheGreenRowWithNoAction(_ authorization: NotificationAuthorization) async throws {
    let fixture = try NotificationsFixture(authorization)
    #expect(fixture.model.notificationStatusRow == nil)
    await fixture.model.refreshNotificationAuthorization()
    let row = try #require(fixture.model.notificationStatusRow)
    #expect(row.title == "Notifications are allowed.")
    #expect(row.symbol == "checkmark.circle.fill")
    #expect(row.tone == .success)
    #expect(row.action == nil)
    #expect(row.actionLabel == nil)
    #expect(!fixture.model.showsNotificationsBlockedCaption)
    #expect(fixture.port.requests == 0)
  }

  @Test func notDeterminedShowsAllowNotificationsAndPressingItRequestsOnce() async throws {
    let fixture = try NotificationsFixture(.notDetermined, afterRequest: .authorized)
    await fixture.model.refreshNotificationAuthorization()
    let row = try #require(fixture.model.notificationStatusRow)
    #expect(row.title == "Notifications aren't set up yet.")
    #expect(row.symbol == "info.circle")
    #expect(row.tone == .info)
    #expect(row.actionLabel == "Allow Notifications")
    #expect(fixture.port.requests == 0)
    async let first: Void = fixture.model.allowNotifications()
    async let second: Void = fixture.model.allowNotifications()
    _ = await (first, second)
    #expect(fixture.port.requests == 1)
    #expect(!fixture.model.requestingNotifications)
    #expect(fixture.model.notificationStatusRow?.title == "Notifications are allowed.")
    await fixture.model.allowNotifications()
    #expect(fixture.port.requests == 1)
    #expect(fixture.port.posted.isEmpty)
  }

  static let boundedRequest: Comment =
    "A-WR-07: Allow notifications waits for the system prompt at most 5 s, as onboarding does, and a late answer still applies"

  @Test func allowNotificationsThatGetsNoAnswerEndsAtItsBoundAndALateAnswerStillApplies() async throws {
    let fixture = try NotificationsFixture(.notDetermined, afterRequest: .authorized)
    await fixture.model.refreshNotificationAuthorization()
    fixture.port.holdRequests()
    defer { fixture.port.releaseRequests() }
    fixture.model.authorizationWaitSeconds = 0.2
    let model = fixture.model
    let call = Task { await model.allowNotifications() }
    let ended = await waitUntil(timeout: 10) { !model.requestingNotifications && fixture.port.requests == 1 }
    #expect(ended, Self.boundedRequest)
    #expect(
      fixture.model.notificationAuthorization == .notDetermined,
      "R2T-WR-05: the held request had not answered, so only the bound ended the wait")
    fixture.port.releaseRequests()
    await call.value
    #expect(await waitUntil { model.notificationAuthorization == .authorized }, Self.boundedRequest)
  }

  @Test func theNotificationRequestBoundIsTheProjectsSystemCallBound() throws {
    let fixture = try NotificationsFixture(.notDetermined)
    #expect(fixture.model.authorizationWaitSeconds == Timing.systemCallTimeoutSeconds)
  }

  @Test func openingThePaneReadsTheAuthorizationAndNeverRequestsIt() async throws {
    let fixture = try NotificationsFixture(.notDetermined)
    fixture.model.open(pane: .general)
    let port = fixture.port
    #expect(await waitUntil { port.reads >= 1 })
    #expect(await waitUntil { fixture.model.notificationAuthorization == .notDetermined })
    await fixture.model.refreshNotificationAuthorization()
    fixture.model.select(.battery)
    fixture.model.select(.general)
    #expect(fixture.port.requests == 0)
    #expect(fixture.port.posted.isEmpty)
  }

  @Test func aReadAwaitedRightAfterSettingsOpensLeavesTheStatusSet() async throws {
    let fixture = try NotificationsFixture(.denied)
    fixture.model.open(pane: .general)
    await fixture.model.refreshNotificationAuthorization()
    #expect(fixture.model.notificationAuthorization == .denied)
    #expect(fixture.port.requests == 0)
  }

  @Test func aReadThatStartedBeforeTheGrantNeverOverwritesIt() async throws {
    let fixture = try NotificationsFixture(.notDetermined, afterRequest: .authorized)
    await fixture.model.refreshNotificationAuthorization()
    let port = fixture.port
    let model = fixture.model
    port.holdNextRead()
    let stale = Task { await model.refreshNotificationAuthorization() }
    #expect(await waitUntil { port.reads == 2 })
    await model.allowNotifications()
    #expect(model.notificationAuthorization == .authorized)
    port.releaseRead()
    await stale.value
    #expect(model.notificationAuthorization == .authorized)
    #expect(port.requests == 1)
  }

  @Test func deniedShowsTheOrangeRowWithOpenNotificationSettingsAndNeverPromptsAgain() async throws {
    let fixture = try NotificationsFixture(.denied)
    await fixture.model.refreshNotificationAuthorization()
    let row = try #require(fixture.model.notificationStatusRow)
    #expect(row.title == "Notifications are off for Overtime in System Settings.")
    #expect(row.symbol == "exclamationmark.triangle.fill")
    #expect(row.tone == .warning)
    #expect(row.actionLabel == "Open Notification Settings")
    fixture.model.openNotificationSettings()
    #expect(fixture.opened.urls == [SystemSettingsLinks.notifications])
    await fixture.model.allowNotifications()
    await fixture.model.refreshNotificationAuthorization()
    #expect(fixture.port.requests == 0)
    #expect(fixture.port.posted.isEmpty)
  }

  @Test(arguments: [NotificationAuthorization.denied, .notDetermined])
  func withoutPermissionTheCaptionShowsAndTheSwitchesStayEditable(_ authorization: NotificationAuthorization)
    async throws
  {
    let fixture = try NotificationsFixture(authorization)
    await fixture.model.refreshNotificationAuthorization()
    #expect(fixture.model.showsNotificationsBlockedCaption)
    #expect(GeneralPane.notificationsBlockedCaption == "Overtime won't show notifications until you allow them.")
    fixture.model.setNotification(.keepAwakeFailed, enabled: false)
    #expect(!fixture.model.isNotificationEnabled(.keepAwakeFailed))
    #expect(fixture.filePreferences?.notifications["keepAwakeFailed"] == false)
    #expect(fixture.port.requests == 0)
  }

  @Test func aGrantSeenOnTheNextReadClearsTheCaption() async throws {
    let fixture = try NotificationsFixture(.denied)
    await fixture.model.refreshNotificationAuthorization()
    #expect(fixture.model.showsNotificationsBlockedCaption)
    fixture.port.set(.authorized)
    await fixture.model.refreshNotificationAuthorization()
    #expect(!fixture.model.showsNotificationsBlockedCaption)
    #expect(fixture.model.notificationStatusRow?.action == nil)
  }

  @Test func withoutANotificationPortThereIsNoStatusRowAndNoCaption() async throws {
    let fixture = try Fixture()
    await fixture.model.refreshNotificationAuthorization()
    await fixture.model.allowNotifications()
    #expect(fixture.model.notificationStatusRow == nil)
    #expect(!fixture.model.showsNotificationsBlockedCaption)
  }

  @Test func remindAfterOffersOneToTwelveHoursAndShowsThreeHoursByDefault() throws {
    let fixture = try NotificationsFixture()
    #expect(SettingsModel.reminderHourChoices == Array(1...12))
    #expect(
      SettingsModel.reminderHourChoices.map { NotificationContent.hours($0) } == [
        "1 hour", "2 hours", "3 hours", "4 hours", "5 hours", "6 hours", "7 hours", "8 hours", "9 hours", "10 hours",
        "11 hours", "12 hours",
      ])
    #expect(fixture.model.forceReminderHours == 3)
    #expect(NotificationContent.hours(fixture.model.forceReminderHours) == "3 hours")
    #expect(fixture.model.canChangeForceReminderHours)
  }

  @Test func choosingAnIntervalWritesItAndTellsTheCoordinator() throws {
    let fixture = try NotificationsFixture()
    fixture.model.setForceReminderHours(1)
    #expect(fixture.model.forceReminderHours == 1)
    #expect(fixture.filePreferences?.forceReminderHours == 1)
    #expect(fixture.changes.count == 1)
    fixture.model.setForceReminderHours(1)
    #expect(fixture.changes.count == 1)
    for outOfRange in [0, 13, -1] {
      fixture.model.setForceReminderHours(outOfRange)
    }
    #expect(fixture.model.forceReminderHours == 1)
    #expect(fixture.filePreferences?.forceReminderHours == 1)
    #expect(fixture.changes.count == 1)
  }

  @Test func remindAfterIsDisabledWhileTheReminderSwitchIsOff() throws {
    let fixture = try NotificationsFixture()
    fixture.model.setNotification(.forceReminder, enabled: false)
    #expect(!fixture.model.canChangeForceReminderHours)
    #expect(fixture.model.forceReminderHours == 3)
    fixture.model.setNotification(.forceReminder, enabled: true)
    #expect(fixture.model.canChangeForceReminderHours)
  }

  @Test func theNotificationsCopyMatchesTheUISpec() throws {
    let fixture = try NotificationsFixture(settings: Settings(batteryLowPercent: 15, batteryResumePercent: 30))
    let floor = fixture.model.settings.batteryLowPercent
    #expect(GeneralPane.notificationsTitle == "Notifications")
    #expect(GeneralPane.remindAfterLabel == "Remind after")
    #expect(
      NotificationCategory.allCases.map { GeneralPane.notificationLabel($0) } == [
        "Keep-awake failed", "Battery floor", "Battery low when Claude starts", "Battery temperature",
        "Lid-closed summary", "Keep Awake reminder",
      ])
    #expect(
      NotificationCategory.allCases.map { GeneralPane.notificationCaption($0, floorPercent: floor) } == [
        "When Overtime can't keep the Mac awake while Claude works, or its self-test fails.",
        "When the battery reaches 15% with the lid open.",
        "When Claude starts while the battery is already below 15%.",
        "When the battery reaches 45°C with the lid open.",
        "One summary when you open the lid, only if something happened while it was closed.",
        "When Keep Awake has been on with no Claude activity.",
      ])
    #expect(
      GeneralPane.notificationCaption(.batteryFloor, floorPercent: 10)
        == "When the battery reaches 10% with the lid open.")
  }

  @Test func theNotificationCaptionsFollowTheProtectionSwitches() {
    let off = "Battery protection is off in Settings > Battery."
    for category in [NotificationCategory.batteryFloor, .belowFloorAtStart] {
      let caption = GeneralPane.notificationCaption(category, floorPercent: 10, batteryProtectionEnabled: false)
      #expect(caption == off)
    }
    let floorOn = GeneralPane.notificationCaption(.batteryFloor, floorPercent: 10, batteryProtectionEnabled: true)
    #expect(floorOn == "When the battery reaches 10% with the lid open.")
    let startOn = GeneralPane.notificationCaption(.belowFloorAtStart, floorPercent: 10)
    #expect(startOn == "When Claude starts while the battery is already below 10%.")
    #expect(GeneralPane.notificationLabel(.batteryTemperature) == "Battery temperature")
    let hot = GeneralPane.notificationCaption(.batteryTemperature, floorPercent: 10, releaseCelsius: 45)
    #expect(hot == "When the battery reaches 45°C with the lid open.")
    let hotter = GeneralPane.notificationCaption(.batteryTemperature, floorPercent: 10, releaseCelsius: 52)
    #expect(hotter == "When the battery reaches 52°C with the lid open.")
    let hotOff = GeneralPane.notificationCaption(
      .batteryTemperature, floorPercent: 10, releaseCelsius: 45, temperatureProtectionEnabled: false)
    #expect(hotOff == "Temperature protection is off in Settings > Battery.")
    let unaffected = GeneralPane.notificationCaption(
      .batteryTemperature, floorPercent: 10, releaseCelsius: 45, batteryProtectionEnabled: false)
    #expect(unaffected == hot)
  }

  @Test func aPaneWithItemsReportsNeedsAttentionAndItsHelpListsThePaneTexts() async throws {
    let fixture = try AttentionFixture(notifications: .denied)
    fixture.panel.attachLoginItem(PanelModelTests.FakeLoginItem(status: .requiresApproval))
    await fixture.open()
    let badge = try #require(fixture.model.sidebarBadge(for: .general))
    #expect(badge.texts == ["Launch at login needs your approval.", "Notifications are off for Overtime."])
    #expect(badge.help == "Launch at login needs your approval.\nNotifications are off for Overtime.")
    #expect(SidebarBadge.style(for: .general).accessibilityValue == "Needs attention")
    #expect(SidebarBadge.style(for: .general).symbol == "exclamationmark.triangle.fill")
    #expect(!SidebarBadge.style(for: .general).isUpdate)
    #expect(fixture.badgedPanes == [.general])
    #expect(fixture.port.requests == 0)
    #expect(fixture.location.requests == 0)
  }

  @Test func withNoItemsNoSidebarRowShowsABadge() async throws {
    let fixture = try AttentionFixture(settings: Settings(hotspotAutoDetect: true))
    fixture.panel.attachLoginItem(PanelModelTests.FakeLoginItem(status: .enabled))
    await fixture.open()
    #expect(fixture.badgedPanes.isEmpty)
    #expect(fixture.model.attentionBadges.isEmpty)
  }

  @Test func aNotDeterminedNotificationStatusShowsNoBadge() async throws {
    let fixture = try AttentionFixture(notifications: .notDetermined)
    await fixture.open()
    #expect(fixture.model.showsNotificationsBlockedCaption)
    #expect(fixture.badgedPanes.isEmpty)
  }

  @Test func aDetectionWarningBadgesTheDiagnosticsPaneUntilItClears() async throws {
    let fixture = try AttentionFixture()
    await fixture.open()
    fixture.host.publish(EngineSnapshot(wanted: false, reason: "idle", detectionWarnings: [.terminalSilence]))
    #expect(await waitUntil { fixture.model.sidebarBadge(for: .diagnostics) != nil })
    #expect(fixture.model.sidebarBadge(for: .diagnostics)?.help == "Overtime may be missing Claude activity.")
    #expect(fixture.badgedPanes == [.diagnostics])
    fixture.host.publish(EngineSnapshot(wanted: false, reason: "idle"))
    #expect(await waitUntil { fixture.badgedPanes.isEmpty })
  }

  @Test func aHotspotWithoutLocationBadgesTheNetworkPaneAndShowsItsRow() async throws {
    let fixture = try AttentionFixture(settings: Settings(hotspotAutoDetect: true), location: .denied)
    await fixture.open()
    #expect(fixture.model.locationRow?.title == "Location access is off for Overtime.")
    #expect(
      fixture.model.sidebarBadge(for: .network)?.texts == [
        "Location access is off. Failover still works, but with Location, Overtime can join the hotspot directly."
      ])
    #expect(fixture.badgedPanes == [.network])
    fixture.location.current = .notDetermined
    fixture.model.refreshLocationStatus()
    #expect(fixture.model.locationRow?.actionLabel == "Allow Location Access")
    #expect(fixture.badgedPanes == [.network])
    fixture.location.current = .authorized
    fixture.model.refreshLocationStatus()
    #expect(fixture.badgedPanes.isEmpty)
    fixture.location.current = .denied
    fixture.model.refreshLocationStatus()
    #expect(fixture.badgedPanes == [.network])
    #expect(await fixture.model.selectHotspot(.none) == .applied)
    #expect(fixture.badgedPanes.isEmpty)
    #expect(fixture.location.requests == 0)
  }

  @Test func theSelfTestAndHelperFlagsBadgeTheirPanesEvenInTheErrorState() async throws {
    let fixture = try AttentionFixture()
    await fixture.open()
    fixture.host.publish(
      EngineSnapshot(
        busy: false, wanted: false, reason: "idle", selfTest: .failed(.timedOut), selfTestErrorActive: true,
        selfTestFailures: 1, selfTestRuns: 1))
    #expect(await waitUntil { fixture.panel.selfTestFailed })
    fixture.panel.helperStale = true
    #expect(fixture.panel.presentation.state == .error(.selfTestFailed))
    #expect(fixture.model.sidebarBadge(for: .diagnostics)?.texts == ["The keep-awake self-test failed."])
    #expect(fixture.model.sidebarBadge(for: .unplugProtection)?.texts == ["Unplug protection is out of date."])
    #expect(fixture.badgedPanes == [.unplugProtection, .diagnostics])
    #expect(fixture.panel.attentionItems == [.helperStale])
  }

  @Test func aWaitingUpdateBadgesAboutWithTheUpdateStyleUntilItClears() async throws {
    let fixture = try AttentionFixture()
    await fixture.open()
    #expect(fixture.model.sidebarBadge(for: .about) == nil)
    #expect(!fixture.model.attentionInputs.updateWaiting)
    fixture.panel.updateWaiting = true
    #expect(fixture.model.attentionInputs.updateWaiting)
    let badge = try #require(fixture.model.sidebarBadge(for: .about))
    #expect(badge.texts == ["An update to Overtime is available."])
    #expect(badge.help == "An update to Overtime is available.")
    #expect(fixture.badgedPanes == [.about])
    #expect(
      SidebarBadge.style(for: .about)
        == SidebarBadge.Style(symbol: "arrow.down.circle", isUpdate: true, accessibilityValue: "Update available"))
    fixture.panel.updateWaiting = false
    #expect(fixture.model.sidebarBadge(for: .about) == nil)
    #expect(fixture.badgedPanes.isEmpty)
  }

  @Test func aWaitingUpdateLeavesTheAboutBadgeWhileAnUninstallRuns() async throws {
    let fixture = try AttentionFixture()
    await fixture.open()
    fixture.panel.updateWaiting = true
    #expect(fixture.model.sidebarBadge(for: .about) != nil)
    fixture.panel.uninstalling = true
    #expect(!fixture.model.attentionInputs.updateWaiting)
    #expect(fixture.model.sidebarBadge(for: .about) == nil)
    #expect(fixture.badgedPanes.isEmpty)
    fixture.panel.uninstalling = false
    #expect(fixture.model.sidebarBadge(for: .about) != nil)
  }

  @Test func aWaitingUpdateBadgesAboutAlongsideTheOtherPanesTriangles() async throws {
    let fixture = try AttentionFixture(notifications: .denied)
    await fixture.open()
    fixture.panel.updateWaiting = true
    #expect(fixture.badgedPanes == [.general, .about])
    #expect(fixture.model.sidebarBadge(for: .general)?.texts == ["Notifications are off for Overtime."])
    #expect(fixture.model.sidebarBadge(for: .about)?.texts == ["An update to Overtime is available."])
    #expect(fixture.port.posted.isEmpty)
    #expect(fixture.port.requests == 0)
  }

  @Test(arguments: SettingsPane.allCases.filter { $0 != .about })
  func everyOtherPaneKeepsTheTriangleBadgeStyle(_ pane: SettingsPane) {
    #expect(
      SidebarBadge.style(for: pane)
        == SidebarBadge.Style(
          symbol: "exclamationmark.triangle.fill", isUpdate: false, accessibilityValue: "Needs attention"))
  }

  @Test func theBadgeStylesUseOnlyTheUISpecSymbols() {
    let symbols = Set(SettingsPane.allCases.map { SidebarBadge.style(for: $0).symbol })
    #expect(symbols == ["exclamationmark.triangle.fill", "arrow.down.circle"])
    #expect(symbols.isSubset(of: Set(SymbolAvailabilityTests.phaseFiveSymbols)))
  }
}
