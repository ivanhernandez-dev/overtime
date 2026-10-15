import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import Testing

struct LidClosedJournalTests {
  static func snapshot(
    lid: Bool? = true, hold: UInt64 = 0, stuck: UInt64 = 0, battery: UInt64 = 0, sleeps: UInt64 = 0,
    floor: Int = 10, busy: Bool? = false
  ) -> EngineSnapshot {
    EngineSnapshot(
      busy: busy, lidClosed: lid, batteryLowPercent: floor,
      events: EventCounters(
        holdErrorEpisodes: hold, batteryReleases: battery, stuckReleases: stuck, unexpectedSleeps: sleeps))
  }

  @Test func eventsKeepTheOrderObserved() {
    var journal = LidClosedJournal.start(baseline: EventCounters())
    journal.append(from: Self.snapshot(stuck: 1))
    journal.append(from: Self.snapshot(stuck: 1, battery: 1, floor: 15))
    journal.append(from: Self.snapshot(stuck: 1, battery: 1, sleeps: 1, floor: 15))
    journal.append(from: Self.snapshot(hold: 1, stuck: 1, battery: 1, sleeps: 1, floor: 15))
    #expect(
      journal.lines() == [
        "A Claude session looked stuck, so Overtime stopped counting it.",
        "Battery reached 15%, so Overtime let the Mac sleep.",
        "The Mac slept while Claude was working.",
        "Keep-awake failed and was retried.",
      ])
  }

  @Test func holdErrorsMergeIntoOneLineAtTheirFirstPosition() {
    var journal = LidClosedJournal.start(baseline: EventCounters(holdErrorEpisodes: 4))
    journal.append(from: Self.snapshot(hold: 5))
    #expect(journal.lines() == ["Keep-awake failed and was retried."])
    journal.append(from: Self.snapshot(hold: 5, stuck: 1))
    journal.append(from: Self.snapshot(hold: 7, stuck: 1))
    #expect(
      journal.lines() == [
        "Keep-awake failed 3 times and was retried.",
        "A Claude session looked stuck, so Overtime stopped counting it.",
      ])
    #expect(journal.events == [.holdError(count: 3), .stuckRelease])
  }

  @Test func theBaselineAndALowerReplayAddNothing() {
    let baseline = EventCounters(
      holdErrorEpisodes: 2, batteryReleases: 3, stuckReleases: 4, unexpectedSleeps: 5)
    var journal = LidClosedJournal.start(baseline: baseline)
    journal.append(from: Self.snapshot(hold: 2, stuck: 4, battery: 3, sleeps: 5))
    journal.append(from: Self.snapshot(hold: 1, stuck: 0, battery: 0, sleeps: 0))
    #expect(journal.isEmpty)
    #expect(journal.lines().isEmpty)
    #expect(journal.summary() == nil)
  }

  @Test func aSentinelClearIsRecordedLikeAnyOtherEvent() {
    var journal = LidClosedJournal.start(baseline: EventCounters())
    journal.record(.sentinelClear)
    journal.append(from: Self.snapshot(sleeps: 1))
    #expect(
      journal.lines() == [
        "Overtime stopped unexpectedly. Its watchdog restored normal sleep.",
        "The Mac slept while Claude was working.",
      ])
  }

  @Test func theSummaryShowsThreeLinesAndCountsTheRest() throws {
    var journal = LidClosedJournal.start(baseline: EventCounters())
    journal.append(from: Self.snapshot(stuck: 1))
    journal.append(from: Self.snapshot(stuck: 1, battery: 1))
    journal.append(from: Self.snapshot(hold: 1, stuck: 1, battery: 1))
    #expect(journal.summary()?.body.components(separatedBy: "\n").count == 3)
    journal.append(from: Self.snapshot(hold: 1, stuck: 1, battery: 1, sleeps: 1))
    journal.append(from: Self.snapshot(hold: 1, stuck: 2, battery: 1, sleeps: 1))
    let summary = try #require(journal.summary())
    #expect(summary.category == .lidClosedSummary)
    #expect(summary.title == "While the lid was closed")
    #expect(summary.sound == false)
    #expect(summary.turnOffAction == false)
    #expect(
      summary.body.components(separatedBy: "\n") == [
        "A Claude session looked stuck, so Overtime stopped counting it.",
        "Battery reached 10%, so Overtime let the Mac sleep.",
        "Keep-awake failed and was retried.",
        "And 2 more. Details are in the log.",
      ])
  }

  @Test func theJournalIsBoundedAndCountsWhatItDropped() throws {
    var journal = LidClosedJournal.start(baseline: EventCounters())
    journal.append(from: Self.snapshot(stuck: 40))
    journal.append(from: Self.snapshot(hold: UInt64.max, stuck: 40))
    #expect(journal.events.count == LidClosedJournal.maxEvents)
    #expect(journal.omitted == 9)
    let body = try #require(journal.summary()?.body)
    #expect(body.components(separatedBy: "\n").last == "And 38 more. Details are in the log.")
    journal.record(.holdError(count: Int.max), times: UInt64.max)
    #expect(journal.omitted == 10)
  }

  @Test func theJournalTypesHaveNoFileAPI() throws {
    let sources = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Sources/OvertimeAppSupport")
    let journal = try String(
      contentsOf: sources.appendingPathComponent("LidClosedJournal.swift"), encoding: .utf8)
    let policy = try String(
      contentsOf: sources.appendingPathComponent("NotificationPolicy.swift"), encoding: .utf8)
    for text in [journal, policy] {
      for token in [
        "FileManager", "URL", "Data(", "write(", "open(", "fopen", "Codable", "Encodable", "Decodable", "UserDefaults",
        "PrivateFile",
      ] {
        #expect(!text.contains(token), "found \(token)")
      }
    }
  }
}
