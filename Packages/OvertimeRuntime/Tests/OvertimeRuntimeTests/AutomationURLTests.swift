import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeSystem
import Testing

struct AutomationURLTests {
  static let scheme = AutomationURL.releaseScheme

  static let madrid: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
    return calendar
  }()

  static func madridDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
    madrid.date(
      from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
  }

  struct ParseCase: Sendable, CustomTestStringConvertible {
    let url: String
    let result: Result<AutomationCommand, AutomationURLError>

    var testDescription: String { url }
  }

  static let accepted: [ParseCase] = [
    ParseCase(url: "overtime://keep-awake?minutes=1", result: .success(.keepAwake(minutes: 1))),
    ParseCase(url: "overtime://keep-awake?minutes=30", result: .success(.keepAwake(minutes: 30))),
    ParseCase(url: "overtime://keep-awake?minutes=090", result: .success(.keepAwake(minutes: 90))),
    ParseCase(url: "overtime://keep-awake?minutes=1440", result: .success(.keepAwake(minutes: 1440))),
    ParseCase(url: "overtime://keep-awake?until=05:30", result: .success(.keepAwakeUntil(hour: 5, minute: 30))),
    ParseCase(url: "overtime://keep-awake?until=5:30", result: .success(.keepAwakeUntil(hour: 5, minute: 30))),
    ParseCase(url: "overtime://keep-awake?until=00:00", result: .success(.keepAwakeUntil(hour: 0, minute: 0))),
    ParseCase(url: "overtime://keep-awake?until=23:59", result: .success(.keepAwakeUntil(hour: 23, minute: 59))),
    ParseCase(url: "overtime://keep-awake?until=21%3A15", result: .success(.keepAwakeUntil(hour: 21, minute: 15))),
    ParseCase(url: "overtime://keep-awake", result: .success(.keepAwakeUntilStopped)),
    ParseCase(url: "overtime://keep-awake/", result: .success(.keepAwakeUntilStopped)),
    ParseCase(url: "overtime://keep-awake?", result: .success(.keepAwakeUntilStopped)),
    ParseCase(url: "OVERTIME://KEEP-AWAKE?minutes=15", result: .success(.keepAwake(minutes: 15))),
    ParseCase(url: "overtime://stop-keep-awake", result: .success(.stopKeepAwake)),
    ParseCase(url: "overtime://stop-keep-awake/", result: .success(.stopKeepAwake)),
    ParseCase(url: "overtime://stop-keep-awake?", result: .success(.stopKeepAwake)),
  ]

  static let rejected: [ParseCase] = [
    ParseCase(url: "overtime://keep-awake?minutes=0", result: .failure(.invalidMinutes)),
    ParseCase(url: "overtime://keep-awake?minutes=1441", result: .failure(.invalidMinutes)),
    ParseCase(url: "overtime://keep-awake?minutes=99999999999999999999", result: .failure(.invalidMinutes)),
    ParseCase(url: "overtime://keep-awake?minutes=-5", result: .failure(.invalidMinutes)),
    ParseCase(url: "overtime://keep-awake?minutes=+5", result: .failure(.invalidMinutes)),
    ParseCase(url: "overtime://keep-awake?minutes=1.5", result: .failure(.invalidMinutes)),
    ParseCase(url: "overtime://keep-awake?minutes=%205", result: .failure(.invalidMinutes)),
    ParseCase(url: "overtime://keep-awake?minutes=ten", result: .failure(.invalidMinutes)),
    ParseCase(url: "overtime://keep-awake?minutes=", result: .failure(.invalidMinutes)),
    ParseCase(url: "overtime://keep-awake?minutes", result: .failure(.invalidMinutes)),
    ParseCase(url: "overtime://keep-awake?minutes=%0A5", result: .failure(.invalidMinutes)),
    ParseCase(url: "overtime://keep-awake?until=24:00", result: .failure(.invalidTime)),
    ParseCase(url: "overtime://keep-awake?until=12:60", result: .failure(.invalidTime)),
    ParseCase(url: "overtime://keep-awake?until=12:5", result: .failure(.invalidTime)),
    ParseCase(url: "overtime://keep-awake?until=12:005", result: .failure(.invalidTime)),
    ParseCase(url: "overtime://keep-awake?until=123:00", result: .failure(.invalidTime)),
    ParseCase(url: "overtime://keep-awake?until=1200", result: .failure(.invalidTime)),
    ParseCase(url: "overtime://keep-awake?until=12:00:00", result: .failure(.invalidTime)),
    ParseCase(url: "overtime://keep-awake?until=-1:00", result: .failure(.invalidTime)),
    ParseCase(url: "overtime://keep-awake?until=5pm", result: .failure(.invalidTime)),
    ParseCase(url: "overtime://keep-awake?until=", result: .failure(.invalidTime)),
    ParseCase(url: "overtime://keep-awake?until", result: .failure(.invalidTime)),
    ParseCase(url: "overtime://keep-awake?minute=30", result: .failure(.unexpectedParameter)),
    ParseCase(url: "overtime://keep-awake?Minutes=30", result: .failure(.unexpectedParameter)),
    ParseCase(url: "overtime://keep-awake?minutes=30&minutes=60", result: .failure(.unexpectedParameter)),
    ParseCase(url: "overtime://keep-awake?minutes=30&until=05:00", result: .failure(.unexpectedParameter)),
    ParseCase(url: "overtime://keep-awake?minutes=30&", result: .failure(.unexpectedParameter)),
    ParseCase(url: "overtime://stop-keep-awake?minutes=30", result: .failure(.unexpectedParameter)),
    ParseCase(url: "overtime://keepawake", result: .failure(.unknownCommand)),
    ParseCase(url: "overtime://pause?minutes=30", result: .failure(.unknownCommand)),
    ParseCase(url: "overtime://keep-awake/now", result: .failure(.unknownCommand)),
    ParseCase(url: "overtime://", result: .failure(.unknownCommand)),
    ParseCase(url: "overtime:keep-awake", result: .failure(.unknownCommand)),
    ParseCase(url: "overtime-dev://keep-awake", result: .failure(.wrongScheme)),
    ParseCase(url: "https://keep-awake?minutes=30", result: .failure(.wrongScheme)),
    ParseCase(url: "overtime://keep-awake#now", result: .failure(.malformed)),
    ParseCase(url: "overtime://user@keep-awake", result: .failure(.malformed)),
    ParseCase(url: "overtime://keep-awake:80", result: .failure(.malformed)),
    ParseCase(url: "keep-awake?minutes=30", result: .failure(.malformed)),
    ParseCase(url: "", result: .failure(.malformed)),
    ParseCase(url: "overtime://keep awake", result: .failure(.malformed)),
  ]

  @Test(arguments: accepted)
  func eachSupportedURLParsesToItsCommand(_ item: ParseCase) {
    #expect(AutomationURL.parse(item.url, scheme: Self.scheme) == item.result)
  }

  @Test(arguments: rejected)
  func eachInvalidURLIsRejectedWithItsReason(_ item: ParseCase) {
    #expect(AutomationURL.parse(item.url, scheme: Self.scheme) == item.result)
  }

  @Test func theDevelopmentBuildAnswersOnlyItsOwnScheme() {
    #expect(
      AutomationURL.parse("overtime-dev://keep-awake?minutes=5", scheme: AutomationURL.debugScheme)
        == .success(.keepAwake(minutes: 5)))
    #expect(
      AutomationURL.parse("overtime://keep-awake?minutes=5", scheme: AutomationURL.debugScheme)
        == .failure(.wrongScheme))
    #expect(AutomationURL.releaseScheme == "overtime")
    #expect(AutomationURL.debugScheme == "overtime-dev")
  }

  @Test func theMinutesRangeIsTheRangeOfTheKeepAwakeDurationsInSettings() {
    #expect(AutomationURL.minutesRange == Settings.presetMinutesRange)
    #expect(AutomationURL.minutesRange == 1...1440)
  }

  struct ActionCase: Sendable, CustomTestStringConvertible {
    let command: AutomationCommand
    let action: ControlAction

    var testDescription: String { "\(command)" }
  }

  static let actions: [ActionCase] = [
    ActionCase(command: .keepAwake(minutes: 30), action: .keepAwake(.timed(minutes: 30))),
    ActionCase(command: .keepAwake(minutes: 1440), action: .keepAwake(.timed(minutes: 1440))),
    ActionCase(command: .keepAwakeUntilStopped, action: .keepAwake(.untilStopped)),
    ActionCase(command: .stopKeepAwake, action: .stopKeepingAwake),
  ]

  @Test(arguments: actions)
  func eachCommandIsThePanelsOwnControlAction(_ item: ActionCase) {
    let now = Self.madridDate(2026, 10, 21, 20, 30)
    #expect(AutomationURL.action(for: item.command, now: now, calendar: Self.madrid) == item.action)
  }

  @Test func minutesAndUntilStoppedSendTheExactRequestsOfThePanelMenu() {
    let now = Self.madridDate(2026, 10, 21, 20, 30)
    let minutes = AutomationURL.action(for: .keepAwake(minutes: 120), now: now, calendar: Self.madrid)
    let stopped = AutomationURL.action(for: .keepAwakeUntilStopped, now: now, calendar: Self.madrid)
    #expect(ControlMapping.request(for: minutes, now: now, calendar: Self.madrid) == .force(.forSeconds(7200)))
    #expect(ControlMapping.request(for: stopped, now: now, calendar: Self.madrid) == .force(.indefinite))
    let stop = AutomationURL.action(for: .stopKeepAwake, now: now, calendar: Self.madrid)
    #expect(ControlMapping.request(for: stop, now: now, calendar: Self.madrid) == .resume)
  }

  struct UntilCase: Sendable, CustomTestStringConvertible {
    let name: String
    let now: Date
    let hour: Int
    let minute: Int
    let expected: Date
    let seconds: Double

    var testDescription: String { name }
  }

  static let untilCases: [UntilCase] = [
    UntilCase(
      name: "later today", now: madridDate(2026, 10, 21, 20, 30), hour: 21, minute: 0,
      expected: madridDate(2026, 10, 21, 21, 0), seconds: 30 * 60),
    UntilCase(
      name: "past midnight", now: madridDate(2026, 10, 21, 20, 30), hour: 5, minute: 0,
      expected: madridDate(2026, 10, 22, 5, 0), seconds: 8.5 * 3600),
    UntilCase(
      name: "already passed today", now: madridDate(2026, 10, 21, 20, 30), hour: 20, minute: 29,
      expected: madridDate(2026, 10, 22, 20, 29), seconds: 24 * 3600 - 60),
    UntilCase(
      name: "exactly now", now: madridDate(2026, 10, 21, 20, 30), hour: 20, minute: 30,
      expected: madridDate(2026, 10, 22, 20, 30), seconds: 24 * 3600),
    UntilCase(
      name: "seconds into the minute", now: madridDate(2026, 10, 21, 20, 30, 45), hour: 20, minute: 31,
      expected: madridDate(2026, 10, 21, 20, 31), seconds: 15),
    UntilCase(
      name: "midnight", now: madridDate(2026, 10, 21, 23, 0), hour: 0, minute: 0,
      expected: madridDate(2026, 10, 22, 0, 0), seconds: 3600),
    UntilCase(
      name: "across spring forward", now: madridDate(2026, 3, 28, 23, 0), hour: 4, minute: 0,
      expected: madridDate(2026, 3, 29, 4, 0), seconds: 4 * 3600),
    UntilCase(
      name: "a time skipped by spring forward", now: madridDate(2026, 3, 28, 23, 0), hour: 2, minute: 30,
      expected: madridDate(2026, 3, 29, 3, 0), seconds: 3 * 3600),
    UntilCase(
      name: "across fall back", now: madridDate(2026, 10, 24, 23, 0), hour: 4, minute: 0,
      expected: madridDate(2026, 10, 25, 4, 0), seconds: 6 * 3600),
  ]

  @Test(arguments: untilCases)
  func untilIsTheNextLocalTimeStrictlyAfterNow(_ item: UntilCase) {
    let command = AutomationCommand.keepAwakeUntil(hour: item.hour, minute: item.minute)
    let action = AutomationURL.action(for: command, now: item.now, calendar: Self.madrid)
    #expect(action == .keepAwakeUntil(item.expected))
    #expect(
      ControlMapping.request(for: action, now: item.now, calendar: Self.madrid) == .force(.forSeconds(item.seconds)))
  }

  @Test func aDeadlineThatPassedBeforeTheRequestIsBuiltStillSendsAPositiveDuration() {
    let now = Self.madridDate(2026, 10, 21, 20, 30)
    let late = ControlMapping.request(for: .keepAwakeUntil(now.addingTimeInterval(-5)), now: now, calendar: Self.madrid)
    #expect(late == .force(.forSeconds(1)))
  }

  struct LogCase: Sendable, CustomTestStringConvertible {
    let outcome: AutomationOutcome
    let line: String

    var testDescription: String { line }
  }

  static let logs: [LogCase] = [
    LogCase(outcome: .sent(.keepAwake(minutes: 90)), line: "COMMAND url command=keep-awake minutes=90"),
    LogCase(outcome: .sent(.keepAwakeUntil(hour: 5, minute: 0)), line: "COMMAND url command=keep-awake until=05:00"),
    LogCase(outcome: .sent(.keepAwakeUntil(hour: 21, minute: 7)), line: "COMMAND url command=keep-awake until=21:07"),
    LogCase(outcome: .sent(.keepAwakeUntilStopped), line: "COMMAND url command=keep-awake until=stopped"),
    LogCase(outcome: .sent(.stopKeepAwake), line: "COMMAND url command=stop-keep-awake"),
    LogCase(outcome: .rejected(.invalidMinutes), line: "WARN url ignored reason=invalidMinutes"),
    LogCase(outcome: .rejected(.wrongScheme), line: "WARN url ignored reason=wrongScheme"),
    LogCase(
      outcome: .waitingForEngine(.keepAwake(minutes: 30)), line: "COMMAND url waiting command=keep-awake minutes=30"),
    LogCase(outcome: .nothingToStop, line: "COMMAND url ignored command=stop-keep-awake reason=notKeepingAwake"),
    LogCase(
      outcome: .controlsUnavailable(.keepAwakeUntilStopped),
      line: "WARN url ignored command=keep-awake until=stopped reason=controlsUnavailable"),
    LogCase(outcome: .failed(.stopKeepAwake), line: "ERROR url failed command=stop-keep-awake"),
  ]

  @Test(arguments: logs)
  func eachOutcomeWritesOneDecisionLine(_ item: LogCase) {
    let line = DecisionFormatter.line(
      item.outcome.decision, wall: Date(timeIntervalSince1970: 1_800_000_000), timeZone: TimeZone(secondsFromGMT: 0)!)
    #expect(line == "2027-01-15T08:00:00.000Z " + item.line)
  }

  @Test func aRejectedURLNeverWritesWhatItCarriedToTheLog() {
    let hostile = "overtime://keep-awake?minutes=%0A2026-10-21T20:30:00Z%20OVERRIDE%20resume"
    let result = AutomationURL.parse(hostile, scheme: Self.scheme)
    #expect(result == .failure(.invalidMinutes))
    guard case .failure(let error) = result else { return }
    let decision = AutomationOutcome.rejected(error).decision
    #expect(decision.fields == [DecisionField(key: "reason", value: "invalidMinutes")])
  }
}
