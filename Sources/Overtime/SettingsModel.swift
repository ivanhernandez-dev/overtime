import Foundation
import Observation
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import OvertimeSystem

struct SetupInfo: Equatable {
  var appVersion: String
  var osVersion: String
  var osBuild: String?
  var hardwareModel: String?

  static func current(bundle: Bundle = .main) -> SetupInfo {
    SetupInfo(
      appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
      osVersion: SystemInfo.osVersion(), osBuild: SystemInfo.osBuild(), hardwareModel: SystemInfo.hardwareModel())
  }
}

struct TranscriptFolderRow: Equatable, Identifiable {
  let path: String
  let displayPath: String
  let isDefault: Bool
  var warning: String?

  var id: String {
    path
  }

  var removeLabel: String {
    "Remove \(path)"
  }
}

@Observable
final class SettingsModel {
  let settingsFile: URL
  let environment: [String: String]
  let homeDirectory: String
  private(set) var settings: Settings
  private(set) var selectedPane: SettingsPane = .general
  private(set) var texts: [SettingsField: String] = [:]
  private(set) var messages: [SettingsField: String] = [:]
  private(set) var saveError: String?
  private(set) var folderMessage: String?
  private(set) var entrypointDraft = ""
  private(set) var entrypointMessage: String?
  private(set) var knownNetworks: [String]?
  private(set) var knownNetworksRead = false
  private(set) var locationStatus: LocationAuthorization?
  private(set) var preferences: AppPreferences
  private(set) var notificationAuthorization: NotificationAuthorization?
  private(set) var requestingNotifications = false
  let preferencesFile: URL
  let helperPane: HelperPaneModel
  let diagnostics = DiagnosticsModel()
  var host: (any EngineHosting)?

  @ObservationIgnored var logError: (Decision) -> Void = { _ in }
  @ObservationIgnored var onSelectPane: (SettingsPane) -> Void = { _ in }
  @ObservationIgnored var onClose: () -> Void = {}
  @ObservationIgnored var folderPicker: (any FolderPickerPort)?
  @ObservationIgnored var wifi: (any WiFiInfoPort)?
  @ObservationIgnored var location: (any LocationStatusPort)?
  @ObservationIgnored var panel: PanelModel?
  @ObservationIgnored var openURL: (URL) -> Void = { _ in }
  @ObservationIgnored var about = AboutModel()
  @ObservationIgnored var notifications: (any NotificationPort)?
  @ObservationIgnored var onPreferencesChanged: () -> Void = {}
  @ObservationIgnored var onRunOnboarding: () -> Void = {}
  @ObservationIgnored var setupInfo = SetupInfo.current()
  @ObservationIgnored private var lastCommit: Task<SettingsCommitResult?, Never>?
  @ObservationIgnored private var authorizationRequests = 0
  @ObservationIgnored var authorizationWaitSeconds = Timing.systemCallTimeoutSeconds
  @ObservationIgnored var knownNetworksTimeoutSeconds = Timing.systemCallTimeoutSeconds
  @ObservationIgnored private let knownNetworksRunner = DeadlineRunner()

  static let knownNetworksKey = "settings-known-networks"

  static let saveFailedDecision = Decision(keyword: .error, verb: "settings save failed")
  static let preferencesSaveFailedDecision = Decision(keyword: .error, verb: "preferences save failed")
  static let preferencesFileName = "preferences.json"
  static let reminderHourChoices = Array(AppPreferences.forceReminderHoursRange)

  init(
    settingsFile: URL,
    host: (any EngineHosting)? = nil,
    folderPicker: (any FolderPickerPort)? = nil,
    wifi: (any WiFiInfoPort)? = nil,
    location: (any LocationStatusPort)? = nil,
    panel: PanelModel? = nil,
    preferencesFile: URL? = nil,
    notifications: (any NotificationPort)? = nil,
    helper: HelperPaneModel? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: String = NSHomeDirectory()
  ) {
    self.settingsFile = settingsFile
    let preferencesFile =
      preferencesFile ?? settingsFile.deletingLastPathComponent().appendingPathComponent(Self.preferencesFileName)
    self.preferencesFile = preferencesFile
    self.notifications = notifications
    helperPane = helper ?? HelperPaneModel()
    preferences = AppPreferencesStore.read(at: preferencesFile).preferences
    self.host = host
    self.folderPicker = folderPicker
    self.wifi = wifi
    self.location = location
    self.panel = panel
    self.environment = environment
    self.homeDirectory = homeDirectory
    settings = AppHost.loadSettings(from: settingsFile).settings
    diagnostics.inputs = { [weak self] in
      self?.diagnosticsInputs ?? DiagnosticsInputs(homeDirectory: homeDirectory)
    }
    diagnostics.wifi = { [weak self] in self?.wifi }
  }

  var diagnosticsInputs: DiagnosticsInputs {
    DiagnosticsInputs(
      homeDirectory: homeDirectory, hotspot: settings.hotspot, snapshot: panel?.snapshot,
      loginItem: panel?.loginItemStatus, helper: helperPane.source == nil ? nil : helperPane.state,
      selfTest: preferences.selfTest, appVersion: setupInfo.appVersion, osVersion: setupInfo.osVersion,
      osBuild: setupInfo.osBuild, hardwareModel: setupInfo.hardwareModel)
  }

  var canEdit: Bool {
    host != nil
  }

  var helperInstalled: Bool {
    helperPane.isInstalled
  }

  var windowTitle: String {
    selectedPane.title
  }

  func open(pane: SettingsPane?) {
    reload()
    reloadPreferences()
    panel?.refreshLoginItem()
    refreshLocationStatus()
    Task { await refreshNotificationAuthorization() }
    if about.uninstallActive {
      select(.about)
    } else if let pane {
      select(pane)
    }
  }

  func select(_ pane: SettingsPane) {
    guard selectedPane != pane else { return }
    discardEdits()
    selectedPane = pane
    onSelectPane(pane)
  }

  func reload() {
    let loaded = AppHost.loadSettings(from: settingsFile).settings
    if settings != loaded {
      settings = loaded
    }
    discardEdits()
  }

  func discardEdits() {
    if !texts.isEmpty { texts = [:] }
    if !messages.isEmpty { messages = [:] }
    if saveError != nil { saveError = nil }
    if folderMessage != nil { folderMessage = nil }
    if entrypointMessage != nil { entrypointMessage = nil }
    if !entrypointDraft.isEmpty { entrypointDraft = "" }
  }

  func text(for field: SettingsField) -> String {
    texts[field] ?? savedText(for: field)
  }

  func setText(_ text: String, for field: SettingsField) {
    guard texts[field] != text else { return }
    texts[field] = text
  }

  func message(for field: SettingsField) -> String? {
    messages[field]
  }

  func savedText(for field: SettingsField) -> String {
    String(Self.value(of: field, in: settings))
  }

  func stepBounds(for field: SettingsField) -> ClosedRange<Int> {
    Self.stepBounds(for: field, in: settings)
  }

  @discardableResult
  func commit(_ field: SettingsField, text: String) async -> SettingsCommitResult? {
    setText(text, for: field)
    return await serialized { [self] in
      await performCommit(field, text: text)
    }
  }

  func revert(_ field: SettingsField) {
    clearEdit(field)
  }

  @discardableResult
  func commitIfEdited(_ field: SettingsField) async -> SettingsCommitResult? {
    guard let text = texts[field] else { return nil }
    return await commit(field, text: text)
  }

  func close() {
    discardEdits()
    onClose()
  }

  @discardableResult
  func step(_ field: SettingsField, by delta: Int) async -> SettingsCommitResult? {
    await serialized { [self] in
      let current = Self.value(of: field, in: settings)
      let bounds = Self.stepBounds(for: field, in: settings)
      let target = min(max(current + delta, bounds.lowerBound), bounds.upperBound)
      guard target != current else { return nil }
      let text = String(target)
      setText(text, for: field)
      return await performCommit(field, text: text)
    }
  }

  @discardableResult
  func commit(settings candidate: Settings) async -> SettingsCommitResult? {
    await serialized { [self] in
      await save(candidate)
    }
  }

  var folderRows: [TranscriptFolderRow] {
    let warnings = detectionWarnings
    if let roots = settings.transcriptRoots, !roots.isEmpty {
      return roots.map { row(for: $0, isDefault: false, warnings: warnings) }
    }
    return Settings.defaultTranscriptRoots(environment: environment, homeDirectory: homeDirectory).map {
      row(for: $0, isDefault: true, warnings: warnings)
    }
  }

  var detectionWarnings: [DetectionWarning] {
    panel?.snapshot?.detectionWarnings ?? []
  }

  var detectionHealthRows: [DetectionHealthRow] {
    DiagnosticsPane.rows(for: detectionWarnings, homeDirectory: homeDirectory)
  }

  func openDetectionSettings() {
    select(.detection)
  }

  var selfTestStatus: SelfTestStatus {
    panel?.snapshot?.selfTest ?? .notRun
  }

  var selfTestRow: SelfTestRow {
    SelfTestPresentation.row(
      status: selfTestStatus, record: preferences.selfTest, currentBuild: panel?.snapshot?.osBuild)
  }

  var canRunSelfTest: Bool {
    host != nil && SelfTestPresentation.runButtonEnabled(snapshot: panel?.snapshot)
  }

  var selfTestHelp: String? {
    host == nil ? nil : SelfTestPresentation.runUnavailableReason(snapshot: panel?.snapshot)
  }

  var selfTestAnnouncement: String? {
    SelfTestPresentation.announcement(for: selfTestStatus)
  }

  func runSelfTest() async {
    guard canRunSelfTest, let host else { return }
    await host.requestSelfTest()
  }

  var setupCaption: String {
    DiagnosticsPane.setupCaption(setupInfo)
  }

  func runOnboardingAgain() {
    onRunOnboarding()
  }

  var attentionInputs: AttentionInputs {
    AttentionInputs(
      selfTestFailed: panel?.selfTestFailed ?? false, detectionWarnings: detectionWarnings,
      helperReapprove: panel?.helperReapprove ?? false, helperStale: panel?.helperStale ?? false,
      loginItem: panel?.loginItemStatus, notifications: notificationAuthorization, location: locationStatus,
      hotspotChoice: hotspotChoice,
      updateWaiting: (panel?.updateWaiting ?? false) && !(panel?.uninstalling ?? false))
  }

  var attentionBadges: [SettingsPane: [String]] {
    Attention.badges(Attention.items(attentionInputs, forPanel: false))
  }

  func sidebarBadge(for pane: SettingsPane) -> SidebarBadge? {
    guard let texts = attentionBadges[pane], !texts.isEmpty else { return nil }
    return SidebarBadge(texts: texts)
  }

  var showsUseDefaultFolder: Bool {
    !(settings.transcriptRoots ?? []).isEmpty
  }

  @discardableResult
  func addFolder() async -> SettingsCommitResult? {
    guard canEdit, let folderPicker, let url = await folderPicker.chooseFolder() else { return nil }
    let path = Self.folderPath(of: url)
    return await serialized { [self] in
      switch SettingsEditor.addFolder(path, to: settings) {
      case .failure(let error):
        folderMessage = error.message
        return .invalid(error)
      case .success(let candidate):
        return await saveFolders(candidate)
      }
    }
  }

  @discardableResult
  func removeFolder(_ path: String) async -> SettingsCommitResult? {
    await serialized { [self] in
      await saveFolders(SettingsEditor.removeFolder(path, from: settings))
    }
  }

  @discardableResult
  func useDefaultFolder() async -> SettingsCommitResult? {
    await serialized { [self] in
      await saveFolders(SettingsEditor.useDefaultFolder(settings))
    }
  }

  var showsNoIgnoredEntrypoints: Bool {
    settings.ignoredEntrypoints.isEmpty
  }

  var showsRestoreDefaultEntrypoints: Bool {
    settings.ignoredEntrypoints != Settings().ignoredEntrypoints
  }

  func setEntrypointDraft(_ text: String) {
    guard entrypointDraft != text else { return }
    entrypointDraft = text
  }

  @discardableResult
  func addEntrypoint() async -> SettingsCommitResult? {
    let draft = entrypointDraft
    return await serialized { [self] in
      switch SettingsEditor.addEntrypoint(draft, to: settings) {
      case .failure(let error):
        entrypointMessage = error.message
        return .invalid(error)
      case .success(let candidate):
        let result = await saveEntrypoints(candidate)
        if result == .applied || result == .applyTimedOut, entrypointDraft == draft {
          entrypointDraft = ""
        }
        return result
      }
    }
  }

  @discardableResult
  func removeEntrypoint(_ pattern: String) async -> SettingsCommitResult? {
    await serialized { [self] in
      await saveEntrypoints(SettingsEditor.removeEntrypoint(pattern, from: settings))
    }
  }

  @discardableResult
  func restoreDefaultEntrypoints() async -> SettingsCommitResult? {
    await serialized { [self] in
      await saveEntrypoints(SettingsEditor.restoreDefaultEntrypoints(settings))
    }
  }

  private func saveEntrypoints(_ candidate: Settings) async -> SettingsCommitResult? {
    guard candidate != settings else { return nil }
    let result = await save(candidate)
    switch result {
    case .applied, .applyTimedOut, .saveFailed, nil:
      entrypointMessage = nil
    case .invalid(let error):
      entrypointMessage = error.message
    }
    return result
  }

  var hotspotChoice: HotspotChoice {
    HotspotChoice(settings: settings, knownNetworks: knownNetworks)
  }

  var hotspotEntries: [HotspotPicker.Entry] {
    HotspotPicker.entries(knownNetworks: knownNetworks, stored: hotspotChoice)
  }

  var hotspotCaption: String? {
    knownNetworksRead ? HotspotPicker.caption(knownNetworks: knownNetworks) : nil
  }

  func readKnownNetworks() async {
    guard let wifi else { return }
    let outcome = await knownNetworksRunner.perform(timeout: knownNetworksTimeoutSeconds, key: Self.knownNetworksKey) {
      wifi.knownNetworkNames()
    }
    let names: [String]? = if case .value(let read) = outcome { read } else { nil }
    let sorted = names.map(HotspotPicker.sortedNames)
    if knownNetworks != sorted { knownNetworks = sorted }
    if !knownNetworksRead { knownNetworksRead = true }
  }

  @discardableResult
  func selectHotspot(_ choice: HotspotChoice) async -> SettingsCommitResult? {
    await serialized { [self] in
      let candidate = choice.apply(to: settings)
      guard candidate != settings else { return nil }
      return await save(candidate)
    }
  }

  var locationRow: LocationRow? {
    guard let locationStatus else { return nil }
    return LocationRow.for(locationStatus, choice: hotspotChoice)
  }

  func refreshLocationStatus() {
    guard let location else { return }
    let status = location.status()
    if locationStatus != status { locationStatus = status }
  }

  func allowLocationAccess() {
    location?.request()
  }

  func openLocationServices() {
    openURL(SystemSettingsLinks.locationServices)
  }

  var keepDisplayOn: Bool {
    settings.keepDisplayOn
  }

  @discardableResult
  func setKeepDisplayOn(_ enabled: Bool) async -> SettingsCommitResult? {
    await serialized { [self] in
      guard settings.keepDisplayOn != enabled else { return nil }
      var candidate = settings
      candidate.keepDisplayOn = enabled
      return await save(candidate)
    }
  }

  var lidClosedKeepAwake: LidClosedKeepAwake {
    settings.lidClosedKeepAwake
  }

  @discardableResult
  func setLidClosedKeepAwake(_ value: LidClosedKeepAwake) async -> SettingsCommitResult? {
    await serialized { [self] in
      guard settings.lidClosedKeepAwake != value else { return nil }
      var candidate = settings
      candidate.lidClosedKeepAwake = value
      return await save(candidate)
    }
  }

  var pauseChoices: [PauseChoice] {
    PauseChoice.menu(timedMinutes: [settings.pauseFirstMinutes, settings.pauseSecondMinutes])
  }

  var keepAwakeChoices: [KeepAwakeChoice] {
    KeepAwakeChoice.menu(timedMinutes: [settings.keepAwakeFirstMinutes, settings.keepAwakeSecondMinutes])
  }

  var batteryProtectionEnabled: Bool {
    settings.batteryProtectionEnabled
  }

  @discardableResult
  func setBatteryProtectionEnabled(_ enabled: Bool) async -> SettingsCommitResult? {
    await serialized { [self] in
      guard settings.batteryProtectionEnabled != enabled else { return nil }
      var candidate = settings
      candidate.batteryProtectionEnabled = enabled
      return await save(candidate)
    }
  }

  var temperatureProtectionEnabled: Bool {
    settings.temperatureProtectionEnabled
  }

  @discardableResult
  func setTemperatureProtectionEnabled(_ enabled: Bool) async -> SettingsCommitResult? {
    await serialized { [self] in
      guard settings.temperatureProtectionEnabled != enabled else { return nil }
      var candidate = settings
      candidate.temperatureProtectionEnabled = enabled
      return await save(candidate)
    }
  }

  var batteryTemperature: BatteryTemperatureReading? {
    panel?.snapshot?.batteryTemperature
  }

  var batteryTemperatureText: String {
    Self.batteryTemperatureText(batteryTemperature)
  }

  static func batteryTemperatureText(_ reading: BatteryTemperatureReading?) -> String {
    switch reading {
    case .celsius(let celsius)?: "\(celsius)°C"
    case .unavailable?: "Unavailable"
    case .unreadable?: "Can't be read"
    case nil: "Not read yet"
    }
  }

  var launchAtLogin: Bool {
    panel?.launchAtLogin ?? false
  }

  var loginItemCaption: LoginItemCaption? {
    panel?.loginItemCaption
  }

  var canChangeLaunchAtLogin: Bool {
    panel?.loginItem != nil
  }

  func setLaunchAtLogin(_ enabled: Bool) {
    panel?.setLaunchAtLogin(enabled)
  }

  func openLoginItems() {
    panel?.openLoginItems()
  }

  var notificationStatusRow: NotificationStatusRow? {
    notificationAuthorization.map { NotificationStatusRow.for($0) }
  }

  var showsNotificationsBlockedCaption: Bool {
    notificationAuthorization == .denied || notificationAuthorization == .notDetermined
  }

  func refreshNotificationAuthorization() async {
    guard let notifications else { return }
    let requests = authorizationRequests
    let status = await NotificationCoordinator.authorization(of: notifications)
    guard let status, requests == authorizationRequests else { return }
    if notificationAuthorization != status { notificationAuthorization = status }
  }

  func allowNotifications() async {
    guard let notifications, !requestingNotifications, notificationAuthorization == .notDetermined else { return }
    requestingNotifications = true
    _ = await Engine.bounded(seconds: authorizationWaitSeconds) { [weak self] in
      let status = await notifications.requestAuthorization()
      await self?.applyRequested(status)
    }
    requestingNotifications = false
  }

  private func applyRequested(_ status: NotificationAuthorization) {
    authorizationRequests += 1
    if notificationAuthorization != status { notificationAuthorization = status }
  }

  func openNotificationSettings() {
    openURL(SystemSettingsLinks.notifications)
  }

  func isNotificationEnabled(_ category: NotificationCategory) -> Bool {
    preferences.isEnabled(category.preferenceKey)
  }

  func setNotification(_ category: NotificationCategory, enabled: Bool) {
    guard isNotificationEnabled(category) != enabled else { return }
    updatePreferences { $0.notifications[category.preferenceKey] = enabled }
  }

  var forceReminderHours: Int {
    preferences.forceReminderHours
  }

  var canChangeForceReminderHours: Bool {
    isNotificationEnabled(.forceReminder)
  }

  func setForceReminderHours(_ hours: Int) {
    guard AppPreferences.forceReminderHoursRange.contains(hours), preferences.forceReminderHours != hours else {
      return
    }
    updatePreferences { $0.forceReminderHours = hours }
  }

  func reloadPreferences() {
    let loaded = AppPreferencesStore.read(at: preferencesFile).preferences
    if preferences != loaded { preferences = loaded }
  }

  private func updatePreferences(_ change: (inout AppPreferences) -> Void) {
    let candidate: AppPreferences
    do {
      candidate = try AppPreferencesStore.update(at: preferencesFile, change)
    } catch {
      saveError = SettingsEditor.saveFailedMessage
      logError(Self.preferencesSaveFailedDecision)
      return
    }
    preferences = candidate
    if saveError != nil { saveError = nil }
    onPreferencesChanged()
  }

  static func stepSize(for field: SettingsField) -> Int {
    switch field {
    case .batteryLowPercent, .batteryResumePercent, .helperBatteryFloorPercent, .temperatureReleaseCelsius:
      1
    case .transcriptWindowSeconds:
      10
    case .releaseGraceSeconds, .stuckWindowMinutes:
      5
    case .pauseFirstMinutes, .pauseSecondMinutes, .keepAwakeFirstMinutes, .keepAwakeSecondMinutes:
      5
    case .longRunningLimitMinutes:
      15
    }
  }

  private func saveFolders(_ candidate: Settings) async -> SettingsCommitResult? {
    guard candidate != settings else { return nil }
    let result = await save(candidate)
    switch result {
    case .applied, .applyTimedOut, .saveFailed, nil:
      folderMessage = nil
    case .invalid(let error):
      folderMessage = error.message
    }
    return result
  }

  private func row(for path: String, isDefault: Bool, warnings: [DetectionWarning]) -> TranscriptFolderRow {
    TranscriptFolderRow(
      path: path, displayPath: PanelContent.abbreviatingHome(path, homeDirectory: homeDirectory), isDefault: isDefault,
      warning: DetectionPane.folderWarning(for: path, in: warnings))
  }

  static func folderPath(of url: URL) -> String {
    let path = url.standardizedFileURL.path(percentEncoded: false)
    guard path.count > 1, path.hasSuffix("/") else { return path }
    return String(path.dropLast())
  }

  private func serialized(
    _ work: @escaping @MainActor () async -> SettingsCommitResult?
  ) async -> SettingsCommitResult? {
    let previous = lastCommit
    let task = Task { @MainActor in
      _ = await previous?.value
      return await work()
    }
    lastCommit = task
    return await task.value
  }

  private func performCommit(_ field: SettingsField, text: String) async -> SettingsCommitResult? {
    switch SettingsEditor.validate(field, text: text, in: settings) {
    case .failure(let error):
      messages[field] = error.message
      return .invalid(error)
    case .success(let candidate):
      guard candidate != settings else {
        clearEdit(field)
        return nil
      }
      let result = await save(candidate)
      switch result {
      case .applied, .applyTimedOut:
        clearEdit(field)
      case .invalid(let error):
        messages[field] = error.message
      case .saveFailed, nil:
        messages[field] = nil
      }
      return result
    }
  }

  private func save(_ candidate: Settings) async -> SettingsCommitResult? {
    guard let host else { return nil }
    let result = await SettingsCommitter.commit(candidate, to: settingsFile, host: host)
    switch result {
    case .applied, .applyTimedOut:
      settings = candidate
      saveError = nil
    case .saveFailed:
      saveError = SettingsEditor.saveFailedMessage
      logError(Self.saveFailedDecision)
    case .invalid:
      break
    }
    return result
  }

  private func clearEdit(_ field: SettingsField) {
    if texts[field] != nil { texts[field] = nil }
    if messages[field] != nil { messages[field] = nil }
  }

  static func value(of field: SettingsField, in settings: Settings) -> Int {
    SettingsEditor.value(of: field, in: settings)
  }

  static func stepBounds(for field: SettingsField, in settings: Settings) -> ClosedRange<Int> {
    switch field {
    case .batteryLowPercent:
      Settings.batteryLowRange
    case .batteryResumePercent:
      min(settings.batteryLowPercent + 1, Settings.batteryResumeMax)...Settings.batteryResumeMax
    case .transcriptWindowSeconds:
      Int(Settings.transcriptWindowRange.lowerBound)...Int(Settings.transcriptWindowRange.upperBound)
    case .releaseGraceSeconds:
      Int(Settings.releaseGraceRange.lowerBound)...Int(Settings.releaseGraceRange.upperBound)
    case .stuckWindowMinutes:
      Int(Settings.stuckWindowMinSeconds / 60)...Int(Settings.stuckWindowMaxSeconds / 60)
    case .helperBatteryFloorPercent:
      Settings.helperBatteryFloorRange
    case .temperatureReleaseCelsius:
      Settings.temperatureReleaseRange
    case .pauseFirstMinutes, .pauseSecondMinutes, .keepAwakeFirstMinutes, .keepAwakeSecondMinutes:
      Settings.presetMinutesRange
    case .longRunningLimitMinutes:
      Settings.longRunningLimitRange
    }
  }
}
