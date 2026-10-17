import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import OvertimeHelperCore
import OvertimeSystem
import Testing
import os

@testable import Overtime

extension AmphetamineLocator {
  static var absent: AmphetamineLocator {
    AmphetamineLocator(applicationURL: { _ in nil }, fileExists: { _ in false })
  }
}

@MainActor
struct PanelModelTests {
  @MainActor struct Bound {
    let clock = TestClock()
    let host: FakeEngineHost
    let model = PanelModel()

    init() {
      host = FakeEngineHost(clock: clock)
      model.homeDirectory = "/Users/dev"
      model.amphetamineLocator = .absent
      model.bind(to: host)
    }

    func started(secondsAgo: Double) -> Instant {
      clock.mono().adding(seconds: -secondsAgo)
    }
  }

  @Test func onlyTheWorkingSessionsOfASnapshotBecomeRows() async {
    let bound = Bound()
    let started = bound.started(secondsAgo: 86_400)
    let sessions = [
      SessionSummary(
        pid: 11, cwd: "/Users/dev/api", ttyName: "ttys003", startMono: started,
        workingSince: bound.started(secondsAgo: 3900)),
      SessionSummary(
        pid: 12, cwd: "/opt/web", ttyName: "ttys004", startMono: started, workingSince: bound.started(secondsAgo: 30)),
      SessionSummary(pid: 13, cwd: "/Users/dev/notes", ttyName: "ttys005", startMono: started),
    ]
    bound.host.publish(EngineSnapshot(busy: true, wanted: true, reason: "busy", lidClosed: false, sessions: sessions))
    #expect(await waitUntil { bound.model.snapshot?.sessions.count == 3 })
    let list = bound.model.sessionList
    #expect(list.rows.map(\.id) == [11, 12])
    #expect(list.rows.map(\.title) == ["api", "web"])
    #expect(list.rows.map(\.caption) == ["Working · 1h 5m", "Working · <1m"])
    #expect(list.summaryText == "1 more open, idle")
    #expect(bound.model.presentation.reason == "Claude is working in 2 sessions.")
  }

  @Test func noSessionsWhileClaudeIsBusyIsTheTranscriptOnlyState() async {
    let bound = Bound()
    bound.host.publish(EngineSnapshot(busy: true, wanted: true, reason: "busy"))
    #expect(await waitUntil { bound.model.snapshot != nil })
    #expect(bound.model.sessionList.placeholder == .transcriptOnly)
    #expect(bound.model.presentation.reason == "Claude is working.")
  }

  @Test func noSessionsWhileIdleIsTheEmptyState() async {
    let bound = Bound()
    bound.host.publish(EngineSnapshot(busy: false, wanted: false, reason: "idle"))
    #expect(await waitUntil { bound.model.snapshot != nil })
    #expect(bound.model.sessionList.placeholder == .noSessions)
  }

  @Test func aForceShowsTheHoldDurationFromWantedSince() async {
    let bound = Bound()
    let forcedAt = bound.clock.mono()
    bound.host.publish(EngineSnapshot(wanted: true, reason: "forced", force: .indefinite, wantedSince: forcedAt))
    #expect(await waitUntil { bound.model.snapshot?.wantedSince == forcedAt })
    bound.clock.advance(seconds: 48)
    #expect(bound.model.timingLine?.text == "Until you stop it · held for 0:48")
    #expect(bound.model.timingLine?.spoken == "until you stop it, held for less than a minute")
  }

  @Test func theAwakeTimeFollowsTheEngineClock() async {
    let bound = Bound()
    let forcedAt = bound.clock.mono()
    bound.host.publish(EngineSnapshot(wanted: true, reason: "forced", force: .indefinite, wantedSince: forcedAt))
    #expect(await waitUntil { bound.model.snapshot?.wantedSince == forcedAt })
    bound.clock.advance(seconds: 48)
    let forced = bound.model.awakeTime
    #expect(forced.figure == "0:48")
    #expect(!forced.isPlaceholder)
    #expect(forced.note == "Until you stop it")
    #expect(forced.spoken == bound.model.timingLine?.spoken)
    let deadline = bound.clock.mono().adding(seconds: 90)
    bound.host.publish(EngineSnapshot(wanted: false, reason: "paused", pause: .untilMono(deadline, wall: Date())))
    #expect(await waitUntil { bound.model.snapshot?.pause != nil })
    let paused = bound.model.awakeTime
    #expect(paused.figure == AwakeTime.placeholder)
    #expect(paused.isPlaceholder)
    #expect(paused.note == "Resumes in 1:30")
    #expect(paused.spoken == bound.model.timingLine?.spoken)
  }

  @Test func theTimingLineFollowsTheHostClockNotAUICounter() async {
    let bound = Bound()
    let deadline = bound.clock.mono().adding(seconds: 90)
    bound.host.publish(
      EngineSnapshot(wanted: false, reason: "paused", pause: .untilMono(deadline, wall: Date())))
    #expect(await waitUntil { bound.model.snapshot?.pause != nil })
    #expect(bound.model.timingLine?.text == "Resumes in 1:30")
    bound.clock.advance(seconds: 89.6)
    #expect(bound.model.timingLine?.text == "Resumes in 0:01")
  }

  @Test func thePanelTicksOnlyWhileAHostWindowIsVisible() {
    let model = PanelModel()
    let panel = ObjectIdentifier(NSObject.self)
    let reopen = ObjectIdentifier(PanelModel.self)
    #expect(!model.isPanelVisible)
    model.setVisible(true, host: panel)
    model.setVisible(true, host: reopen)
    model.setVisible(false, host: panel)
    #expect(model.isPanelVisible)
    model.setVisible(false, host: reopen)
    #expect(!model.isPanelVisible)
  }

  @Test func theModelOwnsNoTimer() {
    let labels = Mirror(reflecting: PanelModel()).children.compactMap(\.label)
    #expect(!labels.contains { $0.localizedCaseInsensitiveContains("timer") })
  }

  @Test func theStatusLinesFollowTheSnapshot() async {
    let bound = Bound()
    bound.host.publish(
      EngineSnapshot(
        busy: true, wanted: true, reason: "busy", lidClosed: true, power: .battery(percent: 72), externalDisplays: 1))
    #expect(await waitUntil { bound.model.snapshot != nil })
    #expect(bound.model.statusLines.map(\.value) == ["Closed, external display", "72%, on battery", "Failover off"])
  }

  @Test func theStatusChipsFollowTheSnapshot() async throws {
    let bound = Bound()
    bound.host.publish(
      EngineSnapshot(
        busy: true, wanted: true, reason: "busy", lidClosed: true, power: .battery(percent: 72), externalDisplays: 1))
    #expect(await waitUntil { bound.model.snapshot != nil })
    let summary = bound.model.statusChips
    try #require(summary.chips.count == 3)
    #expect(summary.chips.map(\.text) == ["Lid closed", "72%", "Failover off"])
    #expect(summary.details.map(\.text) == ["An external display is connected."])
    #expect(summary.chips.map(\.accessibilityText) == bound.model.statusLines.map(\.accessibilityText))
  }

  @Test func aSwitchedSummaryShowsTheHotspotWhileTheLidIsClosedAndReturningOnceItOpens() async {
    let bound = Bound()
    let summary = NetworkSummary(
      wired: false, wifiFound: true, onHotspot: true, switched: true, readiness: .armed(.auto), phase: .idle)
    bound.host.publish(EngineSnapshot(lidClosed: true, network: summary))
    #expect(await waitUntil { bound.model.snapshot?.lidClosed == true })
    let closed = bound.model.statusLines.last
    #expect(closed?.label == "Network")
    #expect(closed?.value == "On your iPhone hotspot")
    #expect(closed?.detail == "Returns to your usual network when you open the lid.")
    #expect(bound.model.statusLines.dropLast().allSatisfy { $0.detail == nil })
    bound.host.publish(EngineSnapshot(lidClosed: false, network: summary))
    #expect(await waitUntil { bound.model.snapshot?.lidClosed == false })
    let opened = bound.model.statusLines.last
    #expect(opened?.label == "Network")
    #expect(opened?.value == "Returning to your usual network…")
    #expect(opened?.detail == nil)
    #expect(bound.model.statusLines.allSatisfy { $0.detail == nil })
  }

  @Test func aStoppedReturnShowsStillOnTheHotspotWithWhatToDoOnceTheLidIsOpen() async {
    let bound = Bound()
    var summary = NetworkSummary(
      wired: false, wifiFound: true, onHotspot: true, switched: true, readiness: .armed(.auto), phase: .idle,
      returnStop: .adminRequired)
    bound.host.publish(EngineSnapshot(lidClosed: false, network: summary))
    #expect(await waitUntil { bound.model.snapshot?.lidClosed == false })
    let stopped = bound.model.statusLines.last
    #expect(stopped?.label == "Network")
    #expect(stopped?.value == "Still on your iPhone hotspot")
    #expect(stopped?.detail == "Turn Wi-Fi off and on to return to your usual network.")
    #expect(bound.model.statusLines.dropLast().allSatisfy { $0.detail == nil })
    summary.returnStop = .backOnHotspot
    bound.host.publish(EngineSnapshot(lidClosed: false, network: summary))
    #expect(await waitUntil { bound.model.snapshot?.network?.returnStop == .backOnHotspot })
    let rejoined = bound.model.statusLines.last
    #expect(rejoined?.value == "Still on your iPhone hotspot")
    #expect(rejoined?.detail == "macOS rejoined it. Choose your usual network in the Wi-Fi menu.")
    #expect(bound.model.statusLines.dropLast().allSatisfy { $0.detail == nil })
  }

  @Test func aFailoverOffReasonShowsItsDetailUnderTheNetworkRow() async {
    let bound = Bound()
    var summary = NetworkSummary(
      wired: false, wifiFound: true, onHotspot: false, readiness: .off(.wired), phase: .idle)
    bound.host.publish(EngineSnapshot(lidClosed: true, network: summary))
    #expect(await waitUntil { bound.model.snapshot?.network?.readiness == .off(.wired) })
    let offReason = bound.model.statusLines.last
    #expect(offReason?.label == "Network")
    #expect(offReason?.value == "Failover off")
    #expect(offReason?.detail == "The Mac has a wired connection.")
    #expect(bound.model.statusLines.dropLast().allSatisfy { $0.detail == nil })
    summary.readiness = .off(.noHotspot)
    bound.host.publish(EngineSnapshot(lidClosed: true, network: summary))
    #expect(await waitUntil { bound.model.snapshot?.network?.readiness == .off(.noHotspot) })
    #expect(bound.model.statusLines.last?.value == "Failover off")
    #expect(bound.model.statusLines.last?.detail == nil)
    summary.autoDetect = true
    bound.host.publish(EngineSnapshot(lidClosed: true, network: summary))
    #expect(await waitUntil { bound.model.snapshot?.network?.autoDetect == true })
    #expect(bound.model.statusLines.last?.value == "Failover off")
    #expect(
      bound.model.statusLines.last?.detail == "Overtime can't find an iPhone hotspot among your known networks.")
  }

  @Test func theNetworkRowShowsTheHotspotGlyphWhileItSaysTheMacIsOnTheHotspot() async {
    let bound = Bound()
    let summary = NetworkSummary(
      wired: false, wifiFound: true, onHotspot: true, switched: true, readiness: .armed(.auto), phase: .idle)
    bound.host.publish(EngineSnapshot(lidClosed: true, network: summary))
    #expect(await waitUntil { bound.model.snapshot?.lidClosed == true })
    let closed = bound.model.statusLines.last
    #expect(closed?.icon == "personalhotspot")
    #expect(
      closed?.accessibilityText
        == "Network, on your iPhone hotspot. Returns to your usual network when you open the lid.")
    bound.host.publish(EngineSnapshot(lidClosed: false, network: summary))
    #expect(await waitUntil { bound.model.snapshot?.lidClosed == false })
    let opened = bound.model.statusLines.last
    #expect(opened?.icon == "wifi")
    #expect(opened?.value == "Returning to your usual network…")
  }

  @Test func anInstalledAmphetamineAndAHoldShowTheirHints() async {
    let bound = Bound()
    bound.model.amphetamineLocator = AmphetamineLocator(applicationURL: { _ in nil }, fileExists: { _ in true })
    bound.model.refreshInstalledTools()
    bound.host.publish(EngineSnapshot(busy: true, wanted: true, reason: "busy", lidClosed: false))
    #expect(await waitUntil { bound.model.snapshot != nil })
    #expect(bound.model.hints.map(\.priority) == [4, 5])
  }

  @Test func coexistenceHintsNeedAWarnedEpisode() async {
    let bound = Bound()
    bound.host.publish(
      EngineSnapshot(wanted: false, reason: "idle", coexistenceWarned: false, amphetamineRunning: true))
    #expect(await waitUntil { bound.model.snapshot != nil })
    #expect(bound.model.hints.isEmpty)
    bound.host.publish(
      EngineSnapshot(
        busy: true, wanted: true, reason: "busy", coexistenceWarned: true, amphetamineRunning: false,
        otherTools: ["Lungo"]))
    #expect(await waitUntil { bound.model.snapshot?.coexistenceWarned == true })
    #expect(bound.model.hints.first?.text == "Lungo is also managing sleep. Running both is unsupported.")
  }

  @Test func sleepNowSendsAtOnceWhenClaudeIsNotBusy() async {
    let bound = Bound()
    bound.host.publish(EngineSnapshot(busy: false, wanted: false, reason: "idle"))
    #expect(await waitUntil { bound.model.snapshot != nil })
    await bound.model.pressSleepNow()?.value
    #expect(bound.host.requests == [.sleepNow])
    #expect(bound.model.sleepConfirmation.isConfirming == false)
  }

  @Test func sleepNowAsksFirstWhileClaudeIsBusy() async {
    let bound = Bound()
    bound.host.publish(EngineSnapshot(busy: true, wanted: true, reason: "busy"))
    #expect(await waitUntil { bound.model.snapshot != nil })
    #expect(bound.model.pressSleepNow() == nil)
    #expect(bound.model.sleepConfirmation.isConfirming)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(bound.host.requests.isEmpty)
    await bound.model.confirmSleep().value
    #expect(bound.host.requests == [.sleepNow])
    #expect(bound.model.sleepConfirmation.isConfirming == false)
  }

  @Test func keepWorkingSendsNothing() async {
    let bound = Bound()
    bound.host.publish(EngineSnapshot(busy: true, wanted: true, reason: "busy"))
    #expect(await waitUntil { bound.model.snapshot != nil })
    #expect(bound.model.pressSleepNow() == nil)
    bound.model.keepWorking()
    #expect(bound.model.sleepConfirmation.isConfirming == false)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(bound.host.requests.isEmpty)
  }

  @Test func restoreShowsTheSuccessCopyForItsDurationThenTheDerivedReason() async {
    let bound = Bound()
    let reset = FakeEmergencyReset()
    bound.model.emergency = EmergencyCoordinator(reset: reset, releaseUntilIdle: { true })
    bound.model.restoreResultSeconds = 0.3
    bound.host.publish(EngineSnapshot(busy: false, wanted: false, reason: "idle"))
    #expect(await waitUntil { bound.model.snapshot != nil })
    await bound.model.restore()?.value
    #expect(reset.runs == 1)
    #expect(bound.model.presentation.reason == "Normal sleep restored.")
    #expect(bound.model.presentation.state == .idle)
    #expect(await waitUntil { bound.model.presentation.reason == "No Claude activity. The Mac sleeps normally." })
    #expect(bound.model.restoreNotice == nil)
  }

  @Test func aFailedRestoreKeepsItsCopyUntilTheStateChanges() async {
    let bound = Bound()
    let reset = FakeEmergencyReset([.clearFailed("timedOut", helperCleared: true)])
    bound.model.emergency = EmergencyCoordinator(reset: reset, releaseUntilIdle: { true })
    bound.model.restoreResultSeconds = 0.05
    let failure = "Couldn't restore normal sleep. Run Overtime.app/Contents/MacOS/Overtime --reset in Terminal."
    bound.host.publish(EngineSnapshot(busy: true, wanted: true, reason: "busy"))
    #expect(await waitUntil { bound.model.snapshot != nil })
    await bound.model.restore()?.value
    #expect(bound.model.presentation.reason == failure)
    try? await Task.sleep(for: .milliseconds(150))
    #expect(bound.model.presentation.reason == failure)
    let sessions = [SessionSummary(pid: 7, cwd: "/tmp", ttyName: "ttys001", startMono: bound.clock.mono())]
    bound.host.publish(EngineSnapshot(busy: true, wanted: true, reason: "busy", sessions: sessions))
    #expect(await waitUntil { bound.model.snapshot?.sessions.count == 1 })
    #expect(bound.model.presentation.reason == failure)
    bound.host.publish(EngineSnapshot(busy: false, wanted: false, reason: "idle"))
    #expect(await waitUntil { bound.model.presentation.state == .idle })
    #expect(bound.model.presentation.reason == "No Claude activity. The Mac sleeps normally.")
  }

  @Test func aFailedRestoreWhoseHelperDidNotClearNamesSleepDisabled() async {
    let bound = Bound()
    let reset = FakeEmergencyReset([.clearFailed("-1", helperCleared: false)])
    bound.model.emergency = EmergencyCoordinator(reset: reset, releaseUntilIdle: { true })
    bound.host.publish(EngineSnapshot(busy: true, wanted: true, reason: "busy"))
    #expect(await waitUntil { bound.model.snapshot != nil })
    await bound.model.restore()?.value
    #expect(bound.model.restoreNotice?.kind == .restoreFailed)
    #expect(
      bound.model.presentation.reason == EmergencyCoordinator.failedWithSleepDisabledCopy,
      "R2-WR-03: the failure copy names SleepDisabled when the helper did not clear")
    #expect(bound.model.presentation.reason.contains("SleepDisabled"))
  }

  @Test func anOverlappingRestoreChangesNothing() async {
    let bound = Bound()
    bound.model.emergency = EmergencyCoordinator(reset: FakeEmergencyReset([.inProgress]), releaseUntilIdle: { true })
    bound.host.publish(EngineSnapshot(busy: false, wanted: false, reason: "idle"))
    #expect(await waitUntil { bound.model.snapshot != nil })
    await bound.model.restore()?.value
    #expect(bound.model.restoreNotice == nil)
    #expect(bound.model.presentation.reason == "No Claude activity. The Mac sleeps normally.")
  }

  static let helperNotClaimed: Comment =
    "S-CR-01: after a restore whose helper clear did not succeed the panel never says \"Normal sleep restored.\" until SleepDisabled reads 0, and it offers Turn sleep back on…"

  @MainActor struct HelperNotCleared {
    let bound = Bound()
    let log = HelperPaneTests.EventLog()
    let reader: HelperPaneTests.ScriptedReader
    let prompt: HelperPaneTests.FakeAdminPrompt

    init(reads: [Bool?], outcomes: [AdminOutcome] = [], prompt attached: Bool = true) {
      reader = HelperPaneTests.ScriptedReader(reads, log: log)
      prompt = HelperPaneTests.FakeAdminPrompt(outcomes, log: log)
      let reader = reader
      let reset = FakeEmergencyReset([.restored(released: 0, helperCleared: false)])
      bound.model.emergency = EmergencyCoordinator(reset: reset, releaseUntilIdle: { true })
      bound.model.restoreResultSeconds = 60
      bound.model.readSleepDisabled = { reader.read() }
      if attached {
        bound.model.adminPrompt = prompt
      }
    }

    func restore() async {
      bound.host.publish(EngineSnapshot(busy: true, wanted: true, reason: "busy", helperEngaged: true))
      _ = await waitUntil { bound.model.snapshot != nil }
      await bound.model.restore()?.value
    }
  }

  @Test func aRestoreWhoseHelperDidNotClearShowsItsOwnCopyAndOffersTurnSleepBackOnAcrossStateChanges() async {
    let fixture = HelperNotCleared(reads: [true])
    await fixture.restore()
    let model = fixture.bound.model
    #expect(model.presentation.reason == EmergencyCoordinator.helperNotClearedCopy, Self.helperNotClaimed)
    #expect(model.presentation.reason != "Normal sleep restored.", Self.helperNotClaimed)
    #expect(model.offersTurnSleepBackOn, Self.helperNotClaimed)
    #expect(fixture.reader.reads == 1)
    #expect(fixture.prompt.calls == 0, "the administrator prompt opens only on the explicit action")
    fixture.bound.host.publish(EngineSnapshot(busy: false, wanted: false, reason: "idle"))
    #expect(await waitUntil { model.presentation.state == .idle })
    #expect(model.presentation.reason == EmergencyCoordinator.helperNotClearedCopy, Self.helperNotClaimed)
    #expect(model.offersTurnSleepBackOn)
  }

  @Test func turnSleepBackOnAfterAnUnconfirmedRestoreClearsWithTheAdminPromptAndThenSaysRestored() async {
    let fixture = HelperNotCleared(reads: [true, true, false], outcomes: [.succeeded])
    await fixture.restore()
    let model = fixture.bound.model
    #expect(model.offersTurnSleepBackOn)
    await model.turnSleepBackOn()
    #expect(fixture.prompt.calls == 1)
    #expect(fixture.log.all == ["read", "read", "prompt", "read"])
    #expect(model.presentation.reason == "Normal sleep restored.")
    #expect(model.restoreNotice?.kind == .restored)
    #expect(!model.offersTurnSleepBackOn)
    #expect(!model.clearingSleepDisabled)
  }

  @Test(arguments: [
    (AdminOutcome.cancelled, SleepDisabledClearing.cancelledCaption),
    (AdminOutcome.failed("no"), SleepDisabledClearing.failedCaption),
  ])
  func aCancelledOrFailedTurnSleepBackOnSaysSoAndKeepsTheAction(_ outcome: AdminOutcome, _ caption: String) async {
    let fixture = HelperNotCleared(reads: [true], outcomes: [outcome])
    await fixture.restore()
    let model = fixture.bound.model
    await model.turnSleepBackOn()
    #expect(fixture.prompt.calls == 1)
    #expect(model.presentation.reason == caption)
    #expect(model.restoreNotice?.kind == .helperNotCleared)
    #expect(model.offersTurnSleepBackOn)
  }

  @Test func aSleepDisabledReadOfZeroAfterAnUnconfirmedRestoreSaysRestored() async {
    let fixture = HelperNotCleared(reads: [false])
    await fixture.restore()
    let model = fixture.bound.model
    #expect(fixture.reader.reads == 1)
    #expect(model.presentation.reason == "Normal sleep restored.")
    #expect(!model.offersTurnSleepBackOn)
    #expect(fixture.prompt.calls == 0)
  }

  @Test func withoutAnAdminPromptTheUnconfirmedRestoreStillSaysSoButOffersNoAction() async {
    let fixture = HelperNotCleared(reads: [true], prompt: false)
    await fixture.restore()
    let model = fixture.bound.model
    #expect(model.presentation.reason == EmergencyCoordinator.helperNotClearedCopy, Self.helperNotClaimed)
    #expect(!model.offersTurnSleepBackOn)
    await model.turnSleepBackOn()
    #expect(fixture.prompt.calls == 0)
  }

  @Test func aControlFailureNeverReplacesTheUnconfirmedRestoreCopy() async {
    let fixture = HelperNotCleared(reads: [true])
    await fixture.restore()
    let model = fixture.bound.model
    fixture.bound.host.respond(with: .failure("rejected"))
    await model.perform(.pause(.timed(minutes: 60)))
    #expect(fixture.bound.host.requests == [.pause(.forSeconds(3600))])
    #expect(model.presentation.reason == EmergencyCoordinator.helperNotClearedCopy)
  }

  @Test(arguments: RestoreSetup.allCases)
  func restoreRunsInEveryState(_ setup: RestoreSetup) async {
    let model = PanelModel()
    let reset = FakeEmergencyReset()
    model.emergency = EmergencyCoordinator(reset: reset, releaseUntilIdle: { nil })
    setup.apply(to: model)
    #expect(setup.expected == model.presentation.state)
    await model.restore()?.value
    #expect(reset.runs == 1)
    #expect(model.presentation.reason == "Normal sleep restored.")
  }

  enum RestoreSetup: CaseIterable, Sendable {
    case starting
    case holding
    case holdFailed
    case notResponding
    case couldNotStart
    case watchdogUnavailable
    case storageUnavailable

    var expected: PanelState {
      switch self {
      case .starting: .starting
      case .holding: .holding
      case .holdFailed: .error(.holdFailed)
      case .notResponding: .error(.notResponding)
      case .couldNotStart: .error(.couldNotStart)
      case .watchdogUnavailable: .error(.watchdogUnavailable)
      case .storageUnavailable: .error(.storageUnavailable)
      }
    }

    @MainActor func apply(to model: PanelModel) {
      switch self {
      case .starting:
        break
      case .holding:
        model.apply(EngineSnapshot(busy: true, wanted: true, reason: "busy"))
      case .holdFailed:
        model.apply(EngineSnapshot(busy: true, wanted: true, reason: "busy", holdError: true))
      case .notResponding:
        model.engineUnresponsive = true
      case .couldNotStart:
        model.hostFailure = .lockHeldElsewhere
      case .watchdogUnavailable:
        model.hostFailure = .sentinelUnavailable
      case .storageUnavailable:
        model.hostFailure = .storageUnavailable
      }
    }
  }

  @Test func aProbeThatTimesOutShowsTheNotRespondingErrorAndALaterSnapshotClearsIt() async {
    let bound = Bound()
    bound.model.livenessIntervalSeconds = 0.05
    bound.host.scriptProbe(nil)
    bound.host.publish(EngineSnapshot(busy: false, wanted: false, reason: "idle"))
    #expect(await waitUntil { bound.model.snapshot != nil })
    bound.model.setVisible(true, host: ObjectIdentifier(NSObject.self))
    #expect(await waitUntil { bound.model.engineUnresponsive })
    #expect(bound.model.presentation.state == .error(.notResponding))
    #expect(bound.model.presentation.title == "Overtime isn't responding")
    bound.host.scriptProbe(EngineSnapshot(busy: false, wanted: false, reason: "idle"))
    #expect(await waitUntil { !bound.model.engineUnresponsive })
    #expect(bound.model.presentation.state == .idle)
    bound.model.setVisible(false, host: ObjectIdentifier(NSObject.self))
  }

  @Test func nothingProbesWhileThePanelIsClosed() async {
    let bound = Bound()
    bound.model.livenessIntervalSeconds = 0.05
    try? await Task.sleep(for: .milliseconds(200))
    #expect(bound.host.probes == 0)
    let panel = ObjectIdentifier(NSObject.self)
    bound.model.setVisible(true, host: panel)
    #expect(await waitUntil { bound.host.probes >= 2 })
    bound.model.setVisible(false, host: panel)
    try? await Task.sleep(for: .milliseconds(100))
    let settled = bound.host.probes
    try? await Task.sleep(for: .milliseconds(250))
    #expect(bound.host.probes == settled)
  }

  @Test func aControlPressTriggersOneProbe() async {
    let bound = Bound()
    await bound.model.perform(.resume)
    #expect(bound.host.requests == [.resume])
    #expect(bound.host.probes == 1)
  }

  @Test func aTimedOutRestoreFollowUpMarksTheEngineUnresponsive() async {
    let bound = Bound()
    bound.model.emergency = EmergencyCoordinator(
      reset: FakeEmergencyReset(), releaseUntilIdle: { nil }, followUpBoundSeconds: 0.2)
    bound.host.publish(EngineSnapshot(busy: false, wanted: false, reason: "idle"))
    #expect(await waitUntil { bound.model.snapshot != nil })
    bound.host.scriptProbe(nil)
    await bound.model.restore()?.value
    #expect(bound.model.engineUnresponsive)
    #expect(bound.model.presentation.state == .error(.notResponding))
    #expect(bound.model.presentation.reason == "Normal sleep restored.")
  }

  @Test func aRestoreSendsReleaseUntilIdleToTheBoundHost() async {
    let bound = Bound()
    let host = bound.host
    bound.model.emergency = EmergencyCoordinator(
      reset: FakeEmergencyReset(), releaseUntilIdle: { await host.send(.releaseUntilIdle).map(\.ok) })
    await bound.model.restore()?.value
    #expect(bound.host.requests == [.releaseUntilIdle])
    #expect(!bound.model.engineUnresponsive)
  }

  @Test func controlChoicesReachTheHostAsTheirExactRequests() async {
    let bound = Bound()
    await bound.model.perform(.pause(.timed(minutes: 60)))
    await bound.model.perform(.keepAwake(.timed(minutes: 120)))
    await bound.model.perform(.releaseUntilIdle)
    await bound.model.perform(.stopKeepingAwake)
    #expect(
      bound.host.requests == [.pause(.forSeconds(3600)), .force(.forSeconds(7200)), .releaseUntilIdle, .resume])
  }

  static let idleReason = "No Claude activity. The Mac sleeps normally."

  @Test func aRejectedControlShowsItsFailureCopyThenTheDerivedReason() async {
    let bound = Bound()
    bound.model.controlNoticeSeconds = 0.3
    bound.host.respond(with: .failure("engine says no: pause refused"))
    bound.host.publish(EngineSnapshot(busy: false, wanted: false, reason: "idle"))
    #expect(await waitUntil { bound.model.snapshot != nil })
    let response = await bound.model.perform(.pause(.timed(minutes: 60)))
    #expect(response?.ok == false)
    #expect(bound.model.presentation.reason == "Couldn't pause. Try again.")
    #expect(await waitUntil { bound.model.presentation.reason == Self.idleReason })
    #expect(bound.model.restoreNotice == nil)
  }

  @Test func aTimedOutControlShowsItsFailureCopy() async {
    let bound = Bound()
    bound.host.respond(with: nil)
    bound.host.publish(EngineSnapshot(busy: false, wanted: false, reason: "idle"))
    #expect(await waitUntil { bound.model.snapshot != nil })
    #expect(await bound.model.perform(.keepAwake(.timed(minutes: 120))) == nil)
    #expect(bound.host.requests == [.force(.forSeconds(7200))])
    #expect(bound.model.presentation.reason == "Couldn't turn on Keep Awake. Try again.")
  }

  @Test func aControlWithoutAnEngineShowsItsFailureCopy() async {
    let model = PanelModel()
    #expect(await model.perform(.resume) == nil)
    #expect(model.presentation.state == .starting)
    #expect(model.presentation.reason == "Couldn't resume. Try again.")
  }

  @Test func aFailedSleepNowShowsItsFailureCopy() async {
    let bound = Bound()
    bound.host.respond(with: nil)
    bound.host.publish(EngineSnapshot(busy: false, wanted: false, reason: "idle"))
    #expect(await waitUntil { bound.model.snapshot != nil })
    await bound.model.pressSleepNow()?.value
    #expect(bound.host.requests == [.sleepNow])
    #expect(bound.model.presentation.reason == "Couldn't put the Mac to sleep. Try again.")
  }

  @Test func anAcceptedControlShowsNoFailureCopy() async {
    let bound = Bound()
    bound.host.publish(EngineSnapshot(busy: true, wanted: true, reason: "busy"))
    #expect(await waitUntil { bound.model.snapshot != nil })
    #expect(await bound.model.perform(.releaseUntilIdle)?.ok == true)
    #expect(bound.host.requests == [.releaseUntilIdle])
    #expect(bound.model.restoreNotice == nil)
    #expect(bound.model.presentation.reason == "Claude is working.")
  }

  @Test func aStateChangeDropsTheControlFailureCopy() async {
    let bound = Bound()
    bound.model.controlNoticeSeconds = 60
    bound.host.respond(with: .failure("rejected"))
    bound.host.publish(EngineSnapshot(busy: false, wanted: false, reason: "idle"))
    #expect(await waitUntil { bound.model.snapshot != nil })
    await bound.model.perform(.pause(.timed(minutes: 60)))
    #expect(bound.model.presentation.reason == "Couldn't pause. Try again.")
    bound.host.publish(EngineSnapshot(busy: true, wanted: true, reason: "busy"))
    #expect(await waitUntil { bound.model.presentation.state == .holding })
    #expect(bound.model.presentation.reason == "Claude is working.")
    #expect(bound.model.restoreNotice == nil)
  }

  @Test func aControlFailureNeverReplacesTheRestoreFailureCopy() async {
    let bound = Bound()
    let failure = "Couldn't restore normal sleep. Run Overtime.app/Contents/MacOS/Overtime --reset in Terminal."
    bound.model.emergency = EmergencyCoordinator(
      reset: FakeEmergencyReset([.clearFailed("timedOut", helperCleared: true)]), releaseUntilIdle: { true })
    bound.host.publish(EngineSnapshot(busy: true, wanted: true, reason: "busy"))
    #expect(await waitUntil { bound.model.snapshot != nil })
    await bound.model.restore()?.value
    #expect(bound.model.presentation.reason == failure)
    bound.host.respond(with: .failure("rejected"))
    await bound.model.perform(.pause(.timed(minutes: 60)))
    #expect(bound.host.requests == [.pause(.forSeconds(3600))])
    #expect(bound.model.presentation.reason == failure)
  }

  @Test func aStartupFailureReplacesAPendingControlFailureCopyAtOnce() async {
    let model = PanelModel()
    model.controlNoticeSeconds = 60
    #expect(await model.perform(.pause(.timed(minutes: 60))) == nil)
    #expect(model.presentation.reason == "Couldn't pause. Try again.")
    model.hostFailure = .lockHeldElsewhere
    #expect(model.presentation.state == .error(.couldNotStart))
    #expect(
      model.presentation.reason
        == "Another Overtime process is already running, for example overtimed --live. Quit it, then reopen Overtime.")
    #expect(model.restoreNotice == nil)
  }

  @Test func aBlockedRestartReplacesAPendingControlFailureCopyAtOnce() async {
    let bound = Bound()
    bound.model.controlNoticeSeconds = 60
    bound.host.respond(with: .failure("rejected"))
    bound.host.publish(EngineSnapshot(busy: false, wanted: false, reason: "idle"))
    #expect(await waitUntil { bound.model.snapshot != nil })
    await bound.model.perform(.pause(.timed(minutes: 60)))
    #expect(bound.model.presentation.reason == "Couldn't pause. Try again.")
    bound.model.applyRestart(.blocked(.sentinelUnavailable))
    #expect(bound.model.presentation.state == .error(.watchdogUnavailable))
    #expect(bound.model.presentation.reason == "Its keep-awake watchdog could not start. Quit and reopen Overtime.")
    #expect(bound.model.restoreNotice == nil)
  }

  @Test func unbindingClearsAPendingControlFailureCopy() async {
    let bound = Bound()
    bound.model.controlNoticeSeconds = 60
    bound.host.respond(with: .failure("rejected"))
    bound.host.publish(EngineSnapshot(busy: false, wanted: false, reason: "idle"))
    #expect(await waitUntil { bound.model.snapshot != nil })
    await bound.model.perform(.pause(.timed(minutes: 60)))
    #expect(bound.model.presentation.reason == "Couldn't pause. Try again.")
    bound.model.unbind()
    #expect(bound.model.restoreNotice == nil)
    #expect(bound.model.presentation.reason != "Couldn't pause. Try again.")
  }

  static let everyAction: [ControlAction] =
    PauseChoice.defaultMenu.map(ControlAction.pause) + KeepAwakeChoice.defaultMenu.map(ControlAction.keepAwake) + [
      .releaseUntilIdle, .resume, .stopKeepingAwake,
    ]

  @Test(arguments: [RestoreSetup.notResponding, .couldNotStart, .watchdogUnavailable, .storageUnavailable])
  func engineBoundControlsSendNothingWhileTheEngineIsUnavailable(_ setup: RestoreSetup) async {
    let bound = Bound()
    bound.host.publish(EngineSnapshot(busy: true, wanted: true, reason: "busy"))
    #expect(await waitUntil { bound.model.snapshot != nil })
    setup.apply(to: bound.model)
    #expect(bound.model.presentation.state == setup.expected)
    #expect(bound.model.controls.engineControlsEnabled == false)
    for action in Self.everyAction {
      #expect(await bound.model.perform(action) == nil)
    }
    await bound.model.pressSleepNow()?.value
    #expect(bound.model.sleepConfirmation.isConfirming == false)
    await bound.model.confirmSleep().value
    #expect(bound.model.sleepConfirmation.isConfirming == false)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(bound.host.requests.isEmpty)
    #expect(bound.model.restoreNotice == nil)
  }

  @Test func engineBoundControlsStillSendWhenKeepAwakeFailed() async {
    let bound = Bound()
    bound.host.publish(EngineSnapshot(busy: true, wanted: true, reason: "busy", holdError: true))
    #expect(await waitUntil { bound.model.snapshot != nil })
    #expect(bound.model.presentation.state == .error(.holdFailed))
    #expect(bound.model.controls.engineControlsEnabled)
    #expect(await bound.model.perform(.pause(.timed(minutes: 60)))?.ok == true)
    #expect(bound.host.requests == [.pause(.forSeconds(3600))])
  }

  @Test func thePanelMenusFollowTheSnapshotDurations() async {
    let bound = Bound()
    bound.host.publish(
      EngineSnapshot(
        busy: false, wanted: false, reason: "idle", pauseFirstMinutes: 45, pauseSecondMinutes: 90,
        keepAwakeFirstMinutes: 1440, keepAwakeSecondMinutes: 10))
    #expect(await waitUntil { bound.model.snapshot != nil })
    #expect(
      bound.model.pauseChoices.map(\.label) == ["45 Minutes", "1 Hour 30 Minutes", "Until Tomorrow", "Until Resumed"])
    #expect(bound.model.keepAwakeChoices.map(\.label) == ["10 Minutes", "24 Hours", "Until Stopped"])
    #expect(await bound.model.perform(.pause(.timed(minutes: 45)))?.ok == true)
    #expect(bound.host.requests == [.pause(.forSeconds(2700))])
  }

  @Test func thePanelHidesTheUnplugHintWhileTheLidClosedHoldIsOff() async {
    let off = Bound()
    off.host.publish(
      EngineSnapshot(
        busy: true, wanted: true, reason: "busy", lidClosed: false, lidClosedKeepAwake: .never,
        lidClosedHoldAllowed: false))
    #expect(await waitUntil { off.model.snapshot != nil })
    #expect(off.model.presentation.state == .holding)
    #expect(!off.model.hints.contains { $0.action == .setUpUnplugProtection || $0.action == .reviewUnplugProtection })
    #expect(!off.model.hints.contains { $0.priority == 5 })

    let always = Bound()
    always.host.publish(EngineSnapshot(busy: true, wanted: true, reason: "busy", lidClosed: false))
    #expect(await waitUntil { always.model.snapshot != nil })
    #expect(always.model.hints.contains { $0.action == .setUpUnplugProtection })
  }

  @Test func withoutASnapshotThePanelMenusAreTheDefaultOnes() {
    let model = PanelModel()
    #expect(model.snapshot == nil)
    #expect(model.pauseChoices == PauseChoice.defaultMenu)
    #expect(model.keepAwakeChoices == KeepAwakeChoice.defaultMenu)
    #expect(model.pauseChoices.map(\.label) == ["15 Minutes", "1 Hour", "Until Tomorrow", "Until Resumed"])
    #expect(model.keepAwakeChoices.map(\.label) == ["30 Minutes", "2 Hours", "Until Stopped"])
  }

  @Test func copyCommandPutsTheFixedStringOnThePasteboardAndRunsNothing() async {
    let bound = Bound()
    var copied: [String] = []
    bound.model.copyToPasteboard = { copied.append($0) }
    bound.model.performHint(.copyCommand)
    #expect(copied == ["sudo pmset -a disablesleep 0"])
    #expect(bound.host.requests.isEmpty)
  }

  @Test func aLiveSleepDisabledReadFeedsHintOne() async {
    let model = PanelModel()
    #expect(model.hints.isEmpty)
    let live = OSAllocatedUnfairLock<Bool?>(initialState: true)
    model.readSleepDisabled = { live.withLock { $0 } }
    await model.refreshSleepDisabled()?.value
    #expect(model.hints.map(\.priority) == [1])
    #expect(model.hints.first?.action == .copyCommand)
    live.withLock { $0 = false }
    await model.refreshSleepDisabled()?.value
    #expect(model.hints.isEmpty)
    live.withLock { $0 = nil }
    model.applySleepDisabled(true)
    await model.refreshSleepDisabled()?.value
    #expect(model.hints.isEmpty)
  }

  @Test func afterAHostSwapTheModelFollowsTheNewSnapshotStream() async {
    let bound = Bound()
    bound.host.publish(EngineSnapshot(mode: .live, busy: false, wanted: false, reason: "idle"))
    #expect(await waitUntil { bound.model.presentation.state == .idle })
    bound.model.hostFailure = .sentinelUnavailable

    let replacement = FakeEngineHost(clock: bound.clock)
    bound.model.rebind(to: replacement)
    #expect((bound.model.host as? FakeEngineHost) === replacement)
    #expect(bound.model.hostFailure == nil)
    #expect(bound.model.presentation.state == .starting)

    bound.host.publish(EngineSnapshot(wanted: true, reason: "forced", force: .indefinite))
    replacement.publish(EngineSnapshot(wanted: false, reason: "paused", pause: .indefinite))
    #expect(await waitUntil { bound.model.presentation.state == .paused })
    try? await Task.sleep(for: .milliseconds(100))
    #expect(bound.model.presentation.state == .paused)
  }

  final class FakeLoginItem: LoginItemService, @unchecked Sendable {
    struct Refused: Error, CustomStringConvertible {
      var description: String { "Operation not permitted" }
    }

    var status: LoginItemStatus
    var refuse = false
    private(set) var calls: [String] = []

    init(status: LoginItemStatus) {
      self.status = status
    }

    func register() throws {
      calls.append("register")
      if refuse { throw Refused() }
      status = .enabled
    }

    func unregister() throws {
      calls.append("unregister")
      status = .notRegistered
    }

    func openSystemSettings() {
      calls.append("openSystemSettings")
    }
  }

  @Test func theLoginSwitchReflectsTheServiceStatus() {
    let model = PanelModel()
    #expect(model.loginItem == nil)
    #expect(!model.launchAtLogin)
    #expect(model.loginItemCaption == nil)
    let service = FakeLoginItem(status: .enabled)
    model.attachLoginItem(service)
    #expect(model.launchAtLogin)
    #expect(model.loginItemCaption == nil)
    service.status = .notRegistered
    model.refreshLoginItem()
    #expect(!model.launchAtLogin)
    #expect(model.loginItemCaption == nil)
  }

  @Test func theLoginSectionShowsInThePanelOnlyWhenItNeedsAttention() {
    let model = PanelModel()
    model.logLoginItemError = { _ in }
    #expect(!model.showsLoginItemSection)
    let service = FakeLoginItem(status: .enabled)
    model.attachLoginItem(service)
    #expect(!model.showsLoginItemSection)
    service.status = .notRegistered
    model.refreshLoginItem()
    #expect(!model.showsLoginItemSection)
    service.status = .requiresApproval
    model.refreshLoginItem()
    #expect(model.showsLoginItemSection)
    service.status = .notRegistered
    model.refreshLoginItem()
    #expect(!model.showsLoginItemSection)
    service.refuse = true
    model.setLaunchAtLogin(true)
    #expect(service.calls == ["register"])
    #expect(model.loginItemCaption != nil)
    #expect(model.showsLoginItemSection)
  }

  @Test func theApprovalCaptionRendersVerbatimWithOpenLoginItems() {
    let model = PanelModel()
    let service = FakeLoginItem(status: .requiresApproval)
    model.attachLoginItem(service)
    #expect(model.launchAtLogin)
    #expect(model.loginItemCaption?.text == "Needs your approval in System Settings > General > Login Items.")
    #expect(model.loginItemCaption?.tone == .warning)
    #expect(model.loginItemCaption?.actionLabel == "Open Login Items")
    model.openLoginItems()
    #expect(service.calls == ["openSystemSettings"])
  }

  @Test func aRefusedRegistrationShowsTheErrorCaptionAndTheSwitchReverts() {
    let model = PanelModel()
    let service = FakeLoginItem(status: .notRegistered)
    service.refuse = true
    var logged: [String] = []
    model.logLoginItemError = { logged.append($0) }
    model.attachLoginItem(service)
    model.setLaunchAtLogin(true)
    #expect(service.calls == ["register"])
    #expect(!model.launchAtLogin)
    #expect(
      model.loginItemCaption?.text
        == "Couldn't change the login item. Try again, or add Overtime in System Settings > General > Login Items.")
    #expect(model.loginItemCaption?.tone == .error)
    #expect(logged == ["Operation not permitted"])
  }

  @Test func togglingTheSwitchRegistersAndUnregisters() {
    let model = PanelModel()
    let service = FakeLoginItem(status: .notRegistered)
    model.attachLoginItem(service)
    model.setLaunchAtLogin(true)
    #expect(model.launchAtLogin)
    model.setLaunchAtLogin(false)
    #expect(!model.launchAtLogin)
    #expect(service.calls == ["register", "unregister"])
  }

  @Test func aFailedSettingsRestartUnbindsTheStoppedEngineAndShowsTheError() async {
    let bound = Bound()
    bound.model.livenessIntervalSeconds = 0.05
    bound.host.publish(EngineSnapshot(busy: false, wanted: false, reason: "idle"))
    #expect(await waitUntil { bound.model.snapshot != nil })
    bound.model.setVisible(true, host: ObjectIdentifier(bound.host))
    #expect(await waitUntil { bound.host.probes > 0 })

    bound.model.applyRestart(.blocked(.sentinelUnavailable))
    #expect(bound.model.host == nil)
    #expect(bound.model.snapshot == nil)
    #expect(bound.model.presentation.state == .error(.watchdogUnavailable))
    #expect(await bound.model.perform(.pause(.timed(minutes: 15))) == nil)
    #expect(bound.host.requests.isEmpty)

    try? await Task.sleep(for: .milliseconds(100))
    let probes = bound.host.probes
    bound.host.publish(EngineSnapshot(busy: true, wanted: true, reason: "busy"))
    try? await Task.sleep(for: .milliseconds(200))
    #expect(bound.host.probes == probes)
    #expect(bound.model.snapshot == nil)
    #expect(bound.model.presentation.state == .error(.watchdogUnavailable))
  }

  @MainActor struct AttentionPanel {
    let model = PanelModel()
    let port: SettingsWindowTests.FakeNotificationPort
    let location: SettingsWindowTests.FakeLocationStatus
    let opened = OpenedPanes()

    init(
      notifications: NotificationAuthorization = .authorized, location status: LocationAuthorization = .authorized,
      hotspot: HotspotChoice = .none
    ) {
      port = SettingsWindowTests.FakeNotificationPort(notifications)
      location = SettingsWindowTests.FakeLocationStatus(status)
      model.notifications = port
      model.location = location
      model.readHotspotChoice = { hotspot }
      let opened = opened
      model.onOpenSettings = { opened.append($0) }
    }

    func appear() async {
      await model.refreshAttention()?.value
    }
  }

  final class OpenedPanes {
    private(set) var panes: [SettingsPane?] = []

    func append(_ pane: SettingsPane?) {
      panes.append(pane)
    }
  }

  @Test func aMissingRootWarningShowsTheAttentionRowAndReviewOpensDiagnostics() async {
    let bound = Bound()
    let opened = OpenedPanes()
    bound.model.onOpenSettings = { opened.append($0) }
    #expect(bound.model.attentionText == nil)
    bound.host.publish(
      EngineSnapshot(wanted: false, reason: "idle", detectionWarnings: [.rootMissing("/Users/dev/.claude/projects")]))
    #expect(await waitUntil { bound.model.attentionText != nil })
    #expect(bound.model.attentionText == "Overtime may be missing Claude activity.")
    #expect(bound.model.attentionItems == [.detectionHealth])
    #expect(
      AttentionRow.accessibilityLabel(bound.model.attentionText ?? "")
        == "Needs attention: Overtime may be missing Claude activity.")
    #expect(AttentionRow.reviewLabel == "Review in Settings…")
    #expect(AttentionRow.symbol == "exclamationmark.triangle.fill")
    bound.model.reviewAttention()
    #expect(opened.panes == [.diagnostics])
    bound.host.publish(EngineSnapshot(wanted: false, reason: "idle"))
    #expect(await waitUntil { bound.model.attentionText == nil })
    #expect(bound.model.attentionItems.isEmpty)
    bound.model.reviewAttention()
    #expect(opened.panes == [.diagnostics])
  }

  @Test func withNoItemsThereIsNoAttentionRow() async {
    let panel = AttentionPanel()
    panel.model.attachLoginItem(FakeLoginItem(status: .enabled))
    await panel.appear()
    #expect(panel.model.attentionItems.isEmpty)
    #expect(panel.model.attentionText == nil)
    panel.model.reviewAttention()
    #expect(panel.opened.panes.isEmpty)
  }

  @Test func thePermissionStatesAreReadWhenThePanelAppearsAndNeverRequested() async {
    let panel = AttentionPanel(notifications: .denied, location: .denied, hotspot: .autoDetect)
    panel.model.attachLoginItem(FakeLoginItem(status: .requiresApproval))
    #expect(panel.model.attentionItems == [.loginApproval])
    #expect(panel.model.attentionText == "Launch at login needs your approval.")
    #expect(panel.port.reads == 0)
    #expect(panel.location.statusReads == 0)
    await panel.appear()
    #expect(panel.model.attentionItems == [.loginApproval, .notificationsDenied, .locationMissing])
    #expect(panel.model.attentionText == "3 things need your attention.")
    panel.model.reviewAttention()
    #expect(panel.opened.panes == [.general])
    #expect(panel.port.reads == 1)
    #expect(panel.port.requests == 0)
    #expect(panel.port.posted.isEmpty)
    #expect(panel.location.requests == 0)
  }

  @Test func nothingReadsThePermissionStatesWhileThePanelStaysClosed() async {
    let bound = Bound()
    let port = SettingsWindowTests.FakeNotificationPort(.denied)
    let location = SettingsWindowTests.FakeLocationStatus(.denied)
    bound.model.notifications = port
    bound.model.location = location
    bound.model.readHotspotChoice = { .autoDetect }
    bound.host.publish(EngineSnapshot(busy: true, wanted: true, reason: "busy", detectionWarnings: [.terminalSilence]))
    #expect(await waitUntil { bound.model.attentionItems == [.detectionHealth] })
    #expect(!bound.model.isPanelVisible)
    #expect(port.reads == 0)
    #expect(location.statusReads == 0)
  }

  @Test func anItemDisappearsOnTheNextReadOnceItsConditionClears() async {
    let panel = AttentionPanel(notifications: .denied, location: .notDetermined, hotspot: .named("iPhone"))
    await panel.appear()
    #expect(panel.model.attentionItems == [.notificationsDenied, .locationMissing])
    #expect(panel.model.attentionText == "2 things need your attention.")
    panel.port.set(.authorized)
    await panel.appear()
    #expect(panel.model.attentionItems == [.locationMissing])
    #expect(
      panel.model.attentionText
        == "Location access is off. Failover still works, but with Location, Overtime can join the hotspot directly.")
    panel.model.reviewAttention()
    #expect(panel.opened.panes == [.network])
    panel.location.current = .authorized
    await panel.appear()
    #expect(panel.model.attentionText == nil)
    #expect(panel.port.requests == 0)
    #expect(panel.location.requests == 0)
  }

  @Test func locationIsReadOnlyWhileAHotspotIsChosen() async {
    let panel = AttentionPanel(location: .denied, hotspot: .none)
    await panel.appear()
    #expect(panel.model.attentionItems.isEmpty)
    #expect(panel.location.statusReads == 0)
    var choice = HotspotChoice.autoDetect
    panel.model.readHotspotChoice = { choice }
    await panel.appear()
    #expect(panel.model.attentionItems == [.locationMissing])
    #expect(panel.location.statusReads == 1)
    choice = .none
    await panel.appear()
    #expect(panel.model.attentionItems.isEmpty)
    #expect(panel.location.statusReads == 1)
  }

  @Test func theLocationPortIsBuiltOnceAndOnlyAfterAHotspotIsChosen() async {
    let model = PanelModel()
    let location = SettingsWindowTests.FakeLocationStatus(.denied)
    var built = 0
    model.makeLocation = {
      built += 1
      return location
    }
    var choice = HotspotChoice.none
    model.readHotspotChoice = { choice }
    await model.refreshAttention()?.value
    #expect(built == 0)
    choice = .autoDetect
    await model.refreshAttention()?.value
    await model.refreshAttention()?.value
    #expect(built == 1)
    #expect(model.attentionItems == [.locationMissing])
    #expect(location.requests == 0)
  }

  @Test func aFailedSelfTestShowsTheErrorStateAndLeavesThePanelAttentionList() {
    let panel = AttentionPanel()
    #expect(!panel.model.selfTestFailed)
    panel.model.apply(
      EngineSnapshot(
        busy: false, wanted: false, reason: "idle", selfTest: .failed(.timedOut), selfTestErrorActive: true,
        selfTestFailures: 1, selfTestRuns: 1))
    #expect(panel.model.selfTestFailed)
    #expect(panel.model.presentation.state == .error(.selfTestFailed))
    #expect(panel.model.presentation.title == "Self-test failed")
    #expect(
      panel.model.presentation.reason
        == "Overtime's lid-close control failed its launch test. Until it passes, the Mac may sleep with the lid closed. Details are in Settings > Diagnostics."
    )
    #expect(panel.model.presentation.accessibilityLabel == "Overtime, error")
    #expect(panel.model.attentionInputs.selfTestFailed)
    #expect(panel.model.attentionInputs.panelInErrorState)
    #expect(panel.model.attentionItems.isEmpty)
    #expect(panel.model.attentionText == nil)
    #expect(panel.model.controls.engineControlsEnabled)
    panel.model.reviewAttention()
    #expect(panel.opened.panes.isEmpty)
    panel.model.attachLoginItem(FakeLoginItem(status: .requiresApproval))
    #expect(panel.model.attentionItems == [.loginApproval])
    panel.model.apply(
      EngineSnapshot(
        busy: false, wanted: false, reason: "idle", selfTest: .passed, selfTestFailures: 1, selfTestRuns: 2))
    #expect(!panel.model.selfTestFailed)
    #expect(panel.model.presentation.state == .idle)
    #expect(panel.model.attentionItems == [.loginApproval])
  }

  @Test func aSkippedSelfTestIsNeitherAnErrorNorAnAttentionItem() {
    let panel = AttentionPanel()
    panel.model.apply(EngineSnapshot(busy: false, wanted: false, reason: "idle", selfTest: .skipped(.sleepDisabled)))
    #expect(!panel.model.selfTestFailed)
    #expect(panel.model.presentation.state == .idle)
    #expect(panel.model.attentionItems.isEmpty)
  }

  @Test func theHelperItemsFollowTheirFlags() {
    let panel = AttentionPanel()
    panel.model.helperReapprove = true
    panel.model.helperStale = true
    #expect(panel.model.attentionItems == [.helperReapprove, .helperStale])
    panel.model.reviewAttention()
    #expect(panel.opened.panes == [.unplugProtection])
  }

  @Test func byDefaultNoUpdateWaitsAndNoUpdateRowShows() {
    let panel = AttentionPanel()
    #expect(!panel.model.updateWaiting)
    #expect(!panel.model.attentionInputs.updateWaiting)
    #expect(!panel.model.showsUpdateRow)
    #expect(panel.model.attentionText == nil)
  }

  @Test func aWaitingUpdateAloneShowsTheUpdateRow() {
    let panel = AttentionPanel()
    panel.model.updateWaiting = true
    #expect(panel.model.attentionInputs.updateWaiting)
    #expect(panel.model.attentionItems == [.updateAvailable])
    #expect(panel.model.attentionText == "An update to Overtime is available.")
    #expect(panel.model.showsUpdateRow)
    let row = AttentionRow(text: panel.model.attentionText ?? "", isUpdate: panel.model.showsUpdateRow) {}
    #expect(row.shownSymbol == "arrow.down.circle")
    #expect(row.shownReviewLabel == "Review Update…")
    #expect(row.shownAccessibilityLabel == "Update available: An update to Overtime is available.")
    #expect(AttentionRow.updateSymbol == "arrow.down.circle")
    #expect(AttentionRow.reviewUpdateLabel == "Review Update…")
    #expect(
      AttentionRow.updateAccessibilityLabel("An update to Overtime is available.")
        == "Update available: An update to Overtime is available.")
    panel.model.updateWaiting = false
    #expect(panel.model.attentionItems.isEmpty)
    #expect(!panel.model.showsUpdateRow)
  }

  @Test func theTriangleRowIsUnchangedWhenItIsNotTheUpdateRow() {
    let row = AttentionRow(text: "Launch at login needs your approval.") {}
    #expect(!row.isUpdate)
    #expect(row.shownSymbol == "exclamationmark.triangle.fill")
    #expect(row.shownReviewLabel == "Review in Settings…")
    #expect(row.shownAccessibilityLabel == "Needs attention: Launch at login needs your approval.")
  }

  @Test func aWaitingUpdateWithAnotherItemKeepsThePhaseThreeRowAndReviewNeverOpensAbout() async {
    let panel = AttentionPanel(notifications: .denied)
    panel.model.updateWaiting = true
    await panel.appear()
    #expect(panel.model.attentionItems == [.notificationsDenied, .updateAvailable])
    #expect(panel.model.attentionText == "2 things need your attention.")
    #expect(!panel.model.showsUpdateRow)
    var reviews = 0
    panel.model.onReviewUpdate = { reviews += 1 }
    panel.model.reviewAttention()
    #expect(panel.opened.panes == [.general])
    #expect(reviews == 0)
  }

  @Test func aWaitingUpdateLeavesThePanelWhileAnUninstallRuns() {
    let panel = AttentionPanel()
    panel.model.updateWaiting = true
    #expect(panel.model.showsUpdateRow)
    panel.model.uninstalling = true
    #expect(!panel.model.attentionInputs.updateWaiting)
    #expect(panel.model.attentionItems.isEmpty)
    #expect(panel.model.attentionText == nil)
    #expect(!panel.model.showsUpdateRow)
    panel.model.uninstalling = false
    #expect(panel.model.showsUpdateRow)
    #expect(panel.model.attentionItems == [.updateAvailable])
  }

  @Test func aWaitingUpdateBesideAnotherItemLeavesTheCountWhileAnUninstallRuns() async {
    let panel = AttentionPanel(notifications: .denied)
    panel.model.updateWaiting = true
    await panel.appear()
    #expect(panel.model.attentionItems == [.notificationsDenied, .updateAvailable])
    panel.model.uninstalling = true
    #expect(panel.model.attentionItems == [.notificationsDenied])
    #expect(panel.model.attentionText != "2 things need your attention.")
    #expect(!panel.model.showsUpdateRow)
  }

  @Test func reviewingTheUpdateCallsTheReviewHandlerOnceAndOpensNoPane() {
    let panel = AttentionPanel()
    panel.model.updateWaiting = true
    var reviews = 0
    panel.model.onReviewUpdate = { reviews += 1 }
    panel.model.reviewUpdate()
    #expect(reviews == 1)
    #expect(panel.opened.panes.isEmpty)
  }

  @Test func theUpdaterChangeRouteSetsAndClearsUpdateWaitingFromTheReminder() {
    let panel = AttentionPanel()
    let fake = AboutPaneTests.FakeUpdater()
    fake.onChange = { AppDelegate.refreshAfterUpdaterChange(about: nil, panel: panel.model, updater: fake) }
    fake.onChange?()
    #expect(!panel.model.updateWaiting)
    fake.reminder.willShowUpdate(handledBySparkle: true, version: "0.1.1")
    fake.onChange?()
    #expect(!panel.model.updateWaiting)
    fake.reminder.willShowUpdate(handledBySparkle: false, version: "0.1.1")
    fake.onChange?()
    #expect(panel.model.updateWaiting)
    #expect(panel.model.attentionItems == [.updateAvailable])
    fake.reminder.userAttended()
    fake.onChange?()
    #expect(!panel.model.updateWaiting)
    fake.reminder.willShowUpdate(handledBySparkle: false, version: "0.1.2")
    fake.onChange?()
    #expect(panel.model.updateWaiting)
    fake.reminder.sessionFinished()
    fake.onChange?()
    #expect(!panel.model.updateWaiting)
  }

  @Test func withNoUpdaterTheChangeRouteNeverRaisesTheItem() {
    let panel = AttentionPanel()
    panel.model.updateWaiting = true
    AppDelegate.refreshAfterUpdaterChange(about: nil, panel: panel.model, updater: nil)
    #expect(!panel.model.updateWaiting)
    #expect(panel.model.attentionItems.isEmpty)
  }

  @Test func theReviewWiringActivatesTheAppAndThenAsksTheUpdater() {
    let panel = AttentionPanel()
    let fake = AboutPaneTests.FakeUpdater()
    AppDelegate.wireUpdateReview(panel: panel.model, updater: fake, activate: { fake.events.append("activate") })
    panel.model.reviewUpdate()
    #expect(fake.events == ["activate", "check"])
    #expect(panel.opened.panes.isEmpty)
  }

  @Test func theTestHostsPanelNeverHearsOfAnUpdate() throws {
    let delegate = try #require(AppDelegate.shared)
    #expect(delegate.updaterPort == nil)
    #expect(!delegate.model.updateWaiting)
    #expect(!delegate.model.attentionItems.contains(.updateAvailable))
  }

  @Test func theDelegatesUpdaterChangeReachesThePanelAndClearsAFlagNoUpdaterRaised() throws {
    let delegate = try #require(AppDelegate.shared)
    #expect(delegate.updaterPort == nil)
    delegate.model.updateWaiting = true
    delegate.updaterChanged()
    #expect(!delegate.model.updateWaiting)
  }

  nonisolated static let rootlessCopy =
    "With the lid closed, unplugging power or a display can still let the Mac sleep."
  nonisolated static let protectedCopy =
    "Unplug protection is on. Unplugging power or a display with the lid closed won't let the Mac sleep."
  nonisolated static let wanted = EngineSnapshot(busy: true, wanted: true, reason: "busy", lidClosed: false)
  nonisolated static let heldByTheHelper = EngineSnapshot(
    busy: true, wanted: true, reason: "busy", lidClosed: true, helperEngaged: true)
  nonisolated static let owningAnswer = HelperMonitorState(
    installer: .enabled, reachability: .reachable,
    status: HelperStatus(helperVersion: HelperIdentity.version, sleepDisabled: true, owns: true))

  struct HelperHintCase: Sendable, CustomTestStringConvertible {
    let name: String
    let state: HelperMonitorState?
    var engaged = false
    let text: String
    let action: HintAction?

    var testDescription: String { name }
  }

  nonisolated static let helperHintCases = [
    HelperHintCase(name: "no monitor", state: nil, text: rootlessCopy, action: .setUpUnplugProtection),
    HelperHintCase(
      name: "not registered", state: HelperMonitorState(installer: .notRegistered), text: rootlessCopy,
      action: .setUpUnplugProtection),
    HelperHintCase(
      name: "not found", state: HelperMonitorState(installer: .notFound), text: rootlessCopy,
      action: .setUpUnplugProtection),
    HelperHintCase(
      name: "checking", state: HelperMonitorState(), text: rootlessCopy, action: .reviewUnplugProtection),
    HelperHintCase(
      name: "waiting for approval", state: HelperMonitorState(installer: .requiresApproval), text: rootlessCopy,
      action: .reviewUnplugProtection),
    HelperHintCase(
      name: "needs approval again", state: HelperMonitorState(installer: .enabled, reachability: .unreachable),
      text: rootlessCopy, action: .reviewUnplugProtection),
    HelperHintCase(
      name: "out of date",
      state: HelperMonitorState(
        installer: .enabled, reachability: .reachable, status: HelperStatus(helperVersion: 0), staleAttempts: 2),
      text: rootlessCopy, action: .reviewUnplugProtection),
    HelperHintCase(
      name: "error",
      state: HelperMonitorState(installer: .enabled, reachability: .reachable, lastError: "NSCocoaErrorDomain 4097"),
      text: rootlessCopy, action: .reviewUnplugProtection),
    HelperHintCase(
      name: "an install that failed",
      state: HelperMonitorState(installer: .notRegistered, lastError: "Operation not permitted"), text: rootlessCopy,
      action: .reviewUnplugProtection),
    HelperHintCase(name: "standing by", state: HelperPaneTests.standingBy, text: protectedCopy, action: nil),
    HelperHintCase(
      name: "holding now", state: HelperPaneTests.standingBy, engaged: true, text: protectedCopy, action: nil),
  ]

  @Test func aWantedSnapshotWithAReadyHelperSaysUnplugProtectionIsOn() async {
    let fixture = HelperPaneTests.Scripted()
    fixture.panel.apply(Self.wanted)
    #expect(fixture.panel.hints.map(\.action) == [.reviewUnplugProtection])
    await fixture.show(HelperPaneTests.standingBy)
    #expect(fixture.pane.uiState == .onStandingBy)
    #expect(
      fixture.panel.hints == [Hint(priority: 5, icon: "checkmark.shield", tint: .info, text: Self.protectedCopy)])
    fixture.panel.apply(EngineSnapshot(busy: false, wanted: false, reason: "idle"))
    #expect(fixture.panel.hints.isEmpty)
  }

  @Test(arguments: helperHintCases)
  func theUnplugProtectionHintFollowsTheStateTheMonitorReports(_ example: HelperHintCase) {
    let model = PanelModel()
    model.apply(example.engaged ? Self.heldByTheHelper : Self.wanted)
    if let state = example.state {
      model.applyHelper(state)
    }
    #expect(model.hints.map(\.priority) == [5])
    #expect(model.hints.first?.text == example.text)
    #expect(model.hints.first?.action == example.action)
    #expect(model.hints.first?.tint == .info)
    #expect(model.hints.first?.icon == (example.action == nil ? "checkmark.shield" : "info.circle"))
  }

  @Test(arguments: [HintAction.setUpUnplugProtection, .reviewUnplugProtection])
  func bothUnplugProtectionActionsOpenSettingsOnUnplugProtection(_ action: HintAction) {
    let model = PanelModel()
    let opened = OpenedPanes()
    model.onOpenSettings = { opened.append($0) }
    model.copyToPasteboard = { _ in Issue.record("copied on an unplug protection action") }
    model.performHint(action)
    #expect(opened.panes == [.unplugProtection])
  }

  @Test func theRealMonitorsStateReachesThePanelThroughThePaneModel() async {
    let fixture = HelperPaneTests.Monitored(status: .notRegistered)
    fixture.panel.apply(Self.wanted)
    #expect(fixture.panel.helperState == HelperMonitorState())
    #expect(fixture.panel.helperHint == .installedNotReady)
    await fixture.monitor.refresh()
    #expect(await waitUntil { fixture.panel.helperHint == .notInstalled })
    #expect(fixture.panel.hints.map(\.action) == [.setUpUnplugProtection])
    fixture.installer.setStatus(.requiresApproval)
    await fixture.monitor.refresh()
    #expect(await waitUntil { fixture.panel.helperHint == .installedNotReady })
    #expect(fixture.panel.hints.map(\.action) == [.reviewUnplugProtection])
    #expect(fixture.panel.helperState == fixture.pane.state)
    #expect(fixture.panel.helperState == fixture.monitor.state)
    #expect(fixture.connections.all.isEmpty)
    #expect(fixture.installer.calls.isEmpty)
  }

  @Test func thePanelDerivesTheRowThePaneShowsWithAndWithoutTheEnginesHold() async {
    let fixture = HelperPaneTests.Scripted()
    await fixture.show(HelperPaneTests.standingBy)
    fixture.panel.apply(Self.wanted)
    #expect(fixture.panel.helperShown == .onStandingBy)
    #expect(fixture.panel.helperShown == fixture.pane.uiState)
    fixture.panel.apply(Self.heldByTheHelper)
    #expect(fixture.panel.helperShown == .onHolding)
    #expect(fixture.panel.helperShown == fixture.pane.uiState)
    #expect(fixture.panel.helperHint == .ready)
  }

  @Test func aPaneModelWithoutAMonitorTellsThePanelNothing() {
    let panel = PanelModel()
    let pane = HelperPaneModel(panel: panel)
    #expect(pane.uiState == nil)
    #expect(panel.helperState == nil)
    #expect(panel.helperShown == nil)
    #expect(panel.helperHint == .notInstalled)
    #expect(!panel.helperOwnsSleepDisabled)
  }

  @Test func theSleepDisabledHintIsHiddenWhileTheEngineHoldsTheHelperAndComesBackForAValueReadBefore() {
    let model = PanelModel()
    model.applySleepDisabled(true)
    #expect(model.hints.map(\.priority) == [1])
    model.apply(Self.heldByTheHelper)
    #expect(model.helperOwnsSleepDisabled)
    #expect(model.hints.map(\.priority) == [5])
    model.apply(Self.wanted)
    #expect(!model.helperOwnsSleepDisabled)
    #expect(model.hints.map(\.priority) == [1, 5])
    #expect(model.hints.first?.action == .copyCommand)
  }

  @Test func aReadingOfOneTakenWhileTheHelperOwnsTheValueIsNotALeftover() {
    let model = PanelModel()
    model.apply(Self.heldByTheHelper)
    model.applySleepDisabled(true)
    #expect(!model.sleepDisabledLeftover)
    model.apply(Self.wanted)
    #expect(model.hints.map(\.priority) == [5])
    model.applySleepDisabled(true)
    #expect(model.sleepDisabledLeftover)
    #expect(model.hints.map(\.priority) == [1, 5])
  }

  @Test(arguments: [Optional(false), nil])
  func whileTheHelperOwnsTheValueAReadingThatIsNotOneStillClearsAnEarlierLeftover(_ reading: Bool?) {
    let model = PanelModel()
    model.applySleepDisabled(true)
    model.apply(Self.heldByTheHelper)
    model.applySleepDisabled(true)
    #expect(model.sleepDisabledLeftover)
    model.applySleepDisabled(reading)
    #expect(!model.sleepDisabledLeftover)
  }

  @Test func theHelpersOwnAnswerHidesTheHintWithoutAnEngineHold() {
    let model = PanelModel()
    model.applySleepDisabled(true)
    model.applyHelper(Self.owningAnswer)
    #expect(model.helperAnsweredOwning)
    #expect(model.helperOwnsSleepDisabled)
    #expect(model.hints.isEmpty)
    model.applySleepDisabled(false)
    model.applySleepDisabled(true)
    #expect(!model.sleepDisabledLeftover)
    model.applyHelper(HelperPaneTests.standingBy)
    #expect(!model.helperAnsweredOwning)
    #expect(!model.helperOwnsSleepDisabled)
    model.applySleepDisabled(true)
    #expect(model.hints.map(\.priority) == [1])
  }

  @Test func theEndOfAHoldForgetsAnAnswerTheHelperGaveDuringIt() {
    let model = PanelModel()
    model.apply(Self.heldByTheHelper)
    model.applyHelper(Self.owningAnswer)
    #expect(model.helperAnsweredOwning)
    model.apply(
      EngineSnapshot(
        busy: true, wanted: true, reason: "busy", lidClosed: true, power: .ac(percent: 80), helperEngaged: true))
    #expect(model.helperAnsweredOwning)
    model.apply(Self.wanted)
    #expect(!model.helperAnsweredOwning)
    #expect(!model.helperOwnsSleepDisabled)
    model.applySleepDisabled(true)
    #expect(model.hints.map(\.priority) == [1, 5])
    model.applyHelper(Self.owningAnswer)
    #expect(model.helperOwnsSleepDisabled)
    #expect(model.hints.map(\.priority) == [5])
  }

  @Test func anAnswerGivenOutsideAHoldIsKeptWhenASnapshotChanges() {
    let model = PanelModel()
    model.apply(Self.wanted)
    model.applyHelper(Self.owningAnswer)
    model.apply(EngineSnapshot(busy: false, wanted: false, reason: "idle"))
    #expect(model.helperAnsweredOwning)
  }

  @Test func losingTheEngineAlsoForgetsAnAnswerGivenDuringAHold() {
    let model = PanelModel()
    model.apply(Self.heldByTheHelper)
    model.applyHelper(Self.owningAnswer)
    model.unbind()
    #expect(model.snapshot == nil)
    #expect(!model.helperOwnsSleepDisabled)
  }

  @Test func aReadThatStartedUnderTheHelpersHoldIsNotALeftoverWhenItFinishesAfterIt() async {
    let model = PanelModel()
    model.readSleepDisabled = {
      Thread.sleep(forTimeInterval: 0.2)
      return true
    }
    model.apply(Self.heldByTheHelper)
    let read = model.refreshSleepDisabled()
    model.apply(Self.wanted)
    #expect(!model.helperOwnsSleepDisabled)
    await read?.value
    #expect(!model.sleepDisabledLeftover)
    await model.refreshSleepDisabled()?.value
    #expect(model.sleepDisabledLeftover)
  }

  nonisolated static let needsApprovalAgain = HelperMonitorState(installer: .enabled, reachability: .unreachable)
  nonisolated static let outOfDate = HelperMonitorState(
    installer: .enabled, reachability: .reachable, status: HelperStatus(helperVersion: 0), staleAttempts: 2)

  @Test func theHelperItemsFollowTheStateTheMonitorReports() {
    let panel = AttentionPanel()
    panel.model.applyHelper(Self.needsApprovalAgain)
    #expect(panel.model.helperReapprove)
    #expect(!panel.model.helperStale)
    #expect(panel.model.attentionItems == [.helperReapprove])
    #expect(panel.model.attentionText == "Unplug protection needs your approval again.")
    panel.model.reviewAttention()
    #expect(panel.opened.panes == [.unplugProtection])
    panel.model.applyHelper(Self.outOfDate)
    #expect(!panel.model.helperReapprove)
    #expect(panel.model.helperStale)
    #expect(panel.model.attentionItems == [.helperStale])
    #expect(panel.model.attentionText == "Unplug protection is out of date.")
    panel.model.reviewAttention()
    #expect(panel.opened.panes == [.unplugProtection, .unplugProtection])
    panel.model.applyHelper(HelperPaneTests.standingBy)
    #expect(!panel.model.helperReapprove)
    #expect(!panel.model.helperStale)
    #expect(panel.model.attentionItems.isEmpty)
    #expect(panel.model.attentionText == nil)
  }

  @Test func theHelperItemsReachThePanelThroughThePaneModel() async {
    let fixture = HelperPaneTests.Scripted()
    #expect(fixture.panel.attentionItems.isEmpty)
    await fixture.show(Self.needsApprovalAgain)
    #expect(fixture.pane.uiState == .needsApprovalAgain)
    #expect(fixture.panel.attentionItems == [.helperReapprove])
    await fixture.show(Self.outOfDate)
    #expect(fixture.pane.uiState == .outOfDate)
    #expect(fixture.panel.attentionItems == [.helperStale])
    await fixture.show(HelperMonitorState(installer: .notRegistered))
    #expect(fixture.panel.attentionItems.isEmpty)
  }

  @Test func uninstallingWinsOverEverySnapshotAndHostFailure() async {
    let bound = Bound()
    bound.host.publish(EngineSnapshot(wanted: true, reason: "forced", force: .indefinite))
    #expect(await waitUntil { bound.model.presentation.state == .override })
    bound.model.uninstalling = true
    #expect(bound.model.presentation.state == .uninstalling)
    #expect(bound.model.presentation.glyph == .idle)
    #expect(bound.model.presentation.accessibilityLabel == "Overtime, uninstalling")
    #expect(bound.model.presentation.title == "Uninstalling")
    #expect(bound.model.presentation.reason == "Keep-awake is off while Overtime uninstalls. The Mac sleeps normally.")
    bound.model.hostFailure = .lockHeldElsewhere
    #expect(bound.model.presentation.state == .uninstalling)
    let unbound = PanelModel()
    unbound.engineUnresponsive = true
    unbound.uninstalling = true
    #expect(unbound.presentation.state == .uninstalling)
  }

  @Test func uninstallingTurnsTheEngineControlsOffWithTheUninstallHelp() async {
    let bound = Bound()
    bound.host.publish(EngineSnapshot(wanted: true, reason: "forced", force: .indefinite))
    #expect(await waitUntil { bound.model.controls.engineControlsEnabled })
    bound.model.uninstalling = true
    #expect(!bound.model.controls.engineControlsEnabled)
    #expect(bound.model.controls.engineHelp == "Not available while Overtime uninstalls.")
    #expect(bound.model.controls.engineHelp == ControlMapping.uninstallingHelp)
    #expect(await bound.model.perform(.resume) == nil)
    #expect(bound.model.pressSleepNow() == nil)
    #expect(bound.host.requests.isEmpty)
  }

  @Test func settingsOpensOnAboutWhileUninstalling() {
    let model = PanelModel()
    let opened = OpenedPanes()
    model.onOpenSettings = { opened.append($0) }
    model.openSettings()
    model.uninstalling = true
    model.openSettings()
    model.openSettings(.general)
    #expect(opened.panes == [nil, .about, .general])
  }

  @Test func reviewingAnUpdateDoesNothingWhileUninstalling() {
    let model = PanelModel()
    var reviews = 0
    model.onReviewUpdate = { reviews += 1 }
    model.uninstalling = true
    model.reviewUpdate()
    #expect(reviews == 0)
    model.uninstalling = false
    model.reviewUpdate()
    #expect(reviews == 1)
  }
}
