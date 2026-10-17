import Foundation
import OvertimeCore
import OvertimeEngine

public enum PanelError: Sendable, Equatable {
  case holdFailed
  case selfTestFailed
  case notResponding
  case couldNotStart
  case watchdogUnavailable
  case storageUnavailable
}

public enum PanelState: Sendable, Equatable {
  case starting
  case idle
  case holding
  case lidClosedHolding
  case grace
  case paused
  case releasedUntilIdle
  case batteryFloor
  case override
  case uninstalling
  case error(PanelError)
}

public enum HostFailure: Sendable, Equatable {
  case lockHeldElsewhere
  case sentinelUnavailable
  case storageUnavailable
}

public enum StatusGlyph: String, Sendable, Equatable, CaseIterable {
  case idle = "StatusIdle"
  case awake = "StatusAwake"
  case forced = "StatusForced"
  case lidClosed = "StatusLidClosed"
  case waiting = "StatusWaiting"
  case paused = "StatusPaused"
  case batteryLow = "StatusBatteryLow"
  case error = "StatusError"

  public var assetName: String { rawValue }
}

public struct StatusPresentation: Sendable, Equatable {
  public var state: PanelState
  public var glyph: StatusGlyph
  public var fallbackGlyph: String
  public var accessibilityLabel: String
  public var title: String
  public var reason: String

  public init(
    state: PanelState, glyph: StatusGlyph, fallbackGlyph: String, accessibilityLabel: String, title: String,
    reason: String
  ) {
    self.state = state
    self.glyph = glyph
    self.fallbackGlyph = fallbackGlyph
    self.accessibilityLabel = accessibilityLabel
    self.title = title
    self.reason = reason
  }

  public static func derive(
    snapshot: EngineSnapshot?, hostFailure: HostFailure?, engineUnresponsive: Bool, uninstalling: Bool = false
  ) -> StatusPresentation {
    var result = presentation(
      for: state(
        snapshot: snapshot, hostFailure: hostFailure, engineUnresponsive: engineUnresponsive,
        uninstalling: uninstalling))
    switch result.state {
    case .holding:
      result.reason = holdingReason(
        sessionCount: PanelContent.working(snapshot?.sessions ?? [], busy: snapshot?.busy == true).count)
    case .batteryFloor:
      if let snapshot, !snapshot.batteryBlocked, snapshot.temperatureBlocked {
        result.title = hotTitle
        result.accessibilityLabel = hotAccessibilityLabel
        result.reason = hotReason
        if case .celsius(let celsius)? = snapshot.batteryTemperature {
          result.reason = "Battery at \(celsius)°C. \(hotReason)"
        }
      } else if let percent = snapshot?.power?.percent {
        result.reason = "Battery at \(percent)%. \(result.reason)"
      }
    case .override:
      if let snapshot {
        result.reason = overrideReason(lowPercent: snapshot.batteryProtectionEnabled ? snapshot.batteryLowPercent : nil)
      }
    default:
      break
    }
    return result
  }

  public var showsProgress: Bool {
    state == .starting
  }

  public static let hotTitle = "Battery hot"
  public static let hotAccessibilityLabel = "Overtime, battery hot, keep-awake off"
  public static let hotReason = "Keep-awake is off so the battery can cool down."

  public static func overrideReason(lowPercent: Int?) -> String {
    guard let lowPercent else { return "You turned on \(ControlMapping.keepAwakeLabel)." }
    return "You turned on \(ControlMapping.keepAwakeLabel). It still stops at \(lowPercent)% battery."
  }

  public static func holdingReason(sessionCount: Int) -> String {
    switch sessionCount {
    case ...0: "Claude is working."
    case 1: "Claude is working in 1 session."
    default: "Claude is working in \(sessionCount) sessions."
    }
  }

  public static func state(
    snapshot: EngineSnapshot?, hostFailure: HostFailure?, engineUnresponsive: Bool, uninstalling: Bool = false
  ) -> PanelState {
    if uninstalling {
      return .uninstalling
    }
    switch hostFailure {
    case .lockHeldElsewhere:
      return .error(.couldNotStart)
    case .sentinelUnavailable:
      return .error(.watchdogUnavailable)
    case .storageUnavailable:
      return .error(.storageUnavailable)
    case nil:
      break
    }
    if engineUnresponsive {
      return .error(.notResponding)
    }
    guard let snapshot else { return .starting }
    if snapshot.holdError {
      return .error(.holdFailed)
    }
    if snapshot.selfTestErrorActive {
      return .error(.selfTestFailed)
    }
    if snapshot.batteryBlocked || snapshot.temperatureBlocked {
      return .batteryFloor
    }
    if snapshot.pause != nil {
      return .paused
    }
    if snapshot.force != nil || snapshot.reason == "forced" {
      return .override
    }
    if snapshot.releaseUntilIdle || snapshot.reason == "override" {
      return .releasedUntilIdle
    }
    guard snapshot.wanted == true else {
      return snapshot.wanted == nil && snapshot.reason == nil ? .starting : .idle
    }
    if snapshot.reason == "busy" && snapshot.busy == false {
      return .grace
    }
    if snapshot.lidClosed == true {
      return .lidClosedHolding
    }
    return .holding
  }

  public static func presentation(for state: PanelState) -> StatusPresentation {
    switch state {
    case .starting:
      StatusPresentation(
        state: state, glyph: .idle, fallbackGlyph: "moon", accessibilityLabel: "Overtime, starting",
        title: "Starting…", reason: "Reading Claude activity.")
    case .idle:
      StatusPresentation(
        state: state, glyph: .idle, fallbackGlyph: "moon", accessibilityLabel: "Overtime, idle",
        title: "Idle", reason: "No Claude activity. The Mac sleeps normally.")
    case .holding:
      StatusPresentation(
        state: state, glyph: .awake, fallbackGlyph: "sun.max", accessibilityLabel: "Overtime, keeping awake",
        title: "Keeping awake", reason: "Claude is working.")
    case .lidClosedHolding:
      StatusPresentation(
        state: state, glyph: .lidClosed, fallbackGlyph: "laptopcomputer",
        accessibilityLabel: "Overtime, keeping awake with the lid closed", title: "Keeping awake, lid closed",
        reason: "Claude is working. Lid-close sleep is blocked.")
    case .grace:
      StatusPresentation(
        state: state, glyph: .waiting, fallbackGlyph: "hourglass.tophalf.fill",
        accessibilityLabel: "Overtime, releasing soon", title: "Releasing soon",
        reason: "Claude went idle. Overtime waits a little in case it resumes.")
    case .paused:
      StatusPresentation(
        state: state, glyph: .paused, fallbackGlyph: "pause.circle.fill", accessibilityLabel: "Overtime, paused",
        title: "Paused", reason: "Keep-awake is off until the pause ends.")
    case .releasedUntilIdle:
      StatusPresentation(
        state: state, glyph: .paused, fallbackGlyph: "pause.circle.fill", accessibilityLabel: "Overtime, paused",
        title: "Released until idle", reason: "You released the hold. Overtime resumes when Claude goes idle.")
    case .batteryFloor:
      StatusPresentation(
        state: state, glyph: .batteryLow, fallbackGlyph: "battery.25",
        accessibilityLabel: "Overtime, battery low, keep-awake off", title: "Battery low",
        reason: "Keep-awake is off so the Mac can sleep.")
    case .override:
      StatusPresentation(
        state: state, glyph: .forced, fallbackGlyph: "bolt.fill",
        accessibilityLabel: "Overtime, keeping awake manually", title: "Keeping awake manually",
        reason: overrideReason(lowPercent: Settings().batteryLowPercent))
    case .uninstalling:
      StatusPresentation(
        state: state, glyph: .idle, fallbackGlyph: "moon",
        accessibilityLabel: UninstallCopy.panelAccessibilityLabel, title: UninstallCopy.panelTitle,
        reason: UninstallCopy.panelReason)
    case .error(let error):
      errorPresentation(error)
    }
  }

  public static let selfTestFailedTitle = "Self-test failed"
  public static let selfTestFailedReason =
    "Overtime's lid-close control failed its launch test. Until it passes, the Mac may sleep with the lid closed. "
    + "Details are in Settings > Diagnostics."

  private static func errorPresentation(_ error: PanelError) -> StatusPresentation {
    let copy: (title: String, reason: String) =
      switch error {
      case .holdFailed:
        (
          "Keep-awake failed",
          "Overtime couldn't keep the Mac awake and will retry. Until it succeeds, the Mac sleeps normally."
        )
      case .selfTestFailed:
        (selfTestFailedTitle, selfTestFailedReason)
      case .notResponding:
        (
          "Overtime isn't responding",
          "Choose \(ControlMapping.restoreLabel) to make sure the Mac can sleep, then quit and reopen Overtime."
        )
      case .couldNotStart:
        (
          "Overtime couldn't start",
          "Another Overtime process is already running, for example overtimed --live. Quit it, then reopen Overtime."
        )
      case .watchdogUnavailable:
        ("Overtime couldn't start", "Its keep-awake watchdog could not start. Quit and reopen Overtime.")
      case .storageUnavailable:
        (
          "Overtime couldn't start",
          "It couldn't create its support or log folder. Check free disk space and folder permissions, then quit and reopen Overtime."
        )
      }
    return StatusPresentation(
      state: .error(error), glyph: .error, fallbackGlyph: "exclamationmark.triangle",
      accessibilityLabel: "Overtime, error", title: copy.title, reason: copy.reason)
  }
}

public enum TimingKind: Sendable, Equatable {
  case held(since: Instant)
  case grace(deadline: Instant?, since: Instant?)
  case pauseUntilMono(Instant)
  case pauseUntilWall(Date)
  case pauseIndefinite
  case releaseUntilIdle
  case forceUntilMono(Instant, since: Instant?)
  case forceIndefinite(since: Instant?)
  case batteryFloor(resumePercent: Int)
  case batteryHot(resumeCelsius: Int)
}

extension StatusPresentation {
  public static func timingKind(state: PanelState, snapshot: EngineSnapshot?) -> TimingKind? {
    guard let snapshot else { return nil }
    switch state {
    case .holding, .lidClosedHolding:
      return snapshot.wantedSince.map { .held(since: $0) }
    case .grace:
      return .grace(deadline: snapshot.graceDeadline, since: snapshot.wantedSince)
    case .paused:
      switch snapshot.pause {
      case .untilMono(let deadline, _): return .pauseUntilMono(deadline)
      case .untilWall(let date): return .pauseUntilWall(date)
      case .indefinite, nil: return .pauseIndefinite
      }
    case .releasedUntilIdle:
      return .releaseUntilIdle
    case .override:
      if case .untilMono(let deadline)? = snapshot.force {
        return .forceUntilMono(deadline, since: snapshot.wantedSince)
      }
      return .forceIndefinite(since: snapshot.wantedSince)
    case .batteryFloor:
      if snapshot.batteryBlocked {
        return .batteryFloor(resumePercent: snapshot.batteryResumePercent)
      }
      return .batteryHot(resumeCelsius: snapshot.temperatureResumeCelsius)
    case .starting, .idle, .uninstalling, .error:
      return nil
    }
  }
}
