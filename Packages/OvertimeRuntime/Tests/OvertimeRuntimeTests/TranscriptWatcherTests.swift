import Foundation
import OvertimeCore
import OvertimeSystem
import Testing
import os

final class ActivityCollector: Sendable {
  private let items = OSAllocatedUnfairLock<[TranscriptActivity]>(initialState: [])
  private let reports = OSAllocatedUnfairLock<[[RootHealth]]>(initialState: [])

  func consume(_ stream: AsyncStream<Event>) -> Task<Void, Never> {
    Task {
      for await event in stream {
        switch event {
        case .transcriptActivity(let activity):
          items.withLock { $0.append(activity) }
        case .transcriptRoots(let roots):
          reports.withLock { $0.append(roots) }
        default:
          break
        }
      }
    }
  }

  var snapshot: [TranscriptActivity] {
    items.withLock { $0 }
  }

  var rootReports: [[RootHealth]] {
    reports.withLock { $0 }
  }

  func waitFor(count: Int, timeout: Double) async -> [TranscriptActivity] {
    let deadline = ContinuousClock.now + .milliseconds(Int(timeout * 1000))
    while ContinuousClock.now < deadline {
      let current = snapshot
      if current.count >= count { return current }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return snapshot
  }

  func waitForReport(timeout: Double, where matches: ([RootHealth]) -> Bool) async -> [RootHealth]? {
    let deadline = ContinuousClock.now + .milliseconds(Int(timeout * 1000))
    while ContinuousClock.now < deadline {
      if let report = rootReports.last(where: matches) { return report }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return rootReports.last(where: matches)
  }
}

final class GatedClock: ClockPort {
  private struct State {
    var held = false
    var waiting = 0
    var blocked = 0
  }

  static let heldSeconds: Double = 30

  private let state = OSAllocatedUnfairLock(initialState: State())
  private let gate = DispatchSemaphore(value: 0)
  private let inner = SystemClock()

  var blockedCalls: Int {
    state.withLock { $0.blocked }
  }

  func hold() {
    state.withLock { $0.held = true }
  }

  func release() {
    let waiting = state.withLock { state -> Int in
      state.held = false
      defer { state.waiting = 0 }
      return state.waiting
    }
    for _ in 0..<waiting {
      gate.signal()
    }
  }

  func mono() -> Instant {
    let blocks = state.withLock { state -> Bool in
      guard state.held else { return false }
      state.waiting += 1
      state.blocked += 1
      return true
    }
    if blocks {
      _ = gate.wait(timeout: .now() + Self.heldSeconds)
    }
    return inner.mono()
  }

  func wall() -> Date {
    inner.wall()
  }
}

final class GatedStatus: Sendable {
  private struct State {
    var held = false
    var waiting = 0
    var blocked = 0
  }

  private let state = OSAllocatedUnfairLock(initialState: State())
  private let gate = DispatchSemaphore(value: 0)

  var blockedCalls: Int {
    state.withLock { $0.blocked }
  }

  func hold() {
    state.withLock { $0.held = true }
  }

  func release() {
    let waiting = state.withLock { state -> Int in
      state.held = false
      defer { state.waiting = 0 }
      return state.waiting
    }
    for _ in 0..<waiting {
      gate.signal()
    }
  }

  func read(_ path: String) -> RootStatus {
    let blocks = state.withLock { state -> Bool in
      guard state.held else { return false }
      state.waiting += 1
      state.blocked += 1
      return true
    }
    if blocks {
      _ = gate.wait(timeout: .now() + GatedClock.heldSeconds)
    }
    return TranscriptWatcher.status(ofRootAt: path)
  }
}

@Suite(.serialized)
struct TranscriptWatcherTests {
  let clock = SystemClock()

  static func ended(_ task: Task<Void, Never>, within seconds: Double = 5) async -> Bool {
    let done = OSAllocatedUnfairLock(initialState: false)
    Task {
      await task.value
      done.withLock { $0 = true }
    }
    return await OffPool.eventually(seconds: seconds) { done.withLock { $0 } }
  }

  @Test func startReturnsBeforeTheFoldersAreCheckedAndScanned() async throws {
    let temp = try TempDirectory.short()
    try write("{}\n", to: temp.path + "/old/a.jsonl", modifiedSecondsAgo: 60)
    let status = GatedStatus()
    let gated = GatedClock()
    defer {
      status.release()
      gated.release()
    }
    status.hold()
    gated.hold()
    let watcher = TranscriptWatcher(
      roots: [temp.path], clock: gated, seedWindowSeconds: 1800, headers: TranscriptHeaderReader(),
      statusOfRoot: { status.read($0) })
    let stream = try #require(await OffPool.bounded(seconds: 5) { watcher.start() })
    let collector = ActivityCollector()
    let consumer = collector.consume(stream)
    #expect(await OffPool.eventually { status.blockedCalls == 1 })
    #expect(collector.rootReports.isEmpty, "R2T-WR-03: the folder check runs after start() returned")
    status.release()
    #expect(await collector.waitForReport(timeout: 5) { _ in true } == [RootHealth(path: temp.path, status: .ok)])
    #expect(await OffPool.eventually { gated.blockedCalls == 1 })
    #expect(collector.snapshot.isEmpty, "the seed scan runs after start() returned")
    gated.release()
    #expect(await collector.waitFor(count: 1, timeout: 5).count >= 1)
    #expect(await OffPool.bounded(seconds: 5) { watcher.stop() } != nil)
    #expect(await Self.ended(consumer))
  }

  @Test func cancellingTheConsumerNeverWaitsForTheWatchersQueueAndStillStopsTheWatcher() async throws {
    let temp = try TempDirectory.short()
    let gated = GatedClock()
    defer { gated.release() }
    var watcher: TranscriptWatcher? = TranscriptWatcher(
      roots: [temp.path], clock: gated, seedWindowSeconds: 1800, headers: TranscriptHeaderReader())
    weak let released = watcher
    let collector = ActivityCollector()
    let consumer = collector.consume(try #require(watcher).start())
    #expect(await collector.waitForReport(timeout: 5) { _ in true } != nil)
    try await Task.sleep(for: .milliseconds(300))
    gated.hold()
    try write("{}\n", to: temp.path + "/sess/a.jsonl")
    #expect(await OffPool.eventually { gated.blockedCalls >= 1 })
    let cancelled = await OffPool.bounded(seconds: 5) { () -> Bool in
      consumer.cancel()
      return true
    }
    #expect(cancelled == true)
    #expect(await Self.ended(consumer))
    watcher = nil
    #expect(released != nil)
    gated.release()
    #expect(await OffPool.eventually { released == nil })
  }

  @Test func aStreamThatNobodyKeepsStopsTheWatcher() async throws {
    let temp = try TempDirectory.short()
    var watcher: TranscriptWatcher? = TranscriptWatcher(
      roots: [temp.path], clock: clock, seedWindowSeconds: 1800, headers: TranscriptHeaderReader())
    weak let released = watcher
    _ = try #require(watcher).start()
    watcher = nil
    #expect(await OffPool.eventually { released == nil })
  }

  @Test func aSecondStartEndsTheFirstStreamAndTheNewOneKeepsWorking() async throws {
    let temp = try TempDirectory.short()
    let watcher = TranscriptWatcher(
      roots: [temp.path], clock: clock, seedWindowSeconds: 1800, headers: TranscriptHeaderReader())
    let first = ActivityCollector()
    let firstConsumer = first.consume(watcher.start())
    #expect(await first.waitForReport(timeout: 5) { _ in true } != nil)
    let second = ActivityCollector()
    let secondConsumer = second.consume(watcher.start())
    #expect(await Self.ended(firstConsumer))
    #expect(await second.waitForReport(timeout: 5) { _ in true } == [RootHealth(path: temp.path, status: .ok)])
    try await Task.sleep(for: .milliseconds(300))
    try write("{}\n", to: temp.path + "/sess/b.jsonl")
    #expect(await second.waitFor(count: 1, timeout: 5).count >= 1)
    #expect(first.snapshot.isEmpty)
    #expect(await OffPool.bounded(seconds: 5) { watcher.stop() } != nil)
    #expect(await Self.ended(secondConsumer))
  }

  func write(_ text: String, to path: String, modifiedSecondsAgo age: Double = 0) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
    if age > 0 {
      try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: path)
    }
  }

  func secondsBetween(_ a: Instant, _ b: Instant) -> Double {
    a > b ? a.seconds(since: b) : b.seconds(since: a)
  }

  @Test func liveWriteInASubagentDirectoryIsYielded() async throws {
    let temp = try TempDirectory.short()
    try FileManager.default.createDirectory(
      atPath: temp.path + "/sess/subagents", withIntermediateDirectories: true)
    let watcher = TranscriptWatcher(
      roots: [temp.path], clock: clock, seedWindowSeconds: 1800, headers: TranscriptHeaderReader())
    let collector = ActivityCollector()
    let consumer = collector.consume(watcher.start())
    #expect(await collector.waitForReport(timeout: 5) { _ in true } != nil)
    try write("{}\n", to: temp.path + "/sess/subagents/agent-1.jsonl")
    let written = clock.mono()
    let activities = await collector.waitFor(count: 1, timeout: 5)
    #expect(await OffPool.bounded(seconds: 5) { watcher.stop() } != nil)
    #expect(await Self.ended(consumer))
    #expect(activities.count >= 1)
    if let first = activities.first {
      #expect(secondsBetween(first.at, written) < 2)
    }
  }

  @Test func nonTranscriptFilesYieldNothing() async throws {
    let temp = try TempDirectory.short()
    let watcher = TranscriptWatcher(
      roots: [temp.path], clock: clock, seedWindowSeconds: 1800, headers: TranscriptHeaderReader())
    let collector = ActivityCollector()
    let consumer = collector.consume(watcher.start())
    try await Task.sleep(for: .milliseconds(300))
    try write("notes\n", to: temp.path + "/sess/notes.txt")
    try await Task.sleep(for: .seconds(2))
    #expect(collector.snapshot.isEmpty)
    try write("{}\n", to: temp.path + "/sess/control.jsonl")
    let activities = await collector.waitFor(count: 1, timeout: 3)
    #expect(await OffPool.bounded(seconds: 5) { watcher.stop() } != nil)
    #expect(await Self.ended(consumer))
    #expect(activities.count >= 1)
  }

  @Test func seedYieldsARecentPreexistingTranscriptBeforeLiveEvents() async throws {
    let temp = try TempDirectory.short()
    try write("{}\n", to: temp.path + "/old/a.jsonl", modifiedSecondsAgo: 60)
    let wroteOld = clock.mono()
    let watcher = TranscriptWatcher(
      roots: [temp.path], clock: clock, seedWindowSeconds: 1800, headers: TranscriptHeaderReader())
    let collector = ActivityCollector()
    let consumer = collector.consume(watcher.start())
    let seeded = await collector.waitFor(count: 1, timeout: 5)
    #expect(seeded.count >= 1)
    try write("{}\n", to: temp.path + "/new/b.jsonl")
    let wroteNew = clock.mono()
    #expect(
      await OffPool.eventually { collector.snapshot.dropFirst().contains { secondsBetween($0.at, wroteNew) < 2 } })
    let activities = collector.snapshot
    #expect(await OffPool.bounded(seconds: 5) { watcher.stop() } != nil)
    #expect(await Self.ended(consumer))
    guard let first = activities.first else { return }
    #expect(abs(wroteOld.seconds(since: first.at) - 60) < 2)
  }

  @Test func transcriptsOlderThanTheSeedWindowAreNotSeeded() async throws {
    let temp = try TempDirectory.short()
    try write("{}\n", to: temp.path + "/old/a.jsonl", modifiedSecondsAgo: 600)
    let watcher = TranscriptWatcher(
      roots: [temp.path], clock: clock, seedWindowSeconds: 120, headers: TranscriptHeaderReader())
    let collector = ActivityCollector()
    let consumer = collector.consume(watcher.start())
    try await Task.sleep(for: .seconds(1))
    #expect(await OffPool.bounded(seconds: 5) { watcher.stop() } != nil)
    #expect(await Self.ended(consumer))
    #expect(collector.snapshot.isEmpty)
  }

  @Test func rootsGivenThroughASymbolicLinkMatchCanonicalEventPaths() async throws {
    let temp = try TempDirectory()
    let real = temp.path + "/real"
    let link = temp.path + "/link"
    try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
    let watcher = TranscriptWatcher(
      roots: [link], clock: clock, seedWindowSeconds: 1800, headers: TranscriptHeaderReader())
    #expect(watcher.canonicalRoots == [TranscriptWatcher.canonicalPath(real)])
    #expect(watcher.canonicalRoots != [link])
    if temp.path.hasPrefix("/var/") {
      #expect(watcher.canonicalRoots.first?.hasPrefix("/private/var/") == true)
    }
    let collector = ActivityCollector()
    let consumer = collector.consume(watcher.start())
    try await Task.sleep(for: .milliseconds(300))
    try write("{}\n", to: link + "/sess/x.jsonl")
    let activities = await collector.waitFor(count: 1, timeout: 3)
    #expect(await OffPool.bounded(seconds: 5) { watcher.stop() } != nil)
    #expect(await Self.ended(consumer))
    #expect(activities.count >= 1)
  }

  @Test func missingRootsKeepTheirGivenPathAndStartCleanly() async throws {
    let temp = try TempDirectory.short()
    let missing = temp.path + "/does-not-exist"
    let watcher = TranscriptWatcher(
      roots: [missing], clock: clock, seedWindowSeconds: 1800, headers: TranscriptHeaderReader())
    #expect(watcher.canonicalRoots == [missing])
    let collector = ActivityCollector()
    let consumer = collector.consume(watcher.start())
    #expect(await OffPool.bounded(seconds: 5) { watcher.stop() } != nil)
    #expect(await Self.ended(consumer))
    #expect(collector.snapshot.isEmpty)
    #expect(collector.rootReports == [[RootHealth(path: missing, status: .missing)]])
  }

  @Test func aWatcherReportsEachRootWithItsOrigin() async throws {
    let temp = try TempDirectory.short()
    let present = temp.path
    let absentA = temp.url.appendingPathComponent("absent-a", isDirectory: true).path(percentEncoded: false)
    let absentB = temp.url.appendingPathComponent("absent-b", isDirectory: true).path(percentEncoded: false)
    let roots = [
      TranscriptRoot(path: present, origin: .inferred), TranscriptRoot(path: absentA, origin: .inferred),
      TranscriptRoot(path: absentB, origin: .configured),
    ]
    let expected = [
      RootHealth(path: present, status: .ok, origin: .inferred),
      RootHealth(path: absentA, status: .missing, origin: .inferred),
      RootHealth(path: absentB, status: .missing, origin: .configured),
    ]
    let watcher = TranscriptWatcher(
      roots: roots, clock: clock, stuckWindow: StuckWindowBox(seconds: 1800), headers: TranscriptHeaderReader())
    let collector = ActivityCollector()
    let consumer = collector.consume(watcher.start())
    let first = await collector.waitForReport(timeout: 5) { _ in true }
    #expect(await OffPool.bounded(seconds: 5) { watcher.stop() } != nil)
    #expect(await Self.ended(consumer))
    #expect(first == expected)
    #expect(TranscriptWatcher.health(ofRoots: roots) == expected)
  }

  @Test func aRootThatAppearsLaterIsReportedHealthyAndWatched() async throws {
    let temp = try TempDirectory.short()
    let present = temp.path + "/present"
    let late = temp.path + "/late"
    try FileManager.default.createDirectory(atPath: present, withIntermediateDirectories: true)
    let watcher = TranscriptWatcher(
      roots: [present, late], clock: clock, seedWindowSeconds: 1800, headers: TranscriptHeaderReader(),
      healthCheckSeconds: 1)
    let collector = ActivityCollector()
    let consumer = collector.consume(watcher.start())
    let initial = await collector.waitForReport(timeout: 5) { _ in true }
    #expect(initial == [RootHealth(path: present, status: .ok), RootHealth(path: late, status: .missing)])
    try FileManager.default.createDirectory(atPath: late, withIntermediateDirectories: true)
    let healthy = await collector.waitForReport(timeout: 3) { report in
      report.allSatisfy { $0.status == .ok }
    }
    #expect(healthy == [RootHealth(path: present, status: .ok), RootHealth(path: late, status: .ok)])
    #expect(watcher.canonicalRoots.last == TranscriptWatcher.canonicalPath(late))
    try await Task.sleep(for: .milliseconds(300))
    try write("{}\n", to: late + "/sess/new.jsonl")
    let activities = await collector.waitFor(count: 1, timeout: 3)
    #expect(activities.count >= 1)
    try await Task.sleep(for: .milliseconds(1500))
    #expect(await OffPool.bounded(seconds: 5) { watcher.stop() } != nil)
    #expect(await Self.ended(consumer))
    #expect(collector.rootReports.count == 2)
  }

  @Test func aRootThatDisappearsIsReportedMissing() async throws {
    let temp = try TempDirectory.short()
    let root = temp.path + "/root"
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    let watcher = TranscriptWatcher(
      roots: [root], clock: clock, seedWindowSeconds: 1800, headers: TranscriptHeaderReader(), healthCheckSeconds: 1)
    let collector = ActivityCollector()
    let consumer = collector.consume(watcher.start())
    #expect(await collector.waitForReport(timeout: 3) { _ in true } == [RootHealth(path: root, status: .ok)])
    try FileManager.default.removeItem(atPath: root)
    let missing = await collector.waitForReport(timeout: 3) { $0.first?.status == .missing }
    #expect(await OffPool.bounded(seconds: 5) { watcher.stop() } != nil)
    #expect(await Self.ended(consumer))
    #expect(missing == [RootHealth(path: root, status: .missing)])
    #expect(collector.rootReports.first == [RootHealth(path: root, status: .ok)])
  }

  @Test func rootStatusDistinguishesMissingUnreadableAndFiles() throws {
    let temp = try TempDirectory.short()
    let locked = temp.path + "/locked"
    let file = temp.path + "/file"
    try FileManager.default.createDirectory(atPath: locked, withIntermediateDirectories: true)
    try Data().write(to: URL(fileURLWithPath: file))
    #expect(TranscriptWatcher.status(ofRootAt: temp.path) == .ok)
    #expect(TranscriptWatcher.status(ofRootAt: temp.path + "/absent") == .missing)
    #expect(TranscriptWatcher.status(ofRootAt: file) == .missing)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked) }
    #expect(TranscriptWatcher.status(ofRootAt: locked) == .unreadable)
    #expect(
      TranscriptWatcher.health(ofRoots: [temp.path, locked]) == [
        RootHealth(path: temp.path, status: .ok), RootHealth(path: locked, status: .unreadable),
      ])
  }

  @Test func liveAndSeededActivitiesCarryTheHeaderEntrypoint() async throws {
    let temp = try TempDirectory.short()
    try write(#"{"type":"user","entrypoint":"cli"}"# + "\n", to: temp.path + "/a/seed.jsonl", modifiedSecondsAgo: 30)
    let watcher = TranscriptWatcher(
      roots: [temp.path], clock: clock, seedWindowSeconds: 1800, headers: TranscriptHeaderReader())
    let collector = ActivityCollector()
    let consumer = collector.consume(watcher.start())
    #expect(await collector.waitFor(count: 1, timeout: 5).count >= 1)
    try write(#"{"type":"user","entrypoint":"sdk-py"}"# + "\n", to: temp.path + "/b/live.jsonl")
    #expect(await OffPool.eventually { collector.snapshot.dropFirst().contains { $0.entrypoint == "sdk-py" } })
    let activities = collector.snapshot
    #expect(await OffPool.bounded(seconds: 5) { watcher.stop() } != nil)
    #expect(await Self.ended(consumer))
    #expect(activities.first?.entrypoint == "cli")
    #expect(activities.dropFirst().contains { $0.entrypoint == "sdk-py" })
  }

  struct HeaderReader {
    func file(_ contents: [UInt8], in temp: TempDirectory, named name: String = "t.jsonl") throws -> String {
      let path = temp.path + "/" + name
      try Data(contents).write(to: URL(fileURLWithPath: path))
      return path
    }

    @Test func readsTheFixtureHeaders() throws {
      let temp = try TempDirectory()
      let reader = TranscriptHeaderReader()
      let automation = try file(
        Array(#"{"type":"user","entrypoint":"sdk-cli"}"#.utf8) + [10], in: temp, named: "a.jsonl")
      let summary = try file(Array(#"{"type":"summary"}"#.utf8) + [10], in: temp, named: "c.jsonl")
      #expect(reader.entrypoint(forFileAt: automation) == "sdk-cli")
      #expect(reader.entrypoint(forFileAt: summary) == nil)
      #expect(reader.entrypoint(forFileAt: temp.path + "/missing.jsonl") == nil)
    }

    @Test func rereadsASmallFileWhoseHeaderArrivesLater() throws {
      let temp = try TempDirectory()
      let reader = TranscriptHeaderReader()
      let path = try file(Array(#"{"type":"last-prompt"}"#.utf8) + [10], in: temp)
      #expect(reader.entrypoint(forFileAt: path) == nil)
      let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
      try handle.seekToEnd()
      try handle.write(contentsOf: Data((#"{"type":"user","entrypoint":"sdk-ts"}"# + "\n").utf8))
      try handle.close()
      #expect(reader.entrypoint(forFileAt: path) == "sdk-ts")
    }

    @Test func keepsAPositiveVerdictForTheSameFile() throws {
      let temp = try TempDirectory()
      let reader = TranscriptHeaderReader()
      let path = try file(Array(#"{"entrypoint":"cli"}"#.utf8) + [10], in: temp)
      #expect(reader.entrypoint(forFileAt: path) == "cli")
      let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
      try handle.truncate(atOffset: 0)
      try handle.write(contentsOf: Data(#"{"entrypoint":"sdk-cli"}"#.utf8))
      try handle.close()
      #expect(reader.entrypoint(forFileAt: path) == "cli")
    }

    @Test func neverLooksPastTheCapInALargeFile() throws {
      let temp = try TempDirectory()
      let reader = TranscriptHeaderReader()
      let bytes =
        [UInt8](repeating: UInt8(ascii: "x"), count: 70_000) + Array(#""entrypoint":"cli""#.utf8)
        + [UInt8](repeating: UInt8(ascii: "y"), count: 1_000_000)
      let path = try file(bytes, in: temp)
      #expect(reader.entrypoint(forFileAt: path) == nil)
    }

    @Test func ignoresSymbolicLinksAndDirectories() throws {
      let temp = try TempDirectory()
      let reader = TranscriptHeaderReader()
      let target = try file(Array(#"{"entrypoint":"cli"}"#.utf8), in: temp, named: "real.jsonl")
      try FileManager.default.createSymbolicLink(atPath: temp.path + "/link.jsonl", withDestinationPath: target)
      try FileManager.default.createDirectory(atPath: temp.path + "/dir.jsonl", withIntermediateDirectories: true)
      #expect(reader.entrypoint(forFileAt: temp.path + "/link.jsonl") == nil)
      #expect(reader.entrypoint(forFileAt: temp.path + "/dir.jsonl") == nil)
    }

    @Test func dropsCacheEntriesNotSeenWithinTheRetentionWindow() throws {
      let temp = try TempDirectory()
      let clock = FakeClock()
      let reader = TranscriptHeaderReader(clock: clock, retentionSeconds: 1800)
      let first = try file(Array(#"{"entrypoint":"cli"}"#.utf8), in: temp, named: "one.jsonl")
      let second = try file(Array(#"{"entrypoint":"cli"}"#.utf8), in: temp, named: "two.jsonl")
      _ = reader.entrypoint(forFileAt: first)
      _ = reader.entrypoint(forFileAt: second)
      #expect(reader.cachedEntryCount == 2)
      clock.advance(seconds: 1000)
      _ = reader.entrypoint(forFileAt: second)
      clock.advance(seconds: 1000)
      _ = reader.entrypoint(forFileAt: second)
      #expect(reader.cachedEntryCount == 1)
    }

    @Test func retentionFollowsASharedStuckWindowBox() throws {
      let temp = try TempDirectory()
      let clock = FakeClock()
      let box = StuckWindowBox(seconds: 1800)
      let reader = TranscriptHeaderReader(clock: clock, stuckWindow: box)
      let first = try file(Array(#"{"entrypoint":"cli"}"#.utf8), in: temp, named: "one.jsonl")
      let second = try file(Array(#"{"entrypoint":"cli"}"#.utf8), in: temp, named: "two.jsonl")
      _ = reader.entrypoint(forFileAt: first)
      clock.advance(seconds: 120)
      box.seconds = 60
      _ = reader.entrypoint(forFileAt: second)
      #expect(reader.cachedEntryCount == 1)
    }
  }
}
