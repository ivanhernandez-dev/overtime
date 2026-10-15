import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import Testing

struct SelfTestPresentationTests {
  static let ranAt = Date(timeIntervalSince1970: 1_790_505_720)
  static let record = SelfTestRecord(outcome: .passed, reason: nil, at: ranAt, osBuild: "26A428", osVersion: "27.0")

  static var lastRunLine: String {
    "Last run \(UIDateText.string(ranAt)) on macOS 27.0 (26A428)."
  }

  @Test func withNoResultTheRowReadsNotRunYet() {
    let row = SelfTestPresentation.row(status: .notRun, record: nil, currentBuild: nil)
    #expect(row.icon == .symbol("circle"))
    #expect(row.tone == .secondary)
    #expect(row.title == "Not run yet")
    #expect(row.caption == "It runs at launch once the lid is open and Claude isn't working.")
  }

  @Test func aWaitingTestShowsTheClockAndWhenItRuns() {
    let row = SelfTestPresentation.row(status: .waiting, record: nil, currentBuild: "26A428")
    #expect(row.icon == .symbol("clock"))
    #expect(row.tone == .secondary)
    #expect(row.title == "Waiting to run")
    #expect(row.caption == "It runs when the lid is open and Claude isn't working.")
  }

  @Test func aRunningTestShowsProgressAndNoCaption() {
    let row = SelfTestPresentation.row(status: .running, record: Self.record, currentBuild: "26A428")
    #expect(row.icon == .progress)
    #expect(row.title == "Running…")
    #expect(row.caption == nil)
  }

  @Test func aPassedTestShowsTheGreenRowWithTheLastRunLine() {
    let row = SelfTestPresentation.row(status: .passed, record: Self.record, currentBuild: "26A428")
    #expect(row.icon == .symbol("checkmark.circle.fill"))
    #expect(row.tone == .success)
    #expect(row.title == "Passed")
    #expect(row.caption == Self.lastRunLine)
  }

  @Test func aPassedTestWithNoStoredRecordShowsNoCaption() {
    let row = SelfTestPresentation.row(status: .passed, record: nil, currentBuild: "26A428")
    #expect(row.title == "Passed")
    #expect(row.caption == nil)
  }

  @Test func theLastRunLineUsesTheAbbreviatedDateAndShortTime() {
    let line = SelfTestPresentation.lastRun(Self.record)
    #expect(line == Self.lastRunLine)
    #expect(line.hasPrefix("Last run "))
    #expect(line.hasSuffix(" on macOS 27.0 (26A428)."))
  }

  struct ReasonCase: Sendable, CustomTestStringConvertible {
    let name: String
    let status: SelfTestStatus
    let reason: String

    var testDescription: String { name }
  }

  static let refusal = Int32(bitPattern: 0xE000_02C2)

  static let failures: [ReasonCase] = [
    ReasonCase(
      name: "clamshellRefused", status: .failed(.clamshellRefused(refusal)),
      reason: "macOS refused the lid-close control (error 0xE00002C2)."),
    ReasonCase(
      name: "assertionRefused", status: .failed(.assertionRefused(refusal)),
      reason: "macOS refused the idle-sleep assertion (error 0xE00002C2)."),
    ReasonCase(name: "timedOut", status: .failed(.timedOut), reason: "macOS didn't answer within 5 seconds."),
    ReasonCase(
      name: "watchdogNotRunning", status: .failed(.watchdogNotRunning),
      reason: "Overtime's safety watchdog wasn't running."),
    ReasonCase(
      name: "stateNotSaved", status: .failed(.stateNotSaved),
      reason: "Overtime couldn't save its own state, so it didn't touch the lid-close control."),
    ReasonCase(
      name: "a small code is zero-padded", status: .failed(.assertionRefused(5)),
      reason: "macOS refused the idle-sleep assertion (error 0x00000005)."),
  ]

  static let skips: [ReasonCase] = [
    ReasonCase(
      name: "amphetamine", status: .skipped(.amphetamine),
      reason: "Amphetamine is managing lid-close sleep, so Overtime didn't touch it."),
    ReasonCase(
      name: "otherTool", status: .skipped(.otherTool("Keeper")),
      reason: "Keeper is managing sleep, so Overtime didn't touch it."),
    ReasonCase(
      name: "sleepDisabled", status: .skipped(.sleepDisabled),
      reason:
        "Sleep is turned off system-wide (SleepDisabled), so Overtime didn't touch the lid-close control."),
  ]

  @Test(arguments: failures)
  func aFailedRowShowsItsReasonThenTheLastRunLine(_ item: ReasonCase) {
    let row = SelfTestPresentation.row(status: item.status, record: Self.record, currentBuild: "26A428")
    #expect(row.icon == .symbol("xmark.circle.fill"))
    #expect(row.tone == .error)
    #expect(row.title == "Failed")
    #expect(row.caption == item.reason + "\n" + Self.lastRunLine)
    let unrecorded = SelfTestPresentation.row(status: item.status, record: nil, currentBuild: nil)
    #expect(unrecorded.title == "Failed")
    #expect(unrecorded.caption == item.reason)
  }

  @Test(arguments: skips)
  func aSkippedRowShowsItsReasonThenTheLastRunLine(_ item: ReasonCase) {
    let row = SelfTestPresentation.row(status: item.status, record: Self.record, currentBuild: "26A428")
    #expect(row.icon == .symbol("minus.circle.fill"))
    #expect(row.tone == .warning)
    #expect(row.title == "Skipped")
    #expect(row.caption == item.reason + "\n" + Self.lastRunLine)
    let unrecorded = SelfTestPresentation.row(status: item.status, record: nil, currentBuild: nil)
    #expect(unrecorded.title == "Skipped")
    #expect(unrecorded.caption == item.reason)
  }

  @Test func aWaitingTestAfterABuildChangeNamesTheNewBuild() {
    let row = SelfTestPresentation.row(status: .waiting, record: Self.record, currentBuild: "26A430")
    #expect(row.icon == .symbol("clock"))
    #expect(row.tone == .secondary)
    #expect(row.title == "Waiting to run")
    #expect(
      row.caption == "macOS changed to 26A430. The test runs again when the lid is open and Claude isn't working.")
    #expect(
      SelfTestPresentation.buildChangedCaption("26A430")
        == "macOS changed to 26A430. The test runs again when the lid is open and Claude isn't working.")
  }

  @Test(arguments: [
    (SelfTestRecord?.some(record), String?.some("26A428")),
    (.some(record), nil),
    (nil, .some("26A430")),
    (
      .some(SelfTestRecord(outcome: .passed, reason: nil, at: ranAt, osBuild: "unknown", osVersion: "27.0")),
      .some("26A430")
    ),
  ])
  func aWaitingTestWithNoKnownBuildChangeKeepsThePlainCaption(_ record: SelfTestRecord?, _ build: String?) {
    let row = SelfTestPresentation.row(status: .waiting, record: record, currentBuild: build)
    #expect(row.title == "Waiting to run")
    #expect(row.caption == "It runs when the lid is open and Claude isn't working.")
  }

  struct StoredCase: Sendable, CustomTestStringConvertible {
    let name: String
    let record: SelfTestRecord
    let row: SelfTestRow

    var testDescription: String { name }
  }

  static func stored(_ outcome: SelfTestOutcome, reason: String?) -> SelfTestRecord {
    SelfTestRecord(outcome: outcome, reason: reason, at: ranAt, osBuild: "26A428", osVersion: "27.0")
  }

  static var storedRows: [StoredCase] {
    [
      StoredCase(
        name: "passed", record: stored(.passed, reason: nil),
        row: SelfTestRow(icon: .symbol("checkmark.circle.fill"), tone: .success, title: "Passed", caption: lastRunLine)
      ),
      StoredCase(
        name: "failed", record: stored(.failed, reason: "macOS didn't answer within 5 seconds."),
        row: SelfTestRow(
          icon: .symbol("xmark.circle.fill"), tone: .error, title: "Failed",
          caption: "macOS didn't answer within 5 seconds.\n" + lastRunLine)),
      StoredCase(
        name: "skipped", record: stored(.skipped, reason: "Keeper is managing sleep, so Overtime didn't touch it."),
        row: SelfTestRow(
          icon: .symbol("minus.circle.fill"), tone: .warning, title: "Skipped",
          caption: "Keeper is managing sleep, so Overtime didn't touch it.\n" + lastRunLine)),
      StoredCase(
        name: "failed with no stored reason", record: stored(.failed, reason: nil),
        row: SelfTestRow(icon: .symbol("xmark.circle.fill"), tone: .error, title: "Failed", caption: lastRunLine)),
    ]
  }

  @Test(arguments: storedRows)
  func beforeThisLaunchsTestTheRowShowsTheStoredResult(_ item: StoredCase) {
    #expect(SelfTestPresentation.row(status: .notRun, record: item.record, currentBuild: nil) == item.row)
    #expect(SelfTestPresentation.row(for: item.record) == item.row)
    #expect(
      SelfTestPresentation.row(status: .running, record: item.record, currentBuild: nil)
        == SelfTestRow(icon: .progress, tone: .secondary, title: "Running…"))
  }

  struct ButtonCase: Sendable, CustomTestStringConvertible {
    let name: String
    let snapshot: EngineSnapshot?
    let enabled: Bool
    let reason: String?

    var testDescription: String { name }
  }

  static let whileRunning = "Available when the current test finishes."
  static let whileKeepingAwake = "Available when Overtime isn't keeping the Mac awake."
  static let whileLidClosed = "Available when the lid is open."

  static func idle(
    wanted: Bool? = false, lidClosed: Bool? = false, status: SelfTestStatus = .notRun, busy: Bool? = false
  ) -> EngineSnapshot {
    EngineSnapshot(
      busy: busy, wanted: wanted, reason: wanted == true ? "busy" : "idle", lidClosed: lidClosed, selfTest: status)
  }

  static let buttons: [ButtonCase] = [
    ButtonCase(
      name: "no snapshot yet", snapshot: nil, enabled: false, reason: SelfTestPresentation.runUnavailableHelp),
    ButtonCase(name: "idle with the lid open", snapshot: idle(), enabled: true, reason: nil),
    ButtonCase(
      name: "keeping awake", snapshot: idle(wanted: true, busy: true), enabled: false, reason: whileKeepingAwake),
    ButtonCase(name: "in the grace window", snapshot: idle(wanted: true), enabled: false, reason: whileKeepingAwake),
    ButtonCase(name: "lid closed", snapshot: idle(lidClosed: true), enabled: false, reason: whileLidClosed),
    ButtonCase(name: "lid unknown", snapshot: idle(lidClosed: nil), enabled: false, reason: whileLidClosed),
    ButtonCase(name: "running", snapshot: idle(status: .running), enabled: false, reason: whileRunning),
    ButtonCase(
      name: "running with the lid closed", snapshot: idle(lidClosed: true, status: .running), enabled: false,
      reason: whileRunning),
    ButtonCase(
      name: "keeping awake with the lid closed", snapshot: idle(wanted: true, lidClosed: true), enabled: false,
      reason: whileKeepingAwake),
    ButtonCase(name: "keep-awake not decided yet", snapshot: idle(wanted: nil), enabled: true, reason: nil),
    ButtonCase(name: "waiting with the lid open", snapshot: idle(status: .waiting), enabled: true, reason: nil),
    ButtonCase(name: "passed", snapshot: idle(status: .passed), enabled: true, reason: nil),
    ButtonCase(name: "failed", snapshot: idle(status: .failed(.timedOut)), enabled: true, reason: nil),
    ButtonCase(name: "skipped", snapshot: idle(status: .skipped(.sleepDisabled)), enabled: true, reason: nil),
    ButtonCase(name: "busy but paused", snapshot: idle(busy: true), enabled: true, reason: nil),
  ]

  @Test(arguments: buttons)
  func theRunButtonIsOnOnlyWhenTheTestCouldRunNow(_ item: ButtonCase) {
    #expect(SelfTestPresentation.runButtonEnabled(snapshot: item.snapshot) == item.enabled)
  }

  @Test(arguments: buttons)
  func aDisabledRunButtonSaysWhyAndAnEnabledOneSaysNothing(_ item: ButtonCase) {
    #expect(SelfTestPresentation.runUnavailableReason(snapshot: item.snapshot) == item.reason)
    #expect((item.reason == nil) == item.enabled)
  }

  @Test func theRunButtonHelpMatchesTheUISpec() {
    #expect(SelfTestPresentation.runUnavailableHelp == "Available when the lid is open and Claude isn't working.")
  }

  @Test func theDisabledReasonsAreTheUISpecSentences() {
    #expect(SelfTestPresentation.runUnavailableWhileRunning == Self.whileRunning)
    #expect(SelfTestPresentation.runUnavailableWhileKeepingAwake == Self.whileKeepingAwake)
    #expect(SelfTestPresentation.runUnavailableWhileLidClosed == Self.whileLidClosed)
    let reasons = [
      SelfTestPresentation.runUnavailableWhileRunning, SelfTestPresentation.runUnavailableWhileKeepingAwake,
      SelfTestPresentation.runUnavailableWhileLidClosed,
    ]
    for reason in reasons {
      #expect(reason.hasPrefix("Available when "))
      #expect(reason.hasSuffix("."))
    }
  }

  @Test(arguments: [
    (SelfTestStatus.passed, String?.some("Self-test passed.")),
    (.failed(.timedOut), .some("Self-test failed")),
    (.failed(.clamshellRefused(-3)), .some("Self-test failed")),
    (.skipped(.sleepDisabled), .some("Self-test skipped.")),
    (.notRun, nil), (.waiting, nil), (.running, nil),
  ])
  func aFinishedTestIsAnnouncedAndAnUnfinishedOneIsNot(_ status: SelfTestStatus, _ text: String?) {
    #expect(SelfTestPresentation.announcement(for: status) == text)
  }

  @Test func theTimeoutSentenceNamesTheSystemCallBound() {
    #expect(Timing.systemCallTimeoutSeconds == 5)
  }

  @Test func theSectionCopyMatchesTheUISpec() {
    #expect(SelfTestPresentation.sectionTitle == "Self-test")
    #expect(SelfTestPresentation.runButtonTitle == "Run Self-Test")
  }
}
