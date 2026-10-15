import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing

struct ControlMappingTests {
  static let madrid: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
    return calendar
  }()

  static let now = Date(timeIntervalSince1970: 1_790_000_000)

  struct MappingCase: Sendable, CustomTestStringConvertible {
    let action: ControlAction
    let request: CtlRequest

    var testDescription: String { "\(action)" }
  }

  static let mappings: [MappingCase] = [
    MappingCase(action: .pause(.fifteenMinutes), request: .pause(.forSeconds(900))),
    MappingCase(action: .pause(.oneHour), request: .pause(.forSeconds(3600))),
    MappingCase(
      action: .pause(.untilTomorrow),
      request: .pause(.until(ControlMapping.nextLocalMidnight(after: now, calendar: madrid)))),
    MappingCase(action: .pause(.untilResumed), request: .pause(.indefinite)),
    MappingCase(action: .keepAwake(.thirtyMinutes), request: .force(.forSeconds(1800))),
    MappingCase(action: .keepAwake(.twoHours), request: .force(.forSeconds(7200))),
    MappingCase(action: .keepAwake(.untilStopped), request: .force(.indefinite)),
    MappingCase(action: .releaseUntilIdle, request: .releaseUntilIdle),
    MappingCase(action: .resume, request: .resume),
    MappingCase(action: .stopKeepingAwake, request: .resume),
  ]

  @Test(arguments: mappings)
  func eachChoiceMapsToItsExactRequest(_ mapping: MappingCase) {
    #expect(ControlMapping.request(for: mapping.action, now: Self.now, calendar: Self.madrid) == mapping.request)
  }

  @Test func untilTomorrowIsAWallClockPauseAtTheNextLocalMidnight() throws {
    let request = ControlMapping.request(for: .pause(.untilTomorrow), now: Self.now, calendar: Self.madrid)
    guard case .pause(.until(let date)) = request else {
      Issue.record("expected a wall-clock pause, got \(request)")
      return
    }
    let parts = Self.madrid.dateComponents([.hour, .minute, .second], from: date)
    #expect(parts.hour == 0 && parts.minute == 0 && parts.second == 0)
    #expect(date > Self.now)
    #expect(date.timeIntervalSince(Self.now) <= 24 * 3600)
  }

  @Test func menuLabelsMatchTheUISpecVerbatim() {
    #expect(PauseChoice.allCases.map(\.label) == ["15 Minutes", "1 Hour", "Until Tomorrow", "Until Resumed"])
    #expect(KeepAwakeChoice.allCases.map(\.label) == ["30 Minutes", "2 Hours", "Until Stopped"])
    #expect(ControlMapping.pauseLabel == "Pause")
    #expect(ControlMapping.keepAwakeLabel == "Keep Awake")
    #expect(ControlMapping.resumeLabel == "Resume")
    #expect(ControlMapping.stopKeepingAwakeLabel == "Stop Keeping Awake")
    #expect(ControlMapping.releaseUntilIdleLabel == "Release Until Idle")
    #expect(ControlMapping.releaseUnavailableHelp == "Available while Claude is keeping the Mac awake.")
  }

  struct AvailabilityCase: Sendable, CustomTestStringConvertible {
    let name: String
    let snapshot: EngineSnapshot?
    let engineUnresponsive: Bool
    let state: PanelState
    let hostFailure: HostFailure?
    let pauseRow: ControlAvailability.PauseRow
    let keepAwakeRow: ControlAvailability.KeepAwakeRow
    let releaseEnabled: Bool
    let engineControlsEnabled: Bool

    init(
      _ name: String, _ snapshot: EngineSnapshot?, engineUnresponsive: Bool = false, hostFailure: HostFailure? = nil,
      state: PanelState, pauseRow: ControlAvailability.PauseRow = .pauseMenu,
      keepAwakeRow: ControlAvailability.KeepAwakeRow = .keepAwakeMenu, releaseEnabled: Bool,
      engineControlsEnabled: Bool = true
    ) {
      self.name = name
      self.snapshot = snapshot
      self.engineUnresponsive = engineUnresponsive
      self.hostFailure = hostFailure
      self.state = state
      self.pauseRow = pauseRow
      self.keepAwakeRow = keepAwakeRow
      self.releaseEnabled = releaseEnabled
      self.engineControlsEnabled = engineControlsEnabled
    }

    var testDescription: String { name }
  }

  static let availability: [AvailabilityCase] = [
    AvailabilityCase(
      "holding", EngineSnapshot(busy: true, wanted: true, reason: "busy", lidClosed: false), state: .holding,
      releaseEnabled: true),
    AvailabilityCase(
      "lid-closed holding", EngineSnapshot(busy: true, wanted: true, reason: "busy", lidClosed: true),
      state: .lidClosedHolding, releaseEnabled: true),
    AvailabilityCase(
      "grace", EngineSnapshot(busy: false, wanted: true, reason: "busy"), state: .grace, releaseEnabled: true),
    AvailabilityCase(
      "idle", EngineSnapshot(busy: false, wanted: false, reason: "idle"), state: .idle, releaseEnabled: false),
    AvailabilityCase(
      "paused", EngineSnapshot(busy: true, wanted: false, reason: "paused", pause: .indefinite), state: .paused,
      pauseRow: .resume, releaseEnabled: false),
    AvailabilityCase(
      "released until idle", EngineSnapshot(busy: true, wanted: false, reason: "override", releaseUntilIdle: true),
      state: .releasedUntilIdle, pauseRow: .resume, releaseEnabled: false),
    AvailabilityCase(
      "battery floor", EngineSnapshot(busy: true, wanted: false, reason: "battery", batteryBlocked: true),
      state: .batteryFloor, releaseEnabled: false),
    AvailabilityCase(
      "override", EngineSnapshot(busy: false, wanted: true, reason: "forced", force: .indefinite), state: .override,
      keepAwakeRow: .stopKeepingAwake, releaseEnabled: false),
    AvailabilityCase(
      "error", EngineSnapshot(busy: true, wanted: true, reason: "busy", holdError: true), state: .error(.holdFailed),
      releaseEnabled: false),
    AvailabilityCase(
      "self-test failed", EngineSnapshot(busy: false, wanted: false, reason: "idle", selfTestErrorActive: true),
      state: .error(.selfTestFailed), releaseEnabled: false),
    AvailabilityCase(
      "paused after a failed self-test",
      EngineSnapshot(busy: true, wanted: false, reason: "paused", pause: .indefinite, selfTestErrorActive: true),
      state: .error(.selfTestFailed), pauseRow: .resume, releaseEnabled: false),
    AvailabilityCase(
      "not responding", EngineSnapshot(busy: true, wanted: true, reason: "busy"), engineUnresponsive: true,
      state: .error(.notResponding), releaseEnabled: false, engineControlsEnabled: false),
    AvailabilityCase(
      "could not start", nil, hostFailure: .lockHeldElsewhere, state: .error(.couldNotStart), releaseEnabled: false,
      engineControlsEnabled: false),
    AvailabilityCase(
      "watchdog unavailable", nil, hostFailure: .sentinelUnavailable, state: .error(.watchdogUnavailable),
      releaseEnabled: false, engineControlsEnabled: false),
    AvailabilityCase(
      "storage unavailable", nil, hostFailure: .storageUnavailable, state: .error(.storageUnavailable),
      releaseEnabled: false, engineControlsEnabled: false),
    AvailabilityCase(
      "paused while not responding", EngineSnapshot(busy: true, wanted: false, reason: "paused", pause: .indefinite),
      engineUnresponsive: true, state: .error(.notResponding), pauseRow: .resume, releaseEnabled: false,
      engineControlsEnabled: false),
    AvailabilityCase(
      "forced while not responding", EngineSnapshot(busy: false, wanted: true, reason: "forced", force: .indefinite),
      engineUnresponsive: true, state: .error(.notResponding), keepAwakeRow: .stopKeepingAwake, releaseEnabled: false,
      engineControlsEnabled: false),
    AvailabilityCase(
      "force during the battery floor",
      EngineSnapshot(busy: false, wanted: false, reason: "battery", force: .indefinite, batteryBlocked: true),
      state: .batteryFloor, keepAwakeRow: .stopKeepingAwake, releaseEnabled: false),
    AvailabilityCase(
      "pause during the battery floor",
      EngineSnapshot(busy: false, wanted: false, reason: "battery", pause: .indefinite, batteryBlocked: true),
      state: .batteryFloor, pauseRow: .resume, releaseEnabled: false),
  ]

  @Test(arguments: availability)
  func availabilityFollowsThePanelState(_ item: AvailabilityCase) {
    let presentation = StatusPresentation.derive(
      snapshot: item.snapshot, hostFailure: item.hostFailure, engineUnresponsive: item.engineUnresponsive)
    #expect(presentation.state == item.state)
    let availability = ControlAvailability.from(presentation, snapshot: item.snapshot)
    #expect(availability.pauseRow == item.pauseRow)
    #expect(availability.keepAwakeRow == item.keepAwakeRow)
    #expect(availability.releaseEnabled == item.releaseEnabled)
    #expect(availability.engineControlsEnabled == item.engineControlsEnabled)
    #expect(availability.engineHelp == (item.engineControlsEnabled ? nil : ControlMapping.engineUnavailableHelp))
    let releaseHelp: String? =
      if item.releaseEnabled {
        nil
      } else if !item.engineControlsEnabled {
        ControlMapping.engineUnavailableHelp
      } else {
        ControlMapping.releaseUnavailableHelp
      }
    #expect(availability.releaseHelp == releaseHelp)
  }

  struct FailureCase: Sendable, CustomTestStringConvertible {
    let action: ControlAction
    let copy: String

    var testDescription: String { "\(action)" }
  }

  static let failures: [FailureCase] = [
    FailureCase(action: .pause(.fifteenMinutes), copy: "Couldn't pause. Try again."),
    FailureCase(action: .pause(.oneHour), copy: "Couldn't pause. Try again."),
    FailureCase(action: .pause(.untilTomorrow), copy: "Couldn't pause. Try again."),
    FailureCase(action: .pause(.untilResumed), copy: "Couldn't pause. Try again."),
    FailureCase(action: .keepAwake(.thirtyMinutes), copy: "Couldn't turn on Keep Awake. Try again."),
    FailureCase(action: .keepAwake(.twoHours), copy: "Couldn't turn on Keep Awake. Try again."),
    FailureCase(action: .keepAwake(.untilStopped), copy: "Couldn't turn on Keep Awake. Try again."),
    FailureCase(action: .resume, copy: "Couldn't resume. Try again."),
    FailureCase(action: .stopKeepingAwake, copy: "Couldn't stop keeping awake. Try again."),
    FailureCase(action: .releaseUntilIdle, copy: "Couldn't release the hold. Try again."),
  ]

  @Test(arguments: failures)
  func eachControlFailureNamesItsAction(_ item: FailureCase) {
    #expect(ControlFeedback.failureCopy(for: item.action) == item.copy)
  }

  @Test(arguments: [
    EngineSnapshot(busy: true, wanted: true, reason: "busy", lidClosed: false),
    EngineSnapshot(busy: true, wanted: false, reason: "paused", pause: .indefinite),
    EngineSnapshot(busy: false, wanted: true, reason: "forced", force: .indefinite),
    EngineSnapshot(busy: false, wanted: false, reason: "idle"),
  ])
  func whileUninstallingTheEngineControlsAreOffWithTheUninstallHelp(_ snapshot: EngineSnapshot) {
    let presentation = StatusPresentation.derive(
      snapshot: snapshot, hostFailure: nil, engineUnresponsive: false, uninstalling: true)
    let availability = ControlAvailability.from(presentation, snapshot: snapshot)
    #expect(!availability.engineControlsEnabled)
    #expect(!availability.releaseEnabled)
    #expect(availability.uninstalling)
    #expect(availability.engineHelp == "Not available while Overtime uninstalls.")
    #expect(availability.releaseHelp == "Not available while Overtime uninstalls.")
    #expect(ControlMapping.uninstallingHelp == "Not available while Overtime uninstalls.")

    let normal = ControlAvailability.from(
      StatusPresentation.derive(snapshot: snapshot, hostFailure: nil, engineUnresponsive: false), snapshot: snapshot)
    #expect(!normal.uninstalling)
    #expect(normal.engineControlsEnabled)
  }

  @Test func theUninstallHelpIsUsedOnlyWhileUninstalling() {
    let wedged = ControlAvailability.from(
      StatusPresentation.derive(snapshot: nil, hostFailure: .lockHeldElsewhere, engineUnresponsive: false))
    #expect(wedged.engineHelp == ControlMapping.engineUnavailableHelp)
    #expect(wedged.releaseHelp == ControlMapping.engineUnavailableHelp)
  }

  @Test func theSleepNowFailureCopyAndTheHelpMatchTheUISpec() {
    #expect(ControlFeedback.sleepNowFailure == "Couldn't put the Mac to sleep. Try again.")
    #expect(ControlMapping.engineUnavailableHelp == "Unavailable while Overtime isn't running normally.")
    #expect(ControlFeedback.noticeSeconds == 10)
  }

  @Test func aMissingOrRejectedResponseIsAFailure() {
    #expect(ControlFeedback.failed(nil))
    #expect(ControlFeedback.failed(.failure("rejected")))
    #expect(!ControlFeedback.failed(CtlResponse(ok: true)))
    #expect(!ControlFeedback.failed(CtlResponse(ok: true, error: "accepted, pending")))
  }

  @Test func aForceDuringTheBatteryFloorStillShowsTheBatteryFloor() {
    var want = WantState()
    let now = Instant(nanoseconds: 1_000_000_000)
    _ = Want.apply(.force(.indefinite), to: &want, now: now, wall: Self.now)
    _ = Want.evaluate(&want, busy: false, batteryBlocked: true, now: now, wall: Self.now, settings: Settings())
    #expect(want.wanted == false)
    #expect(want.reason == "battery")
    let snapshot = EngineSnapshot(
      busy: false, wanted: want.wanted, reason: want.reason, force: want.force, batteryBlocked: true)
    let presentation = StatusPresentation.derive(snapshot: snapshot, hostFailure: nil, engineUnresponsive: false)
    #expect(presentation.state == .batteryFloor)
    #expect(presentation.title == "Battery low")
  }

  static let shown = Instant(nanoseconds: 1_000_000_000_000)

  @Test func sleepNowActsAtOnceWhenClaudeIsNotBusy() {
    var confirmation = SleepConfirmation()
    #expect(confirmation.press(busy: false, now: Self.shown) == .sleepNow)
    #expect(confirmation.isConfirming == false)
  }

  @Test func sleepNowAsksFirstWhileClaudeIsBusy() {
    var confirmation = SleepConfirmation()
    #expect(confirmation.press(busy: true, now: Self.shown) == nil)
    #expect(confirmation.phase == .confirming(shownAt: Self.shown))
    #expect(confirmation.confirm() == .sleepNow)
    #expect(confirmation.isConfirming == false)
  }

  @Test func keepWorkingCancelsTheConfirmation() {
    var confirmation = SleepConfirmation()
    _ = confirmation.press(busy: true, now: Self.shown)
    confirmation.cancel()
    #expect(confirmation.phase == .idle)
  }

  @Test func theConfirmationExpiresFiveSecondsAfterItWasShown() {
    var confirmation = SleepConfirmation()
    _ = confirmation.press(busy: true, now: Self.shown)
    confirmation.expire(now: Self.shown.adding(seconds: 4.999))
    #expect(confirmation.isConfirming)
    confirmation.expire(now: Self.shown.adding(seconds: 5))
    #expect(confirmation.phase == .idle)
  }

  @Test func anOlderTimeoutDoesNotExpireANewerConfirmation() {
    var confirmation = SleepConfirmation()
    _ = confirmation.press(busy: true, now: Self.shown)
    confirmation.cancel()
    let later = Self.shown.adding(seconds: 3)
    _ = confirmation.press(busy: true, now: later)
    confirmation.expire(now: Self.shown.adding(seconds: SleepConfirmation.timeoutSeconds))
    #expect(confirmation.phase == .confirming(shownAt: later))
  }

  @Test func pressingAgainWhileConfirmingKeepsAsking() {
    var confirmation = SleepConfirmation()
    _ = confirmation.press(busy: true, now: Self.shown)
    #expect(confirmation.press(busy: true, now: Self.shown.adding(seconds: 1)) == nil)
    #expect(confirmation.isConfirming)
  }

  @Test func theConfirmationCopyMatchesTheUISpecVerbatim() {
    #expect(SleepConfirmation.sleepNowLabel == "Sleep Now")
    #expect(SleepConfirmation.prompt == "Claude is working. Sleep anyway?")
    #expect(SleepConfirmation.confirmLabel == "Sleep Anyway")
    #expect(SleepConfirmation.cancelLabel == "Keep Working")
  }
}
