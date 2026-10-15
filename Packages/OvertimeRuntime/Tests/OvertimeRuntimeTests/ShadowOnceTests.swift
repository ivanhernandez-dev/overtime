import Foundation
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing

struct ShadowOnceTests {
  struct Harness {
    let temp: TempDirectory
    let paths: Paths
    let logger: FileLogger
    let clock: FakeClock

    init() throws {
      temp = try TempDirectory()
      paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path], homeDirectory: "/Users/dev")
      try paths.createDirectories()
      logger = try FileLogger(decisionLog: paths.decisionLog(.shadow), errorLog: paths.errorLog(.shadow))
      clock = FakeClock(mono: Instant(nanoseconds: 5_000_000_000_000), wall: Date())
    }

    func engine(_ sources: EngineSources) -> Engine {
      Engine(
        mode: .shadow,
        settings: Settings(),
        clock: clock,
        interpreter: RecordingInterpreter(logger: logger, timeZone: TimeZone(secondsFromGMT: 0)!),
        sources: sources
      )
    }

    func logLines() throws -> [String] {
      try String(contentsOf: paths.decisionLog(.shadow), encoding: .utf8).split(separator: "\n").map(String.init)
    }

    func run(_ sources: EngineSources) async throws -> [String] {
      let engine = engine(sources)
      await engine.logLine(
        Decision(keyword: .start, verb: "shadow", fields: [DecisionField(key: "once", value: "true")]))
      await engine.runOnce()
      return try logLines()
    }
  }

  func wantLines(_ lines: [String]) -> [String] {
    lines.filter { $0.contains(" WANT ") }
  }

  func transcriptRoot(in harness: Harness, modifiedSecondsAgo age: Double) throws -> String {
    let root = harness.temp.url.appendingPathComponent("projects", isDirectory: true)
    let session = root.appendingPathComponent("-Users-dev-repo/subagents", isDirectory: true)
    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
    let file = session.appendingPathComponent("agent-1.jsonl")
    try Data("{}\n".utf8).write(to: file)
    try FileManager.default.setAttributes(
      [.modificationDate: harness.clock.wall().addingTimeInterval(-age)], ofItemAtPath: file.path(percentEncoded: false)
    )
    return root.path(percentEncoded: false)
  }

  @Test func injectedRecentActivityLogsStartThenWantOn() async throws {
    let harness = try Harness()
    let recent = harness.clock.mono().adding(seconds: -10)
    let lines = try await harness.run(
      EngineSources(
        transcriptSeed: { [TranscriptActivity(at: recent)] },
        sampleTick: { TickFacts() }
      ))
    #expect(lines.first?.contains(" START shadow once=true") == true)
    #expect(wantLines(lines).count == 1)
    #expect(wantLines(lines).first?.hasSuffix(" WANT on reason=busy") == true)
    let startIndex = lines.firstIndex { $0.contains(" START ") }
    let wantIndex = lines.firstIndex { $0.contains(" WANT ") }
    #expect(startIndex != nil && wantIndex != nil && startIndex! < wantIndex!)
  }

  @Test func realScannerWithAFreshTranscriptLogsWantOn() async throws {
    let harness = try Harness()
    let scanner = TranscriptScanner(roots: [try transcriptRoot(in: harness, modifiedSecondsAgo: 0)])
    let clock = harness.clock
    let lines = try await harness.run(
      EngineSources(
        transcriptSeed: { scanner.recentActivity(withinSeconds: 1800, clock: clock) },
        sampleTick: { TickFacts() }
      ))
    #expect(wantLines(lines).count == 1)
    #expect(wantLines(lines).first?.hasSuffix(" WANT on reason=busy") == true)
  }

  @Test func realScannerWithATenMinuteOldTranscriptLogsWantOff() async throws {
    let harness = try Harness()
    let scanner = TranscriptScanner(roots: [try transcriptRoot(in: harness, modifiedSecondsAgo: 600)])
    let clock = harness.clock
    #expect(scanner.recentActivity(withinSeconds: 1800, clock: clock).count == 1)
    let lines = try await harness.run(
      EngineSources(
        transcriptSeed: { scanner.recentActivity(withinSeconds: 1800, clock: clock) },
        sampleTick: { TickFacts() }
      ))
    #expect(wantLines(lines).count == 1)
    #expect(wantLines(lines).first?.hasSuffix(" WANT off reason=idle") == true)
  }

  @Test func scannerIgnoresMissingRootsAndNonTranscriptFiles() throws {
    let harness = try Harness()
    let root = try transcriptRoot(in: harness, modifiedSecondsAgo: 0)
    try Data("x".utf8).write(to: URL(fileURLWithPath: root).appendingPathComponent("notes.txt"))
    let scanner = TranscriptScanner(roots: [
      root, harness.temp.url.appendingPathComponent("missing").path(percentEncoded: false),
    ])
    #expect(scanner.recentActivity(withinSeconds: 120, clock: harness.clock).count == 1)
  }

  @Test func commandLineParsing() throws {
    #expect(try CommandLineOptions.parse([]) == CommandLineOptions(mode: .shadow, once: false))
    #expect(try CommandLineOptions.parse(["--shadow", "--once"]) == CommandLineOptions(mode: .shadow, once: true))
    #expect(try CommandLineOptions.parse(["--live"]) == CommandLineOptions(mode: .live, once: false))
    #expect(throws: CommandLineError.self) { try CommandLineOptions.parse(["--live", "--shadow"]) }
  }
}
