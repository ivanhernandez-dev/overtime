import Foundation
import OvertimeCore
import OvertimeEngine
import OvertimeSystem

public enum PauseChoice: Sendable, Hashable {
  case timed(minutes: Int)
  case untilTomorrow
  case untilResumed

  public var label: String {
    switch self {
    case .timed(let minutes): DurationLabel.title(minutes: minutes)
    case .untilTomorrow: "Until Tomorrow"
    case .untilResumed: "Until Resumed"
    }
  }

  public static func menu(timedMinutes: [Int]) -> [PauseChoice] {
    DurationLabel.menuMinutes(timedMinutes).map { PauseChoice.timed(minutes: $0) } + [.untilTomorrow, .untilResumed]
  }

  public static var defaultMenu: [PauseChoice] {
    let settings = Settings()
    return menu(timedMinutes: [settings.pauseFirstMinutes, settings.pauseSecondMinutes])
  }
}

public enum KeepAwakeChoice: Sendable, Hashable {
  case timed(minutes: Int)
  case untilStopped

  public var label: String {
    switch self {
    case .timed(let minutes): DurationLabel.title(minutes: minutes)
    case .untilStopped: "Until Stopped"
    }
  }

  public static func menu(timedMinutes: [Int]) -> [KeepAwakeChoice] {
    DurationLabel.menuMinutes(timedMinutes).map { KeepAwakeChoice.timed(minutes: $0) } + [.untilStopped]
  }

  public static var defaultMenu: [KeepAwakeChoice] {
    let settings = Settings()
    return menu(timedMinutes: [settings.keepAwakeFirstMinutes, settings.keepAwakeSecondMinutes])
  }
}

public enum DurationLabel {
  public static func title(minutes: Int) -> String {
    let hours = minutes / 60
    let rest = minutes % 60
    let hourPart = hours == 1 ? "1 Hour" : "\(hours) Hours"
    let minutePart = rest == 1 ? "1 Minute" : "\(rest) Minutes"
    if hours == 0 { return minutePart }
    if rest == 0 { return hourPart }
    return "\(hourPart) \(minutePart)"
  }

  static func menuMinutes(_ minutes: [Int]) -> [Int] {
    Set(minutes.filter { Settings.presetMinutesRange.contains($0) }).sorted()
  }
}

public enum ControlAction: Sendable, Equatable {
  case pause(PauseChoice)
  case keepAwake(KeepAwakeChoice)
  case keepAwakeUntil(Date)
  case releaseUntilIdle
  case resume
  case stopKeepingAwake
}

public enum ControlMapping {
  public static let pauseLabel = "Pause"
  public static let keepAwakeLabel = "Keep Awake"
  public static let resumeLabel = "Resume"
  public static let stopKeepingAwakeLabel = "Stop Keeping Awake"
  public static let releaseUntilIdleLabel = "Release Until Idle"
  public static let restoreLabel = "Restore Normal Sleep Now"
  public static let releaseUnavailableHelp = "Available while Claude is keeping the Mac awake."
  public static let engineUnavailableHelp = "Unavailable while Overtime isn't running normally."
  public static let uninstallingHelp = "Not available while Overtime uninstalls."
  public static let keepDisplayOnLabel = "Keep display on"
  public static let keepDisplayOnSymbol = "display"
  public static let keepDisplayOnHelp =
    "Keeps the display on while Claude works. With the lid closed and no external display, the display still turns off so the screen locks."

  public static func request(for action: ControlAction, now: Date, calendar: Calendar) -> CtlRequest {
    switch action {
    case .pause(.timed(let minutes)): .pause(.forSeconds(Double(minutes) * 60))
    case .pause(.untilTomorrow): .pause(.until(nextLocalMidnight(after: now, calendar: calendar)))
    case .pause(.untilResumed): .pause(.indefinite)
    case .keepAwake(.timed(let minutes)): .force(.forSeconds(Double(minutes) * 60))
    case .keepAwake(.untilStopped): .force(.indefinite)
    case .keepAwakeUntil(let date): .force(.forSeconds(max(date.timeIntervalSince(now), minimumSeconds)))
    case .releaseUntilIdle: .releaseUntilIdle
    case .resume, .stopKeepingAwake: .resume
    }
  }

  static let minimumSeconds: Double = 1

  public static func nextLocalMidnight(after date: Date, calendar: Calendar) -> Date {
    if let midnight = calendar.nextDate(
      after: date, matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime)
    {
      return midnight
    }
    let startOfDay = calendar.startOfDay(for: date)
    return calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? date.addingTimeInterval(24 * 3600)
  }
}

public enum ControlFeedback {
  public static let noticeSeconds: Double = 10
  public static let sleepNowFailure = "Couldn't put the Mac to sleep. Try again."
  public static let keepDisplayOnFailure = "Couldn't change the display setting. Try again."

  public static func failureCopy(for action: ControlAction) -> String {
    switch action {
    case .pause: "Couldn't pause. Try again."
    case .keepAwake, .keepAwakeUntil: "Couldn't turn on \(ControlMapping.keepAwakeLabel). Try again."
    case .resume: "Couldn't resume. Try again."
    case .stopKeepingAwake: "Couldn't stop keeping awake. Try again."
    case .releaseUntilIdle: "Couldn't release the hold. Try again."
    }
  }

  public static func failed(_ response: CtlResponse?) -> Bool {
    guard let response else { return true }
    return !response.ok
  }

  public static func settingFailed(_ result: SettingsCommitResult?) -> Bool {
    switch result {
    case nil, .applied: false
    case .applyTimedOut, .saveFailed, .invalid: true
    }
  }
}

public struct ControlAvailability: Sendable, Equatable {
  public enum PauseRow: Sendable, Equatable {
    case pauseMenu
    case resume
  }

  public enum KeepAwakeRow: Sendable, Equatable {
    case keepAwakeMenu
    case stopKeepingAwake
  }

  public var pauseRow: PauseRow
  public var keepAwakeRow: KeepAwakeRow
  public var releaseEnabled: Bool
  public var engineControlsEnabled: Bool
  public var uninstalling: Bool

  public init(
    pauseRow: PauseRow, keepAwakeRow: KeepAwakeRow, releaseEnabled: Bool, engineControlsEnabled: Bool = true,
    uninstalling: Bool = false
  ) {
    self.pauseRow = pauseRow
    self.keepAwakeRow = keepAwakeRow
    self.releaseEnabled = releaseEnabled
    self.engineControlsEnabled = engineControlsEnabled
    self.uninstalling = uninstalling
  }

  public var engineHelp: String? {
    engineControlsEnabled ? nil : unavailableHelp
  }

  public var releaseHelp: String? {
    if releaseEnabled { return nil }
    return engineControlsEnabled ? ControlMapping.releaseUnavailableHelp : unavailableHelp
  }

  public var displaySwitchHelp: String {
    engineControlsEnabled ? ControlMapping.keepDisplayOnHelp : unavailableHelp
  }

  private var unavailableHelp: String {
    uninstalling ? ControlMapping.uninstallingHelp : ControlMapping.engineUnavailableHelp
  }

  public static func from(_ presentation: StatusPresentation, snapshot: EngineSnapshot? = nil) -> ControlAvailability {
    let paused =
      presentation.state == .paused || presentation.state == .releasedUntilIdle || snapshot?.pause != nil
      || snapshot?.releaseUntilIdle == true
    let forced = presentation.state == .override || snapshot?.force != nil
    let releaseEnabled: Bool =
      switch presentation.state {
      case .holding, .lidClosedHolding, .grace: true
      default: false
      }
    return ControlAvailability(
      pauseRow: paused ? .resume : .pauseMenu,
      keepAwakeRow: forced ? .stopKeepingAwake : .keepAwakeMenu,
      releaseEnabled: releaseEnabled,
      engineControlsEnabled: engineControlsEnabled(presentation.state),
      uninstalling: presentation.state == .uninstalling)
  }

  private static func engineControlsEnabled(_ state: PanelState) -> Bool {
    if state == .uninstalling { return false }
    guard case .error(let error) = state else { return true }
    switch error {
    case .holdFailed, .selfTestFailed: return true
    case .notResponding, .couldNotStart, .watchdogUnavailable, .storageUnavailable: return false
    }
  }
}

public struct SleepConfirmation: Sendable, Equatable {
  public enum Phase: Sendable, Equatable {
    case idle
    case confirming(shownAt: Instant)
  }

  public static let timeoutSeconds: Double = 5
  public static let sleepNowLabel = "Sleep Now"
  public static let prompt = "Claude is working. Sleep anyway?"
  public static let confirmLabel = "Sleep Anyway"
  public static let cancelLabel = "Keep Working"

  public private(set) var phase: Phase = .idle

  public init() {}

  public var isConfirming: Bool {
    phase != .idle
  }

  public mutating func press(busy: Bool, now: Instant) -> CtlRequest? {
    if isConfirming { return nil }
    guard busy else { return .sleepNow }
    phase = .confirming(shownAt: now)
    return nil
  }

  public mutating func confirm() -> CtlRequest {
    phase = .idle
    return .sleepNow
  }

  public mutating func cancel() {
    phase = .idle
  }

  public mutating func expire(now: Instant) {
    guard case .confirming(let shownAt) = phase, now >= shownAt.adding(seconds: Self.timeoutSeconds) else { return }
    phase = .idle
  }
}
