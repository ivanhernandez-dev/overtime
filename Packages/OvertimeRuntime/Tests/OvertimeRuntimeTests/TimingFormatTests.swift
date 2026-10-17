import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import Testing

struct TimingFormatTests {
  static let now = Instant(nanoseconds: 1_000_000_000_000_000)
  static let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }()
  static let midnight = utc.date(from: DateComponents(year: 2027, month: 1, day: 15))!
  static let nowWall = midnight.addingTimeInterval(-(6 * 3600 + 12 * 60 + 4))

  @Test(arguments: [
    (0.4, "0:01"), (59.2, "1:00"), (3599.2, "1:00:00"), (3600.0, "1:00:00"), (5025.0, "1:23:45"), (-3.0, "0:00"),
    (0.0, "0:00"), (872.0, "14:32"),
  ])
  func countdownsRoundUp(_ seconds: Double, _ text: String) {
    #expect(TimingFormat.countdown(seconds) == text)
  }

  @Test(arguments: [(59.9, "0:59"), (3600.9, "1:00:00"), (48.0, "0:48"), (5025.7, "1:23:45"), (-1.0, "0:00")])
  func durationsRoundDown(_ seconds: Double, _ text: String) {
    #expect(TimingFormat.duration(seconds) == text)
  }

  @Test func spokenFormsAreRoundedToTheMinute() {
    #expect(TimingFormat.spokenCountdown(872) == "about 14 minutes left")
    #expect(TimingFormat.spokenCountdown(61) == "about 1 minute left")
    #expect(TimingFormat.spokenCountdown(42) == "less than a minute left")
    #expect(TimingFormat.spokenDuration(5025) == "held for 1 hour 23 minutes")
    #expect(TimingFormat.spokenDuration(7200) == "held for 2 hours")
    #expect(TimingFormat.spokenDuration(20) == "held for less than a minute")
  }

  struct LineCase: Sendable, CustomTestStringConvertible {
    let name: String
    let snapshot: EngineSnapshot
    let text: String?

    var testDescription: String { name }
  }

  static func ago(_ seconds: Double) -> Instant { now.adding(seconds: -seconds) }
  static func ahead(_ seconds: Double) -> Instant { now.adding(seconds: seconds) }

  static let lineCases: [LineCase] = [
    LineCase(
      name: "holding",
      snapshot: EngineSnapshot(busy: true, wanted: true, reason: "busy", lidClosed: false, wantedSince: ago(5025)),
      text: "Held for 1:23:45"),
    LineCase(
      name: "lid-closed holding",
      snapshot: EngineSnapshot(busy: true, wanted: true, reason: "busy", lidClosed: true, wantedSince: ago(5025)),
      text: "Held for 1:23:45"),
    LineCase(
      name: "grace",
      snapshot: EngineSnapshot(
        busy: false, wanted: true, reason: "busy", wantedSince: ago(5025), graceDeadline: ahead(42)),
      text: "Releasing in 0:42 · held for 1:23:45"),
    LineCase(
      name: "paused timed",
      snapshot: EngineSnapshot(
        wanted: false, reason: "paused", pause: .untilMono(ahead(872), wall: nowWall.addingTimeInterval(872))),
      text: "Resumes in 14:32"),
    LineCase(
      name: "paused until tomorrow",
      snapshot: EngineSnapshot(wanted: false, reason: "paused", pause: .untilWall(midnight)),
      text: "Resumes at midnight (6:12:04)"),
    LineCase(
      name: "paused until resumed",
      snapshot: EngineSnapshot(wanted: false, reason: "paused", pause: .indefinite),
      text: "Paused until you resume"),
    LineCase(
      name: "release until idle",
      snapshot: EngineSnapshot(busy: true, wanted: false, reason: "override", releaseUntilIdle: true),
      text: "Resumes when Claude goes idle"),
    LineCase(
      name: "override timed",
      snapshot: EngineSnapshot(
        wanted: true, reason: "forced", force: .untilMono(ahead(7152)), wantedSince: ago(48)),
      text: "Stops in 1:59:12 · held for 0:48"),
    LineCase(
      name: "override until stopped",
      snapshot: EngineSnapshot(wanted: true, reason: "forced", force: .indefinite, wantedSince: ago(48)),
      text: "Until you stop it · held for 0:48"),
    LineCase(
      name: "battery floor",
      snapshot: EngineSnapshot(
        wanted: false, reason: "battery", batteryBlocked: true, batteryLowPercent: 10, batteryResumePercent: 20),
      text: "Resumes on power or at 20%"),
    LineCase(name: "idle", snapshot: EngineSnapshot(busy: false, wanted: false, reason: "idle"), text: nil),
    LineCase(
      name: "error", snapshot: EngineSnapshot(busy: true, wanted: true, reason: "busy", holdError: true), text: nil),
  ]

  @Test(arguments: lineCases) func eachStateHasItsUISpecTimingLine(_ testCase: LineCase) {
    #expect(line(testCase.snapshot)?.text == testCase.text)
  }

  @Test func theResumePercentComesFromTheSnapshot() {
    let snapshot = EngineSnapshot(
      wanted: false, reason: "battery", batteryBlocked: true, batteryLowPercent: 15, batteryResumePercent: 35)
    #expect(line(snapshot)?.text == "Resumes on power or at 35%")
  }

  @Test func theHotTimingLineNamesTheResumeTemperature() {
    let snapshot = EngineSnapshot(
      busy: true, wanted: false, reason: "temperature", temperatureBlocked: true, temperatureReleaseCelsius: 45,
      temperatureResumeCelsius: 40)
    let kind = StatusPresentation.timingKind(state: .batteryFloor, snapshot: snapshot)
    #expect(kind == .batteryHot(resumeCelsius: 40))
    let lead = parts(snapshot)?.lead
    #expect(lead == TimingLine(text: "Resumes below 40°C", spoken: "resumes below 40 degrees Celsius"))
    #expect(line(snapshot)?.text == "Resumes below 40°C")
  }

  @Test func aWallPauseThatIsNotMidnightCountsDown() {
    let snapshot = EngineSnapshot(
      wanted: false, reason: "paused", pause: .untilWall(Self.nowWall.addingTimeInterval(90)))
    #expect(line(snapshot)?.text == "Resumes in 1:30")
  }

  @Test func aCountdownInThePastShowsZero() {
    let snapshot = EngineSnapshot(
      wanted: false, reason: "paused", pause: .untilMono(Self.ago(5), wall: Self.nowWall.addingTimeInterval(-5)))
    #expect(line(snapshot)?.text == "Resumes in 0:00")
  }

  @Test func theSpokenFormsAreRoundedToTheMinute() {
    let grace = EngineSnapshot(
      busy: false, wanted: true, reason: "busy", wantedSince: Self.ago(5025), graceDeadline: Self.ahead(872))
    #expect(line(grace)?.spoken == "releasing in about 14 minutes, held for 1 hour 23 minutes")
    let midnight = EngineSnapshot(wanted: false, reason: "paused", pause: .untilWall(Self.midnight))
    #expect(line(midnight)?.spoken == "resumes at midnight, about 6 hours 12 minutes left")
    let held = EngineSnapshot(busy: true, wanted: true, reason: "busy", wantedSince: Self.ago(5025))
    #expect(line(held)?.spoken == "held for 1 hour 23 minutes")
  }

  @Test func holdingWithoutAStartHasNoLine() {
    #expect(line(EngineSnapshot(busy: true, wanted: true, reason: "busy")) == nil)
  }

  @Test func theTimingPartsSplitTheLeadFromTheHeldDuration() {
    let held = TimingLine(text: "1:23:45", spoken: "held for 1 hour 23 minutes")
    let holding = EngineSnapshot(
      busy: true, wanted: true, reason: "busy", lidClosed: false, wantedSince: Self.ago(5025))
    #expect(parts(holding) == TimingParts(lead: nil, held: held))
    let grace = EngineSnapshot(
      busy: false, wanted: true, reason: "busy", wantedSince: Self.ago(5025), graceDeadline: Self.ahead(42))
    let releasing = TimingLine(text: "Releasing in 0:42", spoken: "releasing in less than a minute")
    #expect(parts(grace) == TimingParts(lead: releasing, held: held))
    let paused = EngineSnapshot(
      wanted: false, reason: "paused", pause: .untilMono(Self.ahead(872), wall: Self.nowWall.addingTimeInterval(872)))
    let resumes = TimingLine(text: "Resumes in 14:32", spoken: "resumes in about 14 minutes")
    #expect(parts(paused) == TimingParts(lead: resumes, held: nil))
    let bareGrace = EngineSnapshot(busy: false, wanted: true, reason: "busy")
    #expect(
      StatusPresentation.derive(snapshot: bareGrace, hostFailure: nil, engineUnresponsive: false).state == .grace)
    #expect(parts(bareGrace) == TimingParts(lead: nil, held: nil))
    #expect(parts(EngineSnapshot(busy: false, wanted: false, reason: "idle")) == nil)
  }

  private func parts(_ snapshot: EngineSnapshot) -> TimingParts? {
    let presentation = StatusPresentation.derive(snapshot: snapshot, hostFailure: nil, engineUnresponsive: false)
    return TimingLine.parts(
      for: presentation, snapshot: snapshot, nowMono: Self.now, nowWall: Self.nowWall, calendar: Self.utc)
  }

  private func line(_ snapshot: EngineSnapshot) -> TimingLine? {
    let presentation = StatusPresentation.derive(snapshot: snapshot, hostFailure: nil, engineUnresponsive: false)
    return TimingLine.line(
      for: presentation, snapshot: snapshot, nowMono: Self.now, nowWall: Self.nowWall, calendar: Self.utc)
  }
}
