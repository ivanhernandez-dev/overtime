import AppKit
import Foundation
import Observation
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import OvertimeSystem

@Observable
final class PanelModel {
  var snapshot: EngineSnapshot? {
    didSet { forgetTheHelpersAnswerAfterAHold(endedFrom: oldValue) }
  }
  var hostFailure: HostFailure? {
    didSet { dropStaleFailureNotice() }
  }
  var engineUnresponsive = false
  private(set) var visibleHosts: Set<ObjectIdentifier> = []
  var amphetamineInstalled = false
  var sleepDisabledLeftover = false
  private(set) var sleepConfirmation = SleepConfirmation()
  private(set) var restoreNotice: RestoreNotice?
  private(set) var clearingSleepDisabled = false
  private(set) var loginItem: LoginItemPanel?
  private(set) var loginItemStatus: LoginItemStatus?
  var helperReapprove = false
  var helperStale = false
  private(set) var helperState: HelperMonitorState?
  private(set) var helperAnsweredOwning = false
  private(set) var notificationAuthorization: NotificationAuthorization?
  private(set) var locationStatus: LocationAuthorization?
  private(set) var hotspotChoice: HotspotChoice = .none
  var updateWaiting = false
  var uninstalling = false

  @ObservationIgnored private(set) var host: (any EngineHosting)?
  @ObservationIgnored private var bindTask: Task<Void, Never>?
  @ObservationIgnored private var expiryTask: Task<Void, Never>?
  @ObservationIgnored var homeDirectory = NSHomeDirectory()
  @ObservationIgnored private var fallbackClock: any ClockPort = SystemClock()
  @ObservationIgnored var amphetamineLocator = AmphetamineLocator()
  @ObservationIgnored var emergency: EmergencyCoordinator?
  @ObservationIgnored var restoreResultSeconds = EmergencyCoordinator.resultSeconds
  @ObservationIgnored var controlNoticeSeconds = ControlFeedback.noticeSeconds
  @ObservationIgnored private var noticeTask: Task<Void, Never>?
  @ObservationIgnored private var noticeCount = 0
  @ObservationIgnored var livenessIntervalSeconds: Double = 5
  @ObservationIgnored private var livenessTask: Task<Void, Never>?
  @ObservationIgnored var copyToPasteboard: @MainActor (String) -> Void = PanelModel.writeToGeneralPasteboard
  @ObservationIgnored var readSleepDisabled: (@Sendable () -> Bool?)?
  @ObservationIgnored var adminPrompt: (any AdminPrompt)?
  @ObservationIgnored private var sleepDisabledTask: Task<Void, Never>?
  @ObservationIgnored var logLoginItemError: (String) -> Void = { _ in }
  @ObservationIgnored var onOpenSettings: (SettingsPane?) -> Void = { _ in }
  @ObservationIgnored var onReviewUpdate: () -> Void = {}
  @ObservationIgnored var onSetKeepDisplayOn: (@MainActor (Bool) async -> SettingsCommitResult?)?
  @ObservationIgnored var notifications: (any NotificationPort)?
  @ObservationIgnored var location: (any LocationStatusPort)?
  @ObservationIgnored var makeLocation: (() -> (any LocationStatusPort)?)?
  @ObservationIgnored var readHotspotChoice: (() -> HotspotChoice)?
  @ObservationIgnored private var attentionTask: Task<Void, Never>?

  var clock: any ClockPort {
    host?.clock ?? fallbackClock
  }

  var presentation: StatusPresentation {
    var result = derivedPresentation
    if let restoreNotice {
      result.reason = restoreNotice.copy
    }
    return result
  }

  private var derivedPresentation: StatusPresentation {
    StatusPresentation.derive(
      snapshot: snapshot, hostFailure: hostFailure, engineUnresponsive: engineUnresponsive, uninstalling: uninstalling)
  }

  func sessionList(atMono now: Instant) -> SessionList {
    PanelContent.sessions(
      snapshot?.sessions ?? [], busy: snapshot?.busy == true, now: now, homeDirectory: homeDirectory)
  }

  var sessionList: SessionList {
    sessionList(atMono: clock.mono())
  }

  var isPanelVisible: Bool {
    !visibleHosts.isEmpty
  }

  func setVisible(_ visible: Bool, host: ObjectIdentifier) {
    guard visibleHosts.contains(host) != visible else { return }
    if visible {
      visibleHosts.insert(host)
    } else {
      visibleHosts.remove(host)
    }
    updateLiveness()
  }

  private func updateLiveness() {
    guard isPanelVisible, host != nil else {
      livenessTask?.cancel()
      livenessTask = nil
      return
    }
    guard livenessTask == nil else { return }
    let interval = livenessIntervalSeconds
    livenessTask = Task { [weak self] in
      while !Task.isCancelled {
        await self?.probe()
        try? await Task.sleep(for: .seconds(interval))
      }
    }
  }

  func probe() async {
    guard let host else { return }
    let alive = await host.probe() != nil
    guard !Task.isCancelled else { return }
    setEngineUnresponsive(!alive)
  }

  private func setEngineUnresponsive(_ unresponsive: Bool) {
    guard engineUnresponsive != unresponsive else { return }
    engineUnresponsive = unresponsive
    dropStaleFailureNotice()
  }

  var statusLines: [StatusLine] {
    StatusLines.rows(for: snapshot)
  }

  var statusChips: StatusChipSummary {
    StatusChipSummary.make(for: snapshot)
  }

  var hints: [Hint] {
    let warned = snapshot?.coexistenceWarned == true
    return Hints.visible(
      HintInputs(
        sleepDisabledLeftover: sleepDisabledLeftover,
        amphetamineRunning: warned && snapshot?.amphetamineRunning == true,
        otherTools: warned ? snapshot?.otherTools ?? [] : [],
        amphetamineInstalled: amphetamineInstalled,
        keepAwakeWanted: Hints.keepAwakeWanted(presentation.state),
        helper: helperHint,
        helperOwnsSleepDisabled: helperOwnsSleepDisabled))
  }

  var helperShown: HelperUIState? {
    helperState.map { HelperStatusPresentation.derive($0, engaged: snapshot?.helperEngaged == true) }
  }

  var helperHint: HelperHintState {
    HelperHintState.derive(helperShown)
  }

  var helperOwnsSleepDisabled: Bool {
    snapshot?.helperEngaged == true || helperAnsweredOwning
  }

  func applyHelper(_ state: HelperMonitorState) {
    if helperState != state { helperState = state }
    let owning = state.status?.owns == true
    if helperAnsweredOwning != owning { helperAnsweredOwning = owning }
    let item = Attention.helperItem(for: helperShown)
    let reapprove = item == .helperReapprove
    let stale = item == .helperStale
    if helperReapprove != reapprove { helperReapprove = reapprove }
    if helperStale != stale { helperStale = stale }
  }

  private func forgetTheHelpersAnswerAfterAHold(endedFrom previous: EngineSnapshot?) {
    guard previous?.helperEngaged == true, snapshot?.helperEngaged != true, helperAnsweredOwning else { return }
    helperAnsweredOwning = false
  }

  func openSettings(_ pane: SettingsPane? = nil) {
    onOpenSettings(pane ?? (uninstalling ? .about : nil))
  }

  var selfTestFailed: Bool {
    snapshot?.selfTestErrorActive == true
  }

  var attentionInputs: AttentionInputs {
    var panelInErrorState = false
    if case .error = derivedPresentation.state {
      panelInErrorState = true
    }
    return AttentionInputs(
      selfTestFailed: selfTestFailed, detectionWarnings: snapshot?.detectionWarnings ?? [],
      helperReapprove: helperReapprove, helperStale: helperStale, loginItem: loginItemStatus,
      notifications: notificationAuthorization, location: locationStatus, hotspotChoice: hotspotChoice,
      panelInErrorState: panelInErrorState, updateWaiting: updateWaiting && !uninstalling)
  }

  var attentionItems: [AttentionItem] {
    Attention.items(attentionInputs, forPanel: true)
  }

  var attentionText: String? {
    Attention.panelText(attentionItems)
  }

  var showsUpdateRow: Bool {
    attentionItems == [.updateAvailable]
  }

  func reviewAttention() {
    guard let first = attentionItems.first else { return }
    openSettings(first.pane)
  }

  func reviewUpdate() {
    guard !uninstalling else { return }
    onReviewUpdate()
  }

  @discardableResult
  func refreshAttention() -> Task<Void, Never>? {
    if let readHotspotChoice {
      let choice = readHotspotChoice()
      if hotspotChoice != choice { hotspotChoice = choice }
    }
    refreshLocationStatus()
    guard let notifications, attentionTask == nil else { return attentionTask }
    let task = Task { [weak self] in
      let status = await NotificationCoordinator.authorization(of: notifications)
      guard let self else { return }
      self.attentionTask = nil
      if let status, self.notificationAuthorization != status {
        self.notificationAuthorization = status
      }
    }
    attentionTask = task
    return task
  }

  func refreshLocationStatus() {
    guard !hotspotChoice.isNone else { return }
    if location == nil {
      location = makeLocation?()
    }
    guard let location else { return }
    let status = location.status()
    if locationStatus != status { locationStatus = status }
  }

  func performHint(_ action: HintAction) {
    switch action {
    case .copyCommand:
      copyToPasteboard(Hints.sleepDisabledCommand)
    case .setUpUnplugProtection, .reviewUnplugProtection:
      openSettings(.unplugProtection)
    }
  }

  func applySleepDisabled(_ live: Bool?, readWhileHelperOwned: Bool = false) {
    if live == false, restoreNotice?.kind == .helperNotCleared {
      showRestoreNotice(kind: .restored, copy: EmergencyCoordinator.restoredCopy)
    }
    let leftover = live == true
    if leftover, readWhileHelperOwned || helperOwnsSleepDisabled { return }
    if sleepDisabledLeftover != leftover { sleepDisabledLeftover = leftover }
  }

  @discardableResult
  func refreshSleepDisabled() -> Task<Void, Never>? {
    guard let readSleepDisabled, sleepDisabledTask == nil else { return sleepDisabledTask }
    let owned = helperOwnsSleepDisabled
    let task = Task { [weak self] in
      let live = await Task.detached { readSleepDisabled() }.value
      self?.applySleepDisabled(live, readWhileHelperOwned: owned)
      self?.sleepDisabledTask = nil
    }
    sleepDisabledTask = task
    return task
  }

  static func writeToGeneralPasteboard(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }

  func refreshInstalledTools() {
    let installed = amphetamineLocator.isInstalled()
    if amphetamineInstalled != installed {
      amphetamineInstalled = installed
    }
  }

  func attachLoginItem(_ service: any LoginItemService) {
    loginItem = LoginItemPanel(service: service)
    refreshLoginItem()
  }

  func refreshLoginItem() {
    let status = loginItem?.service.status
    if loginItemStatus != status { loginItemStatus = status }
  }

  var launchAtLogin: Bool {
    loginItemStatus?.isOn ?? false
  }

  var loginItemCaption: LoginItemCaption? {
    guard let loginItemStatus else { return nil }
    return LoginItemCaption.for(status: loginItemStatus, lastError: loginItem?.lastError)
  }

  var showsLoginItemSection: Bool {
    loginItem != nil && loginItemCaption != nil
  }

  func setLaunchAtLogin(_ enabled: Bool) {
    guard var panel = loginItem else { return }
    panel.setEnabled(enabled, log: logLoginItemError)
    loginItem = panel
    refreshLoginItem()
  }

  func openLoginItems() {
    loginItem?.openSystemSettings()
  }

  func timingLine(atMono now: Instant, wall: Date) -> TimingLine? {
    TimingLine.line(for: presentation, snapshot: snapshot, nowMono: now, nowWall: wall)
  }

  var timingLine: TimingLine? {
    timingLine(atMono: clock.mono(), wall: clock.wall())
  }

  func awakeTime(atMono now: Instant, wall: Date) -> AwakeTime {
    AwakeTime.make(for: presentation, snapshot: snapshot, nowMono: now, nowWall: wall)
  }

  var awakeTime: AwakeTime {
    awakeTime(atMono: clock.mono(), wall: clock.wall())
  }

  var controls: ControlAvailability {
    ControlAvailability.from(presentation, snapshot: snapshot)
  }

  var keepDisplayOn: Bool {
    snapshot?.keepDisplayOn ?? false
  }

  var pauseChoices: [PauseChoice] {
    guard let snapshot else { return PauseChoice.defaultMenu }
    return PauseChoice.menu(timedMinutes: [snapshot.pauseFirstMinutes, snapshot.pauseSecondMinutes])
  }

  var keepAwakeChoices: [KeepAwakeChoice] {
    guard let snapshot else { return KeepAwakeChoice.defaultMenu }
    return KeepAwakeChoice.menu(timedMinutes: [snapshot.keepAwakeFirstMinutes, snapshot.keepAwakeSecondMinutes])
  }

  @discardableResult
  func perform(_ action: ControlAction) async -> CtlResponse? {
    guard controls.engineControlsEnabled else { return nil }
    guard let host else {
      showControlFailure(ControlFeedback.failureCopy(for: action))
      return nil
    }
    let request = ControlMapping.request(for: action, now: clock.wall(), calendar: Calendar.current)
    let response = await host.send(request)
    if ControlFeedback.failed(response) {
      showControlFailure(ControlFeedback.failureCopy(for: action))
    }
    await probe()
    return response
  }

  func trigger(_ action: ControlAction) {
    Task { await perform(action) }
  }

  @discardableResult
  func setKeepDisplayOn(_ enabled: Bool) async -> SettingsCommitResult? {
    guard controls.engineControlsEnabled, enabled != keepDisplayOn else { return nil }
    guard host != nil, let onSetKeepDisplayOn else {
      showControlFailure(ControlFeedback.keepDisplayOnFailure)
      return nil
    }
    let result = await onSetKeepDisplayOn(enabled)
    if ControlFeedback.settingFailed(result) {
      showControlFailure(ControlFeedback.keepDisplayOnFailure)
    }
    await probe()
    return result
  }

  @discardableResult
  func pressSleepNow() -> Task<Void, Never>? {
    guard controls.engineControlsEnabled else { return nil }
    let now = clock.mono()
    guard let request = sleepConfirmation.press(busy: snapshot?.busy == true, now: now) else {
      scheduleExpiry(shownAt: now)
      return nil
    }
    return send(request)
  }

  @discardableResult
  func confirmSleep() -> Task<Void, Never> {
    expiryTask?.cancel()
    return send(sleepConfirmation.confirm())
  }

  func keepWorking() {
    expiryTask?.cancel()
    sleepConfirmation.cancel()
  }

  private func scheduleExpiry(shownAt: Instant) {
    guard sleepConfirmation.phase == .confirming(shownAt: shownAt) else { return }
    expiryTask?.cancel()
    expiryTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(SleepConfirmation.timeoutSeconds))
      guard let self, !Task.isCancelled else { return }
      self.sleepConfirmation.expire(now: shownAt.adding(seconds: SleepConfirmation.timeoutSeconds))
    }
  }

  private func send(_ request: CtlRequest) -> Task<Void, Never> {
    guard controls.engineControlsEnabled else { return Task {} }
    let host = host
    return Task { [weak self] in
      let response = await host?.send(request)
      if ControlFeedback.failed(response) {
        self?.showControlFailure(ControlFeedback.sleepNowFailure)
      }
      await self?.probe()
    }
  }

  private func showControlFailure(_ copy: String) {
    guard restoreNotice?.kind != .restoreFailed, restoreNotice?.kind != .helperNotCleared else { return }
    noticeTask?.cancel()
    noticeCount += 1
    let id = noticeCount
    restoreNotice = RestoreNotice(id: id, kind: .controlFailed, copy: copy, heldState: derivedPresentation.state)
    let seconds = controlNoticeSeconds
    noticeTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(seconds))
      guard let self, !Task.isCancelled, self.restoreNotice?.id == id else { return }
      self.restoreNotice = nil
    }
  }

  @discardableResult
  func restore() -> Task<Void, Never>? {
    guard let emergency else { return nil }
    return Task { [weak self] in
      let result = await emergency.restore { [weak self] shown in
        await self?.applyRestore(shown)
      }
      guard result.kind == .restored || result.kind == .helperNotCleared else { return }
      if result.kind == .helperNotCleared {
        await self?.refreshSleepDisabled()?.value
      }
      if result.engineUnresponsive {
        self?.setEngineUnresponsive(true)
      } else {
        await self?.probe()
      }
    }
  }

  func applyRestore(_ result: RestoreResult) {
    guard let copy = result.copy else { return }
    switch result.kind {
    case .restored:
      showRestoreNotice(kind: .restored, copy: copy)
    case .helperNotCleared:
      showRestoreNotice(kind: .helperNotCleared, copy: copy)
    case .failed:
      showRestoreNotice(kind: .restoreFailed, copy: copy)
    case .inProgress:
      break
    }
  }

  private func showRestoreNotice(kind: RestoreNotice.Kind, copy: String) {
    noticeTask?.cancel()
    noticeTask = nil
    noticeCount += 1
    let id = noticeCount
    switch kind {
    case .restored:
      restoreNotice = RestoreNotice(id: id, kind: .restored, copy: copy, heldState: nil)
      let seconds = restoreResultSeconds
      noticeTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(seconds))
        guard let self, !Task.isCancelled, self.restoreNotice?.id == id else { return }
        self.restoreNotice = nil
      }
    case .helperNotCleared:
      restoreNotice = RestoreNotice(id: id, kind: .helperNotCleared, copy: copy, heldState: nil)
    case .restoreFailed, .controlFailed:
      restoreNotice = RestoreNotice(id: id, kind: kind, copy: copy, heldState: derivedPresentation.state)
    }
  }

  var offersTurnSleepBackOn: Bool {
    restoreNotice?.kind == .helperNotCleared && adminPrompt != nil && readSleepDisabled != nil
  }

  func turnSleepBackOn() async {
    guard offersTurnSleepBackOn, !clearingSleepDisabled, let read = readSleepDisabled, let prompt = adminPrompt
    else { return }
    clearingSleepDisabled = true
    let outcome = await Self.offMain { SleepDisabledClearing.run(read: read, prompt: prompt) }
    clearingSleepDisabled = false
    guard restoreNotice?.kind == .helperNotCleared else { return }
    if outcome.isClear {
      applySleepDisabled(false)
    } else if let caption = outcome.caption {
      showRestoreNotice(kind: .helperNotCleared, copy: caption)
    }
  }

  nonisolated private static func offMain<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(returning: work())
      }
    }
  }

  private func dropStaleFailureNotice() {
    guard let held = restoreNotice?.heldState, derivedPresentation.state != held else { return }
    restoreNotice = nil
  }

  func bind(to host: any EngineHosting) {
    bindTask?.cancel()
    self.host = host
    refreshInstalledTools()
    livenessTask?.cancel()
    livenessTask = nil
    updateLiveness()
    bindTask = Task { [weak self] in
      let stream = await host.snapshots()
      for await snapshot in stream {
        guard let self, !Task.isCancelled else { return }
        self.apply(snapshot)
      }
    }
  }

  func rebind(to host: any EngineHosting) {
    snapshot = nil
    hostFailure = nil
    engineUnresponsive = false
    bind(to: host)
  }

  func unbind() {
    bindTask?.cancel()
    bindTask = nil
    livenessTask?.cancel()
    livenessTask = nil
    host = nil
    snapshot = nil
    engineUnresponsive = false
    dropStaleFailureNotice()
  }

  func applyRestart(_ result: AppHostStart) {
    switch result {
    case .running(let host):
      rebind(to: host)
    case .blocked(let failure):
      unbind()
      hostFailure = failure
    }
  }

  func apply(_ snapshot: EngineSnapshot) {
    guard self.snapshot != snapshot else { return }
    self.snapshot = snapshot
    dropStaleFailureNotice()
  }

  deinit {
    bindTask?.cancel()
    expiryTask?.cancel()
    noticeTask?.cancel()
    livenessTask?.cancel()
    attentionTask?.cancel()
  }
}

struct RestoreNotice: Equatable {
  enum Kind: Equatable {
    case restored
    case helperNotCleared
    case restoreFailed
    case controlFailed
  }

  let id: Int
  let kind: Kind
  let copy: String
  let heldState: PanelState?
}
