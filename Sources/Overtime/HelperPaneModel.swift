import Foundation
import Observation
import OvertimeAppSupport
import OvertimeCore

nonisolated protocol HelperMonitoring: Sendable {
  func refresh() async -> HelperMonitorState
  func reconnect() async -> HelperMonitorState
  func acknowledgeRemovalFailure() -> HelperMonitorState
  func install() async -> HelperMonitorState
  func remove() async -> HelperMonitorState
  func openLoginItems() async
}

nonisolated extension HelperMonitor: HelperMonitoring {}

@Observable
final class HelperPaneModel {
  static let pollIntervalSeconds: Double = 2

  private(set) var state = HelperMonitorState()
  private(set) var confirmingRemove = false
  private(set) var sleepDisabled: Bool?
  private(set) var clearOutcome: SleepDisabledClearOutcome?
  private(set) var clearing = false

  let panel: PanelModel?
  let source: (any HelperMonitoring)?
  @ObservationIgnored private(set) var visibleHosts: Set<ObjectIdentifier> = []
  @ObservationIgnored var pause: @Sendable (Double) async -> Void = HelperPaneModel.sleep
  @ObservationIgnored var readSleepDisabled: (@Sendable () -> Bool?)?
  @ObservationIgnored var adminPrompt: (any AdminPrompt)?
  @ObservationIgnored var copyToPasteboard: @MainActor (String) -> Void = PanelModel.writeToGeneralPasteboard
  @ObservationIgnored private var pollTask: Task<Void, Never>?
  @ObservationIgnored private var feed: Task<Void, Never>?
  @ObservationIgnored private var acting = false
  @ObservationIgnored private var sleepDisabledRead = false
  @ObservationIgnored private var clears = 0

  init(
    panel: PanelModel? = nil, source: (any HelperMonitoring)? = nil,
    changes: AsyncStream<HelperMonitorState>? = nil
  ) {
    self.panel = panel
    self.source = source
    if source != nil {
      panel?.applyHelper(state)
    }
    feed = changes.map { changes in
      Task { [weak self] in
        for await state in changes {
          self?.apply(state)
        }
      }
    }
  }

  static func monitored(
    panel: PanelModel?, installer: any HelperInstallerService, port: XPCHelperPort,
    log: @escaping @Sendable (Decision) -> Void = { _ in }
  ) -> (pane: HelperPaneModel, monitor: HelperMonitor) {
    let (changes, continuation) = AsyncStream.makeStream(of: HelperMonitorState.self)
    let monitor = HelperMonitor(installer: installer, port: port, log: log) { state in
      continuation.yield(state)
    }
    return (HelperPaneModel(panel: panel, source: monitor, changes: changes), monitor)
  }

  var engaged: Bool {
    panel?.snapshot?.helperEngaged == true
  }

  var uiState: HelperUIState? {
    guard source != nil else { return nil }
    return HelperStatusPresentation.derive(state, engaged: engaged)
  }

  var detail: String? {
    HelperStatusPresentation.detail(for: state)
  }

  var isPolling: Bool {
    pollTask != nil
  }

  nonisolated static func sleep(_ seconds: Double) async {
    try? await Task.sleep(for: .seconds(seconds))
  }

  func apply(_ next: HelperMonitorState) {
    guard state != next else { return }
    state = next
    panel?.applyHelper(next)
  }

  @discardableResult
  func setVisible(_ visible: Bool, host: ObjectIdentifier) -> Task<Void, Never>? {
    if visible {
      if visibleHosts.isEmpty, let source {
        apply(source.acknowledgeRemovalFailure())
      }
      visibleHosts.insert(host)
    } else {
      visibleHosts.remove(host)
    }
    guard visibleHosts.isEmpty else {
      startPolling()
      return nil
    }
    return stopPolling()
  }

  func startPolling() {
    guard pollTask == nil, source != nil else { return }
    sleepDisabledRead = false
    let pause = pause
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        await self?.poll()
        await pause(HelperPaneModel.pollIntervalSeconds)
      }
    }
  }

  @discardableResult
  func stopPolling() -> Task<Void, Never>? {
    let task = pollTask
    pollTask = nil
    task?.cancel()
    return task
  }

  func poll() async {
    await readSleepDisabledIfDue()
    guard let source else { return }
    apply(await source.refresh())
  }

  func perform(_ action: HelperStatusAction) async {
    switch action {
    case .install:
      await install()
    case .openLoginItems:
      await openLoginItems()
    case .remove:
      requestRemove()
    case .reconnect:
      await reconnect()
    }
  }

  func install() async {
    await act { await $0.install() }
  }

  func reconnect() async {
    await act { await $0.reconnect() }
  }

  func openLoginItems() async {
    await source?.openLoginItems()
  }

  func requestRemove() {
    guard !confirmingRemove else { return }
    confirmingRemove = true
  }

  func keepProtection() {
    guard confirmingRemove else { return }
    confirmingRemove = false
  }

  func confirmRemove() async {
    keepProtection()
    await act { await $0.remove() }
  }

  var isInstalled: Bool {
    state.installer?.isInstalled == true
  }

  var helperOwnsSleepDisabled: Bool {
    engaged || state.status?.owns == true
  }

  var showsSleepDisabledRow: Bool {
    guard state.installer != nil, sleepDisabled == true else { return false }
    return !helperOwnsSleepDisabled
  }

  var clearCaption: String? {
    clearOutcome?.caption
  }

  func turnSleepBackOn() async {
    guard showsSleepDisabledRow, !clearing, let read = readSleepDisabled, let prompt = adminPrompt else { return }
    clearing = true
    let outcome = await Self.offMain { SleepDisabledClearing.run(read: read, prompt: prompt) }
    clears += 1
    clearing = false
    if outcome.isClear {
      applySleepDisabled(false)
    } else {
      clearOutcome = outcome
    }
    panel?.refreshSleepDisabled()
  }

  func copyCommand() {
    copyToPasteboard(Hints.sleepDisabledCommand)
  }

  func readSleepDisabledOnce() {
    sleepDisabledRead = false
    Task { [weak self] in
      await self?.readSleepDisabledIfDue()
    }
  }

  private func readSleepDisabledIfDue() async {
    guard let read = readSleepDisabled, !clearing else { return }
    guard !sleepDisabledRead || sleepDisabled != false else { return }
    sleepDisabledRead = true
    let clearsBefore = clears
    let value = await Self.offMain { read() }
    guard clearsBefore == clears else { return }
    applySleepDisabled(value)
  }

  private func applySleepDisabled(_ value: Bool?) {
    guard let value else { return }
    if sleepDisabled != value { sleepDisabled = value }
    if !value, clearOutcome != nil { clearOutcome = nil }
  }

  nonisolated private static func offMain<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(returning: work())
      }
    }
  }

  private func act(_ work: (any HelperMonitoring) async -> HelperMonitorState) async {
    guard let source, !acting else { return }
    acting = true
    let next = await work(source)
    acting = false
    apply(next)
  }

  deinit {
    pollTask?.cancel()
    feed?.cancel()
  }
}
