import AppKit
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import OvertimeHelperClient
import OvertimeSystem
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
  private(set) static weak var shared: AppDelegate?

  let model = PanelModel()
  private(set) var appHost: AppHost?
  private var statusItem: StatusItemController?
  private var menuBarPanel: MenuBarPanelController?
  private var reopenWindow: AuxiliaryWindowController?
  private var settingsPresenter: SettingsPresenter?
  private var sharedSettingsModel: SettingsModel?
  private var onboardingPresenter: OnboardingPresenter?
  private var notificationAdapter: UserNotificationsAdapter?
  private var notificationCoordinator: NotificationCoordinator?
  private(set) var automation: AutomationResponder?
  private var selfTestRecorder: SelfTestRecorder?
  private var helperMonitor: HelperMonitor?
  private(set) var helperPane: HelperPaneModel?
  private var locationReader: LocationStatusReader?
  private var networkPort: LiveNetworkPort?
  private let locationGrant = LocationGrant()
  private var suddenTerminationDisabled = false
  private var lifecycle: TerminationLifecycle?
  private var updater: SparkleUpdater?
  private(set) var uninstallModel: UninstallModel?
  private var terminationSignal: (any DispatchSourceSignal)?
  private let adminPromptCancellation = ToolCancellation()
  private let uninstallPromptCancellation = ToolCancellation()
  private let stagedForQuit = OSAllocatedUnfairLock(initialState: false)
  private let launchWall = Date()

  var composedHost: Bool {
    appHost != nil
  }

  override init() {
    super.init()
    Self.shared = self
  }

  var notificationsAttached: Bool {
    notificationAdapter != nil || notificationCoordinator != nil
  }

  var selfTestRecorderAttached: Bool {
    selfTestRecorder != nil
  }

  var helperMonitorAttached: Bool {
    helperMonitor != nil
  }

  var networkPortAttached: Bool {
    networkPort != nil
  }

  var updaterAttached: Bool {
    updater != nil
  }

  var updaterPort: (any UpdaterPort)? {
    updater
  }

  static var isDebugBuild: Bool {
    #if DEBUG
      true
    #else
      false
    #endif
  }

  static func updaterHost(for mode: AppMode) -> UpdaterHost {
    switch mode {
    case .testHost:
      .testHost
    case .blocked:
      .blocked
    case .live:
      .live
    }
  }

  static func buildsMenuBar(for mode: AppMode) -> Bool {
    switch mode {
    case .testHost:
      false
    case .blocked, .live:
      true
    }
  }

  var menuBarAttached: Bool {
    statusItem != nil || menuBarPanel != nil
  }

  private func startMenuBar() {
    guard Self.buildsMenuBar(for: AppMode.current), !menuBarAttached else { return }
    let panel = MenuBarPanelController(
      model: model, anchor: { [weak self] in self?.statusItem?.anchorFrame },
      setHighlighted: { [weak self] highlighted in self?.statusItem?.setHighlighted(highlighted) })
    menuBarPanel = panel
    statusItem = StatusItemController(model: model) { [weak panel] button, seconds, clicked in
      panel?.send(.itemClick(button), at: seconds, clicked: clicked)
    }
  }

  private func startUpdater() {
    let host = Self.updaterHost(for: AppMode.current)
    guard UpdaterBuildPolicy.buildsUpdater(host: host, debugBuild: Self.isDebugBuild), updater == nil else { return }
    let updater = SparkleUpdater(
      refuseChecks: { [weak self] in
        (terminating: self?.lifecycle?.isTerminating ?? false, uninstalling: self?.uninstallModel?.isActive ?? false)
      },
      removeStagedUpdate: { [weak self] in self?.uninstallModel?.removeStagedUpdate(at: .installOnQuit) })
    self.updater = updater
    updater.onChange = { [weak self] in self?.updaterChanged() }
    Self.wireUpdateReview(panel: model, updater: updater, activate: { NSApp.activate() })
    updater.start()
  }

  func updaterChanged() {
    Self.mirrorStagedForQuit(from: updaterPort, into: stagedForQuit)
    Self.refreshAfterUpdaterChange(about: settingsModel?.about, panel: model, updater: updaterPort)
  }

  static func mirrorStagedForQuit(from updater: (any UpdaterPort)?, into mirror: OSAllocatedUnfairLock<Bool>) {
    let staged = updater?.reminder.stagedForQuit ?? false
    mirror.withLock { $0 = staged }
  }

  static func refreshAfterUpdaterChange(
    about: AboutModel?, panel: PanelModel? = nil, updater: (any UpdaterPort)? = nil
  ) {
    about?.refresh()
    guard let panel else { return }
    let waiting = updater?.reminder.isWaiting ?? false
    if panel.updateWaiting != waiting { panel.updateWaiting = waiting }
  }

  static func wireUpdateReview(panel: PanelModel, updater: any UpdaterPort, activate: @escaping () -> Void) {
    panel.onReviewUpdate = { [weak updater] in
      guard let updater else { return }
      activate()
      updater.checkForUpdates()
    }
  }

  static func aboutModel(updater: (any UpdaterPort)?) -> AboutModel {
    AboutModel(
      mode: AboutModel.mode(isDebugBuild: isDebugBuild, host: updaterHost(for: AppMode.current), updater: updater),
      readLicense: { bundledText("LICENSE") },
      readNotice: { bundledText("NOTICE") },
      activate: { NSApp.activate() },
      openURL: { url in NSWorkspace.shared.open(url) })
  }

  static func bundledText(_ name: String) -> String? {
    guard let url = Bundle.main.url(forResource: name, withExtension: nil) else { return nil }
    return try? String(contentsOf: url, encoding: .utf8)
  }

  var onboardingModel: OnboardingModel? {
    onboardingPresenter?.model
  }

  static func armOnboarding(_ presenter: OnboardingPresenter, preferencesFile: URL) {
    presenter.arm(firstRun: OnboardingFlow.shouldOpen(record: OnboardingFlow.recordState(at: preferencesFile)))
  }

  @discardableResult
  static func openOnboardingAtLaunch(
    _ presenter: OnboardingPresenter, preferencesFile: URL, registerLoginItem: () -> Void
  ) -> Bool {
    armOnboarding(presenter, preferencesFile: preferencesFile)
    registerLoginItem()
    return presenter.openIfArmed()
  }

  static func runOnboardingAgain(_ presenter: OnboardingPresenter) {
    presenter.show()
  }

  private func onboarding(preferencesFile: URL, host: AppHost?) -> OnboardingPresenter {
    if let onboardingPresenter { return onboardingPresenter }
    let onboarding = OnboardingModel(panel: model, preferencesFile: preferencesFile)
    onboarding.logError = { decision in Self.logSettingsError(decision, host: host) }
    onboarding.notifications = notificationAdapter
    onboarding.makeLocation = { [weak self] in self?.sharedLocationReader() }
    onboarding.makeSettings = { [weak self] in self?.onboardingSettingsModel() }
    onboarding.openURL = { url in NSWorkspace.shared.open(url) }
    onboarding.readScreenLock = { ScreenLockReader.read(tools: ToolRunner()) }
    onboarding.wifi = CoreWLANInfo()
    onboarding.helper = helperPane
    onboarding.onFinish = { [weak self] in self?.showMenuBarPanelAfterOnboarding() }
    let presenter = OnboardingPresenter(model: onboarding)
    onboardingPresenter = presenter
    return presenter
  }

  private func showMenuBarPanelAfterOnboarding() {
    Task { @MainActor [weak self] in
      self?.menuBarPanel?.show(at: ProcessInfo.processInfo.systemUptime)
    }
  }

  func showOnboarding() {
    guard !AppMode.current.isTestHost else { return }
    let paths =
      appHost?.paths
      ?? AppPaths.primary(
        environment: ProcessInfo.processInfo.environment, homeDirectory: NSHomeDirectory())
    Self.runOnboardingAgain(onboarding(preferencesFile: paths.preferencesFile, host: appHost))
  }

  static func beginLaunchSelfTest(on host: any EngineHosting, recorder: SelfTestRecorder) async {
    recorder.start(host: host)
    await host.requestSelfTest()
  }

  private func startSelfTest(engineHost: LiveEngineHost, host: AppHost) {
    let recorder = SelfTestRecorder(
      preferencesFile: host.paths.preferencesFile,
      log: { decision in Self.logSettingsError(decision, host: host) },
      onRecord: { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.settingsModel?.reloadPreferences()
          self?.onboardingModel?.reloadSelfTestRecord()
        }
      })
    selfTestRecorder = recorder
    Task { await Self.beginLaunchSelfTest(on: engineHost, recorder: recorder) }
  }

  func applicationWillFinishLaunching(_ notification: Notification) {
    installAutomation(for: AppMode.current)
    guard case .live = AppMode.current else { return }
    let adapter = UserNotificationsAdapter()
    adapter.responder = NotificationResponder(
      host: { [weak self] in self?.model.host },
      onOpenSettings: { [weak self] pane in self?.showSettings(pane: pane) })
    adapter.attach()
    notificationAdapter = adapter
  }

  static func awaitsEngine(for mode: AppMode) -> Bool {
    if case .live = mode { return true }
    return false
  }

  private func installAutomation(for mode: AppMode) {
    guard !mode.isTestHost, automation == nil else { return }
    automation = AutomationResponder(
      model: model, awaitingEngine: Self.awaitsEngine(for: mode),
      log: { [weak self] decision in Self.logAutomation(decision, host: self?.appHost) })
    NSAppleEventManager.shared().setEventHandler(
      self, andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
      forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
  }

  @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
    let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue ?? ""
    automation?.enqueue(text)
  }

  private func startNotifications(engineHost: LiveEngineHost, host: AppHost) {
    guard let adapter = notificationAdapter else { return }
    let preferencesFile = host.paths.preferencesFile
    let coordinator = NotificationCoordinator(
      port: adapter,
      preferences: { AppPreferencesStore.read(at: preferencesFile).preferences },
      log: { decision in Self.logNotification(decision, host: host) },
      relaunchHistory: host.paths.relaunchHistory, launchWall: launchWall)
    notificationCoordinator = coordinator
    coordinator.start(host: engineHost)
  }

  @discardableResult
  static func bindRestarted(
    _ engineHost: any EngineHosting, notifications: NotificationCoordinator?, recorder: SelfTestRecorder?,
    helper: HelperMonitor?
  ) -> Task<Void, Never>? {
    notifications?.rebind(to: engineHost)
    recorder?.start(host: engineHost)
    helper?.start(host: engineHost)
    guard recorder != nil else { return nil }
    return Task { await engineHost.requestSelfTest() }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    switch AppMode.current {
    case .testHost:
      return
    case .blocked(let failure):
      startMenuBar()
      model.hostFailure = failure
      model.emergency = blockedEmergency()
      attachSettings()
      attachSleepDisabledReader()
    case .live(let locks):
      startMenuBar()
      startHosting(locks: locks)
      startUpdater()
    }
  }

  var settingsModel: SettingsModel? {
    sharedSettingsModel
  }

  private func attachSettings() {
    model.onOpenSettings = { [weak self] pane in
      self?.showSettings(pane: pane)
    }
    model.onSetKeepDisplayOn = { [weak self] enabled in await self?.commitKeepDisplayOn(enabled) }
  }

  func showSettings(pane: SettingsPane? = nil) {
    guard !AppMode.current.isTestHost else { return }
    if settingsPresenter == nil {
      settingsPresenter = SettingsPresenter(model: makeSettingsModel())
    }
    syncSettingsHost()
    settingsPresenter?.show(pane: pane)
  }

  private func makeSettingsModel() -> SettingsModel {
    if let sharedSettingsModel { return sharedSettingsModel }
    let host = appHost
    let paths =
      host?.paths
      ?? AppPaths.primary(
        environment: ProcessInfo.processInfo.environment, homeDirectory: NSHomeDirectory())
    let location = sharedLocationReader()
    let settingsModel = SettingsModel(
      settingsFile: paths.settingsFile, folderPicker: AppKitFolderPicker(), wifi: CoreWLANInfo(),
      location: location, panel: model, preferencesFile: paths.preferencesFile, notifications: notificationAdapter,
      helper: helperPane)
    settingsModel.logError = { decision in Self.logSettingsError(decision, host: host) }
    settingsModel.openURL = { url in NSWorkspace.shared.open(url) }
    settingsModel.about = Self.aboutModel(updater: updaterPort)
    settingsModel.about.uninstall = makeUninstallModel()
    settingsModel.onPreferencesChanged = { [weak self] in
      self?.notificationCoordinator?.preferencesChanged()
    }
    settingsModel.onRunOnboarding = { [weak self] in
      self?.showOnboarding()
    }
    settingsModel.diagnostics.savePanel = AppKitSavePanel()
    settingsModel.diagnostics.logsDirectory = paths.logsDirectory
    settingsModel.diagnostics.reveal = { urls in NSWorkspace.shared.activateFileViewerSelecting(urls) }
    settingsModel.diagnostics.makeExporter = { inputs in
      DiagnosticsExporter(
        paths: paths, tools: ToolRunner(), inputs: inputs, clock: SystemClock(),
        helperLogDirectory: SMAppServiceDaemon.identity.logDirectory,
        log: { decision in Self.logSettingsError(decision, host: host) })
    }
    sharedSettingsModel = settingsModel
    return settingsModel
  }

  private func onboardingSettingsModel() -> SettingsModel? {
    guard !AppMode.current.isTestHost else { return nil }
    let settings = makeSettingsModel()
    syncSettingsHost()
    return settings
  }

  private func commitKeepDisplayOn(_ enabled: Bool) async -> SettingsCommitResult? {
    guard !AppMode.current.isTestHost else { return nil }
    let settings = makeSettingsModel()
    syncSettingsHost()
    return await settings.setKeepDisplayOn(enabled)
  }

  nonisolated private static let uninstallLogger = Logger(subsystem: FileLogger.logSubsystem, category: "uninstall")

  private func makeUninstallModel() -> UninstallModel? {
    if let uninstallModel { return uninstallModel }
    guard !AppMode.current.isTestHost else { return nil }
    let table = Entry.uninstallTable
    let cancellation = adminPromptCancellation
    let uninstallCancellation = uninstallPromptCancellation
    let staged = stagedForQuit
    let system = LiveUninstallSystem.app(
      table: table, identity: SMAppServiceDaemon.identity,
      stop: { [weak self] in await self?.stopForUninstall() ?? .notRunning },
      staged: { staged.withLock { $0 } }, cancellation: uninstallCancellation)
    let coordinator = UninstallCoordinator(
      system: system, table: table, mode: .app,
      log: { decision in
        let line = DecisionFormatter.line(decision, wall: Date(), timeZone: .current)
        Self.uninstallLogger.notice("\(line, privacy: .public)")
      })
    let uninstall = UninstallModel(
      coordinator: coordinator, table: table, helperStatus: { system.helperStatus() }, panel: model,
      quit: { NSApp.terminate(nil) },
      openLoginItems: { SMAppServiceLoginItem().openSystemSettings() },
      revealApp: { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) },
      readSleepDisabled: { SleepDisabledReader.read(tools: ToolRunner()) },
      adminPrompt: AppleScriptAdminPrompt(cancellation: cancellation),
      copyToPasteboard: PanelModel.writeToGeneralPasteboard,
      cancelAdminPrompt: { uninstallCancellation.cancel() })
    uninstallModel = uninstall
    return uninstall
  }

  private func stopForUninstall() async -> UninstallEngineStop {
    guard let host = appHost else { return .notRunning }
    let wasRunning = host.runningHost != nil
    let stopped = await host.terminate()
    helperMonitor?.stop()
    guard wasRunning else { return .notRunning }
    return stopped ? .stopped : .unconfirmed
  }

  private func sharedLocationReader() -> LocationStatusReader {
    if let locationReader { return locationReader }
    let reader = LocationStatusReader()
    reader.onChange = { [weak self] status in
      self?.locationGrant.set(status == .authorized)
      self?.settingsModel?.refreshLocationStatus()
      self?.model.refreshLocationStatus()
      self?.onboardingModel?.refreshLocationStatus()
    }
    locationReader = reader
    return reader
  }

  private func attachAttention(host: AppHost) {
    let settingsFile = host.paths.settingsFile
    model.notifications = notificationAdapter
    model.makeLocation = { [weak self] in self?.sharedLocationReader() }
    model.readHotspotChoice = {
      HotspotChoice(settings: AppHost.loadSettings(from: settingsFile).settings, knownNetworks: nil)
    }
  }

  private func syncSettingsHost() {
    settingsModel?.host = model.host
  }

  private func blockedEmergency() -> EmergencyCoordinator {
    let environment = ProcessInfo.processInfo.environment
    let homeDirectory = NSHomeDirectory()
    let primary = AppPaths.primary(environment: environment, homeDirectory: homeDirectory)
    let secondary = AppPaths.secondary(environment: environment, homeDirectory: homeDirectory)
    let sockets = [primary, secondary].compactMap { $0?.controlSocket(.live) }
    return AppHost.makeEmergencyCoordinator(
      host: { nil }, fallbackSockets: sockets, helperClear: Self.emergencyHelperClear())
  }

  private static func emergencyHelperClear() -> @Sendable () -> Bool {
    let identity = SMAppServiceDaemon.identity
    return AppHost.emergencyHelperClear(installer: SMAppServiceDaemon(identity: identity)) {
      HelperXPCClient.privileged(identity: identity)
    }
  }

  private func attachSleepDisabledReader() {
    model.readSleepDisabled = { SleepDisabledReader.read(tools: ToolRunner()) }
    model.adminPrompt = AppleScriptAdminPrompt(cancellation: adminPromptCancellation)
    model.refreshSleepDisabled()
  }

  private func startHosting(locks: HeldLocks) {
    let environment = ProcessInfo.processInfo.environment
    let homeDirectory = NSHomeDirectory()
    let helperPort = XPCHelperPort.privileged(identity: SMAppServiceDaemon.identity)
    let paths = AppPaths.primary(environment: environment, homeDirectory: homeDirectory)
    locationGrant.set(sharedLocationReader().status() == .authorized)
    let network = LiveNetworkPort.system(paths: paths, location: locationGrant)
    network.start()
    networkPort = network
    let host = AppHost(
      paths: paths,
      version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
      environment: environment,
      homeDirectory: homeDirectory,
      wifi: CoreWLANInfo(),
      helper: helperPort,
      network: network
    )
    appHost = host
    let helper = HelperPaneModel.monitored(
      panel: model, installer: SMAppServiceDaemon(), port: helperPort,
      log: { decision in Self.logSettingsError(decision, host: host) })
    helper.pane.readSleepDisabled = { SleepDisabledReader.read(tools: ToolRunner()) }
    helper.pane.adminPrompt = AppleScriptAdminPrompt(cancellation: adminPromptCancellation)
    helperMonitor = helper.monitor
    helperPane = helper.pane
    model.emergency = AppHost.makeEmergencyCoordinator(
      host: { host.runningHost }, helperClear: Self.emergencyHelperClear())
    model.logLoginItemError = { message in Self.logLoginItemError(message, host: host) }
    attachSettings()
    attachAttention(host: host)
    model.attachLoginItem(SMAppServiceLoginItem())
    attachSleepDisabledReader()
    ProcessInfo.processInfo.disableSuddenTermination()
    suddenTerminationDisabled = true
    let lifecycle = TerminationLifecycle(
      host: host,
      prepare: { [weak self] in await self?.settleForQuit() },
      onFinished: { [weak self] in self?.releaseSuddenTermination() })
    self.lifecycle = lifecycle
    lifecycle.observePowerOff()
    installTerminationSignal()
    let start = host.beginStart(locks: locks)
    Task {
      switch await start.value {
      case .running(let engineHost):
        model.bind(to: engineHost)
        automation?.engineStarted()
        syncSettingsHost()
        startNotifications(engineHost: engineHost, host: host)
        Self.openOnboardingAtLaunch(
          onboarding(preferencesFile: host.paths.preferencesFile, host: host),
          preferencesFile: host.paths.preferencesFile,
          registerLoginItem: { [weak self] in self?.applyFirstRunLogin(host: host) })
        startSelfTest(engineHost: engineHost, host: host)
        helperMonitor?.start(host: engineHost)
      case .blocked(let failure):
        model.hostFailure = failure
        automation?.engineFailed()
      }
    }
  }

  private func applyFirstRunLogin(host: AppHost) {
    guard let service = model.loginItem?.service else { return }
    FirstRunLogin.apply(
      service: service, recordURL: host.paths.loginItemRecord, now: Date(), log: model.logLoginItemError)
    model.refreshLoginItem()
  }

  nonisolated private static func logLoginItemError(_ message: String, host: AppHost) {
    let decision = Decision(
      keyword: .error, verb: "login item failed", fields: [DecisionField(key: "reason", value: message)])
    if let running = host.runningHost {
      running.engine.logImmediately(decision)
    } else {
      let line = DecisionFormatter.line(decision, wall: Date(), timeZone: .current)
      loginItemLogger.error("\(line, privacy: .public)")
    }
  }

  nonisolated private static let loginItemLogger = Logger(subsystem: FileLogger.logSubsystem, category: "login")

  nonisolated private static let settingsLogger = Logger(subsystem: FileLogger.logSubsystem, category: "settings")

  nonisolated private static func logSettingsError(_ decision: Decision, host: AppHost?) {
    if let running = host?.runningHost {
      running.engine.logImmediately(decision)
    } else {
      let line = DecisionFormatter.line(decision, wall: Date(), timeZone: .current)
      settingsLogger.error("\(line, privacy: .public)")
    }
  }

  nonisolated private static let automationLogger = Logger(subsystem: FileLogger.logSubsystem, category: "automation")

  nonisolated private static func logAutomation(_ decision: Decision, host: AppHost?) {
    if let running = host?.runningHost {
      running.engine.logImmediately(decision)
    } else {
      let line = DecisionFormatter.line(decision, wall: Date(), timeZone: .current)
      automationLogger.notice("\(line, privacy: .public)")
    }
  }

  nonisolated private static let notificationLogger = Logger(
    subsystem: FileLogger.logSubsystem, category: "notifications")

  nonisolated private static func logNotification(_ decision: Decision, host: AppHost) {
    if let running = host.runningHost {
      running.engine.logImmediately(decision)
    } else {
      let line = DecisionFormatter.line(decision, wall: Date(), timeZone: .current)
      notificationLogger.notice("\(line, privacy: .public)")
    }
  }

  private func settleForQuit() async {
    uninstallModel?.requestStopForQuit()
    adminPromptCancellation.cancel()
    await uninstallModel?.settleForQuit(forced: { [weak self] in self?.lifecycle?.logoutPending == true })
  }

  private func releaseSuddenTermination() {
    guard suddenTerminationDisabled else { return }
    suddenTerminationDisabled = false
    ProcessInfo.processInfo.enableSuddenTermination()
  }

  private func installTerminationSignal() {
    signal(SIGTERM, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    source.setEventHandler {
      MainActor.assumeIsolated {
        NSApp.terminate(nil)
      }
    }
    source.resume()
    terminationSignal = source
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let task = lifecycle?.begin() else { return .terminateNow }
    Task {
      await task.value
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  func applicationWillTerminate(_ notification: Notification) {
    uninstallModel?.removeStagedUpdate(at: .quit)
    uninstallModel?.purgePreferencesAtQuit()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    guard !AppMode.current.isTestHost else { return false }
    if reopenWindow == nil {
      reopenWindow = ReopenWindow.controller(model: model)
    }
    reopenWindow?.show()
    return false
  }
}
