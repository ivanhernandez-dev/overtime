import Foundation
import OvertimeAppSupport
import Testing

struct UIDateTextTests {
  static let date = Date(timeIntervalSince1970: 1_773_666_300)
  static let gmt = TimeZone(secondsFromGMT: 0)!

  static func text(_ identifier: String, timeZone: TimeZone = gmt) -> String {
    UIDateText.string(date, locale: Locale(identifier: identifier), timeZone: timeZone)
  }

  static func hasNonEnglishLetter(_ text: String) -> Bool {
    let letters: Set<Unicode.GeneralCategory> = [.uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .otherLetter]
    return text.unicodeScalars.contains { !$0.isASCII && letters.contains($0.properties.generalCategory) }
  }

  static func offset(of needle: String, in text: String) -> Int? {
    text.range(of: needle).map { text.distance(from: text.startIndex, to: $0.lowerBound) }
  }

  @Test(arguments: ["es_ES", "de_DE", "fr_FR", "ja_JP"])
  func theMonthIsEnglishUnderEveryNonEnglishLocale(_ identifier: String) {
    let text = Self.text(identifier)
    #expect(text.contains("Mar"), "\(identifier): \(text)")
  }

  @Test(arguments: ["es_ES", "de_DE", "fr_FR", "ja_JP", "ar_SA", "ru_RU", "zh_CN", "he_IL"])
  func noLocaleYieldsANonEnglishLetter(_ identifier: String) {
    let text = Self.text(identifier)
    #expect(!Self.hasNonEnglishLetter(text), "\(identifier): \(text)")
  }

  @Test func theRegionKeepsItsDateOrder() throws {
    let spanish = Self.text("es_ES")
    let spanishDay = try #require(Self.offset(of: "16", in: spanish), "\(spanish)")
    let spanishMonth = try #require(Self.offset(of: "Mar", in: spanish), "\(spanish)")
    #expect(spanishDay < spanishMonth, "\(spanish)")
    let american = Self.text("en_US")
    let americanDay = try #require(Self.offset(of: "16", in: american), "\(american)")
    let americanMonth = try #require(Self.offset(of: "Mar", in: american), "\(american)")
    #expect(americanMonth < americanDay, "\(american)")
  }

  @Test func anEnglishUserSeesTheSameTextAsBefore() {
    let before = Self.date.formatted(
      Date.FormatStyle(date: .abbreviated, time: .shortened, locale: Locale(identifier: "en_US"), timeZone: Self.gmt))
    #expect(Self.text("en_US") == before)
  }

  @Test func theHourCycleIsKept() {
    let twentyFour = Self.text("en_US@hours=h23")
    #expect(!twentyFour.contains("AM") && !twentyFour.contains("PM"), "\(twentyFour)")
    let twelve = Self.text("es_ES@hours=h12")
    #expect(twelve.contains("PM"), "\(twelve)")
  }

  @Test func theTimeZoneIsKept() throws {
    let madrid = try #require(TimeZone(identifier: "Europe/Madrid"))
    let newYork = try #require(TimeZone(identifier: "America/New_York"))
    #expect(Self.text("es_ES", timeZone: madrid).contains("14:05"))
    #expect(Self.text("es_ES", timeZone: newYork).contains("9:05"))
  }

  static func expectKept(_ locale: Locale) {
    let english = UIDateText.englishLocale(keeping: locale)
    #expect(english.language.languageCode == .english, "\(english.identifier)")
    #expect(english.region == locale.region, "\(english.identifier)")
    #expect(english.hourCycle == locale.hourCycle, "\(english.identifier)")
    #expect(english.calendar.identifier == locale.calendar.identifier, "\(english.identifier)")
  }

  @Test(arguments: ["es_ES", "es_ES@hours=h12", "ar_SA", "de_DE@calendar=japanese"])
  func theEnglishLocaleKeepsRegionHourCycleAndCalendar(_ identifier: String) {
    Self.expectKept(Locale(identifier: identifier))
  }

  @Test func theEnglishLocaleKeepsTheCurrentRegionHourCycleAndCalendar() {
    Self.expectKept(Locale.autoupdatingCurrent)
  }

  @Test func theSelfTestCaptionUsesTheHelper() {
    let spanish = Locale(identifier: "es_ES")
    let record = SelfTestRecord(outcome: .passed, reason: nil, at: Self.date, osBuild: "26A428", osVersion: "27.0")
    let line = SelfTestPresentation.lastRun(record, locale: spanish, timeZone: Self.gmt)
    let date = UIDateText.string(Self.date, locale: spanish, timeZone: Self.gmt)
    #expect(line == "Last run " + date + " on macOS 27.0 (26A428).")
    #expect(line.contains("Mar"), "\(line)")
  }
}
