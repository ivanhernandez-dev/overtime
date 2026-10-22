import Foundation
import Testing

@testable import OvertimeCore

struct LongRunningWorkTests {
  static let me: UInt32 = 501
  static let other: UInt32 = 502
  static let terminal: UInt32 = 0x1000_0004
  static let secondTerminal: UInt32 = 0x1000_0008
  static let noDevice = ProcessRecord.noDevice
  static let now = Instant(nanoseconds: 0).adding(seconds: 1_000_000)
  static let claudePath = "/Users/dev/.local/bin/claude"
  static let desktopPath =
    "/Applications/Claude.app/Contents/Resources/claude-code/2.1.281/claude.app/Contents/MacOS/claude"
  static let snapshot = "/Users/dev/.claude/shell-snapshots/snapshot-zsh-0-test.sh"
  static let readBack = "pwd -P >| /tmp/claude-1a2b-cwd"
  static let toolCommand = "source " + snapshot + " 2>/dev/null || true && eval 'npm test' && " + readBack

  let detector = ClaudeCodeDetector(userID: LongRunningWorkTests.me)

  static func started(_ age: Double) -> Instant {
    now.adding(seconds: -age)
  }

  static func buffer(_ argv: [String], execPath: String? = nil) -> [UInt8] {
    let argc = withUnsafeBytes(of: Int32(argv.count).littleEndian) { Array($0) }
    let strings = [execPath ?? argv.first ?? "", ""] + argv + ["", "TERM=xterm-256color"]
    return argc + strings.flatMap { Array($0.utf8) + [0] }
  }

  static func parsed(_ argv: [String]) throws -> ProcArgs {
    try #require(ProcArgsParser.parse(buffer(argv)))
  }

  static func flags(_ argv: [String]) -> ProcArgsFlags {
    ProcArgsParser.flags(buffer(argv))
  }

  static func claude(
    pid: Int32 = 4100,
    ppid: Int32 = 90,
    uid: UInt32 = me,
    tty: UInt32 = terminal,
    comm: String = "2.1.308",
    argv0: String? = claudePath,
    argv1: String? = nil,
    printMode: Bool = false,
    zombie: Bool = false,
    start: Instant? = started(3600)
  ) -> ProcessRecord {
    ProcessRecord(
      pid: pid, ppid: ppid, uid: uid, comm: comm, ttyDevice: tty, startMono: start, argv0: argv0, argv1: argv1,
      execPath: argv0, processGroup: pid, zombie: zombie, printMode: printMode)
  }

  static func record(
    pid: Int32,
    ppid: Int32,
    from argv: [String],
    uid: UInt32 = me,
    comm: String = "2.1.308",
    tty: UInt32 = terminal,
    start: Instant? = started(600)
  ) throws -> ProcessRecord {
    let args = try parsed(argv)
    let flags = Self.flags(argv)
    return ProcessRecord(
      pid: pid, ppid: ppid, uid: uid, comm: comm, ttyDevice: tty, startMono: start, argv0: args.argv0,
      argv1: args.argv1, execPath: args.execPath, claudeConfigDirectory: args.claudeConfigDirectory,
      processGroup: pid, printMode: flags.printMode, claudeToolCommand: flags.claudeToolCommand)
  }

  static func shell(
    pid: Int32 = 4200,
    parent: Int32 = 4100,
    age: Double = 40,
    uid: UInt32 = me,
    comm: String = "zsh",
    tty: UInt32 = noDevice,
    group: Int32? = nil,
    marked: Bool = true,
    zombie: Bool = false,
    hasStart: Bool = true
  ) -> ProcessRecord {
    ProcessRecord(
      pid: pid, ppid: parent, uid: uid, comm: comm, ttyDevice: tty, startMono: hasStart ? started(age) : nil,
      argv0: "/bin/" + comm, argv1: "-c", execPath: "/bin/" + comm, processGroup: group ?? pid, zombie: zombie,
      claudeToolCommand: marked)
  }

  static func child(
    pid: Int32, parent: Int32, comm: String, tty: UInt32 = terminal, group: Int32, argv0: String? = nil
  ) -> ProcessRecord {
    ProcessRecord(
      pid: pid, ppid: parent, uid: me, comm: comm, ttyDevice: tty, startMono: started(600), argv0: argv0 ?? comm,
      processGroup: group)
  }

  static func strings(in value: Any) -> [String] {
    if let text = value as? String {
      return [text]
    }
    return Mirror(reflecting: value).children.flatMap { strings(in: $0.value) }
  }

  @Test func aToolCommandCarriesTheSnapshotMarker() throws {
    let argv = ["/bin/zsh", "-c", Self.toolCommand]
    let args = try Self.parsed(argv)
    let flags = Self.flags(argv)
    #expect(flags.claudeToolCommand)
    #expect(!flags.printMode)
    #expect(args.argv0 == "/bin/zsh")
    #expect(args.argv1 == "-c")
  }

  @Test func aLoginShellFallbackIsRecognisedByTheWorkingFolderReadBack() {
    let flags = Self.flags(["/bin/bash", "-c", "-l", "eval 'make' && pwd -P >| /tmp/claude-9f-cwd"])
    #expect(flags.claudeToolCommand)
  }

  @Test func aSandboxedCommandIsRecognisedByTheWorkingFolderReadBack() {
    let flags = Self.flags(["/bin/zsh", "-c", "eval 'swift build' && pwd -P >| /private/tmp/sandbox/cwd-9f"])
    #expect(flags.claudeToolCommand)
  }

  @Test func aPrefixedCommandStillCarriesTheMarkers() throws {
    let command =
      "/usr/local/bin/wrap 'source " + Self.snapshot
      + " 2>/dev/null || true && eval '\\''ls'\\'' && pwd -P >| /tmp/claude-1-cwd'"
    #expect(Self.flags(["/bin/zsh", "-c", command]).claudeToolCommand)
  }

  @Test(arguments: [
    (["-p"], true),
    (["--print"], true),
    (["--print=text"], true),
    (["--session-id", "x", "--settings", "s.json", "-p", "--model", "m"], true),
    (["--", "-p"], false),
    (["--output-format", "stream-json", "--verbose", "--input-format", "stream-json"], false),
    (["--chrome-native-host"], false),
    (["--resume"], false),
    (["--system-prompt=use -p to print"], false),
    (["-pc"], false),
    ([], false),
  ])
  func printModeIsReadFromTheArguments(arguments: [String], expected: Bool) throws {
    let argv = [Self.claudePath] + arguments
    _ = try Self.parsed(argv)
    let flags = Self.flags(argv)
    #expect(flags.printMode == expected)
    #expect(!flags.claudeToolCommand)
  }

  @Test func aHookCommandIsNotAToolCommand() {
    #expect(!Self.flags(["/bin/sh", "-c", "/Users/dev/.claude/hooks/statusline.sh"]).claudeToolCommand)
    #expect(!Self.flags(["bash", "/Users/dev/.claude/hooks/statusline.sh"]).claudeToolCommand)
    #expect(Self.flags([]) == .none)
    #expect(ProcArgsParser.flags([1, 0, 0]) == .none)
  }

  @Test func theCommandTextIsNeverKept() throws {
    let command = "source " + Self.snapshot + " 2>/dev/null || true && eval 'TOKEN=abc123 npm test' && " + Self.readBack
    let argv = ["/bin/zsh", "-c", command]
    let args = try Self.parsed(argv)
    let flags = Self.flags(argv)
    let record = ProcessRecord(
      pid: 4200, ppid: 4100, uid: Self.me, comm: "zsh", startMono: Self.started(40), argv0: args.argv0,
      argv1: args.argv1, execPath: args.execPath, claudeConfigDirectory: args.claudeConfigDirectory,
      processGroup: 4200, printMode: flags.printMode, claudeToolCommand: flags.claudeToolCommand)
    let kept = Self.strings(in: args) + Self.strings(in: flags) + Self.strings(in: record)
    #expect(!kept.isEmpty)
    #expect(kept.allSatisfy { !$0.contains("TOKEN") })
    #expect(kept.allSatisfy { !$0.contains("npm test") })
  }

  @Test func theSpikesToolShellMakesItsSessionWaiting() {
    let records = [
      Self.claude(),
      Self.shell(age: 40),
      Self.child(pid: 4300, parent: 4100, comm: "caffeinate", group: 4100),
      Self.child(pid: 4301, parent: 4100, comm: "node", group: 4100),
      Self.child(pid: 4302, parent: 4100, comm: "python3.13", group: 4100),
      Self.shell(pid: 4303, age: 120, comm: "bash", marked: false),
    ]
    let work = detector.longRunningWork(in: records, now: Self.now)
    #expect(work.waitingSessionPIDs == [4100])
    #expect(work.printRunStarts.isEmpty)
  }

  @Test(arguments: [0, 29.9, 30, 3600, 21600])
  func aCommandCountsFromThirtySeconds(age: Double) {
    let work = detector.longRunningWork(in: [Self.claude(), Self.shell(age: age)], now: Self.now)
    #expect(work.waitingSessionPIDs == (age >= 30 ? [4100] : []))
  }

  @Test func aTerminalLessSessionsCommandCounts() {
    let desktop = Self.claude(tty: Self.noDevice, argv0: Self.desktopPath)
    let headless = Self.claude(pid: 5100, tty: Self.noDevice)
    let records = [desktop, Self.shell(age: 31), headless, Self.shell(pid: 5200, parent: 5100, age: 31)]
    #expect(detector.longRunningWork(in: records, now: Self.now).waitingSessionPIDs == [4100, 5100])
  }

  @Test func twoCommandsOfOneSessionAreOneWaitingSession() {
    let one = [Self.claude(), Self.shell(pid: 4200), Self.shell(pid: 4201, comm: "bash")]
    #expect(detector.longRunningWork(in: one, now: Self.now).waitingSessionPIDs == [4100])
    let two = one + [Self.claude(pid: 5100), Self.shell(pid: 5200, parent: 5100)]
    #expect(detector.longRunningWork(in: two, now: Self.now).waitingSessionPIDs == [4100, 5100])
  }

  @Test func aClaudePrintRunIsListedWithItsStart() throws {
    let argv = [Self.claudePath, "--session-id", "x", "-p", "--model", "m"]
    let withTerminal = try Self.record(pid: 6100, ppid: 6000, from: argv, start: Self.started(120))
    let fromLaunchd = try Self.record(
      pid: 6200, ppid: 1, from: [Self.claudePath, "-p", "review"], tty: Self.noDevice, start: Self.started(45))
    let work = detector.longRunningWork(in: [withTerminal, fromLaunchd], now: Self.now)
    #expect(work.printRunStarts == [6100: Self.started(120), 6200: Self.started(45)])
    #expect(work.waitingSessionPIDs.isEmpty)
  }

  @Test func aNestedPrintRunAndItsWaitingParentAreBothSeen() throws {
    let printRun = try Self.record(
      pid: 4400, ppid: 4300, from: [Self.claudePath, "--session-id", "x", "-p", "--model", "m"],
      tty: Self.secondTerminal)
    let records = [
      Self.claude(),
      Self.shell(age: 300),
      Self.child(pid: 4300, parent: 4200, comm: "Python", tty: Self.noDevice, group: 4200),
      printRun,
      Self.child(pid: 4500, parent: 4400, comm: "node", tty: Self.secondTerminal, group: 4400),
    ]
    let work = detector.longRunningWork(in: records, now: Self.now)
    #expect(work.waitingSessionPIDs == [4100])
    #expect(Set(work.printRunStarts.keys) == [4400])
  }

  @Test func aPrintRunIsNotASilentTerminalSession() throws {
    let interactive = Self.claude(start: Self.started(3600))
    let printRun = try Self.record(pid: 6100, ppid: 6000, from: [Self.claudePath, "-p"], start: Self.started(60))
    let signals = detector.signals(from: [interactive, printRun])
    #expect(signals.terminalAgentStarts == [Self.started(3600)])
  }

  @Test(arguments: [
    ("claude", true),
    ("2.1.308", true),
    ("10.0.1", true),
    ("node", false),
    ("bash", false),
    ("2", false),
    ("v2.1.3", false),
    ("1.2.3-beta", false),
    ("2.1.", false),
    ("", false),
  ])
  func looksLikeClaudeAcceptsTheInstalledNames(comm: String, expected: Bool) {
    #expect(ClaudeCodeDetector.looksLikeClaude(comm: comm) == expected)
  }

  @Test func aHookNeverCounts() {
    let records = [Self.claude(), Self.shell(age: 120, comm: "bash", marked: false)]
    #expect(detector.longRunningWork(in: records, now: Self.now).waitingSessionPIDs.isEmpty)
  }

  @Test func anMCPServerOrTheSnapshotShellNeverCounts() {
    let records = [
      Self.claude(),
      Self.shell(pid: 4200, age: 60, group: 4100),
      Self.shell(pid: 4201, age: 60, tty: Self.terminal, group: 4100),
      Self.child(pid: 4300, parent: 4100, comm: "node", group: 4100),
    ]
    #expect(detector.longRunningWork(in: records, now: Self.now).waitingSessionPIDs.isEmpty)
  }

  @Test func aShellWithATerminalNeverCounts() {
    let records = [Self.claude(), Self.shell(age: 60, tty: Self.terminal)]
    #expect(detector.longRunningWork(in: records, now: Self.now).waitingSessionPIDs.isEmpty)
  }

  @Test func aNonShellChildNeverCounts() {
    let records = [Self.claude(), Self.shell(age: 60, comm: "python3.13")]
    #expect(detector.longRunningWork(in: records, now: Self.now).waitingSessionPIDs.isEmpty)
  }

  @Test func anOrphanedShellNoLongerCounts() {
    let orphan = [Self.claude(), Self.shell(parent: 1, age: 600)]
    #expect(detector.longRunningWork(in: orphan, now: Self.now).waitingSessionPIDs.isEmpty)
    let missingParent = [Self.claude(), Self.shell(parent: 9999, age: 600)]
    #expect(detector.longRunningWork(in: missingParent, now: Self.now).waitingSessionPIDs.isEmpty)
  }

  @Test func aShellOfANonClaudeParentNeverCounts() {
    let loginShell = Self.child(pid: 4100, parent: 90, comm: "zsh", group: 4100, argv0: "-zsh")
    #expect(detector.longRunningWork(in: [loginShell, Self.shell()], now: Self.now).waitingSessionPIDs.isEmpty)
    let terminalApp = Self.child(
      pid: 4100, parent: 1, comm: "Terminal", tty: Self.noDevice, group: 4100,
      argv0: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")
    #expect(detector.longRunningWork(in: [terminalApp, Self.shell()], now: Self.now).waitingSessionPIDs.isEmpty)
  }

  @Test func anotherUsersShellOrParentNeverCounts() {
    let otherShell = [Self.claude(), Self.shell(uid: Self.other)]
    #expect(detector.longRunningWork(in: otherShell, now: Self.now).waitingSessionPIDs.isEmpty)
    let otherSession = [Self.claude(uid: Self.other), Self.shell(uid: Self.other)]
    #expect(detector.longRunningWork(in: otherSession, now: Self.now).waitingSessionPIDs.isEmpty)
  }

  @Test func aZombieShellOrParentNeverCounts() {
    let zombieShell = [Self.claude(), Self.shell(zombie: true)]
    #expect(detector.longRunningWork(in: zombieShell, now: Self.now).waitingSessionPIDs.isEmpty)
    let zombieParent = [Self.claude(zombie: true), Self.shell()]
    #expect(detector.longRunningWork(in: zombieParent, now: Self.now).waitingSessionPIDs.isEmpty)
  }

  @Test func anUnreadableParentNeverCounts() {
    let unreadable = ProcessRecord(
      pid: 4100, ppid: 90, uid: Self.me, comm: "2.1.308", ttyDevice: Self.terminal, startMono: Self.started(600),
      processGroup: 4100)
    #expect(detector.longRunningWork(in: [unreadable, Self.shell()], now: Self.now).waitingSessionPIDs.isEmpty)
  }

  @Test func aCommandWithoutAStartNeverCounts() {
    let records = [Self.claude(), Self.shell(hasStart: false)]
    #expect(detector.longRunningWork(in: records, now: Self.now).waitingSessionPIDs.isEmpty)
  }

  @Test func streamJsonHostsAreNotPrintRuns() throws {
    let shapes = [
      [Self.claudePath, "--output-format", "stream-json", "--verbose", "--input-format", "stream-json"],
      [Self.desktopPath, "--output-format", "stream-json", "--verbose", "--input-format", "stream-json"],
      [Self.claudePath, "--chrome-native-host"],
      [Self.claudePath, "--resume"],
    ]
    var records: [ProcessRecord] = []
    for (index, argv) in shapes.enumerated() {
      records.append(try Self.record(pid: 7000 + Int32(index), ppid: 1, from: argv, tty: Self.noDevice))
    }
    #expect(records.allSatisfy(ClaudeCodeDetector.isClaude))
    #expect(detector.longRunningWork(in: records, now: Self.now).printRunStarts.isEmpty)
  }

  @Test func aPrintFlagOnAProcessThatIsNotClaudeDoesNotCount() {
    let server = ProcessRecord(
      pid: 7100, ppid: 1, uid: Self.me, comm: "node", startMono: Self.started(600), argv0: "node",
      argv1: "/opt/web/server.js", execPath: "/usr/local/bin/node", processGroup: 7100, printMode: true)
    #expect(detector.longRunningWork(in: [server], now: Self.now).printRunStarts.isEmpty)
  }

  @Test func aPrintRunWithoutAStartIsNotCounted() {
    let run = Self.claude(pid: 6100, printMode: true, start: nil)
    #expect(detector.longRunningWork(in: [run], now: Self.now).printRunStarts.isEmpty)
  }

  @Test func theWindowsAreThirtyAndSixSeconds() {
    #expect(Timing.backgroundCommandMinimumAgeSeconds == 30)
    #expect(Timing.sessionWaitingGraceSeconds == 6)
  }
}
