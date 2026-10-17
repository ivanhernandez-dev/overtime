import Foundation
import Observation
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import OvertimeSystem

@Observable
final class OnboardingModel {
  let panel: PanelModel
  let preferencesFile: URL
  private(set) var steps: [OnboardingStep]
  private(set) var index = 0
  private(set) var results: [OnboardingStep: OnboardingStepResult] = [:]
  private(set) var isActive = false
  private(set) var selfTestRecord: SelfTestRecord?
  private(set) var requestingSelfTest = false
  private(set) var selfTestRequested = false
  @ObservationIgnored private var selfTestEngine: UUID?
  private(set) var notificationAuthorization: NotificationAuthorization?
  private(set) var locationStatus: LocationAuthorization?
  private(set) var stepChanges = 0
  var inFlight: OnboardingInFlight?
  var helper: HelperPaneModel?
  private(set) var screenLockRow: CheckRow?
  private(set) var hotspotRow: CheckRow?

  @ObservationIgnored var logError: (Decision) -> Void = { _ in }
  @ObservationIgnored var onClose: () -> Void = {}
  @ObservationIgnored var onFinish: () -> Void = {}
  @ObservationIgnored var readScreenLock: (@Sendable () -> ScreenLockStatus)?
  @ObservationIgnored var wifi: (any WiFiInfoPort)?
  @ObservationIgnored var checksTimeoutSeconds = Timing.systemCallTimeoutSeconds
  @ObservationIgnored private var readingScreenLock = false
  @ObservationIgnored private var readingNetworks = false
  @ObservationIgnored private var windowVisible = false
  @ObservationIgnored private let checksRunner = DeadlineRunner()
  @ObservationIgnored var notifications: (any NotificationPort)?
  @ObservationIgnored var location: (any LocationStatusPort)?
  @ObservationIgnored var makeLocation: (() -> (any LocationStatusPort)?)?
  @ObservationIgnored var openURL: (URL) -> Void = { _ in }
  @ObservationIgnored var authorizationWaitSeconds = Timing.systemCallTimeoutSeconds
  @ObservationIgnored private var authorizationAnswers = 0
  @ObservationIgnored private var flight = 0

  static let writeFailedDecision = Decision(keyword: .error, verb: "onboarding record write failed")

  init(panel: PanelModel, preferencesFile: URL) {
    self.panel = panel
    self.preferencesFile = preferencesFile
    steps = OnboardingStep.allCases
  }

  func begin() {
    guard !(isActive && context.actionInFlight) else { return }
    index = 0
    steps = OnboardingStep.allCases
    results = [:]
    selfTestRequested = false
    selfTestEngine = nil
    inFlight = nil
    isActive = true
    stepChanges += 1
    syncHelperVisibility()
  }

  var currentStep: OnboardingStep {
    steps[index]
  }

  var context: OnboardingContext {
    OnboardingContext(
      notifications: notificationAuthorization, location: locationStatus, loginItem: panel.loginItemStatus,
      helperInstalled: helperInstalled, inFlight: shownInFlight,
      selfTest: currentStep == .selfTest ? shownSelfTest : .notRun)
  }

  var stepBody: String {
    OnboardingFlow.body(step: currentStep, context: context)
  }

  var progressLabel: String {
    OnboardingFlow.progressLabel(step: currentStep, in: steps)
  }

  var progressAccessibilityLabel: String {
    OnboardingFlow.accessibilityLabel(step: currentStep, in: steps)
  }

  var dots: [OnboardingDot] {
    OnboardingFlow.dots(current: currentStep, in: steps)
  }

  var showsBack: Bool {
    OnboardingFlow.showsBack(step: currentStep, in: steps)
  }

  var backEnabled: Bool {
    OnboardingFlow.backEnabled(context: context)
  }

  var showsSkip: Bool {
    OnboardingFlow.skipAllowed(step: currentStep, context: context)
  }

  var skipEnabled: Bool {
    OnboardingFlow.skipEnabled(context: context)
  }

  var defaultButton: OnboardingButton {
    OnboardingFlow.defaultButton(step: currentStep, context: context)
  }

  func performDefault() {
    let button = defaultButton
    guard isActive, button.enabled else { return }
    switch button.action {
    case .advance:
      continueStep()
    case .finish:
      finish()
    case .allowNotifications:
      allowNotifications()
    case .allowLocation:
      allowLocation()
    }
  }

  var helperInstalled: Bool? {
    helper?.state.installer?.isInstalled
  }

  var shownInFlight: OnboardingInFlight? {
    inFlight ?? (helper?.state.inFlight == .installing ? .install : nil)
  }

  var helperRowActions: [HelperStatusAction] {
    helper?.uiState?.actions ?? []
  }

  func setWindowVisible(_ visible: Bool) {
    windowVisible = visible
    syncHelperVisibility()
  }

  private func syncHelperVisibility() {
    let shown = isActive && windowVisible && currentStep == .unplugProtection
    helper?.setVisible(shown, host: ObjectIdentifier(self))
  }

  func continueStep() {
    guard isActive, index < steps.count - 1 else { return }
    results[currentStep] = .done
    move(to: index + 1)
  }

  func skipStep() {
    guard isActive, index < steps.count - 1, showsSkip, skipEnabled else { return }
    results[currentStep] = .skipped
    move(to: index + 1)
  }

  func back() {
    guard isActive, showsBack, backEnabled else { return }
    move(to: index - 1)
  }

  func finish() {
    guard isActive, index == steps.count - 1, defaultButton.enabled else { return }
    results[currentStep] = .done
    isActive = false
    write(.completed)
    onClose()
    onFinish()
  }

  func dismissed() {
    guard isActive else { return }
    isActive = false
    syncHelperVisibility()
    write(.dismissed)
  }

  func close() {
    onClose()
  }

  var notificationRow: NotificationStatusRow? {
    notificationAuthorization.map { NotificationStatusRow.for($0) }
  }

  var locationRow: LocationRow? {
    locationStatus.map { LocationRow.for($0) }
  }

  func openNotificationSettings() {
    openURL(SystemSettingsLinks.notifications)
  }

  func openLocationServices() {
    openURL(SystemSettingsLinks.locationServices)
  }

  func refreshStep() {
    guard isActive else { return }
    readStepStatus()
  }

  @discardableResult
  func readNotificationAuthorization() -> Task<Void, Never>? {
    guard let notifications else { return nil }
    let answers = authorizationAnswers
    return Task { [weak self] in
      let status = await NotificationCoordinator.authorization(of: notifications)
      guard let self, let status, answers == self.authorizationAnswers else { return }
      if self.notificationAuthorization != status { self.notificationAuthorization = status }
    }
  }

  func refreshLocationStatus() {
    guard let location else { return }
    let status = location.status()
    if locationStatus != status { locationStatus = status }
    if status != .notDetermined, currentStep == .location { endFlight(flight) }
  }

  private func allowNotifications() {
    guard let notifications else { return }
    let started = startFlight()
    let seconds = authorizationWaitSeconds
    Task { [weak self] in
      _ = await Engine.bounded(seconds: seconds) { [weak self] in
        let status = await notifications.requestAuthorization()
        await self?.applyRequested(status)
      }
      self?.endFlight(started)
    }
  }

  private func applyRequested(_ status: NotificationAuthorization) {
    authorizationAnswers += 1
    if notificationAuthorization != status { notificationAuthorization = status }
  }

  private func allowLocation() {
    guard let location else { return }
    let started = startFlight()
    let seconds = authorizationWaitSeconds
    location.request()
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(seconds))
      self?.endFlight(started)
    }
  }

  private func startFlight() -> Int {
    flight += 1
    inFlight = .authorization
    return flight
  }

  private func endFlight(_ ended: Int) {
    guard ended == flight, inFlight == .authorization else { return }
    inFlight = nil
  }

  var checkRows: [CheckRow] {
    [screenLockRow, hotspotRow, OnboardingChecks.askToJoin].compactMap { $0 }
  }

  var systemSleep: SystemSleepCheck {
    guard let helper else { return .nothing }
    return OnboardingChecks.systemSleep(
      sleepDisabled: helper.sleepDisabled,
      helperOwns: helper.state.installer == nil ? nil : helper.helperOwnsSleepDisabled)
  }

  func open(_ link: CheckRow.Link) {
    openURL(link.url)
  }

  private func readChecks() {
    let runner = checksRunner
    let seconds = checksTimeoutSeconds
    if let read = readScreenLock, !readingScreenLock {
      readingScreenLock = true
      Task { [weak self] in
        let outcome = await runner.perform(timeout: seconds, read)
        self?.applyScreenLock(outcome)
      }
    }
    if let wifi, !readingNetworks {
      readingNetworks = true
      Task { [weak self] in
        let outcome = await runner.perform(timeout: seconds) { wifi.knownNetworkNames() }
        self?.applyKnownNetworks(outcome)
      }
    }
  }

  private func applyScreenLock(_ outcome: DeadlineRunner.Outcome<ScreenLockStatus>) {
    readingScreenLock = false
    let status: ScreenLockStatus = if case .value(let read) = outcome { read } else { .unknown }
    let row = OnboardingChecks.screenLock(status)
    if screenLockRow != row { screenLockRow = row }
  }

  private func applyKnownNetworks(_ outcome: DeadlineRunner.Outcome<[String]?>) {
    readingNetworks = false
    let names: [String]? = if case .value(let read) = outcome { read } else { nil }
    let row = OnboardingChecks.hotspot(knownNetworks: names)
    if hotspotRow != row { hotspotRow = row }
  }

  var shownSelfTest: SelfTestStatus {
    OnboardingFlow.shownSelfTest(status: panel.snapshot?.selfTest ?? .notRun, requesting: requestingSelfTest)
  }

  var selfTestRow: SelfTestRow {
    OnboardingFlow.selfTestRow(status: shownSelfTest, record: selfTestRecord, currentBuild: panel.snapshot?.osBuild)
  }

  var selfTestNote: String? {
    if case .failed = shownSelfTest { return OnboardingFlow.selfTestFailedCaption }
    return nil
  }

  var canStartSelfTest: Bool {
    isActive && currentStep == .selfTest && !selfTestRequested
      && SelfTestPresentation.runButtonEnabled(snapshot: panel.snapshot)
  }

  @discardableResult
  func startSelfTestIfDue() -> Task<Void, Never>? {
    guard canStartSelfTest, let host = panel.host else { return nil }
    selfTestRequested = true
    selfTestEngine = host.engineToken
    requestingSelfTest = true
    return Task { [weak self] in
      await host.requestSelfTest()
      self?.requestingSelfTest = false
    }
  }

  private func forgetASelfTestOfAnEarlierEngine() {
    guard let asked = selfTestEngine, let host = panel.host, host.engineToken != asked else { return }
    selfTestEngine = nil
    selfTestRequested = false
  }

  func reloadSelfTestRecord() {
    let stored = AppPreferencesStore.read(at: preferencesFile).preferences.selfTest
    if selfTestRecord != stored { selfTestRecord = stored }
  }

  private func move(to target: Int) {
    index = target
    stepChanges += 1
    syncHelperVisibility()
    if currentStep == .checks { readChecks() }
    readStepStatus()
  }

  private func readStepStatus() {
    switch currentStep {
    case .launchAtLogin:
      panel.refreshLoginItem()
    case .notifications:
      readNotificationAuthorization()
    case .location:
      if location == nil { location = makeLocation?() }
      refreshLocationStatus()
    case .selfTest:
      forgetASelfTestOfAnEarlierEngine()
      reloadSelfTestRecord()
      startSelfTestIfDue()
    case .checks:
      helper?.readSleepDisabledOnce()
    case .welcome, .unplugProtection:
      break
    }
  }

  private func write(_ outcome: OnboardingOutcome) {
    let record: OnboardingRecord = OnboardingFlow.record(outcome: outcome, results: results, at: panel.clock.wall())
    do {
      try AppPreferencesStore.update(at: preferencesFile) { $0.onboarding = record }
    } catch {
      logError(Self.writeFailedDecision)
    }
  }
}
