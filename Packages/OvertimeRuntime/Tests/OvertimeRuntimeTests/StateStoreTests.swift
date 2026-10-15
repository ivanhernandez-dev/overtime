import Foundation
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing

@Suite(.serialized)
struct StateStoreTests {
  static func mode(of url: URL) throws -> Int? {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
    return (attributes[.posixPermissions] as? NSNumber)?.intValue
  }

  static let populated = PersistedState(
    bootSessionUUID: "11111111-2222-3333-4444-555555555555",
    ownsHold: true,
    pause: PersistedPause(kind: PersistedPause.indefinite),
    releaseUntilIdle: true
  )

  @Test func aWrittenFileIsPrivateAndReadsBackEqual() throws {
    let temp = try TempDirectory()
    let url = temp.url.appendingPathComponent("shadow-state.json")
    try StateStore.write(Self.populated, to: url)
    #expect(try Self.mode(of: url) == 0o600)
    #expect(StateStore.read(at: url) == .state(Self.populated))
  }

  @Test func aSecondWriteReplacesTheFileWhole() throws {
    let temp = try TempDirectory()
    let url = temp.url.appendingPathComponent("shadow-state.json")
    try StateStore.write(Self.populated, to: url)
    try StateStore.write(PersistedState(), to: url)
    #expect(StateStore.read(at: url) == .state(PersistedState()))
    #expect(try Self.mode(of: url) == 0o600)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: temp.path)
    #expect(leftovers == ["shadow-state.json"])
  }

  @Test(arguments: [Data("[1,2]".utf8), Data(#"{"ownsHold": tr"#.utf8), Data([0xFF, 0x00, 0x13, 0x37, 0xC0])])
  func corruptContentReadsAsCorrupt(_ content: Data) throws {
    let temp = try TempDirectory()
    let url = temp.url.appendingPathComponent("state.json")
    try content.write(to: url)
    #expect(StateStore.read(at: url) == .corrupt)
  }

  @Test func aMissingFileReadsAsMissing() throws {
    let temp = try TempDirectory()
    #expect(StateStore.read(at: temp.url.appendingPathComponent("state.json")) == .missing)
  }

  @Test func aDirectoryInPlaceOfTheFileReadsAsCorrupt() throws {
    let temp = try TempDirectory()
    let url = temp.url.appendingPathComponent("state.json")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    #expect(StateStore.read(at: url) == .corrupt)
  }

  @Test func scenario16FromDiskExecutesNothing() throws {
    let temp = try TempDirectory()
    let marker = temp.url.appendingPathComponent("pwned").path(percentEncoded: false)
    let url = temp.url.appendingPathComponent("state.json")
    let text = #"{"ownsHold": true, "switchedToHotspot": "x", "evil": "$(touch "# + marker + #")"}"#
    try Data(text.utf8).write(to: url)
    #expect(StateStore.read(at: url) == .state(PersistedState(ownsHold: true)))
    #expect(!FileManager.default.fileExists(atPath: marker))
  }

  @Test func theBootSessionIsReadableAndStable() {
    let first = BootSession.current()
    #expect(first != nil)
    #expect(first?.isEmpty == false)
    #expect(first == BootSession.current())
  }

  @Test func theShadowInterpreterPersistsOnlyTheShadowStateFile() async throws {
    let temp = try TempDirectory()
    let paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path], homeDirectory: "/Users/dev")
    try paths.createDirectories()
    let logger = try FileLogger(decisionLog: paths.decisionLog(.shadow), errorLog: paths.errorLog(.shadow))
    let interpreter = RecordingInterpreter(logger: logger, timeZone: TimeZone(secondsFromGMT: 0)!, paths: paths)
    _ = await interpreter.perform([.persist(Self.populated)], wall: Date())
    #expect(StateStore.read(at: paths.stateFile(.shadow)) == .state(Self.populated))
    #expect(!FileManager.default.fileExists(atPath: paths.stateFile(.live).path(percentEncoded: false)))
    #expect(try Self.mode(of: paths.stateFile(.shadow)) == 0o600)
  }

  @Test func aFailedStateWriteIsLogged() async throws {
    let temp = try TempDirectory()
    let paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path], homeDirectory: "/Users/dev")
    try paths.createDirectories()
    try FileManager.default.createDirectory(at: paths.stateFile(.shadow), withIntermediateDirectories: false)
    let logger = try FileLogger(decisionLog: paths.decisionLog(.shadow), errorLog: paths.errorLog(.shadow))
    let interpreter = RecordingInterpreter(logger: logger, timeZone: TimeZone(secondsFromGMT: 0)!, paths: paths)
    _ = await interpreter.perform([.persist(Self.populated)], wall: Date())
    let log = try String(contentsOf: paths.decisionLog(.shadow), encoding: .utf8)
    #expect(log.contains(" ERROR state write failed"))
  }

  @Test func runOnceStartsFromThePersistedStateAndKeepsAnIndefinitePause() async throws {
    let temp = try TempDirectory()
    let paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path], homeDirectory: "/Users/dev")
    try paths.createDirectories()
    try StateStore.write(
      PersistedState(pause: PersistedPause(kind: PersistedPause.indefinite)), to: paths.stateFile(.shadow))
    let logger = try FileLogger(decisionLog: paths.decisionLog(.shadow), errorLog: paths.errorLog(.shadow))
    let engine = Engine(
      mode: .shadow,
      settings: Settings(),
      clock: FakeClock(),
      interpreter: RecordingInterpreter(logger: logger, timeZone: TimeZone(secondsFromGMT: 0)!, paths: paths),
      sources: EngineSources(
        transcriptSeed: { [] },
        sampleTick: { TickFacts() },
        launchFacts: { LaunchFacts(persisted: StateStore.read(at: paths.stateFile(.shadow)), bootSessionUUID: "boot") }
      )
    )
    await engine.runOnce()
    let log = try String(contentsOf: paths.decisionLog(.shadow), encoding: .utf8)
    #expect(log.contains(" WANT off reason=paused"))
    #expect(await engine.state.want.pause == .indefinite)
    guard case .state(let saved) = StateStore.read(at: paths.stateFile(.shadow)) else {
      Issue.record("state file not rewritten")
      return
    }
    #expect(saved.bootSessionUUID == "boot")
    #expect(saved.pause == PersistedPause(kind: PersistedPause.indefinite))
  }

  @Test func statusArgumentsParseWithoutStartingAnEngine() throws {
    #expect(try CommandLineOptions.parseInvocation(["--status"]) == .status(.shadow))
    #expect(try CommandLineOptions.parseInvocation(["--status", "--shadow"]) == .status(.shadow))
    #expect(try CommandLineOptions.parseInvocation(["--live", "--status"]) == .status(.live))
    #expect(throws: CommandLineError.self) { try CommandLineOptions.parseInvocation(["--status", "--once"]) }
  }

  @Test func theStatusReportDescribesEachSnapshot() {
    #expect(StatusReport.json(.missing) == #"{"state":"missing"}"#)
    #expect(StatusReport.json(.corrupt) == #"{"state":"corrupt"}"#)
    let report = StatusReport.json(.state(Self.populated))
    #expect(report.contains(#""kind":"indefinite""#))
    #expect(report.contains(#""ownsHold":true"#))
  }
}
