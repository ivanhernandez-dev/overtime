import Darwin
import Foundation
import OvertimeCore
import Testing
import os

@testable import OvertimeSystem

@Suite(.processCleanup)
struct ProcessScannerTests {
  @Test func samplesTheTestProcessReadOnly() throws {
    let scanner = ProcessScanner(userID: getuid())
    let records = scanner.sample(clock: SystemClock(), extraCandidates: [getpid()])
    let own = try #require(records.first { $0.pid == getpid() })
    #expect(own.uid == getuid())
    #expect(own.ppid == getppid())
    #expect(!own.comm.isEmpty)
    #expect(own.argv0 != nil)
    #expect(own.pidPath != nil)
    #expect(own.startMono != nil)
    #expect(records.allSatisfy { $0.uid == getuid() })
  }

  @Test func repeatedSamplesAgreeThroughTheCache() throws {
    let scanner = ProcessScanner(userID: getuid())
    let first = try #require(scanner.sample(extraCandidates: [getpid()]).first { $0.pid == getpid() })
    let second = try #require(scanner.sample(extraCandidates: [getpid()]).first { $0.pid == getpid() })
    #expect(first.argv0 == second.argv0)
    #expect(first.execPath == second.execPath)
    #expect(first.pidPath == second.pidPath)
  }

  @Test func anotherUsersIdentityYieldsNoRecords() {
    let scanner = ProcessScanner(userID: UInt32.max - 7)
    #expect(scanner.sample(extraCandidates: [getpid()]).isEmpty)
  }

  final class ReadLog: Sendable {
    private let reads = OSAllocatedUnfairLock(initialState: (args: [Int32](), paths: [Int32]()))

    func noteArgs(_ pid: Int32) {
      reads.withLock { $0.args.append(pid) }
    }

    func notePath(_ pid: Int32) {
      reads.withLock { $0.paths.append(pid) }
    }

    var args: [Int32] {
      reads.withLock { $0.args }
    }

    var paths: [Int32] {
      reads.withLock { $0.paths }
    }
  }

  static func countingScanner(_ log: ReadLog) -> ProcessScanner {
    ProcessScanner(
      userID: getuid(),
      readArgs: { pid in
        log.noteArgs(pid)
        return ProcessScanner.procArgs(pid)
      },
      readPath: { pid in
        log.notePath(pid)
        return ProcessScanner.pidPath(pid)
      })
  }

  static func candidates(of records: [ProcessRecord], extra: Set<Int32>) -> Set<Int32> {
    var candidates = extra
    for record in records {
      if record.ttyDevice != ProcessRecord.noDevice || record.comm == ProcessScanner.amphetamineComm {
        candidates.insert(record.pid)
      }
      if record.comm == "caffeinate" {
        candidates.insert(record.pid)
        candidates.insert(record.ppid)
      }
    }
    return candidates.intersection(records.map(\.pid))
  }

  @Test func argvIsReadOnlyForCandidatePids() {
    let log = ReadLog()
    let scanner = Self.countingScanner(log)
    let records = scanner.sample(clock: SystemClock(), extraCandidates: [getpid()])
    let pids = Set(records.map(\.pid))
    let candidates = Self.candidates(of: records, extra: [getpid()])
    #expect(pids.count == records.count)
    #expect(candidates.contains(getpid()))
    #expect(candidates.isStrictSubset(of: pids))
    #expect(log.args.count == Set(log.args).count)
    #expect(log.paths.count == Set(log.paths).count)
    #expect(Set(log.args) == candidates)
    #expect(Set(log.paths) == candidates)
    #expect(log.args.count < records.count)
    let others = records.filter { !candidates.contains($0.pid) }
    #expect(!others.isEmpty)
    for record in others {
      #expect(record.argv0 == nil, "\(record.pid) \(record.comm)")
      #expect(record.argv1 == nil, "\(record.pid) \(record.comm)")
      #expect(record.execPath == nil, "\(record.pid) \(record.comm)")
      #expect(record.pidPath == nil, "\(record.pid) \(record.comm)")
      #expect(record.claudeConfigDirectory == nil, "\(record.pid) \(record.comm)")
    }
  }

  static func ownClaudeBuffer(configDirectory: String) -> [UInt8] {
    let argc = withUnsafeBytes(of: Int32(1).littleEndian) { Array($0) }
    let strings = ["/Users/dev/.local/bin/claude", "", "claude", "CLAUDE_CONFIG_DIR=" + configDirectory, "", "pfz=0"]
    return argc + strings.flatMap { Array($0.utf8) + [0] }
  }

  @Test func aCandidateCarriesTheConfigDirectoryOfItsOwnBuffer() throws {
    let log = ReadLog()
    let own = getpid()
    let configDirectory = "/tmp/ot-sr6-scanner-config"
    let scanner = ProcessScanner(
      userID: getuid(),
      readArgs: { pid in
        log.noteArgs(pid)
        return pid == own ? Self.ownClaudeBuffer(configDirectory: configDirectory) : nil
      },
      readPath: ProcessScanner.pidPath)
    let records = scanner.sample(clock: SystemClock(), extraCandidates: [own])
    let record = try #require(records.first { $0.pid == own })
    #expect(record.argv0 == "claude")
    #expect(record.claudeConfigDirectory == configDirectory)
    #expect(ClaudeCodeDetector(userID: getuid()).signals(from: records).claudeConfigDirectories == [configDirectory])
    #expect(log.args.filter { $0 == own }.count == 1)
  }

  @Test func theOwnBufferYieldsTheConfigDirectoryItWasStartedWith() throws {
    let buffer = ProcessScanner.procArgs(getpid())
    let read = buffer.flatMap(ProcArgsParser.parse)
    let parsed = try #require(read)
    #expect(parsed.argv0 == CommandLine.arguments.first)
    let inherited = ProcessInfo.processInfo.environment[ProcArgsParser.configDirectoryVariable]
    let expected = inherited.flatMap { value in
      (1...ProcArgsParser.maxConfigDirectoryBytes).contains(value.utf8.count) ? value : nil
    }
    #expect(parsed.claudeConfigDirectory == expected)
  }

  @Test func aSecondSampleReadsNothingAgainForUnchangedProcesses() {
    let log = ReadLog()
    let scanner = Self.countingScanner(log)
    _ = scanner.sample(clock: SystemClock(), extraCandidates: [getpid()])
    let firstArgs = log.args
    let firstPaths = log.paths
    #expect(firstArgs.contains(getpid()))
    let records = scanner.sample(clock: SystemClock(), extraCandidates: [getpid()])
    let againArgs = Set(log.args.dropFirst(firstArgs.count))
    let againPaths = Set(log.paths.dropFirst(firstPaths.count))
    #expect(!againArgs.contains(getpid()))
    #expect(!againPaths.contains(getpid()))
    #expect(againArgs.isDisjoint(with: firstArgs))
    #expect(againPaths.isDisjoint(with: firstPaths))
    #expect(againArgs.isSubset(of: Self.candidates(of: records, extra: [getpid()])))
    let own = records.first { $0.pid == getpid() }
    #expect(own?.argv0 != nil)
    #expect(own?.pidPath != nil)
  }

  @Test func aProcessThatExecsIsReadAgainUnderItsNewImage() async throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/bash")
    child.arguments = ["-c", "read -r line; exec /bin/sleep 30"]
    let input = Pipe()
    child.standardInput = input
    child.standardOutput = FileHandle.nullDevice
    child.standardError = FileHandle.nullDevice
    try child.run()
    ProcessCleanup.track(child)
    let pid = child.processIdentifier
    let scanner = ProcessScanner(userID: getuid())
    func current() -> ProcessRecord? {
      scanner.sample(extraCandidates: [pid]).first { $0.pid == pid }
    }
    let before = try #require(current())
    #expect(before.comm == "bash")
    #expect(before.argv0 == "/bin/bash")
    try input.fileHandleForWriting.write(contentsOf: Data("go\n".utf8))
    #expect(await OffPool.eventually(seconds: 5) { current()?.comm == "sleep" })
    let after = try #require(current())
    #expect(after.comm == "sleep")
    #expect(after.argv0 == "/bin/sleep")
    #expect(after.pidPath == "/bin/sleep")
  }

  struct Stage: Sendable {
    var comm: String
    var startSeconds: UInt64 = 1_792_000_000
    var execPath: String
    var arguments: [String]
    var pidPath: String
  }

  final class StagedProcess: Sendable {
    static let pid: Int32 = 4242
    static let userID: UInt32 = 501
    static let terminal: UInt32 = 0x1000_0003

    private let stages: [Stage]
    private let index = OSAllocatedUnfairLock(initialState: 0)

    init(_ stages: [Stage]) {
      self.stages = stages
    }

    var stage: Stage {
      stages[index.withLock { $0 }]
    }

    func advance() {
      index.withLock { $0 = min($0 + 1, stages.count - 1) }
    }

    func entries() -> [ProcessScanner.Entry] {
      [
        ProcessScanner.Entry(
          pid: Self.pid, ppid: 1, uid: Self.userID, comm: stage.comm, ttyDevice: Self.terminal,
          startSeconds: stage.startSeconds, startMicroseconds: 250_000)
      ]
    }

    func scanner(_ log: ReadLog) -> ProcessScanner {
      ProcessScanner(
        userID: Self.userID,
        readArgs: { pid in
          log.noteArgs(pid)
          return pid == Self.pid ? ProcessScannerTests.buffer(self.stage) : nil
        },
        readPath: { pid in
          log.notePath(pid)
          return pid == Self.pid ? self.stage.pidPath : nil
        },
        readEntries: { self.entries() })
    }
  }

  static func buffer(_ stage: Stage) -> [UInt8] {
    let argc = withUnsafeBytes(of: Int32(stage.arguments.count).littleEndian) { Array($0) }
    let strings = [stage.execPath, ""] + stage.arguments + ["", "TERM=xterm-256color"]
    return argc + strings.flatMap { Array($0.utf8) + [0] }
  }

  static let shim = Stage(
    comm: "bash", execPath: "/bin/bash", arguments: ["bash", "/Users/dev/.terminal/bin/claude"],
    pidPath: "/bin/bash")
  static let wrapper = Stage(
    comm: "bash", execPath: "/bin/bash", arguments: ["bash", "/Users/dev/.terminal/bin/claude-wrapper"],
    pidPath: "/bin/bash")
  static let claude = Stage(
    comm: "2.1.302", execPath: "/Users/dev/.local/bin/claude", arguments: ["/Users/dev/.local/bin/claude"],
    pidPath: "/Users/dev/.local/share/claude/versions/2.1.302")

  @Test func aClaudeSessionStartedThroughAnExecWrapperIsRecognisedAfterTheExec() throws {
    let staged = StagedProcess([Self.shim, Self.wrapper, Self.claude])
    let scanner = staged.scanner(ReadLog())
    let detector = ClaudeCodeDetector(userID: StagedProcess.userID)
    var verdicts: [Bool] = []
    var starts: [Int] = []
    for _ in 0..<3 {
      let records = scanner.sample()
      let record = try #require(records.first { $0.pid == StagedProcess.pid })
      verdicts.append(ClaudeCodeDetector.isClaude(record))
      starts.append(detector.signals(from: records).terminalAgentStarts.count)
      staged.advance()
    }
    #expect(verdicts == [false, false, true])
    #expect(starts == [0, 0, 1])
    let last = try #require(scanner.sample().first { $0.pid == StagedProcess.pid })
    #expect(last.argv0 == "/Users/dev/.local/bin/claude")
    #expect(last.pidPath == "/Users/dev/.local/share/claude/versions/2.1.302")
  }

  @Test func anExecIsReadOnceAndThenServedFromTheCache() {
    let staged = StagedProcess([Self.shim, Self.wrapper, Self.claude, Self.claude])
    let log = ReadLog()
    let scanner = staged.scanner(log)
    var argReads: [Int] = []
    var pathReads: [Int] = []
    for _ in 0..<4 {
      let (args, paths) = (log.args.count, log.paths.count)
      _ = scanner.sample()
      argReads.append(log.args.count - args)
      pathReads.append(log.paths.count - paths)
      staged.advance()
    }
    #expect(argReads == [1, 0, 1, 0])
    #expect(pathReads == [1, 0, 1, 0])
  }

  @Test func aRestartedPidWithTheSameNameIsStillReadAgain() {
    var restarted = Self.claude
    restarted.startSeconds += 60
    let staged = StagedProcess([Self.claude, Self.claude, restarted])
    let log = ReadLog()
    let scanner = staged.scanner(log)
    var argReads: [Int] = []
    for _ in 0..<3 {
      let before = log.args.count
      _ = scanner.sample()
      argReads.append(log.args.count - before)
      staged.advance()
    }
    #expect(argReads == [1, 0, 1])
  }
}
