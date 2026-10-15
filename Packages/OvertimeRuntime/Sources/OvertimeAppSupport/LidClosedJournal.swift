import Foundation
import OvertimeCore
import OvertimeEngine

public enum JournalEvent: Sendable, Equatable {
  case batteryRelease(floorPercent: Int)
  case stuckRelease
  case holdError(count: Int)
  case sentinelClear
  case unexpectedSleep
  case hotspotSwitch
  case wifiCycle(count: Int)

  public var line: String {
    switch self {
    case .batteryRelease(let floorPercent):
      NotificationContent.batteryReleaseLine(floorPercent: floorPercent)
    case .stuckRelease:
      NotificationContent.stuckReleaseLine
    case .holdError(let count):
      NotificationContent.holdErrorLine(count: count)
    case .sentinelClear:
      NotificationContent.sentinelClearLine
    case .unexpectedSleep:
      NotificationContent.unexpectedSleepLine
    case .hotspotSwitch:
      NotificationContent.hotspotSwitchLine
    case .wifiCycle(let count):
      NotificationContent.wifiCycleLine(count: count)
    }
  }
}

public struct LidClosedJournal: Sendable, Equatable {
  public static let maxEvents = 32

  public private(set) var events: [JournalEvent] = []
  public private(set) var omitted = 0
  private var baseline: EventCounters
  private var hotspotSwitchNoted = false

  private init(baseline: EventCounters) {
    self.baseline = baseline
  }

  public static func start(baseline: EventCounters) -> LidClosedJournal {
    LidClosedJournal(baseline: baseline)
  }

  public var isEmpty: Bool {
    events.isEmpty && omitted == 0
  }

  public mutating func append(from snapshot: EngineSnapshot) {
    let counters = snapshot.events
    record(.holdError(count: 1), times: delta(\.holdErrorEpisodes, counters))
    record(.stuckRelease, times: delta(\.stuckReleases, counters))
    record(.batteryRelease(floorPercent: snapshot.batteryLowPercent), times: delta(\.batteryReleases, counters))
    record(.unexpectedSleep, times: delta(\.unexpectedSleeps, counters))
    record(.hotspotSwitch, times: delta(\.hotspotSwitches, counters))
    record(.wifiCycle(count: 1), times: delta(\.wifiCycles, counters))
  }

  public mutating func record(_ event: JournalEvent, times: UInt64 = 1) {
    guard times > 0 else { return }
    let count = Int(clamping: times)
    switch event {
    case .holdError(let each):
      recordMerged(.holdError(count: Self.multiplying(each, count)))
    case .wifiCycle(let each):
      recordMerged(.wifiCycle(count: Self.multiplying(each, count)))
    case .hotspotSwitch:
      recordHotspotSwitch()
    case .batteryRelease, .stuckRelease, .sentinelClear, .unexpectedSleep:
      let room = max(0, Self.maxEvents - events.count)
      let kept = min(count, room)
      events.append(contentsOf: repeatElement(event, count: kept))
      omitted = Self.adding(omitted, count - kept)
    }
  }

  public func lines() -> [String] {
    events.map(\.line)
  }

  public func summary() -> NotificationIntent? {
    guard !isEmpty else { return nil }
    return NotificationContent.lidClosedSummary(lines: lines(), omitted: omitted)
  }

  private mutating func recordHotspotSwitch() {
    guard !hotspotSwitchNoted else { return }
    hotspotSwitchNoted = true
    if events.count < Self.maxEvents {
      events.append(.hotspotSwitch)
    } else {
      omitted = Self.adding(omitted, 1)
    }
  }

  private mutating func recordMerged(_ event: JournalEvent) {
    if let index = events.firstIndex(where: { Self.merging($0, event) != nil }),
      let merged = Self.merging(events[index], event)
    {
      events[index] = merged
    } else if events.count < Self.maxEvents {
      events.append(event)
    } else {
      omitted = Self.adding(omitted, 1)
    }
  }

  private static func merging(_ existing: JournalEvent, _ event: JournalEvent) -> JournalEvent? {
    switch (existing, event) {
    case (.holdError(let earlier), .holdError(let later)):
      .holdError(count: adding(earlier, later))
    case (.wifiCycle(let earlier), .wifiCycle(let later)):
      .wifiCycle(count: adding(earlier, later))
    default:
      nil
    }
  }

  private mutating func delta(_ counter: WritableKeyPath<EventCounters, UInt64>, _ counters: EventCounters) -> UInt64 {
    let current = counters[keyPath: counter]
    guard current > baseline[keyPath: counter] else { return 0 }
    defer { baseline[keyPath: counter] = current }
    return current - baseline[keyPath: counter]
  }

  private static func multiplying(_ lhs: Int, _ rhs: Int) -> Int {
    let (product, overflow) = lhs.multipliedReportingOverflow(by: rhs)
    return overflow ? Int.max : product
  }

  private static func adding(_ lhs: Int, _ rhs: Int) -> Int {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? Int.max : sum
  }
}
