import Darwin
import Foundation
import OvertimeCore
import OvertimeSystem
import Testing
import os

struct SessionReaderTests {
  final class Counter: Sendable {
    private let reads = OSAllocatedUnfairLock(initialState: [Int32]())

    var count: Int { reads.withLock { $0.count } }

    func directory(_ pid: Int32) -> String? {
      reads.withLock { $0.append(pid) }
      return "/Users/dev/p\(pid)"
    }
  }

  static let terminal: UInt32 = 0x1000_0003
  static let t0 = Instant(nanoseconds: 1_000 * 1_000_000_000)

  static func claude(pid: Int32, start: UInt64?, tty: UInt32 = terminal) -> ProcessRecord {
    ProcessRecord(
      pid: pid, ppid: 1, uid: getuid(), comm: "claude", ttyDevice: tty,
      startMono: start.map { Instant(nanoseconds: $0 * 1_000_000_000) }, argv0: "claude")
  }

  static func caffeinate(pid: Int32, parent: Int32) -> ProcessRecord {
    ProcessRecord(pid: pid, ppid: parent, uid: getuid(), comm: "caffeinate", argv0: "caffeinate")
  }

  @Test func theTestProcessReadsItsOwnWorkingDirectory() {
    let reader = SessionReader()
    let record = ProcessRecord(pid: getpid(), ppid: getppid(), uid: getuid(), comm: "tests")
    #expect(reader.summary(for: record).cwd == FileManager.default.currentDirectoryPath)
  }

  @Test func aRecordWithoutATerminalHasNoTerminalName() {
    let reader = SessionReader()
    let record = ProcessRecord(pid: getpid(), ppid: getppid(), uid: getuid(), comm: "tests")
    #expect(reader.summary(for: record).ttyName == nil)
    #expect(SessionReader.terminalName(ProcessRecord.noDevice) == nil)
  }

  @Test func launchdHasNoReadableWorkingDirectory() {
    #expect(SessionReader.currentDirectory(1) == nil)
  }

  @Test func aKnownSessionIsReadOnce() {
    let counter = Counter()
    let reader = SessionReader(readDirectory: counter.directory, readTerminal: { _ in "ttys003" })
    let record = Self.claude(pid: 500, start: 100)
    let first = reader.summary(for: record)
    let second = reader.summary(for: record)
    #expect(first == second)
    #expect(counter.count == 1)
  }

  @Test func sampleJitterInTheStartKeepsTheCachedSummary() {
    let counter = Counter()
    let reader = SessionReader(readDirectory: counter.directory, readTerminal: { _ in "ttys003" })
    var record = Self.claude(pid: 500, start: 100)
    let first = reader.summary(for: record)
    record.startMono = record.startMono?.adding(seconds: 0.004)
    #expect(reader.summary(for: record) == first)
    #expect(counter.count == 1)
  }

  @Test func aReusedPIDWithANewStartIsReadAgain() {
    let counter = Counter()
    let reader = SessionReader(readDirectory: counter.directory, readTerminal: { _ in "ttys003" })
    _ = reader.summary(for: Self.claude(pid: 500, start: 100))
    let reused = reader.summary(for: Self.claude(pid: 500, start: 900))
    #expect(counter.count == 2)
    #expect(reused.startMono == Instant(nanoseconds: 900_000_000_000))
  }

  @Test func onlyTerminalClaudeProcessesAreSessionsOldestFirst() {
    let reader = SessionReader(readDirectory: { "/Users/dev/p\($0)" }, readTerminal: { _ in "ttys003" })
    let records = [
      Self.claude(pid: 30, start: 300),
      ProcessRecord(pid: 31, ppid: 1, uid: getuid(), comm: "zsh", ttyDevice: Self.terminal, argv0: "-zsh"),
      Self.claude(pid: 32, start: 100, tty: ProcessRecord.noDevice),
      Self.claude(pid: 20, start: 200),
      Self.claude(pid: 12, start: 200),
      Self.claude(pid: 5, start: nil),
    ]
    #expect(reader.sessions(from: records, at: Self.t0).map(\.pid) == [12, 20, 30, 5])
  }

  @Test func aSessionThatLeftTheSampleIsForgotten() {
    let counter = Counter()
    let reader = SessionReader(readDirectory: counter.directory, readTerminal: { _ in "ttys003" })
    let record = Self.claude(pid: 70, start: 10)
    _ = reader.sessions(from: [record], at: Self.t0)
    _ = reader.sessions(from: [], at: Self.t0.adding(seconds: 2))
    _ = reader.sessions(from: [record], at: Self.t0.adding(seconds: 4))
    #expect(counter.count == 2)
  }

  @Test func aSummaryCarriesOnlyThePIDCwdTerminalStartAndWorkingSince() {
    let summary = SessionSummary(pid: 1, cwd: "/", ttyName: "ttys001", startMono: Instant(nanoseconds: 1))
    let labels = Mirror(reflecting: summary).children.map(\.label)
    #expect(labels == ["pid", "cwd", "ttyName", "startMono", "workingSince", "waitingSince", "printRun", "terminal"])
  }

  @Test func aWorkingSessionCarriesTheTickItWasFirstSeenWorking() {
    let reader = SessionReader(readDirectory: { "/Users/dev/p\($0)" }, readTerminal: { _ in "ttys003" })
    let records = [
      Self.claude(pid: 30, start: 300), Self.claude(pid: 20, start: 200), Self.caffeinate(pid: 31, parent: 30),
    ]
    let first = reader.sessions(from: records, at: Self.t0)
    #expect(first.map(\.pid) == [20, 30])
    #expect(first.map(\.workingSince) == [nil, Self.t0])
    let second = reader.sessions(from: records, at: Self.t0.adding(seconds: 2))
    #expect(second.map(\.workingSince) == [nil, Self.t0])
  }

  @Test func sampleJitterInTheStartKeepsTheWorkingEpisode() {
    let counter = Counter()
    let reader = SessionReader(readDirectory: counter.directory, readTerminal: { _ in "ttys003" })
    var session = Self.claude(pid: 30, start: 300)
    let child = Self.caffeinate(pid: 31, parent: 30)
    _ = reader.sessions(from: [session, child], at: Self.t0)
    session.startMono = session.startMono?.adding(seconds: 0.004)
    let jittered = reader.sessions(from: [session, child], at: Self.t0.adding(seconds: 2))
    #expect(jittered.map(\.workingSince) == [Self.t0])
    #expect(counter.count == 1)
  }

  @Test func aReusedPIDWithANewStartStartsANewWorkingEpisode() {
    let reader = SessionReader(readDirectory: { "/Users/dev/p\($0)" }, readTerminal: { _ in "ttys003" })
    let child = Self.caffeinate(pid: 31, parent: 30)
    _ = reader.sessions(from: [Self.claude(pid: 30, start: 300), child], at: Self.t0)
    let later = Self.t0.adding(seconds: 2)
    let reused = reader.sessions(from: [Self.claude(pid: 30, start: 900), child], at: later)
    #expect(reused.map(\.workingSince) == [later])
  }

  static func waiting(_ pids: Set<Int32>) -> LongRunningWork {
    LongRunningWork(waitingSessionPIDs: pids)
  }

  static func printRun(pid: Int32, ppid: Int32 = 1, start: UInt64, tty: UInt32 = ProcessRecord.noDevice)
    -> ProcessRecord
  {
    ProcessRecord(
      pid: pid, ppid: ppid, uid: getuid(), comm: "2.1.308", ttyDevice: tty,
      startMono: Instant(nanoseconds: start * 1_000_000_000), argv0: "/Users/dev/.local/bin/claude", printMode: true)
  }

  @Test func aWaitingTerminalSessionKeepsItsFirstWaitingTick() throws {
    let reader = SessionReader(readDirectory: { "/Users/dev/p\($0)" }, readTerminal: { _ in "ttys003" })
    let records = [Self.claude(pid: 30, start: 300)]
    for offset in [0.0, 2, 4] {
      let sessions = reader.sessions(from: records, at: Self.t0.adding(seconds: offset), work: Self.waiting([30]))
      let session = try #require(sessions.first)
      #expect(session.waitingSince == Self.t0)
      #expect(session.isWaiting)
      #expect(session.terminal)
      #expect(!session.printRun)
      #expect(!session.isWorking)
    }
  }

  @Test func aWaitingSessionWithoutATerminalIsListed() throws {
    let counter = Counter()
    let reader = SessionReader(readDirectory: counter.directory, readTerminal: { _ in "ttys003" })
    let records = [Self.claude(pid: 32, start: 100, tty: ProcessRecord.noDevice)]
    _ = reader.sessions(from: records, at: Self.t0, work: Self.waiting([32]))
    let sessions = reader.sessions(from: records, at: Self.t0.adding(seconds: 2), work: Self.waiting([32]))
    let session = try #require(sessions.first)
    #expect(sessions.count == 1)
    #expect(session.pid == 32)
    #expect(!session.terminal)
    #expect(session.ttyName == nil)
    #expect(session.cwd == "/Users/dev/p32")
    #expect(session.waitingSince == Self.t0)
    #expect(counter.count == 1)
  }

  @Test func aClaudePrintRunIsListedAsAPrintRun() throws {
    let counter = Counter()
    let reader = SessionReader(readDirectory: counter.directory, readTerminal: { _ in "ttys008" })
    var withTerminal = Self.printRun(pid: 61, ppid: 60, start: 500, tty: Self.terminal)
    var fromLaunchd = Self.printRun(pid: 62, start: 600)
    let starts = [Instant(nanoseconds: 500_000_000_000), Instant(nanoseconds: 600_000_000_000)]
    let work = LongRunningWork(printRunStarts: [61: starts[0], 62: starts[1]])
    let first = reader.sessions(from: [withTerminal, fromLaunchd], at: Self.t0, work: work)
    #expect(first.map(\.pid) == [61, 62])
    #expect(first.map(\.printRun) == [true, true])
    #expect(first.map(\.terminal) == [true, false])
    withTerminal.startMono = withTerminal.startMono?.adding(seconds: 0.4)
    fromLaunchd.startMono = fromLaunchd.startMono?.adding(seconds: 0.4)
    let second = reader.sessions(from: [withTerminal, fromLaunchd], at: Self.t0.adding(seconds: 2), work: work)
    #expect(second.map(\.startMono) == first.map(\.startMono))
    #expect(second.compactMap(\.startMono) == starts)
    #expect(counter.count == 2)
  }

  @Test func aSessionThatStopsWaitingLosesItsWaitingTickAfterTheGrace() {
    let reader = SessionReader(readDirectory: { "/Users/dev/p\($0)" }, readTerminal: { _ in "ttys003" })
    let records = [Self.claude(pid: 30, start: 300)]
    var listed: [Int] = []
    func waitingSince(at offset: Double, waiting: Bool) -> Instant? {
      let work = waiting ? Self.waiting([30]) : LongRunningWork()
      let sessions = reader.sessions(from: records, at: Self.t0.adding(seconds: offset), work: work)
      listed.append(sessions.count)
      return sessions.first?.waitingSince
    }
    for offset in stride(from: 0.0, through: 10, by: 2) {
      #expect(waitingSince(at: offset, waiting: true) == Self.t0)
    }
    #expect(waitingSince(at: 12, waiting: false) == Self.t0)
    #expect(waitingSince(at: 14, waiting: false) == Self.t0)
    #expect(waitingSince(at: 16, waiting: false) == nil)
    #expect(waitingSince(at: 18, waiting: false) == nil)
    #expect(waitingSince(at: 20, waiting: true) == Self.t0.adding(seconds: 20))
    #expect(listed == Array(repeating: 1, count: 11))
  }

  @Test func aTerminalLessSessionThatIsNeitherWaitingNorAPrintRunIsNotListed() {
    let reader = SessionReader(readDirectory: { "/Users/dev/p\($0)" }, readTerminal: { _ in "ttys003" })
    let records = [Self.claude(pid: 32, start: 100, tty: ProcessRecord.noDevice), Self.claude(pid: 30, start: 300)]
    #expect(reader.sessions(from: records, at: Self.t0, work: Self.waiting([99])).map(\.pid) == [30])
  }

  @Test func theNestedPrintRunAndItsWaitingParentAreTwoSummaries() {
    let reader = SessionReader(readDirectory: { "/Users/dev/p\($0)" }, readTerminal: { _ in "ttys003" })
    let interactive = Self.claude(pid: 41, start: 100)
    let run = Self.printRun(pid: 44, ppid: 43, start: 400, tty: 0x1000_0008)
    let work = LongRunningWork(waitingSessionPIDs: [41], printRunStarts: [44: Instant(nanoseconds: 400_000_000_000)])
    let sessions = reader.sessions(from: [interactive, run], at: Self.t0, work: work)
    #expect(sessions.map(\.pid) == [41, 44])
    #expect(sessions.map(\.isWaiting) == [true, false])
    #expect(sessions.map(\.printRun) == [false, true])
  }
}
