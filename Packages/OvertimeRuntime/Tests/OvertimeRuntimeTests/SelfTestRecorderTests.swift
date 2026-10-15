import Foundation
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing
import os

@testable import OvertimeAppSupport

struct SelfTestRecorderTests {
  static let wall = Date(timeIntervalSince1970: 1_790_505_720)
  static let build = "99Z999"
  static let version = "99.9"
  static let refusal = Int32(bitPattern: 0xE000_02C2)

  final class Records: Sendable {
    private let stored = OSAllocatedUnfairLock<[SelfTestRecord]>(initialState: [])

    var all: [SelfTestRecord] {
      stored.withLock { $0 }
    }

    func append(_ record: SelfTestRecord) {
      stored.withLock { $0.append(record) }
    }

    func wait(seconds: Double = 5, for count: Int) async -> Bool {
      await NotificationPolicyTests.waitFor(seconds: seconds) { self.all.count >= count }
    }
  }

  struct Fixture {
    let temp: TempDirectory
    let file: URL
    let clock = FakeClock(wall: SelfTestRecorderTests.wall)
    let host: ScriptedSnapshotHost
    let log = DecisionRecorder()
    let records = Records()
    let recorder: SelfTestRecorder

    init(preferences: AppPreferences? = nil) throws {
      temp = try TempDirectory()
      file = temp.url.appendingPathComponent("preferences.json")
      if let preferences {
        try AppPreferencesStore.write(preferences, to: file)
      }
      host = ScriptedSnapshotHost(clock: clock)
      let log = log
      let records = records
      recorder = SelfTestRecorder(
        preferencesFile: file, osVersion: { SelfTestRecorderTests.version }, log: { log.record($0) },
        onRecord: { records.append($0) })
    }

    var stored: AppPreferences? {
      guard case .loaded(let preferences) = AppPreferencesStore.read(at: file) else { return nil }
      return preferences
    }

    var logLines: [String] {
      log.decisions.map { NotificationPolicyTests.text($0) }
    }

    func setFolder(mode: Int) throws {
      try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: temp.path)
    }
  }

  static func snapshot(
    _ status: SelfTestStatus, runs: UInt64, failures: UInt64 = 0, lidClosed: Bool? = false, osBuild: String? = build
  ) -> EngineSnapshot {
    EngineSnapshot(
      busy: false, wanted: false, reason: "idle", lidClosed: lidClosed, selfTest: status, selfTestFailures: failures,
      selfTestRuns: runs, osBuild: osBuild)
  }

  static func record(_ outcome: SelfTestOutcome, reason: String? = nil, at: Date = wall) -> SelfTestRecord {
    SelfTestRecord(outcome: outcome, reason: reason, at: at, osBuild: build, osVersion: version)
  }

  @Test func aRunningThenPassedSnapshotWritesOneRecordAndKeepsEveryOtherField() async throws {
    var existing = AppPreferences()
    existing.notifications["batteryFloor"] = false
    existing.forceReminderHours = 7
    existing.onboarding = OnboardingRecord(
      version: 2, outcome: .completed, steps: ["login": "done"], at: Date(timeIntervalSince1970: 1_780_000_000))
    let fixture = try Fixture(preferences: existing)
    defer { fixture.recorder.stop() }
    fixture.recorder.start(host: fixture.host)
    #expect(fixture.recorder.isRunning)
    fixture.host.yield(Self.snapshot(.notRun, runs: 0, osBuild: nil))
    fixture.host.yield(Self.snapshot(.running, runs: 1))
    fixture.host.yield(Self.snapshot(.passed, runs: 1))
    #expect(await fixture.records.wait(for: 1))
    #expect(fixture.records.all == [Self.record(.passed)])
    var expected = existing
    expected.selfTest = Self.record(.passed)
    #expect(fixture.stored == expected)
    #expect(fixture.recorder.lastRecord == Self.record(.passed))
    let attributes = try FileManager.default.attributesOfItem(atPath: fixture.file.path(percentEncoded: false))
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect(fixture.log.decisions.isEmpty)
  }

  struct ReasonCase: Sendable, CustomTestStringConvertible {
    let name: String
    let status: SelfTestStatus
    let outcome: SelfTestOutcome
    let reason: String

    var testDescription: String { name }
  }

  static let reasons: [ReasonCase] = [
    ReasonCase(
      name: "clamshellRefused", status: .failed(.clamshellRefused(refusal)), outcome: .failed,
      reason: "macOS refused the lid-close control (error 0xE00002C2)."),
    ReasonCase(
      name: "assertionRefused", status: .failed(.assertionRefused(refusal)), outcome: .failed,
      reason: "macOS refused the idle-sleep assertion (error 0xE00002C2)."),
    ReasonCase(
      name: "timedOut", status: .failed(.timedOut), outcome: .failed, reason: "macOS didn't answer within 5 seconds."),
    ReasonCase(
      name: "watchdogNotRunning", status: .failed(.watchdogNotRunning), outcome: .failed,
      reason: "Overtime's safety watchdog wasn't running."),
    ReasonCase(
      name: "amphetamine", status: .skipped(.amphetamine), outcome: .skipped,
      reason: "Amphetamine is managing lid-close sleep, so Overtime didn't touch it."),
    ReasonCase(
      name: "otherTool", status: .skipped(.otherTool("Keeper")), outcome: .skipped,
      reason: "Keeper is managing sleep, so Overtime didn't touch it."),
    ReasonCase(
      name: "sleepDisabled", status: .skipped(.sleepDisabled), outcome: .skipped,
      reason: "Sleep is turned off system-wide (SleepDisabled), so Overtime didn't touch the lid-close control."),
  ]

  @Test(arguments: reasons)
  func aFailedOrSkippedRecordCarriesItsReasonText(_ item: ReasonCase) async throws {
    let fixture = try Fixture()
    defer { fixture.recorder.stop() }
    fixture.recorder.start(host: fixture.host)
    let runs: UInt64 = item.outcome == .failed ? 1 : 0
    fixture.host.yield(Self.snapshot(item.status, runs: runs, failures: runs))
    #expect(await fixture.records.wait(for: 1))
    let expected = Self.record(item.outcome, reason: item.reason)
    #expect(fixture.records.all == [expected])
    #expect(fixture.stored?.selfTest == expected)
    #expect(fixture.stored?.notifications == AppPreferences().notifications)
  }

  @Test func repeatedPassedSnapshotsWriteOnceAndASecondRunWritesAgain() async throws {
    let fixture = try Fixture()
    defer { fixture.recorder.stop() }
    fixture.recorder.start(host: fixture.host)
    fixture.host.yield(Self.snapshot(.passed, runs: 1))
    #expect(await fixture.records.wait(for: 1))
    fixture.clock.advance(seconds: 60)
    fixture.host.yield(Self.snapshot(.passed, runs: 1, lidClosed: true))
    fixture.host.yield(Self.snapshot(.waiting, runs: 1, lidClosed: true))
    fixture.host.yield(Self.snapshot(.passed, runs: 1, lidClosed: nil))
    fixture.host.yield(Self.snapshot(.running, runs: 2))
    fixture.host.yield(Self.snapshot(.passed, runs: 2))
    #expect(await fixture.records.wait(for: 2))
    let later = Self.wall.addingTimeInterval(60)
    #expect(fixture.records.all == [Self.record(.passed), Self.record(.passed, at: later)])
    #expect(fixture.stored?.selfTest == Self.record(.passed, at: later))
  }

  @Test func aWriteFailureIsLoggedAndTheNextResultIsStillRecorded() async throws {
    let fixture = try Fixture()
    defer {
      try? fixture.setFolder(mode: 0o700)
      fixture.recorder.stop()
    }
    fixture.recorder.start(host: fixture.host)
    try fixture.setFolder(mode: 0o500)
    fixture.host.yield(Self.snapshot(.failed(.timedOut), runs: 1, failures: 1))
    let log = fixture.log
    let logged = await NotificationPolicyTests.waitFor { log.decisions.count == 1 }
    #expect(logged)
    #expect(fixture.logLines == ["ERROR preferences write failed"])
    #expect(fixture.records.all.isEmpty)
    #expect(fixture.recorder.lastRecord == nil)
    try fixture.setFolder(mode: 0o700)
    #expect(AppPreferencesStore.read(at: fixture.file) == .missing)
    fixture.host.yield(Self.snapshot(.passed, runs: 2, failures: 1))
    #expect(await fixture.records.wait(for: 1))
    #expect(fixture.records.all == [Self.record(.passed)])
    #expect(fixture.stored?.selfTest == Self.record(.passed))
    #expect(fixture.logLines == ["ERROR preferences write failed"])
  }

  @Test func aStartOnANewHostReleasesTheOldStreamAndFollowsTheNewCounters() async throws {
    let fixture = try Fixture()
    defer { fixture.recorder.stop() }
    fixture.recorder.start(host: fixture.host)
    fixture.host.yield(Self.snapshot(.passed, runs: 2))
    #expect(await fixture.records.wait(for: 1))
    let restarted = ScriptedSnapshotHost(clock: fixture.clock)
    fixture.recorder.start(host: restarted)
    let old = fixture.host
    let rebound = await NotificationPolicyTests.waitFor { old.terminated == 1 && restarted.subscriptions == 1 }
    #expect(rebound)
    restarted.yield(Self.snapshot(.failed(.timedOut), runs: 1, failures: 1))
    #expect(await fixture.records.wait(for: 2))
    #expect(fixture.records.all.map(\.outcome) == [.passed, .failed])
    #expect(fixture.recorder.isRunning)
  }

  @Test func stopReleasesTheStreamAndRecordsNothingMore() async throws {
    let fixture = try Fixture()
    fixture.recorder.start(host: fixture.host)
    let host = fixture.host
    let subscribed = await NotificationPolicyTests.waitFor { host.subscriptions == 1 }
    #expect(subscribed)
    fixture.recorder.stop()
    #expect(!fixture.recorder.isRunning)
    let released = await NotificationPolicyTests.waitFor { host.terminated == 1 }
    #expect(released)
    #expect(fixture.records.all.isEmpty)
    #expect(AppPreferencesStore.read(at: fixture.file) == .missing)
  }

  @Test func aResultSeenInTheFirstSnapshotIsRecorded() async throws {
    let fixture = try Fixture()
    defer { fixture.recorder.stop() }
    fixture.host.yield(Self.snapshot(.passed, runs: 1))
    fixture.recorder.start(host: fixture.host)
    #expect(await fixture.records.wait(for: 1))
    #expect(fixture.records.all == [Self.record(.passed)])
  }

  @Test func aResultWithNoBuildInTheSnapshotIsStoredAsUnknown() async throws {
    let fixture = try Fixture()
    defer { fixture.recorder.stop() }
    fixture.recorder.start(host: fixture.host)
    fixture.host.yield(Self.snapshot(.passed, runs: 1, osBuild: nil))
    #expect(await fixture.records.wait(for: 1))
    #expect(fixture.records.all.map(\.osBuild) == ["unknown"])
    #expect(SelfTestRecorder.unknownBuild == "unknown")
  }

  static func results(_ snapshots: [EngineSnapshot]) -> [SelfTestRecording.Result?] {
    var recording = SelfTestRecording()
    return snapshots.map { recording.result(for: $0) }
  }

  @Test func onlyAFinishedRunOrASkipIsAResult() {
    #expect(
      Self.results([
        Self.snapshot(.notRun, runs: 0), Self.snapshot(.waiting, runs: 0), Self.snapshot(.running, runs: 1),
      ]) == [nil, nil, nil])
    #expect(
      Self.results([Self.snapshot(.running, runs: 1), Self.snapshot(.passed, runs: 1)])
        == [nil, SelfTestRecording.Result(outcome: .passed, reason: nil)])
  }

  @Test func aPassedOrFailedResultCountsOncePerRun() {
    let failed = SelfTestRecording.Result(outcome: .failed, reason: "macOS didn't answer within 5 seconds.")
    let passed = SelfTestRecording.Result(outcome: .passed, reason: nil)
    #expect(
      Self.results([
        Self.snapshot(.failed(.timedOut), runs: 1, failures: 1),
        Self.snapshot(.failed(.timedOut), runs: 1, failures: 1, lidClosed: true),
        Self.snapshot(.waiting, runs: 1, failures: 1),
        Self.snapshot(.failed(.timedOut), runs: 1, failures: 1),
        Self.snapshot(.failed(.timedOut), runs: 2, failures: 2),
        Self.snapshot(.passed, runs: 3, failures: 2),
        Self.snapshot(.passed, runs: 4, failures: 2),
        Self.snapshot(.passed, runs: 3, failures: 2),
      ]) == [failed, nil, nil, nil, failed, passed, passed, nil])
  }

  @Test func aSkipCountsOnEachTransitionIntoIt() {
    let disabled = SelfTestRecording.Result(
      outcome: .skipped,
      reason: "Sleep is turned off system-wide (SleepDisabled), so Overtime didn't touch the lid-close control.")
    let keeper = SelfTestRecording.Result(
      outcome: .skipped, reason: "Keeper is managing sleep, so Overtime didn't touch it.")
    #expect(
      Self.results([
        Self.snapshot(.skipped(.sleepDisabled), runs: 0),
        Self.snapshot(.skipped(.sleepDisabled), runs: 0, lidClosed: true),
        Self.snapshot(.waiting, runs: 0),
        Self.snapshot(.skipped(.sleepDisabled), runs: 0),
        Self.snapshot(.skipped(.otherTool("Keeper")), runs: 0),
        Self.snapshot(.passed, runs: 1),
        Self.snapshot(.skipped(.otherTool("Keeper")), runs: 1),
      ]) == [disabled, nil, nil, disabled, keeper, SelfTestRecording.Result(outcome: .passed, reason: nil), keeper])
  }

  @Test func theWriteFailureLineIsPinned() {
    #expect(NotificationPolicyTests.text(SelfTestRecorder.writeFailedDecision) == "ERROR preferences write failed")
  }
}
