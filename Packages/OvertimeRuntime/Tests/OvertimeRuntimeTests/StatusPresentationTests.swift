import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing

struct StatusPresentationTests {
  struct Case: Sendable, CustomTestStringConvertible {
    let name: String
    let snapshot: EngineSnapshot?
    let state: PanelState
    let glyph: StatusGlyph
    let fallback: String
    let label: String
    let title: String
    let reason: String

    var testDescription: String { name }
  }

  static let cases: [Case] = [
    Case(
      name: "starting", snapshot: nil, state: .starting, glyph: .idle, fallback: "moon",
      label: "Overtime, starting", title: "Starting…", reason: "Reading Claude activity."),
    Case(
      name: "idle", snapshot: EngineSnapshot(busy: false, wanted: false, reason: "idle"), state: .idle,
      glyph: .idle, fallback: "moon", label: "Overtime, idle", title: "Idle",
      reason: "No Claude activity. The Mac sleeps normally."),
    Case(
      name: "holding", snapshot: EngineSnapshot(busy: true, wanted: true, reason: "busy", lidClosed: false),
      state: .holding, glyph: .awake, fallback: "sun.max", label: "Overtime, keeping awake",
      title: "Keeping awake", reason: "Claude is working."),
    Case(
      name: "lid-closed holding", snapshot: EngineSnapshot(busy: true, wanted: true, reason: "busy", lidClosed: true),
      state: .lidClosedHolding, glyph: .lidClosed, fallback: "laptopcomputer",
      label: "Overtime, keeping awake with the lid closed", title: "Keeping awake, lid closed",
      reason: "Claude is working. Lid-close sleep is blocked."),
    Case(
      name: "grace", snapshot: EngineSnapshot(busy: false, wanted: true, reason: "busy"), state: .grace,
      glyph: .waiting, fallback: "hourglass.tophalf.fill", label: "Overtime, releasing soon",
      title: "Releasing soon", reason: "Claude went idle. Overtime waits a little in case it resumes."),
    Case(
      name: "paused", snapshot: EngineSnapshot(busy: true, wanted: false, reason: "paused", pause: .indefinite),
      state: .paused, glyph: .paused, fallback: "pause.circle.fill", label: "Overtime, paused",
      title: "Paused", reason: "Keep-awake is off until the pause ends."),
    Case(
      name: "released until idle",
      snapshot: EngineSnapshot(busy: true, wanted: false, reason: "override", releaseUntilIdle: true),
      state: .releasedUntilIdle, glyph: .paused, fallback: "pause.circle.fill", label: "Overtime, paused",
      title: "Released until idle", reason: "You released the hold. Overtime resumes when Claude goes idle."),
    Case(
      name: "battery floor",
      snapshot: EngineSnapshot(busy: true, wanted: false, reason: "battery", batteryBlocked: true),
      state: .batteryFloor, glyph: .batteryLow, fallback: "battery.25",
      label: "Overtime, battery low, keep-awake off", title: "Battery low",
      reason: "Keep-awake is off so the Mac can sleep."),
    Case(
      name: "override", snapshot: EngineSnapshot(busy: false, wanted: true, reason: "forced", force: .indefinite),
      state: .override, glyph: .forced, fallback: "bolt.fill",
      label: "Overtime, keeping awake manually", title: "Keeping awake manually",
      reason: "You turned on Keep Awake. It still stops at 10% battery."),
    Case(
      name: "hold error", snapshot: EngineSnapshot(busy: true, wanted: true, reason: "busy", holdError: true),
      state: .error(.holdFailed), glyph: .error, fallback: "exclamationmark.triangle",
      label: "Overtime, error", title: "Keep-awake failed",
      reason: "Overtime couldn't keep the Mac awake and will retry. Until it succeeds, the Mac sleeps normally."),
    Case(
      name: "self-test failed", snapshot: failedSelfTest(), state: .error(.selfTestFailed),
      glyph: .error, fallback: "exclamationmark.triangle", label: "Overtime, error",
      title: "Self-test failed",
      reason:
        "Overtime's lid-close control failed its launch test. Until it passes, the Mac may sleep with the lid closed. Details are in Settings > Diagnostics."
    ),
  ]

  static func failedSelfTest(
    busy: Bool? = false, wanted: Bool? = false, reason: String? = "idle", pause: PauseState? = nil,
    batteryBlocked: Bool = false, holdError: Bool = false, status: SelfTestStatus = .failed(.timedOut),
    errorActive: Bool = true
  ) -> EngineSnapshot {
    EngineSnapshot(
      busy: busy, wanted: wanted, reason: reason, pause: pause, batteryBlocked: batteryBlocked, holdError: holdError,
      selfTest: status, selfTestErrorActive: errorActive, selfTestFailures: 1, selfTestRuns: 1)
  }

  @Test(arguments: cases) func eachStateMapsToItsUISpecRow(_ testCase: Case) {
    let presentation = StatusPresentation.derive(
      snapshot: testCase.snapshot, hostFailure: nil, engineUnresponsive: false)
    #expect(presentation.state == testCase.state)
    #expect(presentation.glyph == testCase.glyph)
    #expect(presentation.fallbackGlyph == testCase.fallback)
    #expect(presentation.accessibilityLabel == testCase.label)
    #expect(presentation.title == testCase.title)
    #expect(presentation.reason == testCase.reason)
  }

  @Test func aClosedLidIsLidClosedHoldingOnlyWhileTheHoldIsAllowed() {
    let allowed = StatusPresentation.derive(
      snapshot: EngineSnapshot(busy: true, wanted: true, reason: "busy", lidClosed: true, lidClosedHoldAllowed: true),
      hostFailure: nil, engineUnresponsive: false)
    #expect(allowed.state == .lidClosedHolding)
    let off = StatusPresentation.derive(
      snapshot: EngineSnapshot(
        busy: true, wanted: true, reason: "busy", lidClosed: true, lidClosedKeepAwake: .never,
        lidClosedHoldAllowed: false),
      hostFailure: nil, engineUnresponsive: false)
    #expect(off.state == .holding)
    #expect(off.glyph == .awake)
    #expect(off.fallbackGlyph == "sun.max")
    #expect(off.accessibilityLabel == "Overtime, keeping awake")
    #expect(off.title == "Keeping awake")
    #expect(off.reason == "Claude is working.")
  }

  static let uninstallingInputs: [(EngineSnapshot?, HostFailure?, Bool)] = [
    (nil, nil, false),
    (EngineSnapshot(busy: true, wanted: true, reason: "busy", lidClosed: true), nil, false),
    (EngineSnapshot(busy: true, wanted: true, reason: "busy", holdError: true), nil, false),
    (EngineSnapshot(busy: false, wanted: true, reason: "forced", force: .indefinite), nil, false),
    (Self.failedSelfTest(), nil, false),
    (EngineSnapshot(busy: true, wanted: true, reason: "busy"), nil, true),
    (nil, .lockHeldElsewhere, false),
    (nil, .sentinelUnavailable, true),
    (EngineSnapshot(wanted: false, reason: "battery", batteryBlocked: true), .storageUnavailable, true),
  ]

  @Test func uninstallingWinsOverEveryOtherInput() {
    for (snapshot, failure, unresponsive) in Self.uninstallingInputs {
      let presentation = StatusPresentation.derive(
        snapshot: snapshot, hostFailure: failure, engineUnresponsive: unresponsive, uninstalling: true)
      #expect(presentation.state == .uninstalling)
      #expect(presentation.glyph == .idle)
      #expect(presentation.fallbackGlyph == "moon")
      #expect(presentation.accessibilityLabel == "Overtime, uninstalling")
      #expect(presentation.title == "Uninstalling")
      #expect(presentation.reason == "Keep-awake is off while Overtime uninstalls. The Mac sleeps normally.")
      #expect(!presentation.showsProgress)
      #expect(StatusPresentation.timingKind(state: presentation.state, snapshot: snapshot) == nil)
      #expect(
        StatusPresentation.state(
          snapshot: snapshot, hostFailure: failure, engineUnresponsive: unresponsive, uninstalling: true)
          == .uninstalling)
      #expect(!Hints.keepAwakeWanted(presentation.state))
    }
    let paused = EngineSnapshot(busy: true, wanted: false, reason: "paused", pause: .indefinite)
    #expect(StatusPresentation.timingKind(state: .paused, snapshot: paused) == .pauseIndefinite)
    #expect(StatusPresentation.timingKind(state: .uninstalling, snapshot: paused) == nil)
  }

  @Test func withoutTheUninstallFlagTheStateIsUnchanged() {
    for (snapshot, failure, unresponsive) in Self.uninstallingInputs {
      let flagged = StatusPresentation.derive(
        snapshot: snapshot, hostFailure: failure, engineUnresponsive: unresponsive, uninstalling: false)
      let plain = StatusPresentation.derive(snapshot: snapshot, hostFailure: failure, engineUnresponsive: unresponsive)
      #expect(flagged == plain)
      #expect(plain.state != .uninstalling)
    }
  }

  @Test func holdErrorWinsOverTheBatteryFloor() {
    let snapshot = EngineSnapshot(wanted: false, reason: "battery", batteryBlocked: true, holdError: true)
    #expect(derive(snapshot) == .error(.holdFailed))
  }

  @Test func aHoldFailureWinsOverAFailedSelfTest() {
    #expect(
      derive(Self.failedSelfTest(busy: true, wanted: true, reason: "busy", holdError: true)) == .error(.holdFailed))
  }

  @Test(arguments: [
    failedSelfTest(wanted: false, reason: "battery", batteryBlocked: true),
    failedSelfTest(busy: true, wanted: false, reason: "paused", pause: .indefinite),
    failedSelfTest(busy: true, wanted: true, reason: "busy"),
    failedSelfTest(status: .skipped(.sleepDisabled)),
    failedSelfTest(status: .waiting),
  ])
  func aFailedSelfTestWinsOverEveryStateBelowTheHoldFailure(_ snapshot: EngineSnapshot) {
    #expect(derive(snapshot) == .error(.selfTestFailed))
  }

  @Test func aHostFailureAndAnUnresponsiveEngineWinOverAFailedSelfTest() {
    let blocked = StatusPresentation.derive(
      snapshot: Self.failedSelfTest(), hostFailure: .sentinelUnavailable, engineUnresponsive: false)
    #expect(blocked.state == .error(.watchdogUnavailable))
    let wedged = StatusPresentation.derive(snapshot: Self.failedSelfTest(), hostFailure: nil, engineUnresponsive: true)
    #expect(wedged.state == .error(.notResponding))
  }

  @Test(arguments: [
    SelfTestStatus.skipped(.amphetamine), .skipped(.otherTool("Keeper")), .skipped(.sleepDisabled), .notRun,
    .waiting, .running, .passed,
  ])
  func aSelfTestThatDidNotFailIsNeverAnError(_ status: SelfTestStatus) {
    #expect(derive(EngineSnapshot(busy: false, wanted: false, reason: "idle", selfTest: status)) == .idle)
  }

  @Test func aFailedStatusWhoseErrorWasClearedIsNotAnError() {
    #expect(derive(Self.failedSelfTest(errorActive: false)) == .idle)
  }

  @Test func theSelfTestErrorCopyIsExposedForOtherSurfaces() {
    let presentation = StatusPresentation.presentation(for: .error(.selfTestFailed))
    #expect(presentation.title == StatusPresentation.selfTestFailedTitle)
    #expect(presentation.reason == StatusPresentation.selfTestFailedReason)
    #expect(presentation.glyph == StatusPresentation.presentation(for: .error(.holdFailed)).glyph)
  }

  @Test func theBatteryFloorWinsOverAPause() {
    let snapshot = EngineSnapshot(wanted: false, reason: "battery", pause: .indefinite, batteryBlocked: true)
    #expect(derive(snapshot) == .batteryFloor)
  }

  @Test func aForceWithTheLidClosedStaysOverride() {
    let snapshot = EngineSnapshot(busy: true, wanted: true, reason: "forced", force: .indefinite, lidClosed: true)
    #expect(derive(snapshot) == .override)
  }

  @Test func graceWithTheLidClosedStaysGrace() {
    let snapshot = EngineSnapshot(busy: false, wanted: true, reason: "busy", lidClosed: true)
    #expect(derive(snapshot) == .grace)
  }

  @Test func releaseUntilIdleIsPausedTitledReleasedUntilIdle() {
    let presentation = StatusPresentation.derive(
      snapshot: EngineSnapshot(busy: true, wanted: false, reason: "override", releaseUntilIdle: true),
      hostFailure: nil, engineUnresponsive: false)
    #expect(presentation.glyph == .paused)
    #expect(presentation.accessibilityLabel == "Overtime, paused")
    #expect(presentation.title == "Released until idle")
  }

  @Test func anUnresponsiveEngineIsAnError() {
    let presentation = StatusPresentation.derive(
      snapshot: EngineSnapshot(busy: false, wanted: false, reason: "idle"), hostFailure: nil,
      engineUnresponsive: true)
    #expect(presentation.state == .error(.notResponding))
    #expect(presentation.glyph == .error)
    #expect(presentation.title == "Overtime isn't responding")
    #expect(
      presentation.reason
        == "Choose Restore Normal Sleep Now to make sure the Mac can sleep, then quit and reopen Overtime.")
  }

  @Test func aLockHeldElsewhereCouldNotStart() {
    let presentation = StatusPresentation.derive(
      snapshot: nil, hostFailure: .lockHeldElsewhere, engineUnresponsive: false)
    #expect(presentation.state == .error(.couldNotStart))
    #expect(presentation.title == "Overtime couldn't start")
    #expect(
      presentation.reason
        == "Another Overtime process is already running, for example overtimed --live. Quit it, then reopen Overtime.")
  }

  @Test func anUnavailableWatchdogCouldNotStart() {
    let presentation = StatusPresentation.derive(
      snapshot: nil, hostFailure: .sentinelUnavailable, engineUnresponsive: false)
    #expect(presentation.state == .error(.watchdogUnavailable))
    #expect(presentation.title == "Overtime couldn't start")
    #expect(presentation.reason == "Its keep-awake watchdog could not start. Quit and reopen Overtime.")
  }

  @Test func unavailableStorageCouldNotStartWithItsOwnReason() {
    let presentation = StatusPresentation.derive(
      snapshot: nil, hostFailure: .storageUnavailable, engineUnresponsive: false)
    #expect(presentation.state == .error(.storageUnavailable))
    #expect(presentation.title == "Overtime couldn't start")
    #expect(
      presentation.reason
        == "It couldn't create its support or log folder. Check free disk space and folder permissions, then quit and reopen Overtime."
    )
    #expect(!presentation.reason.contains("already running"))
  }

  static let menuBarStates: [PanelState] = [
    .idle, .holding, .lidClosedHolding, .grace, .paused, .batteryFloor, .override, .error(.holdFailed),
  ]

  static let panelStates: [PanelState] = menuBarStates + [.starting, .releasedUntilIdle, .uninstalling]

  static let errors: [PanelError] = [
    .holdFailed, .selfTestFailed, .notResponding, .couldNotStart, .watchdogUnavailable, .storageUnavailable,
  ]

  @Test func theEightStatesUseEightDistinctGlyphsAndLabels() {
    let presentations = Self.menuBarStates.map(StatusPresentation.presentation(for:))
    let glyphs = presentations.map(\.glyph)
    #expect(glyphs == [.idle, .awake, .lidClosed, .waiting, .paused, .batteryLow, .forced, .error])
    #expect(Set(glyphs).count == 8)
    for (index, glyph) in glyphs.enumerated() {
      #expect(!glyphs[(index + 1)...].contains(glyph), "\(glyph) is shared by two menu bar states")
    }
    #expect(Set(presentations.map(\.accessibilityLabel)).count == 8)
    #expect(
      presentations.map(\.accessibilityLabel) == [
        "Overtime, idle", "Overtime, keeping awake", "Overtime, keeping awake with the lid closed",
        "Overtime, releasing soon", "Overtime, paused", "Overtime, battery low, keep-awake off",
        "Overtime, keeping awake manually", "Overtime, error",
      ])
  }

  @Test func everyStatusGlyphIsShownBySomeState() {
    #expect(Self.panelStates.count == 11)
    let shown = Set(Self.panelStates.map { StatusPresentation.presentation(for: $0).glyph })
    #expect(shown == Set(StatusGlyph.allCases))
    #expect(StatusGlyph.allCases.count == 8)
  }

  @Test func everyErrorShowsTheErrorGlyph() {
    #expect(Self.errors.count == 6)
    for error in Self.errors {
      #expect(StatusPresentation.presentation(for: .error(error)).glyph == .error, "\(error)")
    }
  }

  @Test func theGlyphAssetNamesArePinned() {
    #expect(
      StatusGlyph.allCases.map(\.assetName) == [
        "StatusIdle", "StatusAwake", "StatusForced", "StatusLidClosed", "StatusWaiting", "StatusPaused",
        "StatusBatteryLow", "StatusError",
      ])
    #expect(Set(StatusGlyph.allCases.map(\.assetName)).count == 8)
  }

  @Test(arguments: [
    (0, "Claude is working."), (1, "Claude is working in 1 session."), (2, "Claude is working in 2 sessions."),
  ])
  func theHoldingReasonCountsOnlyWorkingSessions(_ count: Int, _ reason: String) {
    let since = Instant(nanoseconds: 1_000_000_000_000)
    let working = (0..<count).map {
      SessionSummary(pid: Int32(100 + $0), cwd: "/tmp", ttyName: nil, startMono: nil, workingSince: since)
    }
    let idle = (0..<2).map { SessionSummary(pid: Int32(200 + $0), cwd: "/tmp", ttyName: nil, startMono: nil) }
    let sessions = working + idle
    let presentation = StatusPresentation.derive(
      snapshot: EngineSnapshot(busy: true, wanted: true, reason: "busy", lidClosed: false, sessions: sessions),
      hostFailure: nil, engineUnresponsive: false)
    #expect(presentation.state == .holding)
    #expect(presentation.reason == reason)
  }

  @Test(arguments: [
    (0, 1, "Claude is waiting on a background command."),
    (0, 2, "Claude is waiting on background commands in 2 sessions."),
    (1, 1, "Claude is working in 1 session and waiting in 1 more."),
    (2, 3, "Claude is working in 2 sessions and waiting in 3 more."),
  ])
  func theReasonCountsWaitingSessionsApart(_ working: Int, _ waiting: Int, _ reason: String) {
    #expect(StatusPresentation.holdingReason(working: working, waiting: waiting) == reason)
    let since = Instant(nanoseconds: 1_000_000_000_000)
    let workingSessions = (0..<working).map {
      SessionSummary(pid: Int32(100 + $0), cwd: "/tmp", ttyName: "ttys001", startMono: nil, workingSince: since)
    }
    let waitingSessions = (0..<waiting).map {
      SessionSummary(pid: Int32(200 + $0), cwd: "/tmp", ttyName: "ttys002", startMono: nil, waitingSince: since)
    }
    let idle = [SessionSummary(pid: 300, cwd: "/tmp", ttyName: "ttys003", startMono: nil)]
    let snapshot = EngineSnapshot(
      busy: true, wanted: true, reason: "busy", lidClosed: false, sessions: workingSessions + waitingSessions + idle,
      backgroundCommandsHolding: true)
    let presentation = StatusPresentation.derive(snapshot: snapshot, hostFailure: nil, engineUnresponsive: false)
    #expect(presentation.state == .holding)
    #expect(presentation.reason == reason)
  }

  @Test func aRunningACommandRowCountsAsWorking() {
    let since = Instant(nanoseconds: 1_000_000_000_000)
    let command = SessionSummary(
      pid: 400, cwd: "/tmp", ttyName: nil, startMono: since, waitingSince: since, terminal: false)
    let snapshot = EngineSnapshot(
      busy: true, wanted: true, reason: "busy", lidClosed: false, sessions: [command], backgroundCommandsHolding: true)
    let presentation = StatusPresentation.derive(snapshot: snapshot, hostFailure: nil, engineUnresponsive: false)
    #expect(presentation.reason == "Claude is working in 1 session.")
    let run = SessionSummary(pid: 500, cwd: "/tmp", ttyName: nil, startMono: since, printRun: true, terminal: false)
    let printSnapshot = EngineSnapshot(
      busy: true, wanted: true, reason: "busy", lidClosed: false, sessions: [run], printRunsHolding: true)
    let printPresentation = StatusPresentation.derive(
      snapshot: printSnapshot, hostFailure: nil, engineUnresponsive: false)
    #expect(printPresentation.reason == "Claude is working in 1 session.")
  }

  @Test(arguments: [
    (0, "Claude is working."), (1, "Claude is working in 1 session."), (3, "Claude is working in 3 sessions."),
  ])
  func withoutWaitingRowsTheReasonIsUnchanged(_ working: Int, _ reason: String) {
    #expect(StatusPresentation.holdingReason(working: working, waiting: 0) == reason)
    #expect(StatusPresentation.holdingReason(sessionCount: working) == reason)
  }

  @Test func sessionsDoNotChangeTheLidClosedReason() {
    let sessions = [SessionSummary(pid: 7, cwd: "/tmp", ttyName: "ttys001", startMono: nil)]
    let presentation = StatusPresentation.derive(
      snapshot: EngineSnapshot(busy: true, wanted: true, reason: "busy", lidClosed: true, sessions: sessions),
      hostFailure: nil, engineUnresponsive: false)
    #expect(presentation.reason == "Claude is working. Lid-close sleep is blocked.")
  }

  @Test func theBatteryFloorReasonNamesThePercentWhenKnown() {
    let presentation = StatusPresentation.derive(
      snapshot: EngineSnapshot(
        wanted: false, reason: "battery", batteryBlocked: true, power: .battery(percent: 9)),
      hostFailure: nil, engineUnresponsive: false)
    #expect(presentation.reason == "Battery at 9%. Keep-awake is off so the Mac can sleep.")
  }

  @Test func theOverrideReasonUsesTheConfiguredFloor() {
    let presentation = StatusPresentation.derive(
      snapshot: EngineSnapshot(wanted: true, reason: "forced", force: .indefinite, batteryLowPercent: 15),
      hostFailure: nil, engineUnresponsive: false)
    #expect(presentation.reason == "You turned on Keep Awake. It still stops at 15% battery.")
  }

  @Test func theOverrideReasonNamesTheGivenFloor() {
    #expect(
      StatusPresentation.overrideReason(lowPercent: 7) == "You turned on Keep Awake. It still stops at 7% battery.")
  }

  @Test func theOverrideTemplateTakesTheDefaultSettingsFloor() {
    #expect(
      StatusPresentation.presentation(for: .override).reason
        == StatusPresentation.overrideReason(lowPercent: Settings().batteryLowPercent))
  }

  static let hot = EngineSnapshot(busy: true, wanted: false, reason: "temperature", temperatureBlocked: true)

  @Test func aHotBatteryShowsTheBatteryLimitStateWithTheHotCopy() {
    let presentation = StatusPresentation.derive(snapshot: Self.hot, hostFailure: nil, engineUnresponsive: false)
    #expect(presentation.state == .batteryFloor)
    #expect(presentation.glyph == .batteryLow)
    #expect(presentation.title == "Battery hot")
    #expect(presentation.accessibilityLabel == "Overtime, battery hot, keep-awake off")
  }

  @Test func theHotReasonNamesTheReadingWhenItIsKnown() {
    var known = Self.hot
    known.batteryTemperature = .celsius(47)
    let knownReason = StatusPresentation.derive(snapshot: known, hostFailure: nil, engineUnresponsive: false).reason
    #expect(knownReason == "Battery at 47°C. Keep-awake is off so the battery can cool down.")
    var unreadable = Self.hot
    unreadable.batteryTemperature = .unreadable
    let unreadableReason = StatusPresentation.derive(
      snapshot: unreadable, hostFailure: nil, engineUnresponsive: false
    ).reason
    #expect(unreadableReason == "Keep-awake is off so the battery can cool down.")
  }

  @Test func aLowBatteryKeepsTheLowCopyWhenTheBatteryIsAlsoHot() {
    let snapshot = EngineSnapshot(
      busy: true, wanted: false, reason: "battery", batteryBlocked: true, power: .battery(percent: 9),
      temperatureBlocked: true, batteryTemperature: .celsius(47))
    let presentation = StatusPresentation.derive(snapshot: snapshot, hostFailure: nil, engineUnresponsive: false)
    #expect(presentation.state == .batteryFloor)
    #expect(presentation.title == "Battery low")
    #expect(presentation.accessibilityLabel == "Overtime, battery low, keep-awake off")
    #expect(presentation.reason == "Battery at 9%. Keep-awake is off so the Mac can sleep.")
  }

  @Test func withBatteryProtectionOffTheOverrideReasonDropsTheBatterySentence() {
    let off = EngineSnapshot(
      wanted: true, reason: "forced", force: .indefinite, batteryLowPercent: 15, batteryProtectionEnabled: false)
    let offReason = StatusPresentation.derive(snapshot: off, hostFailure: nil, engineUnresponsive: false).reason
    #expect(offReason == "You turned on Keep Awake.")
    #expect(StatusPresentation.overrideReason(lowPercent: nil) == "You turned on Keep Awake.")
    let on = EngineSnapshot(wanted: true, reason: "forced", force: .indefinite, batteryLowPercent: 15)
    let onReason = StatusPresentation.derive(snapshot: on, hostFailure: nil, engineUnresponsive: false).reason
    #expect(onReason == "You turned on Keep Awake. It still stops at 15% battery.")
  }

  @Test(arguments: [
    PanelState.starting, .idle, .holding, .lidClosedHolding, .grace, .paused, .releasedUntilIdle, .batteryFloor,
    .override, .uninstalling, .error(.holdFailed), .error(.selfTestFailed), .error(.notResponding),
    .error(.couldNotStart), .error(.watchdogUnavailable), .error(.storageUnavailable),
  ])
  func onlyStartingShowsProgress(_ state: PanelState) {
    #expect(StatusPresentation.presentation(for: state).showsProgress == (state == .starting))
  }

  private func derive(_ snapshot: EngineSnapshot) -> PanelState {
    StatusPresentation.derive(snapshot: snapshot, hostFailure: nil, engineUnresponsive: false).state
  }
}
