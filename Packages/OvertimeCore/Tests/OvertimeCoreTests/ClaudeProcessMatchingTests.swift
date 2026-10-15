import Foundation
import Testing

@testable import OvertimeCore

struct ClaudeProcessMatchingTests {
  static let me: UInt32 = 501
  static let ttyA: UInt32 = 0x1000_0005
  static let ttyB: UInt32 = 0x1000_0007
  static let noDevice: UInt32 = 0xFFFF_FFFF

  let detector = ClaudeCodeDetector(userID: ClaudeProcessMatchingTests.me)

  func claude(
    pid: Int32,
    ppid: Int32 = 90,
    uid: UInt32 = ClaudeProcessMatchingTests.me,
    tty: UInt32 = ClaudeProcessMatchingTests.ttyA,
    comm: String = "2.1.283",
    argv0: String? = "claude",
    argv1: String? = nil,
    execPath: String? = nil,
    pidPath: String? = nil,
    start: UInt64 = 1_000
  ) -> ProcessRecord {
    ProcessRecord(
      pid: pid, ppid: ppid, uid: uid, comm: comm, ttyDevice: tty, startMono: Instant(nanoseconds: start),
      argv0: argv0, argv1: argv1, execPath: execPath, pidPath: pidPath)
  }

  func caffeinate(
    pid: Int32,
    parent: Int32,
    uid: UInt32 = ClaudeProcessMatchingTests.me,
    tty: UInt32 = ClaudeProcessMatchingTests.ttyA,
    argv1: String? = "-i"
  ) -> ProcessRecord {
    ProcessRecord(
      pid: pid, ppid: parent, uid: uid, comm: "caffeinate", ttyDevice: tty, argv0: "caffeinate", argv1: argv1,
      execPath: "/usr/bin/caffeinate", pidPath: "/usr/bin/caffeinate")
  }

  @Test func corpusC01BareArgv0ClaudeOnATerminalWithCaffeinateIsBusy() {
    let signals = detector.signals(from: [claude(pid: 100), caffeinate(pid: 101, parent: 100)])
    #expect(signals.busyProcessCount == 1)
    #expect(signals.sessionCount == 1)
  }

  @Test func corpusC02NativeInstallPathsWithCaffeinateIsBusy() {
    let record = claude(
      pid: 100, argv0: "/Users/dev/.local/bin/claude", execPath: "/Users/dev/.local/bin/claude",
      pidPath: "/Users/dev/.local/share/claude/versions/2.1.283")
    #expect(ClaudeCodeDetector.isClaude(record))
    let signals = detector.signals(from: [record, caffeinate(pid: 101, parent: 100)])
    #expect(signals.busyProcessCount == 1)
  }

  @Test func corpusC03VersionedInstallPathAsArgv0IsClaude() {
    #expect(ClaudeCodeDetector.isClaude(claude(pid: 100, argv0: "/Users/dev/.local/share/claude/versions/2.1.300")))
    #expect(
      ClaudeCodeDetector.isClaude(
        claude(pid: 100, argv0: nil, pidPath: "/Users/dev/.local/share/claude/versions/2.1.300")))
    #expect(
      !ClaudeCodeDetector.isClaude(
        claude(pid: 100, argv0: nil, pidPath: "/Users/dev/.local/share/claude/versions/latest")))
    #expect(
      !ClaudeCodeDetector.isClaude(claude(pid: 100, argv0: nil, pidPath: "/Users/dev/.local/share/claude/versions/2")))
  }

  @Test func corpusC04NpmNodeRunningTheClaudeCodeCliIsClaude() {
    let record = claude(
      pid: 100, comm: "node", argv0: "node",
      argv1: "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js")
    #expect(ClaudeCodeDetector.isClaude(record))
  }

  @Test func corpusC05NpmBinShimUnderNodeOrBunIsClaude() {
    #expect(
      ClaudeCodeDetector.isClaude(claude(pid: 100, comm: "node", argv0: "node", argv1: "/opt/homebrew/bin/claude")))
    #expect(ClaudeCodeDetector.isClaude(claude(pid: 100, comm: "bun", argv0: "/opt/homebrew/bin/bun", argv1: "claude")))
    #expect(
      !ClaudeCodeDetector.isClaude(claude(pid: 100, comm: "node", argv0: "node", argv1: "/Users/dev/app/server.js")))
  }

  @Test func corpusC06TerminalLessClaudeWithCaffeinateIsNotBusy() {
    let host = claude(
      pid: 100, tty: ClaudeProcessMatchingTests.noDevice, argv0: "/Users/dev/.local/bin/claude",
      argv1: "--chrome-native-host")
    #expect(ClaudeCodeDetector.isClaude(host))
    #expect(!host.hasControllingTerminal)
    let signals = detector.signals(
      from: [host, caffeinate(pid: 101, parent: 100, tty: ClaudeProcessMatchingTests.noDevice)])
    #expect(signals.busyProcessCount == 0)
    #expect(signals.sessionCount == 0)
    #expect(signals.terminalAgentStarts.isEmpty)
  }

  @Test func corpusC07OrphanedCaffeinateIsNotBusy() {
    let signals = detector.signals(from: [claude(pid: 1), caffeinate(pid: 101, parent: 1)])
    #expect(signals.busyProcessCount == 0)
  }

  @Test func corpusC08WrapperParentOnAnotherTerminalStillCountsTheClaudeChild() {
    let wrapper = ProcessRecord(
      pid: 200, ppid: 90, uid: ClaudeProcessMatchingTests.me, comm: "python3.14",
      ttyDevice: ClaudeProcessMatchingTests.ttyA, argv0: "/Users/dev/.local/share/uv/tools/claude-swap/bin/python",
      execPath: "/Users/dev/.local/share/uv/tools/claude-swap/bin/python")
    let child = claude(pid: 201, ppid: 200, tty: ClaudeProcessMatchingTests.ttyB)
    let signals = detector.signals(
      from: [wrapper, child, caffeinate(pid: 202, parent: 201, tty: ClaudeProcessMatchingTests.ttyB)])
    #expect(!ClaudeCodeDetector.isClaude(wrapper))
    #expect(signals.busyProcessCount == 1)
    #expect(signals.sessionCount == 1)
  }

  @Test func corpusC09KernelNameClaudeWithAPythonArgv0IsNotClaude() {
    let record = claude(pid: 100, comm: "claude", argv0: "/usr/bin/python3", execPath: "/usr/bin/python3")
    #expect(!ClaudeCodeDetector.isClaude(record))
    #expect(detector.signals(from: [record, caffeinate(pid: 101, parent: 100)]).busyProcessCount == 0)
  }

  @Test func corpusC10UsersOwnCaffeinateUnderZshIsNotBusy() {
    let shell = ProcessRecord(
      pid: 300, ppid: 90, uid: ClaudeProcessMatchingTests.me, comm: "zsh", ttyDevice: ClaudeProcessMatchingTests.ttyA,
      argv0: "-zsh", execPath: "/bin/zsh")
    let signals = detector.signals(from: [shell, caffeinate(pid: 301, parent: 300, argv1: "-d")])
    #expect(signals.busyProcessCount == 0)
  }

  @Test func corpusC11ClaudeWithOnlyNonCaffeinateChildrenIsNotBusy() {
    let server = ProcessRecord(
      pid: 101, ppid: 100, uid: ClaudeProcessMatchingTests.me, comm: "node", ttyDevice: ClaudeProcessMatchingTests.ttyA,
      argv0: "node", argv1: "server.js")
    let sleeper = ProcessRecord(
      pid: 102, ppid: 100, uid: ClaudeProcessMatchingTests.me, comm: "sleep",
      ttyDevice: ClaudeProcessMatchingTests.ttyA,
      argv0: "sleep", argv1: "600")
    let signals = detector.signals(from: [claude(pid: 100, start: 42), server, sleeper])
    #expect(signals.busyProcessCount == 0)
    #expect(signals.sessionCount == 0)
    #expect(signals.terminalAgentStarts == [Instant(nanoseconds: 42)])
  }

  @Test func corpusC12ABashScriptWhoseArgumentStartsWithClaudeIsNotClaude() {
    let record = ProcessRecord(
      pid: 400, ppid: 1, uid: ClaudeProcessMatchingTests.me, comm: "bash", argv0: "/bin/bash",
      argv1: "/Users/dev/.local/bin/claude-wrapper", execPath: "/bin/bash", pidPath: "/bin/bash")
    #expect(!ClaudeCodeDetector.isClaude(record))
  }

  @Test func corpusC13TheDesktopAppBinaryIsNotClaude() {
    let path = "/Applications/Claude.app/Contents/MacOS/Claude"
    let record = claude(
      pid: 500, tty: ClaudeProcessMatchingTests.noDevice, comm: "Claude", argv0: path, execPath: path, pidPath: path)
    #expect(!ClaudeCodeDetector.isClaude(record))
  }

  @Test func corpusC14TwoClaudeVersionsAtOnceAreTwoBusySessions() {
    let older = claude(
      pid: 100, comm: "2.1.282", argv0: "claude", pidPath: "/Users/dev/.local/share/claude/versions/2.1.282", start: 1)
    let newer = claude(
      pid: 200, tty: ClaudeProcessMatchingTests.ttyB, comm: "2.1.283", argv0: "/Users/dev/.local/bin/claude",
      pidPath: "/Users/dev/.local/share/claude/versions/2.1.283", start: 2)
    let signals = detector.signals(
      from: [
        older, newer, caffeinate(pid: 101, parent: 100),
        caffeinate(pid: 201, parent: 200, tty: ClaudeProcessMatchingTests.ttyB),
      ])
    #expect(signals.busyProcessCount == 2)
    #expect(signals.sessionCount == 2)
    #expect(Set(signals.terminalAgentStarts) == [Instant(nanoseconds: 1), Instant(nanoseconds: 2)])
  }

  @Test func corpusC15AnotherUsersCaffeinateIsIgnored() {
    let otherClaude = claude(pid: 100, uid: 502)
    let signals = detector.signals(
      from: [
        otherClaude, caffeinate(pid: 101, parent: 100, uid: 502), claude(pid: 200),
        caffeinate(pid: 201, parent: 200, uid: 502),
      ])
    #expect(signals.busyProcessCount == 0)
    #expect(signals.sessionCount == 0)
    #expect(signals.terminalAgentStarts == [Instant(nanoseconds: 1_000)])
  }

  @Test func corpusC16UnreadableArgvNeverFallsBackToTheKernelName() {
    let record = claude(pid: 100, comm: "2.1.283", argv0: nil, argv1: nil, execPath: nil, pidPath: nil)
    #expect(!ClaudeCodeDetector.isClaude(record))
    #expect(detector.signals(from: [record, caffeinate(pid: 101, parent: 100)]) == .none)
    #expect(detector.signals(from: []) == .none)
    #expect(detector.signals(from: [caffeinate(pid: 101, parent: 77)]) == .none)
    #expect(!ClaudeCodeDetector.isClaude(claude(pid: 100, argv0: "Claude")))
    #expect(!ClaudeCodeDetector.isClaude(claude(pid: 100, argv0: "")))
  }

  @Test func corpusC17ProcArgsParserIsBoundsCheckedAndSkipsPadding() {
    #expect(ProcArgsParser.parse([]) == nil)
    #expect(ProcArgsParser.parse([1, 0, 0]) == nil)
    #expect(ProcArgsParser.parse(bytes(argc: 0, "/bin/x", padding: 3, ["x"])) == nil)
    #expect(ProcArgsParser.parse(bytes(argc: -1, "/bin/x", padding: 3, ["x"])) == nil)
    #expect(ProcArgsParser.parse(littleEndian(1) + Array("/bin/x".utf8)) == nil)
    #expect(ProcArgsParser.parse(bytes(argc: 1, "/bin/x", padding: 5, [])) == nil)
    #expect(ProcArgsParser.parse(littleEndian(1) + Array("/bin/x".utf8) + [0, 0] + Array("x".utf8)) == nil)

    let parsed = ProcArgsParser.parse(
      bytes(
        argc: 3, "/Users/dev/.local/bin/claude", padding: 7,
        ["claude", "--resume", "--system-prompt=secret"]) + Array("PWD=/Users/dev/repo".utf8) + [0])
    #expect(
      parsed == ProcArgs(execPath: "/Users/dev/.local/bin/claude", argv0: "claude", argv1: "--resume"))

    let single = ProcArgsParser.parse(bytes(argc: 1, "/usr/bin/caffeinate", padding: 1, ["caffeinate"]))
    #expect(single == ProcArgs(execPath: "/usr/bin/caffeinate", argv0: "caffeinate", argv1: nil))

    let unterminatedSecond = ProcArgsParser.parse(
      littleEndian(2) + Array("/bin/x".utf8) + [0, 0] + Array("x".utf8) + [0] + Array("tail".utf8))
    #expect(unterminatedSecond == ProcArgs(execPath: "/bin/x", argv0: "x", argv1: nil))

    let invalidUTF8 = ProcArgsParser.parse(littleEndian(1) + [0x2F, 0xFF, 0] + [0] + Array("a".utf8) + [0])
    #expect(invalidUTF8?.argv0 == "a")
    #expect(invalidUTF8?.execPath == "/\u{FFFD}")
  }

  @Test func ttyDeviceIsComparedAsAnUnsignedBitPattern() {
    let almost = claude(pid: 100, tty: 0xFFFF_FFFE)
    let none = claude(pid: 200, tty: 0xFFFF_FFFF)
    #expect(almost.hasControllingTerminal)
    #expect(!none.hasControllingTerminal)
    #expect(ProcessRecord.noDevice == UInt32(bitPattern: -1))
    #expect(
      detector.signals(from: [almost, caffeinate(pid: 101, parent: 100, tty: 0xFFFF_FFFE)]).busyProcessCount == 1)
    #expect(detector.signals(from: [none, caffeinate(pid: 201, parent: 200)]).busyProcessCount == 0)
  }

  func littleEndian(_ value: Int32) -> [UInt8] {
    withUnsafeBytes(of: value.littleEndian) { Array($0) }
  }

  func bytes(argc: Int32, _ execPath: String, padding: Int, _ argv: [String]) -> [UInt8] {
    var result = littleEndian(argc) + Array(execPath.utf8) + [UInt8](repeating: 0, count: padding)
    for argument in argv {
      result += Array(argument.utf8) + [0]
    }
    return result
  }
}
