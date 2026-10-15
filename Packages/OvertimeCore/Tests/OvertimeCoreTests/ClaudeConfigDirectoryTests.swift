import Foundation
import Testing

@testable import OvertimeCore

struct ClaudeConfigDirectoryTests {
  let corpus = ClaudeProcessMatchingTests()

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

  func strings(_ list: [String]) -> [UInt8] {
    list.reduce(into: [UInt8]()) { result, string in
      result += Array(string.utf8) + [0]
    }
  }

  func claudeBuffer(argv: [String], environment: [String], apple: [String] = ["executable_cdhash=00ff"])
    -> [UInt8]
  {
    bytes(argc: Int32(argv.count), "/Users/dev/.local/bin/claude", padding: 7, argv) + strings(environment) + [0]
      + strings(apple)
  }

  func configDirectory(_ environment: [String]) -> String? {
    ProcArgsParser.parse(claudeBuffer(argv: ["claude"], environment: environment))?.claudeConfigDirectory
  }

  func record(_ base: ProcessRecord, _ directory: String?) -> ProcessRecord {
    var result = base
    result.claudeConfigDirectory = directory
    return result
  }

  @Test func theConfigDirectoryIsReadFromTheEnvironmentAfterTheArguments() throws {
    let buffer = claudeBuffer(
      argv: ["claude", "--resume", "x"],
      environment: ["PWD=/Users/dev/repo", "CLAUDE_CONFIG_DIR=/Users/dev/.claude-work", "TERM=xterm-256color"])
    let parsed = try #require(ProcArgsParser.parse(buffer))
    #expect(parsed.claudeConfigDirectory == "/Users/dev/.claude-work")
    #expect(parsed.argv0 == "claude")
    #expect(parsed.argv1 == "--resume")
    #expect(parsed.execPath == "/Users/dev/.local/bin/claude")
  }

  @Test func anArgumentThatLooksLikeTheVariableIsNotTheEnvironment() {
    let argv = ["claude", "CLAUDE_CONFIG_DIR=/decoy-1", "CLAUDE_CONFIG_DIR=/decoy-2"]
    let withEnvironment = ProcArgsParser.parse(claudeBuffer(argv: argv, environment: ["CLAUDE_CONFIG_DIR=/real"]))
    #expect(withEnvironment?.claudeConfigDirectory == "/real")
    #expect(withEnvironment?.argv1 == "CLAUDE_CONFIG_DIR=/decoy-1")

    let emptyEnvironment = ProcArgsParser.parse(claudeBuffer(argv: argv, environment: []))
    #expect(emptyEnvironment != nil)
    #expect(emptyEnvironment?.claudeConfigDirectory == nil)

    let endOfBuffer = ProcArgsParser.parse(bytes(argc: 3, "/Users/dev/.local/bin/claude", padding: 7, argv))
    #expect(endOfBuffer != nil)
    #expect(endOfBuffer?.claudeConfigDirectory == nil)
  }

  @Test func aBufferWithoutAnEnvironmentHasNoConfigDirectory() throws {
    let parsed = try #require(ProcArgsParser.parse(bytes(argc: 2, "/bin/sleep", padding: 2, ["sleep", "30"])))
    #expect(parsed.claudeConfigDirectory == nil)
    #expect(parsed.argv0 == "sleep")
    #expect(parsed.argv1 == "30")
  }

  @Test func anEmptyOversizedOrInvalidValueIsIgnored() {
    #expect(configDirectory(["CLAUDE_CONFIG_DIR="]) == nil)
    let oversized = "/" + String(repeating: "a", count: 1024)
    #expect(oversized.utf8.count == ProcArgsParser.maxConfigDirectoryBytes + 1)
    #expect(configDirectory(["CLAUDE_CONFIG_DIR=" + oversized]) == nil)
    let longest = "/" + String(repeating: "a", count: 1023)
    #expect(longest.utf8.count == ProcArgsParser.maxConfigDirectoryBytes)
    #expect(configDirectory(["CLAUDE_CONFIG_DIR=" + longest]) == longest)
    let invalid =
      bytes(argc: 1, "/Users/dev/.local/bin/claude", padding: 7, ["claude"]) + Array("CLAUDE_CONFIG_DIR=".utf8)
      + [0x2F, 0xFF, 0] + [0] + strings(["executable_cdhash=00ff"])
    let parsedInvalid = ProcArgsParser.parse(invalid)
    #expect(parsedInvalid != nil)
    #expect(parsedInvalid?.claudeConfigDirectory == nil)
  }

  @Test func theEnvironmentEndsAtTheFirstEmptyString() {
    let afterEnd = ProcArgsParser.parse(
      claudeBuffer(argv: ["claude"], environment: ["A=1"], apple: ["CLAUDE_CONFIG_DIR=/after"]))
    #expect(afterEnd != nil)
    #expect(afterEnd?.claudeConfigDirectory == nil)
    let beforeEnd = ProcArgsParser.parse(
      claudeBuffer(
        argv: ["claude"], environment: ["A=1", "CLAUDE_CONFIG_DIR=/before"], apple: ["CLAUDE_CONFIG_DIR=/after"]))
    #expect(beforeEnd?.claudeConfigDirectory == "/before")
  }

  @Test func anUnterminatedValueOrATruncatedArgumentListYieldsNothing() {
    let unterminated =
      bytes(argc: 1, "/Users/dev/.local/bin/claude", padding: 7, ["claude"]) + Array("CLAUDE_CONFIG_DIR=/x".utf8)
    let parsedUnterminated = ProcArgsParser.parse(unterminated)
    #expect(parsedUnterminated?.argv0 == "claude")
    #expect(parsedUnterminated?.claudeConfigDirectory == nil)

    let truncated =
      bytes(argc: 5, "/Users/dev/.local/bin/claude", padding: 7, ["claude", "--resume"])
      + strings(["CLAUDE_CONFIG_DIR=/x"])
    let parsedTruncated = ProcArgsParser.parse(truncated)
    #expect(parsedTruncated?.argv0 == "claude")
    #expect(parsedTruncated?.argv1 == "--resume")
    #expect(parsedTruncated?.claudeConfigDirectory == nil)
  }

  @Test func onlyTheExactVariableNameMatchesAndTheFirstOneWins() {
    let environment = [
      "XCLAUDE_CONFIG_DIR=/a", "CLAUDE_CONFIG_DIR_OLD=/b", "claude_config_dir=/c", "CLAUDE_CONFIG_DIR=/first",
      "CLAUDE_CONFIG_DIR=/second",
    ]
    #expect(configDirectory(environment) == "/first")
  }

  @Test func theArgumentFieldsAreUnchangedByTheEnvironment() {
    let parsed = ProcArgsParser.parse(
      bytes(
        argc: 3, "/Users/dev/.local/bin/claude", padding: 7,
        ["claude", "--resume", "--system-prompt=secret"]) + Array("PWD=/Users/dev/repo".utf8) + [0])
    #expect(parsed?.execPath == "/Users/dev/.local/bin/claude")
    #expect(parsed?.argv0 == "claude")
    #expect(parsed?.argv1 == "--resume")
    #expect(parsed?.claudeConfigDirectory == nil)
    #expect(
      parsed == ProcArgs(execPath: "/Users/dev/.local/bin/claude", argv0: "claude", argv1: "--resume"))
  }

  @Test func theParsedArgumentsKeepNoOtherEnvironmentValue() throws {
    let buffer = claudeBuffer(
      argv: ["claude"], environment: ["SECRET_TOKEN=s3cr3t-value", "CLAUDE_CONFIG_DIR=/cfg"])
    let parsed = try #require(ProcArgsParser.parse(buffer))
    let description = String(describing: parsed)
    #expect(!description.contains("s3cr3t-value"))
    #expect(!description.contains("SECRET_TOKEN"))
    let labels = Mirror(reflecting: parsed).children.compactMap(\.label)
    #expect(labels == ["execPath", "argv0", "argv1", "claudeConfigDirectory"])
  }

  @Test func onlyOwnClaudeProcessesContributeConfigDirectories() {
    let records = [
      record(corpus.claude(pid: 100), "/b"),
      record(corpus.claude(pid: 101, tty: ClaudeProcessMatchingTests.noDevice), "/a"),
      record(corpus.claude(pid: 102, tty: ClaudeProcessMatchingTests.ttyB), "/a"),
      record(corpus.claude(pid: 103, comm: "zsh", argv0: "zsh"), "/z"),
      record(corpus.claude(pid: 104, uid: ClaudeProcessMatchingTests.me + 1), "/o"),
      record(corpus.claude(pid: 105), nil),
    ]
    #expect(!ClaudeCodeDetector.isClaude(records[3]))
    let signals = ClaudeCodeDetector(userID: ClaudeProcessMatchingTests.me).signals(from: records)
    #expect(signals.claudeConfigDirectories == ["/a", "/b"])
  }

  @Test func mergedSignalsUniteTheConfigDirectories() {
    let merged = AgentSignals.merged([
      AgentSignals(claudeConfigDirectories: ["/b", "/a"]),
      AgentSignals(claudeConfigDirectories: ["/a", "/c"]),
    ])
    #expect(merged.claudeConfigDirectories == ["/a", "/b", "/c"])
  }
}
