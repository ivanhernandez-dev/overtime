import Foundation
import OvertimeAppSupport
import Testing

struct NextMidnightTests {
  struct Case: Sendable, CustomTestStringConvertible {
    let name: String
    let zone: String
    let now: DateComponents
    let expectedDay: DateComponents
    let expectedInterval: Double?

    var testDescription: String { name }
  }

  static func local(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0)
    -> DateComponents
  {
    DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
  }

  static let cases: [Case] = [
    Case(
      name: "Madrid afternoon", zone: "Europe/Madrid", now: local(2026, 9, 27, 15), expectedDay: local(2026, 9, 28),
      expectedInterval: 9 * 3600),
    Case(
      name: "Madrid exactly at midnight", zone: "Europe/Madrid", now: local(2026, 9, 28),
      expectedDay: local(2026, 9, 29), expectedInterval: 24 * 3600),
    Case(
      name: "Madrid the night before spring forward", zone: "Europe/Madrid", now: local(2026, 3, 28, 23, 30),
      expectedDay: local(2026, 3, 29), expectedInterval: 30 * 60),
    Case(
      name: "Madrid on the 23-hour day", zone: "Europe/Madrid", now: local(2026, 3, 29, 1),
      expectedDay: local(2026, 3, 30), expectedInterval: 22 * 3600),
    Case(
      name: "Madrid on the 25-hour day", zone: "Europe/Madrid", now: local(2026, 10, 25, 1),
      expectedDay: local(2026, 10, 26), expectedInterval: 24 * 3600),
    Case(
      name: "New York afternoon", zone: "America/New_York", now: local(2026, 9, 27, 15),
      expectedDay: local(2026, 9, 28), expectedInterval: 9 * 3600),
    Case(
      name: "New York exactly at midnight", zone: "America/New_York", now: local(2026, 9, 28),
      expectedDay: local(2026, 9, 29), expectedInterval: 24 * 3600),
    Case(
      name: "New York the night before spring forward", zone: "America/New_York", now: local(2026, 3, 7, 23, 30),
      expectedDay: local(2026, 3, 8), expectedInterval: 30 * 60),
    Case(
      name: "New York on the 23-hour day", zone: "America/New_York", now: local(2026, 3, 8, 1),
      expectedDay: local(2026, 3, 9), expectedInterval: 22 * 3600),
    Case(
      name: "New York on the 25-hour day", zone: "America/New_York", now: local(2026, 11, 1, 0, 30),
      expectedDay: local(2026, 11, 2), expectedInterval: 24.5 * 3600),
  ]

  @Test(arguments: cases)
  func theNextLocalMidnightIsStrictlyAfterNowAndAtZeroLocal(_ item: Case) throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: item.zone))
    let now = try #require(calendar.date(from: item.now))
    let midnight = ControlMapping.nextLocalMidnight(after: now, calendar: calendar)
    let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: midnight)
    #expect(midnight > now)
    #expect(parts.hour == 0 && parts.minute == 0 && parts.second == 0)
    #expect(parts.year == item.expectedDay.year)
    #expect(parts.month == item.expectedDay.month)
    #expect(parts.day == item.expectedDay.day)
    if let interval = item.expectedInterval {
      #expect(midnight.timeIntervalSince(now) == interval)
    }
  }

  @Test func aSecondBeforeMidnightGivesThatMidnight() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Europe/Madrid"))
    let now = try #require(calendar.date(from: Self.local(2026, 9, 27, 23, 59, 59)))
    #expect(ControlMapping.nextLocalMidnight(after: now, calendar: calendar).timeIntervalSince(now) == 1)
  }
}
