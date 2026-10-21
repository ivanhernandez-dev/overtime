import Foundation
import OvertimeCore

public enum AutomationCommand: Sendable, Equatable {
  case keepAwake(minutes: Int)
  case keepAwakeUntil(hour: Int, minute: Int)
  case keepAwakeUntilStopped
  case stopKeepAwake

  var logFields: [DecisionField] {
    switch self {
    case .keepAwake(let minutes):
      [
        DecisionField(key: "command", value: AutomationURL.keepAwakeCommand),
        DecisionField(key: "minutes", value: "\(minutes)"),
      ]
    case .keepAwakeUntil(let hour, let minute):
      [
        DecisionField(key: "command", value: AutomationURL.keepAwakeCommand),
        DecisionField(key: "until", value: AutomationURL.clockText(hour: hour, minute: minute)),
      ]
    case .keepAwakeUntilStopped:
      [
        DecisionField(key: "command", value: AutomationURL.keepAwakeCommand),
        DecisionField(key: "until", value: "stopped"),
      ]
    case .stopKeepAwake:
      [DecisionField(key: "command", value: AutomationURL.stopKeepAwakeCommand)]
    }
  }
}

public enum AutomationURLError: String, Error, Sendable, Equatable {
  case malformed
  case wrongScheme
  case unknownCommand
  case unexpectedParameter
  case invalidMinutes
  case invalidTime
}

public enum AutomationOutcome: Sendable, Equatable {
  case sent(AutomationCommand)
  case rejected(AutomationURLError)
  case waitingForEngine(AutomationCommand)
  case nothingToStop
  case controlsUnavailable(AutomationCommand)
  case failed(AutomationCommand)

  public var decision: Decision {
    switch self {
    case .sent(let command):
      Decision(keyword: .command, verb: "url", fields: command.logFields)
    case .rejected(let error):
      Decision(keyword: .warn, verb: "url ignored", fields: [DecisionField(key: "reason", value: error.rawValue)])
    case .waitingForEngine(let command):
      Decision(keyword: .command, verb: "url waiting", fields: command.logFields)
    case .nothingToStop:
      Decision(
        keyword: .command, verb: "url ignored",
        fields: AutomationCommand.stopKeepAwake.logFields + [DecisionField(key: "reason", value: "notKeepingAwake")])
    case .controlsUnavailable(let command):
      Decision(
        keyword: .warn, verb: "url ignored",
        fields: command.logFields + [DecisionField(key: "reason", value: "controlsUnavailable")])
    case .failed(let command):
      Decision(keyword: .error, verb: "url failed", fields: command.logFields)
    }
  }
}

public enum AutomationURL {
  public static let releaseScheme = "overtime"
  public static let debugScheme = "overtime-dev"
  public static let keepAwakeCommand = "keep-awake"
  public static let stopKeepAwakeCommand = "stop-keep-awake"
  public static let minutesParameter = "minutes"
  public static let untilParameter = "until"
  public static let minutesRange = Settings.presetMinutesRange

  public static func parse(_ text: String, scheme: String) -> Result<AutomationCommand, AutomationURLError> {
    guard let components = URLComponents(string: text), let parsedScheme = components.scheme else {
      return .failure(.malformed)
    }
    guard parsedScheme.lowercased() == scheme else { return .failure(.wrongScheme) }
    guard components.user == nil, components.password == nil, components.port == nil, components.fragment == nil
    else { return .failure(.malformed) }
    guard components.path.isEmpty || components.path == "/" else { return .failure(.unknownCommand) }
    let items = components.queryItems ?? []
    switch components.host?.lowercased() {
    case keepAwakeCommand:
      return keepAwake(items)
    case stopKeepAwakeCommand:
      return items.isEmpty ? .success(.stopKeepAwake) : .failure(.unexpectedParameter)
    default:
      return .failure(.unknownCommand)
    }
  }

  public static func action(for command: AutomationCommand, now: Date, calendar: Calendar) -> ControlAction {
    switch command {
    case .keepAwake(let minutes):
      .keepAwake(.timed(minutes: minutes))
    case .keepAwakeUntil(let hour, let minute):
      .keepAwakeUntil(nextLocalTime(hour: hour, minute: minute, after: now, calendar: calendar))
    case .keepAwakeUntilStopped:
      .keepAwake(.untilStopped)
    case .stopKeepAwake:
      .stopKeepingAwake
    }
  }

  public static func nextLocalTime(hour: Int, minute: Int, after date: Date, calendar: Calendar) -> Date {
    if let next = calendar.nextDate(
      after: date, matching: DateComponents(hour: hour, minute: minute, second: 0), matchingPolicy: .nextTime)
    {
      return next
    }
    return date.addingTimeInterval(24 * 3600)
  }

  static func clockText(hour: Int, minute: Int) -> String {
    (hour < 10 ? "0" : "") + "\(hour):" + (minute < 10 ? "0" : "") + "\(minute)"
  }

  private static func keepAwake(_ items: [URLQueryItem]) -> Result<AutomationCommand, AutomationURLError> {
    guard items.count <= 1, items.allSatisfy({ $0.name == minutesParameter || $0.name == untilParameter }) else {
      return .failure(.unexpectedParameter)
    }
    guard let item = items.first else { return .success(.keepAwakeUntilStopped) }
    if item.name == minutesParameter {
      guard let minutes = number(item.value, digits: 1...4), minutesRange.contains(minutes) else {
        return .failure(.invalidMinutes)
      }
      return .success(.keepAwake(minutes: minutes))
    }
    let parts = (item.value ?? "").split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 2, let hour = number(parts[0], digits: 1...2), let minute = number(parts[1], digits: 2...2),
      (0...23).contains(hour), (0...59).contains(minute)
    else { return .failure(.invalidTime) }
    return .success(.keepAwakeUntil(hour: hour, minute: minute))
  }

  private static func number(_ text: String?, digits: ClosedRange<Int>) -> Int? {
    guard let text, digits.contains(text.count), text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
    return Int(text)
  }
}
