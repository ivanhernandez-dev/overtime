import Foundation
import OvertimeCore
import Testing

@testable import OvertimeEngine
@testable import OvertimeSystem

struct EngineLongRunningTests {
  typealias Row = ProcessScannerTests.Row
  typealias Table = ProcessScannerTests.Table

  static let interactive = ProcessScannerTests.claudeRow()

  static let spikeRows = [
    interactive,
    ProcessScannerTests.shellRow(age: 40),
    Row(pid: 4201, ppid: 4100, comm: "bash", age: 1, argv: ["bash", "/Users/dev/.claude/hooks/statusline.sh"]),
    Row(pid: 4300, ppid: 4100, comm: "node", tty: Table.terminal, pgid: 4100, argv: ["node", "/opt/mcp/server.js"]),
  ]

  static let reviewRows = [
    interactive,
    ProcessScannerTests.shellRow(age: 300),
    Row(pid: 4300, ppid: 4200, comm: "Python", pgid: 4200, argv: ["Python", "/opt/review/run.py"]),
    Row(
      pid: 4400, ppid: 4300, comm: "2.1.308", tty: Table.secondTerminal, age: 120,
      argv: [ProcessScannerTests.claudePath, "--session-id", "x", "-p", "--model", "m"]),
    Row(
      pid: 4500, ppid: 4400, comm: "node", tty: Table.secondTerminal, pgid: 4400, argv: ["node", "/opt/mcp/server.js"]),
  ]

  struct Outcome {
    var busyLines: [String]
    var sessions: [SessionSummary]
  }

  static func reduce(_ rows: [Row], settings: Settings = Settings()) -> Outcome {
    let table = Table(rows)
    let records = table.scanner.sample(clock: table.clock)
    let now = table.clock.mono()
    let claude = ClaudeCodeDetector(userID: Table.userID)
    let tick = Composition.tickAgents(from: records, detectors: [claude], claude: claude, now: now)
    let reader = SessionReader(readDirectory: { _ in "/Users/dev/alpha" }, readTerminal: { _ in "ttys004" })
    let sessions = reader.sessions(from: records, at: now, work: tick.work)
    var state = AppState(mode: .shadow)
    let effects = Reducer.reduce(
      &state, Stamped(mono: now, wall: table.clock.wall(), event: .tick(TickFacts(agents: tick.agents))), settings)
    let lines = effects.compactMap { effect -> String? in
      guard case .log(let decision) = effect, decision.keyword == .busy else { return nil }
      return ([decision.verb] + decision.fields.map { "\($0.key)=\($0.value)" }).joined(separator: " ")
    }
    return Outcome(busyLines: lines, sessions: sessions)
  }

  @Test func theSpikeShapeHoldsEndToEnd() throws {
    let outcome = Self.reduce(Self.spikeRows)
    #expect(outcome.busyLines == ["on source=background"])
    let session = try #require(outcome.sessions.first { $0.pid == 4100 })
    #expect(session.isWaiting)
    #expect(session.terminal)
    #expect(!session.printRun)
    #expect(outcome.sessions.count == 1)
  }

  @Test func aClaudePrintRunHoldsEndToEnd() {
    let outcome = Self.reduce(Self.reviewRows)
    #expect(outcome.busyLines == ["on source=print"])
    #expect(outcome.sessions.map(\.pid) == [4100, 4400])
    #expect(outcome.sessions.map(\.isWaiting) == [true, false])
    #expect(outcome.sessions.map(\.printRun) == [false, true])
    let noPrint = Settings(printRunsKeepAwake: false)
    #expect(Self.reduce(Self.reviewRows, settings: noPrint).busyLines == ["on source=background"])
  }

  static func turnsBusyOn(_ outcome: Outcome) -> Bool {
    outcome.busyLines.contains { $0.hasPrefix("on ") }
  }

  @Test func theSwitchesReleaseEndToEnd() {
    let noBackground = Settings(backgroundCommandsKeepAwake: false)
    let spike = Self.reduce(Self.spikeRows, settings: noBackground)
    #expect(spike.busyLines.count == 1)
    #expect(!Self.turnsBusyOn(spike))
    let neither = Settings(backgroundCommandsKeepAwake: false, printRunsKeepAwake: false)
    let review = Self.reduce(Self.reviewRows, settings: neither)
    #expect(review.busyLines.count == 1)
    #expect(!Self.turnsBusyOn(review))
  }

  @Test func aShellLeftByAnExitedSessionDoesNotHoldEndToEnd() {
    var orphan = ProcessScannerTests.shellRow(age: 600)
    orphan.ppid = 1
    let outcome = Self.reduce([orphan])
    #expect(outcome.busyLines == ["off source=transcript"])
    #expect(outcome.sessions.isEmpty)
  }
}
