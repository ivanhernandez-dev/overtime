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

  static func candidates(of records: [ProcessRecord], extra: Set<Int32>, now: Instant) -> Set<Int32> {
    var candidates = extra
    for record in records {
      if record.ttyDevice != ProcessRecord.noDevice || record.comm == ProcessScanner.amphetamineComm {
        candidates.insert(record.pid)
      }
      if record.comm == "caffeinate" {
        candidates.insert(record.pid)
        candidates.insert(record.ppid)
      }
      if ClaudeCodeDetector.toolShellNames.contains(record.comm), !record.hasControllingTerminal,
        record.processGroup == record.pid, !record.zombie, record.ppid > 1, let start = record.startMono,
        now.seconds(since: start) >= Timing.backgroundCommandMinimumAgeSeconds
      {
        candidates.insert(record.pid)
        candidates.insert(record.ppid)
      }
      if !record.hasControllingTerminal, ClaudeCodeDetector.looksLikeClaude(comm: record.comm) {
        candidates.insert(record.pid)
      }
    }
    return candidates.intersection(records.map(\.pid))
  }

  @Test func argvIsReadOnlyForCandidatePids() {
    let log = ReadLog()
    let scanner = Self.countingScanner(log)
    let clock = FakeClock(mono: SystemClock().mono(), wall: Date())
    let records = scanner.sample(clock: clock, extraCandidates: [getpid()])
    let pids = Set(records.map(\.pid))
    let candidates = Self.candidates(of: records, extra: [getpid()], now: clock.mono())
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
    let clock = FakeClock(mono: SystemClock().mono(), wall: Date())
    let records = scanner.sample(clock: clock, extraCandidates: [getpid()])
    let againArgs = Set(log.args.dropFirst(firstArgs.count))
    let againPaths = Set(log.paths.dropFirst(firstPaths.count))
    #expect(!againArgs.contains(getpid()))
    #expect(!againPaths.contains(getpid()))
    #expect(againArgs.isDisjoint(with: firstArgs))
    #expect(againPaths.isDisjoint(with: firstPaths))
    #expect(againArgs.isSubset(of: Self.candidates(of: records, extra: [getpid()], now: clock.mono())))
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
          startSeconds: stage.startSeconds, startMicroseconds: 250_000, pgid: Self.pid, status: 0)
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

  struct Row: Sendable {
    var pid: Int32
    var ppid: Int32
    var comm: String
    var tty: UInt32 = ProcessRecord.noDevice
    var pgid: Int32? = nil
    var status: UInt32 = 0
    var age: Double = 600
    var argv: [String]? = nil
    var uid: UInt32 = Table.userID
  }

  final class Table: Sendable {
    static let userID: UInt32 = 501
    static let terminal: UInt32 = 0x1000_0004
    static let secondTerminal: UInt32 = 0x1000_0008
    static let baseWall: Double = 1_792_000_000

    let rows: [Row]
    let clock = FakeClock(
      mono: Instant(nanoseconds: 1_000_000_000_000_000), wall: Date(timeIntervalSince1970: Table.baseWall))
    let log = ReadLog()

    init(_ rows: [Row]) {
      self.rows = rows
    }

    func entries() -> [ProcessScanner.Entry] {
      rows.map { row in
        let start = Self.baseWall - row.age
        let seconds = start.rounded(.down)
        return ProcessScanner.Entry(
          pid: row.pid, ppid: row.ppid, uid: row.uid, comm: row.comm, ttyDevice: row.tty,
          startSeconds: UInt64(seconds), startMicroseconds: UInt64(((start - seconds) * 1_000_000).rounded()),
          pgid: row.pgid ?? row.pid, status: row.status)
      }
    }

    func row(_ pid: Int32) -> Row? {
      rows.first { $0.pid == pid }
    }

    var scanner: ProcessScanner {
      ProcessScanner(
        userID: Self.userID,
        readArgs: { pid in
          self.log.noteArgs(pid)
          return self.row(pid)?.argv.map(ProcessScannerTests.buffer(argv:))
        },
        readPath: { pid in
          self.log.notePath(pid)
          return self.row(pid)?.argv?.first
        },
        readEntries: { self.entries() })
    }
  }

  static func buffer(argv: [String]) -> [UInt8] {
    buffer(Stage(comm: "", execPath: argv.first ?? "", arguments: argv, pidPath: argv.first ?? ""))
  }

  static let claudePath = "/Users/dev/.local/bin/claude"
  static let toolCommand =
    "source /Users/dev/.claude/shell-snapshots/snapshot-zsh-0-test.sh 2>/dev/null || true && eval 'npm test' && "
    + "pwd -P >| /tmp/claude-1a2b-cwd"

  static func claudeRow(pid: Int32 = 4100, tty: UInt32 = Table.terminal, comm: String = "2.1.308") -> Row {
    Row(pid: pid, ppid: 90, comm: comm, tty: tty, age: 3600, argv: [claudePath])
  }

  static func shellRow(pid: Int32 = 4200, parent: Int32 = 4100, comm: String = "zsh", age: Double = 40) -> Row {
    Row(pid: pid, ppid: parent, comm: comm, age: age, argv: ["/bin/" + comm, "-c", toolCommand])
  }

  @Test func anAgedToolShellAndItsClaudeParentAreReadOnce() throws {
    let table = Table([Self.claudeRow(), Self.shellRow(age: 40)])
    let scanner = table.scanner
    let records = scanner.sample(clock: table.clock)
    #expect(table.log.args.sorted() == [4100, 4200])
    #expect(table.log.paths.sorted() == [4100, 4200])
    let shell = try #require(records.first { $0.pid == 4200 })
    #expect(shell.claudeToolCommand)
    #expect(!shell.printMode)
    #expect(shell.processGroup == 4200)
    #expect(shell.argv0 == "/bin/zsh")
    #expect(shell.argv1 == "-c")
    _ = scanner.sample(clock: table.clock)
    _ = scanner.sample(clock: table.clock)
    #expect(table.log.args.count == 2)
    #expect(table.log.paths.count == 2)
  }

  @Test func aShellIsReadOnlyOnceItIsThirtySecondsOld() {
    let table = Table([Self.claudeRow(), Self.shellRow(age: 29)])
    let scanner = table.scanner
    _ = scanner.sample(clock: table.clock)
    #expect(table.log.args == [4100])
    table.clock.advance(seconds: 2)
    let records = scanner.sample(clock: table.clock)
    #expect(table.log.args == [4100, 4200])
    #expect(records.first { $0.pid == 4200 }?.claudeToolCommand == true)
  }

  @Test(arguments: ["2.1.308", "claude"])
  func aClaudeLookingProcessWithoutATerminalIsReadOnce(comm: String) throws {
    let table = Table([Row(pid: 6100, ppid: 1, comm: comm, age: 120, argv: [Self.claudePath, "-p", "review"])])
    let scanner = table.scanner
    let records = scanner.sample(clock: table.clock)
    _ = scanner.sample(clock: table.clock)
    #expect(table.log.args == [6100])
    let run = try #require(records.first)
    #expect(run.printMode)
    #expect(!run.claudeToolCommand)
    #expect(ClaudeCodeDetector.isClaude(run))
  }

  @Test func aTerminalLessParentOfAToolShellIsRead() throws {
    let parent = Row(pid: 5100, ppid: 1, comm: "node", age: 3600, argv: ["node", "/Users/dev/.npm/bin/claude"])
    let table = Table([parent, Self.shellRow(pid: 5200, parent: 5100)])
    let records = table.scanner.sample(clock: table.clock)
    #expect(table.log.args.sorted() == [5100, 5200])
    let read = try #require(records.first { $0.pid == 5100 })
    #expect(ClaudeCodeDetector.isClaude(read))
    let work = ClaudeCodeDetector(userID: Table.userID).longRunningWork(in: records, now: table.clock.mono())
    #expect(work.waitingSessionPIDs == [5100])
  }

  @Test func theRecordsCarryTheProcessGroupAndZombieState() throws {
    let table = Table([
      Self.claudeRow(),
      Row(pid: 4300, ppid: 4100, comm: "node", tty: Table.terminal, pgid: 4100),
      Row(pid: 4400, ppid: 90, comm: "Python", pgid: 4390),
      Row(pid: 4500, ppid: 4100, comm: "zsh", status: ProcessScanner.zombieStatus),
    ])
    let records = table.scanner.sample(clock: table.clock)
    #expect(records.count == 4)
    for record in records {
      let row = try #require(table.row(record.pid))
      #expect(record.processGroup == (row.pgid ?? row.pid))
      #expect(record.zombie == (record.pid == 4500))
    }
  }

  @Test func theZombieStatusIsTheKernels() {
    #expect(ProcessScanner.zombieStatus == 5)
  }

  static let spikeTable = [
    claudeRow(),
    shellRow(age: 300),
    Row(pid: 4201, ppid: 4100, comm: "bash", age: 1, argv: ["bash", "/Users/dev/.claude/hooks/statusline.sh"]),
    Row(pid: 4300, ppid: 4100, comm: "node", tty: Table.terminal, pgid: 4100, argv: ["node", "/opt/mcp/server.js"]),
    Row(
      pid: 4301, ppid: 4100, comm: "python3.13", tty: Table.terminal, pgid: 4100,
      argv: ["python3.13", "/opt/mcp/server.py"]),
    Row(pid: 4302, ppid: 4100, comm: "caffeinate", tty: Table.terminal, pgid: 4100, argv: ["caffeinate", "-i"]),
    Row(
      pid: 6100, ppid: 6000, comm: "2.1.308", tty: Table.secondTerminal, age: 120,
      argv: [claudePath, "--session-id", "x", "-p", "--model", "m"]),
  ]

  @Test func theScannedFlagsReachTheDetector() {
    let table = Table(Self.spikeTable)
    let records = table.scanner.sample(clock: table.clock)
    let work = ClaudeCodeDetector(userID: Table.userID).longRunningWork(in: records, now: table.clock.mono())
    #expect(work.waitingSessionPIDs == [4100])
    #expect(Set(work.printRunStarts.keys) == [6100])
    #expect(!table.log.args.contains(4201))
  }

  enum ShellCase: String, CaseIterable, Sendable {
    case withATerminal
    case inItsParentsGroup
    case orphaned
    case zombie
    case sh
    case fish
    case python
  }

  @Test(arguments: ShellCase.allCases)
  func shellsThatCannotBeToolCommandsAreNeverRead(shellCase: ShellCase) {
    var shell = Self.shellRow(pid: 4200, age: 120)
    switch shellCase {
    case .withATerminal: shell.tty = Table.terminal
    case .inItsParentsGroup: shell.pgid = 4100
    case .orphaned: shell.ppid = 1
    case .zombie: shell.status = ProcessScanner.zombieStatus
    case .sh: shell.comm = "sh"
    case .fish: shell.comm = "fish"
    case .python: shell.comm = "Python"
    }
    let table = Table([Self.claudeRow(), shell])
    let records = table.scanner.sample(clock: table.clock)
    let work = ClaudeCodeDetector(userID: Table.userID).longRunningWork(in: records, now: table.clock.mono())
    #expect(work.waitingSessionPIDs.isEmpty)
    if shellCase == .withATerminal {
      #expect(table.log.args.filter { $0 == 4200 }.count == 1)
    } else {
      #expect(!table.log.args.contains(4200))
      #expect(!table.log.paths.contains(4200))
    }
  }

  @Test(arguments: ["node", "bun", "Python", "2", "v2.1.3"])
  func otherTerminalLessProcessesAreNotRead(comm: String) {
    let table = Table([Row(pid: 7100, ppid: 1, comm: comm, argv: [comm, "/opt/web/server.js"])])
    let records = table.scanner.sample(clock: table.clock)
    #expect(records.count == 1)
    #expect(table.log.args.isEmpty)
    #expect(table.log.paths.isEmpty)
  }

  @Test func anotherUsersProcessesAreNeverRead() {
    var claude = Self.claudeRow()
    claude.uid = 502
    var shell = Self.shellRow()
    shell.uid = 502
    let table = Table([claude, shell])
    #expect(table.scanner.sample(clock: table.clock).isEmpty)
    #expect(table.log.args.isEmpty)
    #expect(table.log.paths.isEmpty)
  }

  @Test func theLiveTableMarksOnlyClaudeChildrenAsToolCommands() {
    let records = ProcessScanner(userID: getuid()).sample(clock: SystemClock())
    var byPID: [Int32: ProcessRecord] = [:]
    for record in records {
      byPID[record.pid] = record
    }
    let marked = records.filter(\.claudeToolCommand)
    print("marked tool-command records: \(marked.count)")
    for record in marked {
      guard record.ppid > 1, let parent = byPID[record.ppid] else { continue }
      #expect(ClaudeCodeDetector.isClaude(parent), "pid \(record.pid) ppid \(record.ppid) comm \(parent.comm)")
    }
  }
}
