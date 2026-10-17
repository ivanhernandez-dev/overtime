import Foundation
import OvertimeCore
import OvertimeSystem

public enum SettingsField: String, Sendable, CaseIterable {
  case batteryLowPercent
  case batteryResumePercent
  case transcriptWindowSeconds
  case releaseGraceSeconds
  case stuckWindowMinutes
  case helperBatteryFloorPercent
  case temperatureReleaseCelsius
  case pauseFirstMinutes
  case pauseSecondMinutes
  case keepAwakeFirstMinutes
  case keepAwakeSecondMinutes
}

public struct SettingsValidationError: Error, Sendable, Equatable {
  public let message: String

  public init(message: String) {
    self.message = message
  }
}

public enum SettingsEditor {
  public static let releaseAtRangeMessage = "Enter a whole percentage from 1 to 50."
  public static let helperFloorRangeMessage = rangeMessage("a whole percentage", Settings.helperBatteryFloorRange)
  public static let temperatureReleaseRangeMessage = rangeMessage(
    "a whole number of degrees", Settings.temperatureReleaseRange)
  public static let durationRangeMessage = rangeMessage("a whole number of minutes", Settings.presetMinutesRange)

  static func rangeMessage(_ kind: String, _ range: ClosedRange<Int>) -> String {
    "Enter \(kind) from \(range.lowerBound) to \(range.upperBound)."
  }
  public static let transcriptWindowRangeMessage = "Enter a whole number of seconds from 10 to 3600."
  public static let releaseGraceRangeMessage = "Enter a whole number of seconds from 1 to 3600."
  public static let stuckLimitRangeMessage = "Enter a whole number of minutes from 1 to 240."
  public static let foldersMustBeFullPathsMessage = "Transcript folders must be full paths."
  public static let saveFailedMessage =
    "Couldn't save your settings. The change wasn't applied. Try again, or export diagnostics if it keeps happening."

  public static let emptyEntrypointMessage = "Enter a pattern, such as sdk-*."
  public static let entrypointCharactersMessage = "Use only letters, digits, and - _ . * (up to 64 characters)."
  public static let duplicateFolderMessage = "That folder is already in the list."
  public static let maxEntrypointLength = 64

  public static func duplicateEntrypointMessage(pattern: String) -> String {
    "\(pattern) is already in the list."
  }

  public static func windowLongerThanStuckLimitMessage(stuckWindowSeconds: Double) -> String {
    "Must not be longer than the stuck-session limit (\(minutesPhrase(stuckWindowSeconds)))."
  }

  public static func stuckLimitShorterThanWindowMessage(transcriptWindowSeconds: Double) -> String {
    "Must be at least as long as the transcript window (\(minutesPhrase(transcriptWindowSeconds)))."
  }

  public static func releaseAtNotBelowResumeMessage(resumePercent: Int) -> String {
    "Must be lower than the resume level (\(resumePercent)%)."
  }

  public static func resumeAtRangeMessage(releasePercent: Int) -> String {
    "Enter a whole percentage from \(releasePercent + 1) to \(Settings.batteryResumeMax)."
  }

  public static func parseWholeNumber(_ text: String) -> Int? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
    return Int(trimmed)
  }

  public static func validate(_ field: SettingsField, text: String, in settings: Settings) -> Result<
    Settings, SettingsValidationError
  > {
    guard let value = parseWholeNumber(text) else {
      return .failure(rangeError(field, in: settings))
    }
    let candidate = candidate(field, value: value, in: settings)
    if let problem = fieldProblem(field, in: candidate) ?? problem(in: candidate) {
      return .failure(problem)
    }
    return .success(candidate)
  }

  public static func addEntrypoint(_ pattern: String, to settings: Settings) -> Result<
    Settings, SettingsValidationError
  > {
    let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return .failure(SettingsValidationError(message: emptyEntrypointMessage))
    }
    guard trimmed.utf8.count <= maxEntrypointLength, trimmed.utf8.allSatisfy(isEntrypointByte) else {
      return .failure(SettingsValidationError(message: entrypointCharactersMessage))
    }
    guard !settings.ignoredEntrypoints.contains(trimmed) else {
      return .failure(SettingsValidationError(message: duplicateEntrypointMessage(pattern: trimmed)))
    }
    var candidate = settings
    candidate.ignoredEntrypoints.append(trimmed)
    return .success(candidate)
  }

  public static func removeEntrypoint(_ pattern: String, from settings: Settings) -> Settings {
    var candidate = settings
    candidate.ignoredEntrypoints.removeAll { $0 == pattern }
    return candidate
  }

  public static func restoreDefaultEntrypoints(_ settings: Settings) -> Settings {
    var candidate = settings
    candidate.ignoredEntrypoints = Settings().ignoredEntrypoints
    return candidate
  }

  public static func addFolder(_ path: String, to settings: Settings) -> Result<Settings, SettingsValidationError> {
    guard path.hasPrefix("/") else {
      return .failure(SettingsValidationError(message: foldersMustBeFullPathsMessage))
    }
    let roots = settings.transcriptRoots ?? []
    let canonical = TranscriptWatcher.canonicalPath(path)
    guard !roots.contains(where: { TranscriptWatcher.canonicalPath($0) == canonical }) else {
      return .failure(SettingsValidationError(message: duplicateFolderMessage))
    }
    var candidate = settings
    candidate.transcriptRoots = roots + [path]
    return .success(candidate)
  }

  public static func removeFolder(_ path: String, from settings: Settings) -> Settings {
    var candidate = settings
    let remaining = (settings.transcriptRoots ?? []).filter { $0 != path }
    candidate.transcriptRoots = remaining.isEmpty ? nil : remaining
    return candidate
  }

  public static func useDefaultFolder(_ settings: Settings) -> Settings {
    var candidate = settings
    candidate.transcriptRoots = nil
    return candidate
  }

  static func isEntrypointByte(_ byte: UInt8) -> Bool {
    switch byte {
    case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
      UInt8(ascii: "0")...UInt8(ascii: "9"):
      true
    case UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "*"):
      true
    default:
      false
    }
  }

  static func minutesPhrase(_ seconds: Double) -> String {
    let minutes = Int((seconds / 60).rounded(.up))
    return minutes == 1 ? "1 minute" : "\(minutes) minutes"
  }

  public static func isValid(_ settings: Settings) -> Bool {
    SettingsStore.validationProblem(settings) == nil && settings.validated().adjustments.isEmpty
  }

  public static func problem(in settings: Settings) -> SettingsValidationError? {
    for field in SettingsField.allCases {
      if let problem = fieldProblem(field, in: settings) {
        return problem
      }
    }
    let storeProblem = SettingsStore.validationProblem(settings)
    if storeProblem == "transcriptRoots" {
      return SettingsValidationError(message: foldersMustBeFullPathsMessage)
    }
    guard !isValid(settings) else { return nil }
    let key = storeProblem ?? settings.validated().adjustments.first?.key
    let field = SettingsField.allCases.first { fieldKey($0) == key } ?? .batteryLowPercent
    return rangeError(field, in: settings)
  }

  static func fieldKey(_ field: SettingsField) -> String {
    field == .stuckWindowMinutes ? "stuckWindowSeconds" : field.rawValue
  }

  static func candidate(_ field: SettingsField, value: Int, in settings: Settings) -> Settings {
    var candidate = settings
    switch field {
    case .batteryLowPercent:
      candidate.batteryLowPercent = value
    case .batteryResumePercent:
      candidate.batteryResumePercent = value
    case .transcriptWindowSeconds:
      candidate.transcriptWindowSeconds = Double(value)
    case .releaseGraceSeconds:
      candidate.releaseGraceSeconds = Double(value)
    case .stuckWindowMinutes:
      candidate.stuckWindowSeconds = Double(value) * 60
    case .helperBatteryFloorPercent:
      candidate.helperBatteryFloorPercent = value
    case .temperatureReleaseCelsius:
      candidate.temperatureReleaseCelsius = value
    case .pauseFirstMinutes:
      candidate.pauseFirstMinutes = value
    case .pauseSecondMinutes:
      candidate.pauseSecondMinutes = value
    case .keepAwakeFirstMinutes:
      candidate.keepAwakeFirstMinutes = value
    case .keepAwakeSecondMinutes:
      candidate.keepAwakeSecondMinutes = value
    }
    return candidate
  }

  static func rangeError(_ field: SettingsField, in settings: Settings) -> SettingsValidationError {
    switch field {
    case .batteryLowPercent:
      SettingsValidationError(message: releaseAtRangeMessage)
    case .batteryResumePercent:
      SettingsValidationError(message: resumeAtRangeMessage(releasePercent: settings.batteryLowPercent))
    case .transcriptWindowSeconds:
      SettingsValidationError(message: transcriptWindowRangeMessage)
    case .releaseGraceSeconds:
      SettingsValidationError(message: releaseGraceRangeMessage)
    case .stuckWindowMinutes:
      SettingsValidationError(message: stuckLimitRangeMessage)
    case .helperBatteryFloorPercent:
      SettingsValidationError(message: helperFloorRangeMessage)
    case .temperatureReleaseCelsius:
      SettingsValidationError(message: temperatureReleaseRangeMessage)
    case .pauseFirstMinutes, .pauseSecondMinutes, .keepAwakeFirstMinutes, .keepAwakeSecondMinutes:
      SettingsValidationError(message: durationRangeMessage)
    }
  }

  static func fieldProblem(_ field: SettingsField, in settings: Settings) -> SettingsValidationError? {
    switch field {
    case .batteryLowPercent:
      guard Settings.batteryLowRange.contains(settings.batteryLowPercent) else {
        return rangeError(field, in: settings)
      }
      guard settings.batteryLowPercent < settings.batteryResumePercent else {
        return SettingsValidationError(
          message: releaseAtNotBelowResumeMessage(resumePercent: settings.batteryResumePercent))
      }
      return nil
    case .batteryResumePercent:
      let lower = settings.batteryLowPercent + 1
      guard lower <= Settings.batteryResumeMax,
        (lower...Settings.batteryResumeMax).contains(settings.batteryResumePercent)
      else {
        return rangeError(field, in: settings)
      }
      return nil
    case .transcriptWindowSeconds:
      guard Settings.transcriptWindowRange.contains(settings.transcriptWindowSeconds) else {
        return rangeError(field, in: settings)
      }
      guard settings.transcriptWindowSeconds <= settings.stuckWindowSeconds else {
        return SettingsValidationError(
          message: windowLongerThanStuckLimitMessage(stuckWindowSeconds: settings.stuckWindowSeconds))
      }
      return nil
    case .releaseGraceSeconds:
      return Settings.releaseGraceRange.contains(settings.releaseGraceSeconds) ? nil : rangeError(field, in: settings)
    case .stuckWindowMinutes:
      let range = Settings.stuckWindowMinSeconds...Settings.stuckWindowMaxSeconds
      guard range.contains(settings.stuckWindowSeconds) else {
        return rangeError(field, in: settings)
      }
      guard settings.stuckWindowSeconds >= settings.transcriptWindowSeconds else {
        return SettingsValidationError(
          message: stuckLimitShorterThanWindowMessage(transcriptWindowSeconds: settings.transcriptWindowSeconds))
      }
      return nil
    case .helperBatteryFloorPercent:
      return Settings.helperBatteryFloorRange.contains(settings.helperBatteryFloorPercent)
        ? nil : rangeError(field, in: settings)
    case .temperatureReleaseCelsius:
      return Settings.temperatureReleaseRange.contains(settings.temperatureReleaseCelsius)
        ? nil : rangeError(field, in: settings)
    case .pauseFirstMinutes:
      return Settings.presetMinutesRange.contains(settings.pauseFirstMinutes) ? nil : rangeError(field, in: settings)
    case .pauseSecondMinutes:
      return Settings.presetMinutesRange.contains(settings.pauseSecondMinutes) ? nil : rangeError(field, in: settings)
    case .keepAwakeFirstMinutes:
      return Settings.presetMinutesRange.contains(settings.keepAwakeFirstMinutes)
        ? nil : rangeError(field, in: settings)
    case .keepAwakeSecondMinutes:
      return Settings.presetMinutesRange.contains(settings.keepAwakeSecondMinutes)
        ? nil : rangeError(field, in: settings)
    }
  }
}

public enum SettingsCommitResult: Sendable, Equatable {
  case applied
  case invalid(SettingsValidationError)
  case saveFailed
  case applyTimedOut
}

public enum SettingsCommitter {
  public static func commit(_ settings: Settings, to url: URL, host: any EngineHosting) async -> SettingsCommitResult {
    if let problem = SettingsEditor.problem(in: settings) {
      return .invalid(problem)
    }
    do {
      try SettingsStore.save(settings, to: url)
    } catch {
      return .saveFailed
    }
    guard await host.apply(settings: settings) else { return .applyTimedOut }
    return .applied
  }
}
