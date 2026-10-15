import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import Testing

struct RelaunchDetectionTests {
  static let launch: Int64 = 1_800_000_000
  static let launchWall = Date(timeIntervalSince1970: TimeInterval(launch) + 0.75)

  static func detected(_ text: String) -> Bool {
    RelaunchDetection.wasRelaunched(historyText: text, launchWall: launchWall)
  }

  @Test(arguments: [0, 1, 30, 60])
  func aNewestEntryWithinSixtySecondsBeforeLaunchMeansRelaunched(_ age: Int64) {
    #expect(Self.detected("\(Self.launch - 400)\n\(Self.launch - age)\n"))
  }

  @Test(arguments: [61, 120, 599, 600, 5_000])
  func anOlderNewestEntryMeansNotRelaunched(_ age: Int64) {
    #expect(!Self.detected("\(Self.launch - 900)\n\(Self.launch - age)\n"))
  }

  @Test(arguments: [
    "", "\n", "garbage\n", "12abc\n", "-9223372036854775808\n", "9223372036854775807\n", "\(launch + 1)\n",
    "\(launch + 30)\n\(launch + 50)\n",
  ])
  func anEmptyMalformedOrFutureHistoryMeansNotRelaunched(_ text: String) {
    #expect(!Self.detected(text))
  }

  @Test func theNewestEntryDecidesWhateverTheOrder() {
    #expect(Self.detected("\(Self.launch - 5)\n\(Self.launch - 300)\n"))
  }

  @Test func aNonFiniteOrAbsurdLaunchWallMeansNotRelaunched() {
    for wall in [Date(timeIntervalSince1970: .infinity), Date(timeIntervalSince1970: 1e300)] {
      #expect(!RelaunchDetection.wasRelaunched(historyText: "\(Self.launch)\n", launchWall: wall))
    }
  }

  @Test func theHistoryFileIsReadBoundedAndAMissingOrOversizedFileMeansNotRelaunched() throws {
    let folder = try TempDirectory()
    let file = folder.url.appendingPathComponent("relaunch-history")
    #expect(!RelaunchDetection.wasRelaunched(historyAt: file, launchWall: Self.launchWall))
    try "\(Self.launch - 10)\n".write(to: file, atomically: true, encoding: .utf8)
    #expect(RelaunchDetection.wasRelaunched(historyAt: file, launchWall: Self.launchWall))
    let padding = String(repeating: "\n", count: 4_096)
    try (padding + "\(Self.launch - 10)\n").write(to: file, atomically: true, encoding: .utf8)
    #expect(RelaunchDetection.readHistory(at: file) == nil)
    #expect(!RelaunchDetection.wasRelaunched(historyAt: file, launchWall: Self.launchWall))
  }

  static func runCoordinator(history: String?, firstLidClosed: Bool?) async throws -> FakeNotificationPort {
    let folder = try TempDirectory()
    let file = folder.url.appendingPathComponent("relaunch-history")
    if let history {
      try history.write(to: file, atomically: true, encoding: .utf8)
    }
    let clock = FakeClock(wall: Date(timeIntervalSince1970: TimeInterval(launch) + 20))
    let host = ScriptedSnapshotHost(clock: clock)
    let port = FakeNotificationPort()
    let coordinator = NotificationCoordinator(
      port: port, preferences: { AppPreferences() }, log: { _ in }, relaunchHistory: file)
    defer { coordinator.stop() }
    coordinator.start(host: host)
    if firstLidClosed == nil {
      host.yield(LidClosedJournalTests.snapshot(lid: nil))
    }
    host.yield(LidClosedJournalTests.snapshot(lid: firstLidClosed ?? true))
    host.yield(LidClosedJournalTests.snapshot(lid: false))
    host.yield(marker)
    #expect(await port.wait { $0.posted.last?.category == .keepAwakeFailed })
    return port
  }

  static let marker = EngineSnapshot(busy: true, lidClosed: false, events: EventCounters(holdErrorsWhileBusy: 1))
  static let sentinelLine = "Overtime stopped unexpectedly. Its watchdog restored normal sleep."

  @Test func aRelaunchWithTheLidClosedSeedsTheNextSummary() async throws {
    let port = try await Self.runCoordinator(history: "\(Self.launch - 900)\n\(Self.launch)\n", firstLidClosed: true)
    #expect(port.posted.map(\.category) == [.lidClosedSummary, .keepAwakeFailed])
    #expect(port.posted.first?.body == Self.sentinelLine)
  }

  @Test func aRelaunchSeenFirstWithAnUnknownLidWaitsForTheFirstKnownLidState() async throws {
    let port = try await Self.runCoordinator(history: "\(Self.launch)\n", firstLidClosed: nil)
    #expect(port.posted.map(\.category) == [.lidClosedSummary, .keepAwakeFailed])
    #expect(port.posted.first?.body == Self.sentinelLine)
  }

  @Test func aRelaunchWithTheLidOpenPostsNothing() async throws {
    let port = try await Self.runCoordinator(history: "\(Self.launch)\n", firstLidClosed: false)
    #expect(port.posted.map(\.category) == [.keepAwakeFailed])
  }

  @Test(arguments: [String?.none, "", "\(launch - 300)\n"])
  func noRecentRelaunchPostsNothingOnAQuietClose(_ history: String?) async throws {
    let port = try await Self.runCoordinator(history: history, firstLidClosed: true)
    #expect(port.posted.map(\.category) == [.keepAwakeFailed])
  }

  @Test func aRebindNeverSeedsTheSentinelClearAgain() async throws {
    let folder = try TempDirectory()
    let file = folder.url.appendingPathComponent("relaunch-history")
    try "\(Self.launch)\n".write(to: file, atomically: true, encoding: .utf8)
    let clock = FakeClock(wall: Date(timeIntervalSince1970: TimeInterval(Self.launch) + 5))
    let first = ScriptedSnapshotHost(clock: clock)
    let second = ScriptedSnapshotHost(clock: clock)
    let port = FakeNotificationPort()
    let coordinator = NotificationCoordinator(
      port: port, preferences: { AppPreferences() }, log: { _ in }, relaunchHistory: file)
    defer { coordinator.stop() }
    coordinator.start(host: first)
    first.yield(LidClosedJournalTests.snapshot(lid: false))
    first.yield(Self.marker)
    #expect(await port.wait { $0.posted.count == 1 })
    coordinator.rebind(to: second)
    clock.advance(seconds: NotificationPolicy.capSeconds + 1)
    second.yield(LidClosedJournalTests.snapshot(lid: true))
    second.yield(LidClosedJournalTests.snapshot(lid: false))
    second.yield(Self.marker)
    #expect(await port.wait { $0.posted.count == 2 })
    #expect(port.posted.map(\.category) == [.keepAwakeFailed, .keepAwakeFailed])
  }
}
