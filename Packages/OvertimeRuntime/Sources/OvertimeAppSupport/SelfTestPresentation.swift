import Foundation
import OvertimeCore
import OvertimeEngine

public struct SelfTestRow: Sendable, Equatable {
  public enum Icon: Sendable, Equatable {
    case symbol(String)
    case progress
  }

  public enum Tone: Sendable, Equatable {
    case secondary
    case success
    case warning
    case error
  }

  public let icon: Icon
  public let tone: Tone
  public let title: String
  public let caption: String?

  public init(icon: Icon, tone: Tone, title: String, caption: String? = nil) {
    self.icon = icon
    self.tone = tone
    self.title = title
    self.caption = caption
  }
}

public enum SelfTestPresentation {
  public static let sectionTitle = "Self-test"
  public static let runButtonTitle = "Run Self-Test"

  public static let notRunSymbol = "circle"
  public static let notRunTitle = "Not run yet"
  public static let notRunCaption = "It runs at launch once the lid is open and Claude isn't working."

  public static let waitingSymbol = "clock"
  public static let waitingTitle = "Waiting to run"
  public static let waitingCaption = "It runs when the lid is open and Claude isn't working."

  public static let runningTitle = "Running…"

  public static let passedSymbol = "checkmark.circle.fill"
  public static let passedTitle = "Passed"

  public static let failedSymbol = "xmark.circle.fill"
  public static let failedTitle = "Failed"

  public static let skippedSymbol = "minus.circle.fill"
  public static let skippedTitle = "Skipped"

  public static func row(status: SelfTestStatus, record: SelfTestRecord?, currentBuild: String?) -> SelfTestRow {
    switch status {
    case .notRun:
      record.map(row(for:))
        ?? SelfTestRow(icon: .symbol(notRunSymbol), tone: .secondary, title: notRunTitle, caption: notRunCaption)
    case .waiting:
      SelfTestRow(
        icon: .symbol(waitingSymbol), tone: .secondary, title: waitingTitle,
        caption: waitingCaption(record: record, currentBuild: currentBuild))
    case .running:
      SelfTestRow(icon: .progress, tone: .secondary, title: runningTitle)
    case .passed:
      SelfTestRow(icon: .symbol(passedSymbol), tone: .success, title: passedTitle, caption: record.map { lastRun($0) })
    case .failed(let failure):
      SelfTestRow(
        icon: .symbol(failedSymbol), tone: .error, title: failedTitle,
        caption: caption(reason: reason(for: failure), record: record))
    case .skipped(let skip):
      SelfTestRow(
        icon: .symbol(skippedSymbol), tone: .warning, title: skippedTitle,
        caption: caption(reason: reason(for: skip), record: record))
    }
  }

  public static let runUnavailableHelp = "Available when the lid is open and Claude isn't working."
  public static let runUnavailableWhileRunning = "Available when the current test finishes."
  public static let runUnavailableWhileKeepingAwake = "Available when Overtime isn't keeping the Mac awake."
  public static let runUnavailableWhileLidClosed = "Available when the lid is open."
  public static let passedAnnouncement = "Self-test passed."
  public static let skippedAnnouncement = "Self-test skipped."

  public static func buildChangedCaption(_ build: String) -> String {
    "macOS changed to \(build). The test runs again when the lid is open and Claude isn't working."
  }

  static func waitingCaption(record: SelfTestRecord?, currentBuild: String?) -> String {
    guard let record, let currentBuild, record.osBuild != SelfTestRecorder.unknownBuild,
      record.osBuild != currentBuild
    else { return waitingCaption }
    return buildChangedCaption(currentBuild)
  }

  public static func row(for record: SelfTestRecord) -> SelfTestRow {
    let caption = [record.reason, lastRun(record)].compactMap { $0 }.joined(separator: "\n")
    return switch record.outcome {
    case .passed:
      SelfTestRow(icon: .symbol(passedSymbol), tone: .success, title: passedTitle, caption: caption)
    case .failed:
      SelfTestRow(icon: .symbol(failedSymbol), tone: .error, title: failedTitle, caption: caption)
    case .skipped:
      SelfTestRow(icon: .symbol(skippedSymbol), tone: .warning, title: skippedTitle, caption: caption)
    }
  }

  public static func runButtonEnabled(snapshot: EngineSnapshot?) -> Bool {
    guard let snapshot else { return false }
    return snapshot.wanted != true && snapshot.lidClosed == false && snapshot.selfTest != .running
  }

  public static func runUnavailableReason(snapshot: EngineSnapshot?) -> String? {
    guard let snapshot else { return runUnavailableHelp }
    if snapshot.selfTest == .running { return runUnavailableWhileRunning }
    if snapshot.wanted == true { return runUnavailableWhileKeepingAwake }
    if snapshot.lidClosed != false { return runUnavailableWhileLidClosed }
    return nil
  }

  public static func announcement(for status: SelfTestStatus) -> String? {
    switch status {
    case .passed: passedAnnouncement
    case .failed: StatusPresentation.selfTestFailedTitle
    case .skipped: skippedAnnouncement
    case .notRun, .waiting, .running: nil
    }
  }

  public static let clamshellRefusedFormat = "macOS refused the lid-close control (error 0x%08X)."
  public static let assertionRefusedFormat = "macOS refused the idle-sleep assertion (error 0x%08X)."
  public static let timedOutReason = "macOS didn't answer within 5 seconds."
  public static let watchdogNotRunningReason = "Overtime's safety watchdog wasn't running."
  public static let stateNotSavedReason =
    "Overtime couldn't save its own state, so it didn't touch the lid-close control."
  public static let amphetamineReason = "Amphetamine is managing lid-close sleep, so Overtime didn't touch it."
  public static let otherToolReasonSuffix = " is managing sleep, so Overtime didn't touch it."
  public static let sleepDisabledReason =
    "Sleep is turned off system-wide (SleepDisabled), so Overtime didn't touch the lid-close control."

  public static func reason(for failure: SelfTestFailure) -> String {
    switch failure {
    case .clamshellRefused(let code):
      String(format: clamshellRefusedFormat, UInt32(bitPattern: code))
    case .assertionRefused(let code):
      String(format: assertionRefusedFormat, UInt32(bitPattern: code))
    case .timedOut:
      timedOutReason
    case .watchdogNotRunning:
      watchdogNotRunningReason
    case .stateNotSaved:
      stateNotSavedReason
    }
  }

  public static func reason(for skip: SelfTestSkip) -> String {
    switch skip {
    case .amphetamine:
      amphetamineReason
    case .otherTool(let name):
      name + otherToolReasonSuffix
    case .sleepDisabled:
      sleepDisabledReason
    }
  }

  static func caption(reason: String, record: SelfTestRecord?) -> String {
    guard let record else { return reason }
    return reason + "\n" + lastRun(record)
  }

  public static func lastRun(
    _ record: SelfTestRecord, locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent
  ) -> String {
    let date = UIDateText.string(record.at, locale: locale, timeZone: timeZone)
    return "Last run \(date) on macOS \(record.osVersion) (\(record.osBuild))."
  }
}
