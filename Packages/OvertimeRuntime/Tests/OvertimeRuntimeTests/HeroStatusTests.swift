import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import Testing

struct HeroStatusTests {
  static let states: [PanelState] = [
    .starting, .idle, .holding, .lidClosedHolding, .grace, .paused, .releasedUntilIdle, .batteryFloor, .override,
    .uninstalling, .error(.holdFailed), .error(.selfTestFailed), .error(.notResponding), .error(.couldNotStart),
    .error(.watchdogUnavailable), .error(.storageUnavailable),
  ]
  static let litStates: [PanelState] = [.holding, .lidClosedHolding, .override]

  struct Expected: Sendable {
    let figure: String?
    let note: String?
  }

  static let expected: [String: Expected] = [
    "holding": Expected(figure: "1:23:45", note: nil),
    "lid-closed holding": Expected(figure: "1:23:45", note: nil),
    "grace": Expected(figure: "1:23:45", note: "Releasing in 0:42"),
    "paused timed": Expected(figure: nil, note: "Resumes in 14:32"),
    "paused until tomorrow": Expected(figure: nil, note: "Resumes at midnight (6:12:04)"),
    "paused until resumed": Expected(figure: nil, note: "Paused until you resume"),
    "release until idle": Expected(figure: nil, note: "Resumes when Claude goes idle"),
    "override timed": Expected(figure: "0:48", note: "Stops in 1:59:12"),
    "override until stopped": Expected(figure: "0:48", note: "Until you stop it"),
    "battery floor": Expected(figure: nil, note: "Resumes on power or at 20%"),
    "idle": Expected(figure: nil, note: nil),
    "error": Expected(figure: nil, note: nil),
  ]

  static func presentation(_ snapshot: EngineSnapshot) -> StatusPresentation {
    StatusPresentation.derive(snapshot: snapshot, hostFailure: nil, engineUnresponsive: false)
  }

  static func awakeTime(_ snapshot: EngineSnapshot) -> AwakeTime {
    AwakeTime.make(
      for: presentation(snapshot), snapshot: snapshot, nowMono: TimingFormatTests.now,
      nowWall: TimingFormatTests.nowWall, calendar: TimingFormatTests.utc)
  }

  static func line(_ snapshot: EngineSnapshot) -> TimingLine? {
    TimingLine.line(
      for: presentation(snapshot), snapshot: snapshot, nowMono: TimingFormatTests.now,
      nowWall: TimingFormatTests.nowWall, calendar: TimingFormatTests.utc)
  }

  @Test func onlyTheThreeKeepingAwakeStatesLight() {
    #expect(Self.states.count == 16)
    for state in Self.states {
      #expect(HeroStatus.isLit(state) == Self.litStates.contains(state), "\(state)")
    }
    #expect(Self.states.filter(HeroStatus.isLit) == Self.litStates)
  }

  @Test(arguments: TimingFormatTests.lineCases)
  func theAwakeTimeShowsTheHeldDurationAndTheLeadAsANote(_ testCase: TimingFormatTests.LineCase) throws {
    #expect(Set(Self.expected.keys) == Set(TimingFormatTests.lineCases.map(\.name)))
    let expected = try #require(Self.expected[testCase.name], "no expectation for \(testCase.name)")
    let time = Self.awakeTime(testCase.snapshot)
    if let figure = expected.figure {
      #expect(time.figure == figure)
      #expect(!time.isPlaceholder)
    } else {
      #expect(time.figure == AwakeTime.placeholder)
      #expect(time.isPlaceholder)
    }
    #expect(time.note == expected.note)
  }

  @Test(arguments: TimingFormatTests.lineCases)
  func theAwakeTimeRebuildsEveryTimingLine(_ testCase: TimingFormatTests.LineCase) {
    let line = Self.line(testCase.snapshot)
    let time = Self.awakeTime(testCase.snapshot)
    #expect(time.spoken == (line?.spoken ?? ""))
    if time.isPlaceholder {
      #expect(time.figure == AwakeTime.placeholder)
      #expect(time.note == line?.text)
    } else {
      let rebuilt = time.note.map { "\($0) · held for \(time.figure)" } ?? "Held for \(time.figure)"
      #expect(rebuilt == line?.text)
    }
  }

  @Test func holdingWithoutAStartShowsTheDash() {
    let snapshot = EngineSnapshot(busy: true, wanted: true, reason: "busy")
    #expect(Self.presentation(snapshot).state == .holding)
    let time = Self.awakeTime(snapshot)
    #expect(time == AwakeTime(figure: AwakeTime.placeholder, isPlaceholder: true, note: nil, spoken: ""))
    #expect(AwakeTime.placeholder == "—")
    #expect(AwakeTime.unit == "awake")
  }
}
