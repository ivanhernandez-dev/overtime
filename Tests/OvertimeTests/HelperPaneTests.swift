import AppKit
import Foundation
import OvertimeAppSupport
import OvertimeEngine
import OvertimeHelperClient
import OvertimeHelperCore
import Testing
import os

import struct SwiftUI.ButtonRole
import struct SwiftUI.Color

@testable import Overtime

@MainActor
struct HelperPaneTests {
  final class EventLog: Sendable {
    private let events = OSAllocatedUnfairLock<[String]>(initialState: [])

    var all: [String] {
      events.withLock { $0 }
    }

    func append(_ event: String) {
      events.withLock { $0.append(event) }
    }

    func count(of event: String) -> Int {
      events.withLock { events in events.filter { $0 == event }.count }
    }
  }

  final class FakeHelperSource: HelperMonitoring {
    private struct Stored {
      var state: HelperMonitorState
      var afterAction: HelperMonitorState?
      var refreshSeconds: Double = 0
    }

    let log: EventLog
    private let stored: OSAllocatedUnfairLock<Stored>

    init(_ state: HelperMonitorState = HelperMonitorState(), log: EventLog = EventLog()) {
      self.log = log
      stored = OSAllocatedUnfairLock(initialState: Stored(state: state))
    }

    var refreshes: Int {
      log.count(of: "refresh")
    }

    var actions: [String] {
      log.all.filter { $0 != "refresh" && $0 != "refreshed" }
    }

    func set(_ state: HelperMonitorState) {
      stored.withLock { $0.state = state }
    }

    func script(afterAction state: HelperMonitorState) {
      stored.withLock { $0.afterAction = state }
    }

    func slowRefresh(seconds: Double) {
      stored.withLock { $0.refreshSeconds = seconds }
    }

    func refresh() async -> HelperMonitorState {
      log.append("refresh")
      let seconds = stored.withLock { $0.refreshSeconds }
      if seconds > 0 {
        try? await Task.sleep(for: .seconds(seconds))
      }
      log.append("refreshed")
      return stored.withLock { $0.state }
    }

    func reconnect() async -> HelperMonitorState {
      log.append("reconnect")
      return stored.withLock { $0.state }
    }

    func acknowledgeRemovalFailure() -> HelperMonitorState {
      stored.withLock { $0.state }
    }

    func install() async -> HelperMonitorState {
      act("install")
    }

    func remove() async -> HelperMonitorState {
      act("remove")
    }

    func openLoginItems() async {
      log.append("openLoginItems")
    }

    private func act(_ name: String) -> HelperMonitorState {
      log.append(name)
      return stored.withLock { stored in
        if let next = stored.afterAction {
          stored.state = next
        }
        return stored.state
      }
    }
  }

  @MainActor struct Monitored {
    let installer: FakeHelperInstaller
    let connections: EventLog
    let panel: PanelModel
    let pane: HelperPaneModel
    let monitor: HelperMonitor

    init(status: HelperInstallerStatus = .notRegistered) {
      let installer = FakeHelperInstaller(status: status)
      let connections = EventLog()
      self.installer = installer
      self.connections = connections
      let client = HelperXPCClient(requirement: "anchor apple") {
        connections.append("connection")
        return NSXPCConnection(listenerEndpoint: NSXPCListener.anonymous().endpoint)
      }
      let panel = PanelModel()
      let made = HelperPaneModel.monitored(panel: panel, installer: installer, port: XPCHelperPort(client: client))
      self.panel = panel
      pane = made.pane
      monitor = made.monitor
      pane.pause = { _ in try? await Task.sleep(for: .milliseconds(20)) }
    }
  }

  @MainActor struct Scripted {
    let log: EventLog
    let source: FakeHelperSource
    let panel: PanelModel
    let pane: HelperPaneModel
    let host = ObjectIdentifier(NSObject.self)

    init(_ state: HelperMonitorState = HelperMonitorState()) {
      let log = EventLog()
      let source = FakeHelperSource(state, log: log)
      let panel = PanelModel()
      let pane = HelperPaneModel(panel: panel, source: source)
      self.log = log
      self.source = source
      self.panel = panel
      self.pane = pane
      pane.pause = { seconds in
        log.append("pause \(seconds)")
        try? await Task.sleep(for: .milliseconds(20))
      }
    }

    func show(_ state: HelperMonitorState) async {
      source.set(state)
      await pane.poll()
    }
  }

  struct ProgressCase: Sendable, CustomTestStringConvertible {
    let state: HelperMonitorState
    let title: String
    var detail: String?

    var testDescription: String {
      title
    }
  }

  struct ProblemCase: Sendable, CustomTestStringConvertible {
    let state: HelperMonitorState
    let title: String
    let caption: String
    let actions: [String]
    let tone: HelperStatusTone

    var testDescription: String {
      title
    }
  }

  nonisolated static let current = HelperStatus(helperVersion: HelperIdentity.version, sleepDisabled: false)
  nonisolated static let standingBy = HelperMonitorState(installer: .enabled, reachability: .reachable, status: current)
  nonisolated static let removeLabel = "Remove Unplug Protection…"

  nonisolated static let progressCases = [
    ProgressCase(state: HelperMonitorState(), title: "Checking unplug protection…"),
    ProgressCase(
      state: HelperMonitorState(installer: .notRegistered, inFlight: .installing), title: "Installing…"),
    ProgressCase(
      state: HelperMonitorState(
        installer: .enabled, reachability: .reachable, status: HelperStatus(helperVersion: 0), staleAttempts: 1),
      title: "Updating the helper…", detail: "Helper version 0."),
    ProgressCase(state: HelperMonitorState(installer: .enabled, inFlight: .removing), title: "Removing…"),
  ]

  nonisolated static let problemCases = [
    ProblemCase(
      state: HelperMonitorState(installer: .enabled, reachability: .unreachable),
      title: "Needs your approval again",
      caption:
        "macOS stopped the helper, usually after an update. In System Settings > General > Login Items & Extensions, turn Overtime off and on again under Allow in the Background.",
      actions: ["Open Login Items", removeLabel], tone: .warning),
    ProblemCase(
      state: HelperMonitorState(
        installer: .enabled, reachability: .reachable, status: HelperStatus(helperVersion: 0), staleAttempts: 2),
      title: "Out of date",
      caption:
        "The installed helper is older than this version of Overtime. Remove unplug protection, then install it again.",
      actions: [removeLabel], tone: .warning),
    ProblemCase(
      state: HelperMonitorState(installer: .enabled, reachability: .reachable, lastError: "NSCocoaErrorDomain 4097"),
      title: "Unplug protection isn't working",
      caption:
        "Overtime couldn't talk to the helper. Keep-awake still works without it. Try again, or remove and reinstall it.",
      actions: ["Reconnect Helper", removeLabel], tone: .error),
  ]

  final class ScriptedReader: Sendable {
    let log: EventLog
    private let values: OSAllocatedUnfairLock<[Bool?]>
    private let held = OSAllocatedUnfairLock(initialState: (next: false, returned: 0))
    private let gate = DispatchSemaphore(value: 0)

    init(_ values: [Bool?], log: EventLog) {
      self.log = log
      self.values = OSAllocatedUnfairLock(initialState: values)
    }

    var heldReadsReturned: Int {
      held.withLock { $0.returned }
    }

    func holdNextRead() {
      held.withLock { $0.next = true }
    }

    func releaseRead() {
      gate.signal()
    }

    var reads: Int {
      log.count(of: "read")
    }

    func set(_ next: [Bool?]) {
      values.withLock { $0 = next }
    }

    func read() -> Bool? {
      log.append("read")
      let value = values.withLock { values in
        values.count > 1 ? values.removeFirst() : values.first ?? nil
      }
      let holds = held.withLock { held -> Bool in
        defer { held.next = false }
        return held.next
      }
      if holds {
        _ = gate.wait(timeout: .now() + FakeHelperInstaller.heldSeconds)
        held.withLock { $0.returned += 1 }
      }
      return value
    }
  }

  final class FakeAdminPrompt: AdminPrompt {
    private struct Stored {
      var outcomes: [AdminOutcome]
      var holding = false
    }

    let log: EventLog
    private let stored: OSAllocatedUnfairLock<Stored>
    private let gate = DispatchSemaphore(value: 0)

    init(_ outcomes: [AdminOutcome], log: EventLog) {
      self.log = log
      stored = OSAllocatedUnfairLock(initialState: Stored(outcomes: outcomes))
    }

    var calls: Int {
      log.count(of: "prompt")
    }

    func hold() {
      stored.withLock { $0.holding = true }
    }

    func release() {
      stored.withLock { $0.holding = false }
      for _ in 0..<4 { gate.signal() }
    }

    func clearSleepDisabled() -> AdminOutcome {
      log.append("prompt")
      let (outcome, holds) = stored.withLock { stored -> (AdminOutcome, Bool) in
        (stored.outcomes.isEmpty ? .succeeded : stored.outcomes.removeFirst(), stored.holding)
      }
      if holds {
        _ = gate.wait(timeout: .now() + FakeHelperInstaller.heldSeconds)
      }
      return outcome
    }
  }

  @MainActor struct Clearing {
    let log: EventLog
    let source: FakeHelperSource
    let reader: ScriptedReader
    let prompt: FakeAdminPrompt
    let copied: EventLog
    let panel: PanelModel
    let pane: HelperPaneModel
    let host = ObjectIdentifier(NSObject.self)

    init(
      reads: [Bool?], outcomes: [AdminOutcome] = [],
      state: HelperMonitorState = HelperMonitorState(installer: .notRegistered)
    ) {
      let log = EventLog()
      let source = FakeHelperSource(state)
      let reader = ScriptedReader(reads, log: log)
      let prompt = FakeAdminPrompt(outcomes, log: log)
      let copied = EventLog()
      let panel = PanelModel()
      let pane = HelperPaneModel(panel: panel, source: source)
      pane.pause = { _ in try? await Task.sleep(for: .milliseconds(20)) }
      pane.readSleepDisabled = { reader.read() }
      pane.adminPrompt = prompt
      pane.copyToPasteboard = { copied.append($0) }
      self.log = log
      self.source = source
      self.reader = reader
      self.prompt = prompt
      self.copied = copied
      self.panel = panel
      self.pane = pane
    }
  }

  struct OwnershipCase: Sendable, CustomTestStringConvertible {
    let name: String
    let state: HelperMonitorState
    var engaged = false
    let shown: Bool

    var testDescription: String {
      name
    }
  }

  nonisolated static let cancelledCaption =
    "You cancelled the administrator prompt. Sleep is still turned off system-wide."
  nonisolated static let failedCaption =
    "Couldn't turn sleep back on. Run this in Terminal: sudo pmset -a disablesleep 0"

  nonisolated static let ownershipCases = [
    OwnershipCase(name: "not installed", state: HelperMonitorState(installer: .notRegistered), shown: true),
    OwnershipCase(name: "not found", state: HelperMonitorState(installer: .notFound), shown: true),
    OwnershipCase(name: "waiting for approval", state: HelperMonitorState(installer: .requiresApproval), shown: true),
    OwnershipCase(
      name: "installed and not the owner",
      state: HelperMonitorState(
        installer: .enabled, reachability: .reachable,
        status: HelperStatus(helperVersion: HelperIdentity.version, sleepDisabled: true, owns: false)),
      shown: true),
    OwnershipCase(
      name: "needs approval again", state: HelperMonitorState(installer: .enabled, reachability: .unreachable),
      shown: true),
    OwnershipCase(
      name: "the helper owns it",
      state: HelperMonitorState(
        installer: .enabled, reachability: .reachable,
        status: HelperStatus(helperVersion: HelperIdentity.version, sleepDisabled: true, owns: true)),
      shown: false),
    OwnershipCase(
      name: "the engine holds the helper before its first answer",
      state: HelperMonitorState(
        installer: .enabled, reachability: .reachable,
        status: HelperStatus(helperVersion: HelperIdentity.version, sleepDisabled: false, owns: false)),
      engaged: true, shown: false),
    OwnershipCase(name: "before the first status read", state: HelperMonitorState(), shown: false),
  ]

  func ended(_ task: Task<Void, Never>?) async -> Bool {
    guard let task else { return false }
    let done = OSAllocatedUnfairLock(initialState: false)
    Task {
      await task.value
      done.withLock { $0 = true }
    }
    return await waitUntil { done.withLock { $0 } }
  }

  @Test func beforeThePaneIsVisibleNothingIsReadRegisteredOrConnected() async throws {
    let fixture = Monitored()
    try await Task.sleep(for: .milliseconds(150))
    #expect(fixture.installer.statusReads == 0)
    #expect(fixture.installer.calls.isEmpty)
    #expect(fixture.connections.all.isEmpty)
    #expect(!fixture.pane.isPolling)
    #expect(fixture.pane.uiState == .checking)
    #expect(fixture.pane.uiState?.title == "Checking unplug protection…")
  }

  @Test func installRegistersOnceOpensLoginItemsOnTheApprovalThrowAndShowsWaitingForYourApproval() async {
    let fixture = Monitored()
    fixture.installer.failRegister(leaving: .requiresApproval)
    await fixture.pane.poll()
    #expect(fixture.pane.uiState == .off)
    #expect(fixture.pane.uiState?.actions.map(\.label) == ["Install Unplug Protection…"])
    await fixture.pane.perform(.install)
    #expect(fixture.installer.calls == ["register", "openSystemSettings"])
    #expect(fixture.pane.uiState == .waitingForApproval)
    #expect(fixture.pane.uiState?.title == "Waiting for your approval")
    #expect(
      fixture.pane.uiState?.caption
        == "Turn on Overtime under Allow in the Background in System Settings > General > Login Items & Extensions.")
    #expect(fixture.pane.uiState?.actions.map(\.label) == ["Open Login Items", Self.removeLabel])
    #expect(fixture.pane.detail == nil)
    #expect(fixture.connections.all.isEmpty)
  }

  @Test func whileRegisterIsInFlightTheRowShowsInstallingAndASecondPressRegistersNothing() async {
    let fixture = Monitored()
    fixture.installer.failRegister(leaving: .requiresApproval)
    fixture.installer.holdCalls()
    defer { fixture.installer.releaseCalls() }
    let pane = fixture.pane
    let first = Task { await pane.perform(.install) }
    #expect(await waitUntil { pane.uiState == .installing })
    #expect(pane.uiState?.title == "Installing…")
    #expect(pane.uiState?.icon == .progress)
    #expect(pane.uiState?.actions.isEmpty == true)
    await pane.perform(.install)
    #expect(fixture.installer.heldReturned == 0)
    fixture.installer.releaseCalls()
    await first.value
    #expect(fixture.installer.calls == ["register", "openSystemSettings"])
    #expect(await waitUntil { pane.uiState == .waitingForApproval })
  }

  @Test func theMonitoredPaneReadsTheEnginesHoldFromThePanel() {
    let fixture = Monitored()
    #expect(!fixture.pane.engaged)
    fixture.panel.apply(EngineSnapshot(helperEngaged: true))
    #expect(fixture.pane.engaged)
    #expect(fixture.pane.helperOwnsSleepDisabled)
  }

  @Test func aPollReadsSleepDisabledBeforeItAsksTheMonitor() async {
    let log = EventLog()
    let source = FakeHelperSource(Self.standingBy, log: log)
    let reader = ScriptedReader([true], log: log)
    let pane = HelperPaneModel(source: source)
    pane.readSleepDisabled = { reader.read() }
    await pane.poll()
    #expect(log.all == ["read", "refresh", "refreshed"])
  }

  @Test func openLoginItemsOpensSystemSettingsAndRegistersNothing() async {
    let fixture = Monitored(status: .requiresApproval)
    await fixture.pane.poll()
    await fixture.pane.perform(.openLoginItems)
    #expect(fixture.installer.calls == ["openSystemSettings"])
    #expect(fixture.pane.uiState == .waitingForApproval)
  }

  static let reconnectNeverRegisters: Comment =
    "S-WR-03 / A-WR-02: Reconnect helper clears the kept action failure and reads again; it never registers the daemon"

  @Test func aRegisterErrorShowsTheErrorRowAndReconnectClearsItWithoutInstalling() async {
    let fixture = Monitored()
    fixture.installer.failRegister(leaving: .notRegistered)
    await fixture.pane.perform(.install)
    #expect(fixture.pane.uiState == .error)
    #expect(fixture.pane.uiState?.actions.map(\.label) == ["Reconnect Helper", Self.removeLabel])
    await fixture.pane.perform(.reconnect)
    #expect(fixture.installer.calls == ["register"], Self.reconnectNeverRegisters)
    #expect(fixture.pane.uiState == .off)
    #expect(fixture.pane.uiState?.actions.map(\.label) == ["Install Unplug Protection…"])
    #expect(fixture.connections.all.isEmpty)
  }

  @Test func reconnectAsksTheMonitorToReconnectAndNothingElse() async {
    let fixture = Scripted()
    await fixture.show(Self.problemCases[2].state)
    #expect(fixture.pane.uiState == .error)
    fixture.source.set(Self.standingBy)
    await fixture.pane.perform(.reconnect)
    #expect(fixture.source.actions == ["reconnect"], Self.reconnectNeverRegisters)
    #expect(fixture.pane.uiState == .onStandingBy)
  }

  @Test func reconnectAfterARemovalThatFailedShowsTheHelperAgainAndRegistersNothing() async {
    let fixture = Monitored(status: .requiresApproval)
    fixture.installer.failUnregister()
    await fixture.pane.poll()
    fixture.pane.requestRemove()
    await fixture.pane.confirmRemove()
    #expect(fixture.pane.uiState == .error)
    await fixture.pane.perform(.reconnect)
    #expect(fixture.pane.uiState == .waitingForApproval, Self.reconnectNeverRegisters)
    #expect(fixture.installer.calls == ["unregister"], Self.reconnectNeverRegisters)
  }

  @Test func thePanePollsTheMonitorWhileVisibleAndStopsWhenItDisappears() async throws {
    let fixture = Scripted(Self.standingBy)
    try await Task.sleep(for: .milliseconds(100))
    #expect(fixture.source.refreshes == 0)
    #expect(!fixture.pane.isPolling)
    fixture.pane.setVisible(true, host: fixture.host)
    #expect(fixture.pane.isPolling)
    #expect(await waitUntil { fixture.source.refreshes >= 3 })
    #expect(fixture.pane.uiState == .onStandingBy)
    let stopped = fixture.pane.setVisible(false, host: fixture.host)
    #expect(!fixture.pane.isPolling)
    #expect(await ended(stopped))
    let count = fixture.source.refreshes
    try await Task.sleep(for: .milliseconds(300))
    #expect(fixture.source.refreshes == count)
    #expect(fixture.source.actions.allSatisfy { $0.hasPrefix("pause") })
  }

  @Test func eachPollWaitsForItsRefreshAndThenSleepsTwoSeconds() async {
    let fixture = Scripted(Self.standingBy)
    fixture.source.slowRefresh(seconds: 0.1)
    fixture.pane.setVisible(true, host: fixture.host)
    #expect(await waitUntil { fixture.log.all.count >= 7 })
    let stopped = fixture.pane.setVisible(false, host: fixture.host)
    #expect(await ended(stopped))
    #expect(
      Array(fixture.log.all.prefix(6)) == ["refresh", "refreshed", "pause 2.0", "refresh", "refreshed", "pause 2.0"])
    #expect(HelperPaneModel.pollIntervalSeconds == 2)
  }

  @Test func theDefaultPauseSleepsBetweenPollsAndEndsAtOnceWhenThePaneHides() async throws {
    let source = FakeHelperSource(Self.standingBy)
    let pane = HelperPaneModel(source: source)
    let host = ObjectIdentifier(NSObject.self)
    let paused = EventLog()
    let defaultPause = pane.pause
    pane.pause = { seconds in
      paused.append("pause \(seconds)")
      await defaultPause(3600)
      paused.append(Task.isCancelled ? "cancelled" : "elapsed")
    }
    pane.setVisible(true, host: host)
    #expect(await waitUntil { paused.all == ["pause 2.0"] })
    #expect(source.refreshes == 1)
    #expect(await ended(pane.setVisible(false, host: host)))
    #expect(paused.all == ["pause 2.0", "cancelled"])
    #expect(source.refreshes == 1)
  }

  @Test func aSecondVisibleHostKeepsThePollUntilBothAreHidden() async {
    let fixture = Scripted(Self.standingBy)
    let onboarding = ObjectIdentifier(NSString.self)
    fixture.pane.setVisible(true, host: fixture.host)
    fixture.pane.setVisible(true, host: onboarding)
    #expect(fixture.pane.setVisible(false, host: fixture.host) == nil)
    #expect(fixture.pane.isPolling)
    let before = fixture.source.refreshes
    #expect(await waitUntil { fixture.source.refreshes >= before + 2 })
    let stopped = fixture.pane.setVisible(false, host: onboarding)
    #expect(!fixture.pane.isPolling)
    #expect(await ended(stopped))
  }

  @Test func theRealMonitorReadsTheInstallerOnlyWhileThePaneIsVisible() async throws {
    let fixture = Monitored()
    let host = ObjectIdentifier(NSObject.self)
    fixture.pane.setVisible(true, host: host)
    #expect(await waitUntil { fixture.installer.statusReads >= 3 })
    #expect(fixture.pane.uiState == .off)
    let stopped = fixture.pane.setVisible(false, host: host)
    #expect(await ended(stopped))
    let reads = fixture.installer.statusReads
    try await Task.sleep(for: .milliseconds(300))
    #expect(fixture.installer.statusReads == reads)
    #expect(fixture.installer.calls.isEmpty)
    #expect(fixture.connections.all.isEmpty)
  }

  @Test func withAReachableEngagedHelperTheRowReadsOnHoldingNowWithTheDetailLine() async {
    let fixture = Scripted()
    let holding = HelperStatus(helperVersion: HelperIdentity.version, sleepDisabled: true, owns: true, engaged: true)
    await fixture.show(HelperMonitorState(installer: .enabled, reachability: .reachable, status: holding))
    fixture.panel.apply(EngineSnapshot(helperEngaged: true))
    #expect(fixture.pane.uiState == .onHolding)
    #expect(fixture.pane.uiState?.title == "On, holding now")
    #expect(fixture.pane.uiState?.caption == "System sleep is off until the lid opens or Claude finishes.")
    #expect(fixture.pane.uiState?.icon == .symbol("checkmark.shield.fill", .success))
    #expect(fixture.pane.uiState?.actions.map(\.label) == [Self.removeLabel])
    #expect(fixture.pane.detail == "Helper version \(HelperIdentity.version). System sleep: off.")
    fixture.panel.apply(EngineSnapshot(helperEngaged: false))
    await fixture.show(Self.standingBy)
    #expect(fixture.pane.uiState == .onStandingBy)
    #expect(fixture.pane.uiState?.title == "On")
    #expect(fixture.pane.uiState?.caption == "It turns system sleep off only while Claude works with the lid closed.")
    #expect(fixture.pane.detail == "Helper version \(HelperIdentity.version). System sleep: on.")
  }

  @Test(arguments: progressCases)
  func theProgressStatesShowTheirTitleWithASpinnerAndNoActions(_ progress: ProgressCase) async {
    let fixture = Scripted()
    await fixture.show(progress.state)
    #expect(fixture.pane.uiState?.title == progress.title)
    #expect(fixture.pane.uiState?.icon == .progress)
    #expect(fixture.pane.uiState?.caption == nil)
    #expect(fixture.pane.uiState?.actions.isEmpty == true)
    #expect(fixture.pane.detail == progress.detail)
  }

  @Test(arguments: problemCases)
  func theProblemStatesShowTheirUISpecRow(_ problem: ProblemCase) async {
    let fixture = Scripted()
    await fixture.show(problem.state)
    #expect(fixture.pane.uiState?.title == problem.title)
    #expect(fixture.pane.uiState?.caption == problem.caption)
    #expect(fixture.pane.uiState?.actions.map(\.label) == problem.actions)
    #expect(fixture.pane.uiState?.icon == .symbol("exclamationmark.triangle.fill", problem.tone))
  }

  @Test(arguments: HelperUIState.allCases)
  func removeIsDestructiveInEveryRowThatShowsIt(_ state: HelperUIState) {
    for action in state.actions {
      let destructive = UnplugProtectionPane.role(for: action) == .destructive
      #expect(destructive == (action.label == Self.removeLabel))
    }
  }

  @Test func sixRowsShowTheDestructiveRemoveAndTheToneColoursFollowTheUISpec() {
    let withRemove = HelperUIState.allCases.filter { state in
      state.actions.contains { UnplugProtectionPane.role(for: $0) == .destructive }
    }
    #expect(withRemove == [.waitingForApproval, .onStandingBy, .onHolding, .needsApprovalAgain, .outOfDate, .error])
    #expect(UnplugProtectionPane.tint(for: .secondary) == Color.secondary)
    #expect(UnplugProtectionPane.tint(for: .success) == Color.green)
    #expect(UnplugProtectionPane.tint(for: .warning) == Color.orange)
    #expect(UnplugProtectionPane.tint(for: .error) == Color.red)
    #expect(UnplugProtectionPane.statusTitle == "Status")
  }

  @Test func aModelWithoutAMonitorShowsNoRowAndNeverPolls() async {
    let pane = HelperPaneModel()
    let host = ObjectIdentifier(NSObject.self)
    #expect(pane.uiState == nil)
    #expect(pane.detail == nil)
    #expect(pane.setVisible(true, host: host) == nil)
    #expect(!pane.isPolling)
    await pane.perform(.install)
    #expect(pane.uiState == nil)
  }

  @Test func settingsHandsThePaneTheHelperModelItWasGiven() throws {
    let folder = try TestFolder()
    let file = folder.url.appendingPathComponent("settings.json")
    let fixture = Scripted()
    #expect(SettingsModel(settingsFile: file, helper: fixture.pane).helperPane === fixture.pane)
    #expect(SettingsModel(settingsFile: file).helperPane.uiState == nil)
  }

  @Test func removeAsksFirstAndOnlyTheDestructiveButtonUnregisters() async {
    let fixture = Monitored(status: .requiresApproval)
    await fixture.pane.poll()
    #expect(!fixture.pane.confirmingRemove)
    await fixture.pane.perform(.remove)
    #expect(fixture.pane.confirmingRemove)
    #expect(fixture.installer.calls.isEmpty)
    fixture.pane.keepProtection()
    #expect(!fixture.pane.confirmingRemove)
    #expect(fixture.installer.calls.isEmpty)
    #expect(fixture.pane.uiState == .waitingForApproval)
    await fixture.pane.perform(.remove)
    #expect(fixture.pane.confirmingRemove)
    await fixture.pane.confirmRemove()
    #expect(fixture.installer.calls == ["unregister"])
    #expect(!fixture.pane.confirmingRemove)
    #expect(fixture.pane.uiState == .off)
    #expect(fixture.pane.uiState?.actions.map(\.label) == ["Install Unplug Protection…"])
    #expect(fixture.connections.all.isEmpty)
  }

  @Test func whileUnregisterIsInFlightTheRowShowsRemovingAndASecondConfirmationUnregistersNothing() async {
    let fixture = Monitored(status: .requiresApproval)
    fixture.installer.holdCalls()
    defer { fixture.installer.releaseCalls() }
    let pane = fixture.pane
    await pane.poll()
    pane.requestRemove()
    let first = Task { await pane.confirmRemove() }
    #expect(await waitUntil { pane.uiState == .removing })
    #expect(pane.uiState?.title == "Removing…")
    #expect(pane.uiState?.icon == .progress)
    await pane.confirmRemove()
    #expect(fixture.installer.heldReturned == 0)
    fixture.installer.releaseCalls()
    await first.value
    #expect(fixture.installer.calls == ["unregister"])
    #expect(await waitUntil { pane.uiState == .off })
  }

  @Test func anUnregisterErrorShowsTheErrorRowAndKeepsRemoveAvailable() async {
    let fixture = Monitored(status: .requiresApproval)
    fixture.installer.failUnregister()
    await fixture.pane.poll()
    fixture.pane.requestRemove()
    await fixture.pane.confirmRemove()
    #expect(fixture.installer.calls == ["unregister"])
    #expect(fixture.pane.uiState == .error)
    #expect(fixture.pane.uiState?.title == "Unplug protection isn't working")
    #expect(fixture.pane.uiState?.actions.map(\.label) == ["Reconnect Helper", Self.removeLabel])
  }

  static let removalKeptWhilePolling: Comment =
    "R3-WR-01: a failed removal stays on the Error row, with Remove still offered, while the visible pane polls"
  static let removalForgottenOnAppearing: Comment =
    "R3-WR-01: a failed removal is forgotten when the pane goes from hidden to visible, and only then"

  @Test func aFailedRemovalStaysShownWhileTheVisiblePanePolls() async {
    let fixture = Monitored(status: .requiresApproval)
    let pane = fixture.pane
    let host = ObjectIdentifier(NSObject.self)
    fixture.installer.failUnregister()
    pane.setVisible(true, host: host)
    #expect(await waitUntil { pane.uiState == .waitingForApproval })
    pane.requestRemove()
    await pane.confirmRemove()
    #expect(fixture.installer.calls == ["unregister"])
    let reads = fixture.installer.statusReads
    #expect(await waitUntil { fixture.installer.statusReads >= reads + 3 })
    #expect(pane.isPolling)
    #expect(pane.uiState == .error, Self.removalKeptWhilePolling)
    #expect(pane.uiState?.actions.map(\.label) == ["Reconnect Helper", Self.removeLabel], Self.removalKeptWhilePolling)
    #expect(pane.state.lastError == "Operation not permitted", Self.removalKeptWhilePolling)
    #expect(await ended(pane.setVisible(false, host: host)))
  }

  @Test func aFailedRemovalIsForgottenWhenThePaneAppearsAgainButNotWhenASecondHostAppears() async {
    let fixture = Monitored(status: .requiresApproval)
    let pane = fixture.pane
    let host = ObjectIdentifier(NSObject.self)
    let onboarding = ObjectIdentifier(NSString.self)
    fixture.installer.failUnregister()
    pane.setVisible(true, host: host)
    #expect(await waitUntil { pane.uiState == .waitingForApproval })
    pane.requestRemove()
    await pane.confirmRemove()
    #expect(pane.uiState == .error)
    pane.setVisible(true, host: onboarding)
    let reads = fixture.installer.statusReads
    #expect(await waitUntil { fixture.installer.statusReads >= reads + 3 })
    #expect(pane.uiState == .error, Self.removalForgottenOnAppearing)
    #expect(pane.setVisible(false, host: onboarding) == nil)
    #expect(await ended(pane.setVisible(false, host: host)))
    #expect(pane.uiState == .error, Self.removalForgottenOnAppearing)
    pane.setVisible(true, host: host)
    #expect(await waitUntil { pane.uiState == .waitingForApproval }, Self.removalForgottenOnAppearing)
    #expect(pane.state.lastError == nil, Self.removalForgottenOnAppearing)
    #expect(fixture.installer.calls == ["unregister"])
    #expect(await ended(pane.setVisible(false, host: host)))
  }

  @Test(arguments: ownershipCases)
  func theSleepDisabledRowShowsOnlyForAOneTheHelperDoesNotOwn(_ ownership: OwnershipCase) async {
    let fixture = Clearing(reads: [true], state: ownership.state)
    fixture.panel.apply(EngineSnapshot(helperEngaged: ownership.engaged))
    #expect(!fixture.pane.showsSleepDisabledRow)
    await fixture.pane.poll()
    #expect(fixture.pane.sleepDisabled == true)
    #expect(fixture.pane.showsSleepDisabledRow == ownership.shown)
    await fixture.pane.turnSleepBackOn()
    #expect(fixture.prompt.calls == (ownership.shown ? 1 : 0))
  }

  @Test(arguments: [false, nil] as [Bool?])
  func theSleepDisabledRowIsHiddenWhenTheValueIsZeroOrUnreadable(_ reading: Bool?) async {
    let fixture = Clearing(reads: [reading])
    await fixture.pane.poll()
    #expect(fixture.reader.reads == 1)
    #expect(fixture.pane.sleepDisabled == reading)
    #expect(!fixture.pane.showsSleepDisabledRow)
    await fixture.pane.turnSleepBackOn()
    #expect(fixture.reader.reads == 1)
    #expect(fixture.prompt.calls == 0)
  }

  @Test func theRowUsesTheUISpecCopyAndTheOrangeTriangle() {
    #expect(SleepDisabledRow.symbol == "exclamationmark.triangle.fill")
    #expect(SleepDisabledClearing.rowTitle == "Sleep is turned off system-wide (SleepDisabled)")
    #expect(
      SleepDisabledClearing.rowCaption
        == "Overtime didn't set this. Until it's cleared, the Mac can't sleep at all, even with the lid closed and Claude idle."
    )
    #expect(SleepDisabledRow.turnOnLabel == "Turn Sleep Back On…")
    #expect(SleepDisabledRow.turnOnLabel == SleepDisabledClearing.turnOnLabel)
    #expect(SleepDisabledClearing.copyLabel == "Copy Command")
  }

  @Test func sleepDisabledIsReadOncePerAppearanceWhileItIsZeroAndNeverWhileHidden() async throws {
    let fixture = Clearing(reads: [false])
    try await Task.sleep(for: .milliseconds(100))
    #expect(fixture.reader.reads == 0)
    fixture.pane.setVisible(true, host: fixture.host)
    #expect(await waitUntil { fixture.source.refreshes >= 3 })
    #expect(fixture.reader.reads == 1)
    #expect(await ended(fixture.pane.setVisible(false, host: fixture.host)))
    let seen = fixture.source.refreshes
    fixture.pane.setVisible(true, host: fixture.host)
    #expect(await waitUntil { fixture.source.refreshes >= seen + 2 })
    #expect(fixture.reader.reads == 2)
    #expect(await ended(fixture.pane.setVisible(false, host: fixture.host)))
    #expect(fixture.prompt.calls == 0)
  }

  @Test func whileSleepDisabledReadsOneEveryPollReadsItAgainUntilItClears() async {
    let fixture = Clearing(reads: [true])
    fixture.pane.setVisible(true, host: fixture.host)
    #expect(await waitUntil { fixture.reader.reads >= 3 })
    #expect(fixture.pane.showsSleepDisabledRow)
    fixture.reader.set([false])
    #expect(await waitUntil { !fixture.pane.showsSleepDisabledRow })
    #expect(await ended(fixture.pane.setVisible(false, host: fixture.host)))
    #expect(fixture.prompt.calls == 0)
  }

  @Test func turnSleepBackOnPromptsOnlyAfterTheReaderReportsOneAndHidesTheRowOnceItIsClear() async {
    let fixture = Clearing(reads: [true, true, false])
    await fixture.pane.poll()
    #expect(fixture.pane.showsSleepDisabledRow)
    #expect(fixture.log.all == ["read"])
    await fixture.pane.turnSleepBackOn()
    #expect(fixture.log.all == ["read", "read", "prompt", "read"])
    #expect(fixture.pane.sleepDisabled == false)
    #expect(!fixture.pane.showsSleepDisabledRow)
    #expect(fixture.pane.clearCaption == nil)
    #expect(!fixture.pane.clearing)
  }

  @Test func whenTheValueIsAlreadyZeroAtThePressNoPromptIsShown() async {
    let fixture = Clearing(reads: [true, false])
    await fixture.pane.poll()
    await fixture.pane.turnSleepBackOn()
    #expect(fixture.log.all == ["read", "read"])
    #expect(!fixture.pane.showsSleepDisabledRow)
    #expect(fixture.pane.clearCaption == nil)
  }

  @Test func aCancelledPromptShowsItsCaptionAndIsOfferedAgainOnlyByPressingAgain() async {
    let fixture = Clearing(reads: [true], outcomes: [.cancelled, .succeeded])
    await fixture.pane.poll()
    await fixture.pane.turnSleepBackOn()
    #expect(fixture.pane.clearOutcome == .cancelled)
    #expect(fixture.pane.clearCaption == Self.cancelledCaption)
    #expect(fixture.pane.showsSleepDisabledRow)
    #expect(fixture.prompt.calls == 1)
    await fixture.pane.poll()
    await fixture.pane.poll()
    #expect(fixture.prompt.calls == 1)
    #expect(fixture.pane.clearCaption == Self.cancelledCaption)
    fixture.reader.set([true, false])
    await fixture.pane.turnSleepBackOn()
    #expect(fixture.prompt.calls == 2)
    #expect(!fixture.pane.showsSleepDisabledRow)
    #expect(fixture.pane.clearCaption == nil)
  }

  @Test(arguments: [AdminOutcome.failed("The administrator user name or password was incorrect."), .succeeded])
  func aFailedClearShowsTheTerminalCommandAndKeepsTheRow(_ outcome: AdminOutcome) async {
    let fixture = Clearing(reads: [true], outcomes: [outcome])
    await fixture.pane.poll()
    await fixture.pane.turnSleepBackOn()
    #expect(fixture.prompt.calls == 1)
    #expect(fixture.pane.clearCaption == Self.failedCaption)
    #expect(fixture.pane.showsSleepDisabledRow)
    #expect(fixture.pane.sleepDisabled == true)
  }

  @Test func anUnreadableValueAtThePressIsAFailureWithNoPrompt() async {
    let fixture = Clearing(reads: [true, nil])
    await fixture.pane.poll()
    await fixture.pane.turnSleepBackOn()
    #expect(fixture.prompt.calls == 0)
    #expect(fixture.pane.clearOutcome == .failed(.unreadable))
    #expect(fixture.pane.clearCaption == Self.failedCaption)
    #expect(fixture.pane.showsSleepDisabledRow)
  }

  @Test func aLaterReadOfZeroHidesTheRowAndForgetsTheCaption() async {
    let fixture = Clearing(reads: [true], outcomes: [.cancelled])
    await fixture.pane.poll()
    await fixture.pane.turnSleepBackOn()
    #expect(fixture.pane.clearCaption == Self.cancelledCaption)
    fixture.reader.set([false])
    await fixture.pane.poll()
    #expect(!fixture.pane.showsSleepDisabledRow)
    #expect(fixture.pane.clearOutcome == nil)
    #expect(fixture.pane.clearCaption == nil)
  }

  @Test func anUnreadableValueIsReadAgainAtTheNextPoll() async {
    let fixture = Clearing(reads: [nil, true])
    await fixture.pane.poll()
    #expect(fixture.pane.sleepDisabled == nil)
    await fixture.pane.poll()
    #expect(fixture.reader.reads == 2)
    #expect(fixture.pane.showsSleepDisabledRow)
  }

  @Test func anUnreadablePollKeepsTheLastValueRead() async {
    let fixture = Clearing(reads: [true, nil])
    await fixture.pane.poll()
    await fixture.pane.poll()
    #expect(fixture.reader.reads == 2)
    #expect(fixture.pane.sleepDisabled == true)
    #expect(fixture.pane.showsSleepDisabledRow)
  }

  @Test func aReadThatStartedBeforeAClearNeverBringsTheRowBack() async {
    let fixture = Clearing(reads: [true, true, true, false])
    let pane = fixture.pane
    await pane.poll()
    fixture.reader.holdNextRead()
    defer { fixture.reader.releaseRead() }
    let slow = Task { await pane.poll() }
    #expect(await waitUntil { fixture.reader.reads == 2 })
    await pane.turnSleepBackOn()
    #expect(fixture.reader.heldReadsReturned == 0)
    #expect(!pane.showsSleepDisabledRow)
    fixture.reader.releaseRead()
    await slow.value
    #expect(fixture.log.all == ["read", "read", "read", "prompt", "read"])
    #expect(pane.sleepDisabled == false)
    #expect(!pane.showsSleepDisabledRow)
  }

  @Test func whileThePromptIsOpenASecondPressOpensNoSecondPrompt() async {
    let fixture = Clearing(reads: [true, true, false])
    fixture.prompt.hold()
    defer { fixture.prompt.release() }
    let pane = fixture.pane
    await pane.poll()
    let first = Task { await pane.turnSleepBackOn() }
    #expect(await waitUntil { pane.clearing })
    await pane.turnSleepBackOn()
    await pane.poll()
    #expect(pane.clearing)
    fixture.prompt.release()
    await first.value
    #expect(fixture.prompt.calls == 1)
    #expect(fixture.log.all == ["read", "read", "prompt", "read"])
    #expect(!pane.clearing)
    #expect(!pane.showsSleepDisabledRow)
  }

  @Test func copyCommandCopiesTheOneCommandAndPromptsNothing() async {
    let fixture = Clearing(reads: [true])
    await fixture.pane.poll()
    fixture.pane.copyCommand()
    #expect(fixture.copied.all == ["sudo pmset -a disablesleep 0"])
    #expect(fixture.prompt.calls == 0)
    #expect(fixture.reader.reads == 1)
  }

  @Test func aClearMakesThePanelReadSleepDisabledAgain() async {
    let fixture = Clearing(reads: [true, true, false])
    let panelReads = EventLog()
    fixture.panel.applySleepDisabled(true)
    fixture.panel.readSleepDisabled = {
      panelReads.append("read")
      return false
    }
    await fixture.pane.poll()
    #expect(panelReads.all.isEmpty)
    await fixture.pane.turnSleepBackOn()
    #expect(await waitUntil { !fixture.panel.sleepDisabledLeftover })
    #expect(panelReads.all == ["read"])
  }

  @Test func theFourAboutNotesAreTheUISpecOnes() {
    #expect(UnplugProtectionPane.aboutTitle == "About unplug protection")
    #expect(UnplugProtectionPane.noteSymbol == "info.circle")
    #expect(
      UnplugProtectionPane.aboutNotes == [
        "Installing it needs one approval in System Settings. While you approve it, Overtime's login item may briefly show that it needs approval too.",
        "It runs as an administrator and does one thing: it turns system sleep off while Claude works with the lid closed, and back on afterwards.",
        "While it holds the Mac on battery, macOS can't put the Mac to sleep in an emergency. The helper lets go at 10% battery or if the Mac gets too hot.",
        "Turning it off in System Settings also quits Overtime. Open Overtime again afterwards.",
      ])
  }

  @Test func theRemoveConfirmationUsesTheUISpecCopy() {
    #expect(UnplugProtectionPane.removeConfirmation.title == "Remove unplug protection?")
    #expect(
      UnplugProtectionPane.removeConfirmation.message
        == "With the lid closed, unplugging power or a display can let the Mac sleep again.")
    #expect(UnplugProtectionPane.removeConfirmation.confirm == "Remove Unplug Protection")
    #expect(UnplugProtectionPane.removeConfirmation.keep == "Keep Unplug Protection")
  }

  @Test(arguments: [
    (HelperMonitorState(installer: .notRegistered), false), (HelperMonitorState(installer: .notFound), false),
    (HelperMonitorState(installer: .requiresApproval), true), (HelperPaneTests.standingBy, true),
    (HelperMonitorState(), false),
  ])
  func theBatteryPaneShowsTheHelperCaptionOnlyWhenTheHelperIsInstalled(
    _ state: HelperMonitorState, _ installed: Bool
  ) async throws {
    let folder = try TestFolder()
    let fixture = Scripted()
    let settings = SettingsModel(settingsFile: folder.url.appendingPathComponent("settings.json"), helper: fixture.pane)
    #expect(!settings.helperInstalled)
    await fixture.show(state)
    #expect(settings.helperInstalled == installed)
    #expect(BatteryPane.helperCaption == "Unplug protection also releases at 10% on its own. That limit is fixed.")
    #expect(BatteryPane.helperCaption.contains("\(HelperSafetyLimits.defaultBatteryFloorPercent)%"))
  }

  @Test(arguments: HelperUIState.allCases)
  func everyHelperStateUsesTheSharedStatusRowIcon(_ state: HelperUIState) {
    switch state.icon {
    case .progress:
      #expect(HelperStatusRowView.statusIcon(state.icon) == .progress)
    case .symbol(let name, let tone):
      #expect(HelperStatusRowView.statusIcon(state.icon) == .symbol(name, UnplugProtectionPane.tint(for: tone)))
    }
  }
}
