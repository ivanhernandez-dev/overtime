import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import Testing

struct NetworkJournalTests {
  static let switchLine = "Overtime switched the Mac to your iPhone hotspot to stay online."
  static let oneCycleLine = "Overtime restarted the wireless connection to get back online."

  static func snapshot(
    switches: UInt64 = 0, cycles: UInt64 = 0, hold: UInt64 = 0, stuck: UInt64 = 0, sleeps: UInt64 = 0
  ) -> EngineSnapshot {
    EngineSnapshot(
      lidClosed: true,
      events: EventCounters(
        holdErrorEpisodes: hold, stuckReleases: stuck, unexpectedSleeps: sleeps, hotspotSwitches: switches,
        wifiCycles: cycles))
  }

  @Test func aSwitchIsRecordedOnce() {
    var journal = LidClosedJournal.start(baseline: EventCounters())
    journal.append(from: Self.snapshot(switches: 1))
    #expect(journal.events == [.hotspotSwitch])
    #expect(journal.lines() == [Self.switchLine])
  }

  @Test func aRiseOfTwoSwitchesStillAddsOneLine() {
    var journal = LidClosedJournal.start(baseline: EventCounters())
    journal.append(from: Self.snapshot(switches: 2))
    #expect(journal.events == [.hotspotSwitch])
    journal.append(from: Self.snapshot(switches: 3))
    journal.record(.hotspotSwitch)
    #expect(journal.events == [.hotspotSwitch])
    #expect(journal.omitted == 0)
  }

  @Test func threeCyclesMakeOneCountedLine() {
    var journal = LidClosedJournal.start(baseline: EventCounters())
    journal.append(from: Self.snapshot(cycles: 3))
    #expect(journal.events == [.wifiCycle(count: 3)])
    #expect(journal.lines() == ["Overtime restarted the wireless connection 3 times to get back online."])
  }

  @Test func aLaterCycleJoinsTheSameEntry() {
    var journal = LidClosedJournal.start(baseline: EventCounters())
    journal.append(from: Self.snapshot(cycles: 3))
    journal.append(from: Self.snapshot(switches: 1, cycles: 3))
    journal.append(from: Self.snapshot(switches: 1, cycles: 4))
    #expect(journal.events == [.wifiCycle(count: 4), .hotspotSwitch])
    #expect(
      journal.lines() == [
        "Overtime restarted the wireless connection 4 times to get back online.", Self.switchLine,
      ])
  }

  @Test func oneCycleReadsWithoutACount() {
    var journal = LidClosedJournal.start(baseline: EventCounters(wifiCycles: 6))
    journal.append(from: Self.snapshot(cycles: 7))
    #expect(journal.events == [.wifiCycle(count: 1)])
    #expect(journal.lines() == [Self.oneCycleLine])
    #expect(NotificationContent.wifiCycleLine(count: 1) == Self.oneCycleLine)
    #expect(
      NotificationContent.wifiCycleLine(count: 2)
        == "Overtime restarted the wireless connection 2 times to get back online.")
  }

  @Test func noRiseAddsNothing() {
    let baseline = EventCounters(hotspotSwitches: 2, wifiCycles: 5)
    var journal = LidClosedJournal.start(baseline: baseline)
    journal.append(from: Self.snapshot(switches: 2, cycles: 5))
    journal.append(from: Self.snapshot(switches: 1, cycles: 0))
    #expect(journal.isEmpty)
    #expect(journal.summary() == nil)
  }

  @Test func theSummaryFoldsTheNetworkLinesWithTheOthersUnderTheCap() throws {
    var journal = LidClosedJournal.start(baseline: EventCounters())
    journal.append(from: Self.snapshot(stuck: 1))
    journal.append(from: Self.snapshot(switches: 1, stuck: 1))
    journal.append(from: Self.snapshot(switches: 1, cycles: 2, stuck: 1))
    journal.append(from: Self.snapshot(switches: 2, cycles: 2, hold: 1, stuck: 1, sleeps: 1))
    let summary = try #require(journal.summary())
    #expect(summary.category == .lidClosedSummary)
    #expect(summary.sound == false)
    #expect(summary.turnOffAction == false)
    #expect(
      summary.body.components(separatedBy: "\n") == [
        "A Claude session looked stuck, so Overtime stopped counting it.",
        Self.switchLine,
        "Overtime restarted the wireless connection 2 times to get back online.",
        "And 2 more. Details are in the log.",
      ])
  }

  @Test func aFullJournalCountsTheNetworkEventsAsOmitted() {
    var journal = LidClosedJournal.start(baseline: EventCounters())
    journal.append(from: Self.snapshot(stuck: UInt64(LidClosedJournal.maxEvents)))
    journal.append(from: Self.snapshot(switches: 1, cycles: 1, stuck: UInt64(LidClosedJournal.maxEvents)))
    #expect(journal.events.count == LidClosedJournal.maxEvents)
    #expect(journal.omitted == 2)
    journal.append(from: Self.snapshot(switches: 4, cycles: 1, stuck: UInt64(LidClosedJournal.maxEvents)))
    #expect(journal.omitted == 2)
  }

  @Test func aCycleCountThatOverflowsIsCapped() {
    var journal = LidClosedJournal.start(baseline: EventCounters())
    journal.record(.wifiCycle(count: 2), times: UInt64.max)
    journal.record(.wifiCycle(count: 1))
    #expect(journal.events == [.wifiCycle(count: Int.max)])
  }
}
