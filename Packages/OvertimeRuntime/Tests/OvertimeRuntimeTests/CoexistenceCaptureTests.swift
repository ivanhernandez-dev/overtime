import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing

@Suite(.serialized)
struct CoexistenceCaptureTests {
  static let idleType = "PreventUserIdleSystemSleep"
  static let caffeinatePID: Int32 = 90696
  static let claudeParented = [
    ProcessRecord(pid: 90000, ppid: 1, uid: 501, comm: "claude", argv0: "claude"),
    ProcessRecord(pid: 90696, ppid: 90000, uid: 501, comm: "caffeinate"),
  ]
  static let claudeCommandParented = [
    ProcessRecord(pid: 90000, ppid: 1, uid: 501, comm: "claude", argv0: "claude"),
    ProcessRecord(pid: 90100, ppid: 90000, uid: 501, comm: "zsh", argv0: "/bin/zsh", argv1: "-c"),
    ProcessRecord(pid: 90696, ppid: 90100, uid: 501, comm: "caffeinate"),
  ]
  static let shellParented = [
    ProcessRecord(pid: 90000, ppid: 1, uid: 501, comm: "zsh", argv0: "-zsh"),
    ProcessRecord(pid: 90696, ppid: 90000, uid: 501, comm: "caffeinate"),
  ]
  static let scriptParented = [
    ProcessRecord(pid: 90000, ppid: 1, uid: 501, comm: "python3"),
    ProcessRecord(pid: 90696, ppid: 90000, uid: 501, comm: "caffeinate"),
  ]
  static let keepingYouAwake = AssertionCapture.Row(pid: 70001, processName: "KeepingYouAwake", type: idleType)
  static let amphetamine = AssertionCapture.Row(pid: 60001, processName: "Amphetamine", type: idleType)
  static let otherToolPriority = 3
  static let otherToolPhrase = "also managing sleep"
  static let warnMarker = " WARN coexistence"

  static func ordinaryRows() throws -> [AssertionCapture.Row] {
    try AssertionCapture.rows(named: AssertionCapture.ordinaryMac)
  }

  static func foreign(_ rows: [AssertionCapture.Row], processes: [ProcessRecord]) -> [ForeignAssertion] {
    CoexistenceProbe.namingParents(
      CoexistenceProbe.foreignAssertions(
        in: AssertionCapture.table(from: rows), excluding: CoexistenceProbe.claudeCaffeinatePIDs(in: processes)),
      from: processes)
  }

  static func facts(_ rows: [AssertionCapture.Row], processes: [ProcessRecord]) -> CoexistenceFacts {
    CoexistenceFacts(
      amphetamineRunning: CoexistenceProbe.amphetamineRunning(in: processes),
      sleepDisabled: false,
      foreignAssertions: foreign(rows, processes: processes))
  }

  static func hints(for snapshot: EngineSnapshot) -> [Hint] {
    let warned = snapshot.coexistenceWarned
    return Hints.visible(
      HintInputs(
        amphetamineRunning: warned && snapshot.amphetamineRunning,
        otherTools: warned ? snapshot.otherTools : []))
  }

  static func twoSamples(clock: FakeClock, engine: Engine) async -> Bool {
    await EngineSelfTestTests.finishes {
      await engine.step(.tick(EngineSelfTestTests.lidOpen))
      await engine.step(.transcriptActivity(TranscriptActivity(at: clock.mono())))
      for seconds in [2.0, 2.0, 30.0] {
        clock.advance(seconds: seconds)
        await engine.tick()
      }
    }
  }

  static func warnings(in log: String) -> [String] {
    log.split(separator: "\n").map(String.init).filter { $0.contains(warnMarker) }
  }

  @Test func theCaptureLoadsEveryRowWithItsWholeProcessName() throws {
    let rows = try Self.ordinaryRows()
    #expect(rows.count == 15)
    #expect(Set(rows.map(\.pid)).count == 9)
    let watched = rows.filter { CoexistenceProbe.watchedTypes.contains($0.type) }
    #expect(watched.count == 10)
    #expect(
      Set(watched.map(\.processName)).sorted() == [
        "bluetoothd", "caffeinate", "cameracaptured", "coreaudiod", "powerd", "sharingd",
      ])
    #expect(
      rows.contains(AssertionCapture.Row(pid: 864, processName: "Example Browser", type: "NoIdleSleepAssertion")))
  }

  @Test func theCommittedCaptureCarriesNoAssertionIdentifier() throws {
    let fixture = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures").appendingPathComponent(AssertionCapture.ordinaryMac)
    let text = try String(contentsOf: fixture, encoding: .utf8)
    let identifiers = text.split(separator: "[0x").dropFirst().map { $0.prefix { $0 != "]" } }
    #expect(identifiers.count == 15)
    #expect(
      identifiers.allSatisfy { $0 == "0000000000000000" },
      "T-IN-05: powerd's assertion identifiers may carry the time since boot, so the committed capture keeps none")
  }

  @Test func aFileWithNoAssertionRowsThrowsInsteadOfReadingAsEmpty() throws {
    let temp = try TempDirectory()
    let url = temp.url.appendingPathComponent("no-rows.txt")
    try "Assertion status system-wide:\n   UserIsActive                   1\nListed by owning process:\n"
      .write(to: url, atomically: true, encoding: .utf8)
    #expect(throws: AssertionCaptureError.noRows(url.path(percentEncoded: false))) {
      try AssertionCapture.rows(at: url)
    }
  }

  @Test func anOrdinaryMacReportsNoForeignAssertion() throws {
    #expect(CoexistenceProbe.claudeCaffeinatePIDs(in: Self.claudeParented) == [Self.caffeinatePID])
    #expect(try Self.foreign(Self.ordinaryRows(), processes: Self.claudeParented) == [])
  }

  @Test func aCaffeinateStartedByAClaudeCommandIsNotReportedBesideTheOrdinaryTable() throws {
    #expect(CoexistenceProbe.claudeCaffeinatePIDs(in: Self.claudeCommandParented) == [Self.caffeinatePID])
    #expect(try Self.foreign(Self.ordinaryRows(), processes: Self.claudeCommandParented) == [])
  }

  @Test func aListedToolBesideTheOrdinaryTableIsTheOnlyAssertionReported() throws {
    let rows = try Self.ordinaryRows() + [Self.keepingYouAwake]
    #expect(
      Self.foreign(rows, processes: Self.claudeParented) == [
        ForeignAssertion(pid: 70001, type: Self.idleType, processName: "KeepingYouAwake")
      ])
  }

  @Test func anAssertionOwnedByAmphetamineIsStillListed() throws {
    let rows = try Self.ordinaryRows() + [Self.amphetamine]
    #expect(
      Self.foreign(rows, processes: Self.claudeParented) == [
        ForeignAssertion(pid: 60001, type: Self.idleType, processName: "Amphetamine")
      ])
  }

  @Test func onAnOrdinaryMacTheSelfTestRunsAndPasses() async throws {
    let harness = try EngineSelfTestTests.Harness()
    harness.facts.set(coexistence: Self.facts(try Self.ordinaryRows(), processes: Self.claudeParented))
    let engine = try harness.composed()
    #expect(await EngineSelfTestTests.finishes { await engine.step(.tick(EngineSelfTestTests.lidOpen)) })
    #expect(await EngineSelfTestTests.finishes { await engine.requestSelfTest() })
    let snapshot = await engine.currentSnapshot()
    #expect(snapshot.selfTest == .passed)
    #expect(snapshot.selfTestRuns == 1)
  }

  @Test func onAnOrdinaryMacNoWarningIsLoggedAndNoHintIsBuilt() async throws {
    let harness = try EngineSelfTestTests.Harness()
    harness.facts.set(coexistence: Self.facts(try Self.ordinaryRows(), processes: Self.claudeParented))
    let engine = try harness.direct(mode: .live)
    #expect(await Self.twoSamples(clock: harness.clock, engine: engine))
    #expect(harness.facts.samples == 2)
    #expect(!harness.decisionLog().contains(Self.warnMarker))
    let snapshot = await engine.currentSnapshot()
    #expect(snapshot.coexistenceWarned == false)
    #expect(snapshot.otherTools.isEmpty)
    let hints = Self.hints(for: snapshot)
    #expect(!hints.contains { $0.priority == Self.otherToolPriority })
    #expect(!hints.contains { $0.text.contains(Self.otherToolPhrase) })
  }

  @Test func aListedToolIsWarnedAboutAndHintedByName() async throws {
    let harness = try EngineSelfTestTests.Harness()
    let rows = try Self.ordinaryRows() + [Self.keepingYouAwake]
    harness.facts.set(coexistence: Self.facts(rows, processes: Self.claudeParented))
    let engine = try harness.direct(mode: .live)
    #expect(await Self.twoSamples(clock: harness.clock, engine: engine))
    #expect(harness.facts.samples == 2)
    let warnings = Self.warnings(in: harness.decisionLog())
    #expect(warnings.count == 1)
    #expect(
      warnings.first?.hasSuffix(
        " WARN coexistence amphetamine=false sleepDisabled=false foreign=1 names=KeepingYouAwake") == true)
    let snapshot = await engine.currentSnapshot()
    #expect(snapshot.coexistenceWarned == true)
    #expect(snapshot.otherTools == ["KeepingYouAwake"])
    #expect(
      Self.hints(for: snapshot).first { $0.priority == Self.otherToolPriority }?.text
        == "KeepingYouAwake is also managing sleep. Running both is unsupported.")
  }

  @Test func anIdleOnlyListedToolBesideTheOrdinaryTableLetsTheSelfTestPass() async throws {
    let harness = try EngineSelfTestTests.Harness()
    let rows = try Self.ordinaryRows() + [Self.keepingYouAwake]
    harness.facts.set(coexistence: Self.facts(rows, processes: Self.claudeParented))
    let engine = try harness.composed()
    #expect(await EngineSelfTestTests.finishes { await engine.step(.tick(EngineSelfTestTests.lidOpen)) })
    harness.recorder.reset()
    #expect(await EngineSelfTestTests.finishes { await engine.requestSelfTest() })
    let snapshot = await engine.currentSnapshot()
    #expect(snapshot.selfTest == .passed)
    #expect(snapshot.selfTestRuns == 1)
  }

  @Test func aLidCloseToolBesideTheOrdinaryTableStillSkipsTheSelfTestByName() async throws {
    let harness = try EngineSelfTestTests.Harness()
    let rows = try Self.ordinaryRows() + [AssertionCapture.Row(pid: 70002, processName: "NoSleep", type: Self.idleType)]
    harness.facts.set(coexistence: Self.facts(rows, processes: Self.claudeParented))
    let engine = try harness.composed()
    #expect(await EngineSelfTestTests.finishes { await engine.step(.tick(EngineSelfTestTests.lidOpen)) })
    harness.recorder.reset()
    #expect(await EngineSelfTestTests.finishes { await engine.requestSelfTest() })
    let snapshot = await engine.currentSnapshot()
    #expect(snapshot.selfTest == .skipped(.otherTool("NoSleep")))
    #expect(snapshot.selfTestRuns == 0)
    #expect(harness.holdEntries.isEmpty)
  }

  @Test func aCaffeinateStartedFromAShellIsTheOnlyAssertionReported() throws {
    #expect(CoexistenceProbe.claudeCaffeinatePIDs(in: Self.shellParented).isEmpty)
    #expect(
      try Self.foreign(Self.ordinaryRows(), processes: Self.shellParented) == [
        ForeignAssertion(pid: Self.caffeinatePID, type: Self.idleType, processName: "caffeinate", parentName: "zsh")
      ])
  }

  @Test func aCaffeinateStartedFromAShellIsWarnedAboutAndHintedByName() async throws {
    let harness = try EngineSelfTestTests.Harness()
    harness.facts.set(coexistence: Self.facts(try Self.ordinaryRows(), processes: Self.shellParented))
    let engine = try harness.direct(mode: .live)
    #expect(await Self.twoSamples(clock: harness.clock, engine: engine))
    #expect(harness.facts.samples == 2)
    let warnings = Self.warnings(in: harness.decisionLog())
    #expect(warnings.count == 1)
    #expect(
      warnings.first?.hasSuffix(" WARN coexistence amphetamine=false sleepDisabled=false foreign=1 names=caffeinate")
        == true)
    let snapshot = await engine.currentSnapshot()
    #expect(snapshot.otherTools == ["caffeinate (started by zsh)"])
    #expect(
      Self.hints(for: snapshot).first { $0.priority == Self.otherToolPriority }?.text
        == "caffeinate (started by zsh) is also managing sleep. Running both is unsupported.")
  }

  @Test func aCaffeinateStartedByABackgroundScriptIsHintedWithItsStarter() async throws {
    let harness = try EngineSelfTestTests.Harness()
    harness.facts.set(coexistence: Self.facts(try Self.ordinaryRows(), processes: Self.scriptParented))
    let engine = try harness.direct(mode: .live)
    #expect(await Self.twoSamples(clock: harness.clock, engine: engine))
    #expect(harness.facts.samples == 2)
    let warnings = Self.warnings(in: harness.decisionLog())
    #expect(warnings.count == 1)
    #expect(warnings.first?.hasSuffix(" names=caffeinate") == true)
    let snapshot = await engine.currentSnapshot()
    #expect(snapshot.otherTools == ["caffeinate (started by python3)"])
    #expect(
      Self.hints(for: snapshot).first { $0.priority == Self.otherToolPriority }?.text
        == "caffeinate (started by python3) is also managing sleep. Running both is unsupported.")
  }

  @Test func aCaffeinateWithAKnownStarterIsHintedBeforeABareOne() async throws {
    let harness = try EngineSelfTestTests.Harness()
    let bare = AssertionCapture.Row(pid: 90697, processName: "caffeinate", type: Self.idleType)
    let rows = try Self.ordinaryRows() + [bare]
    harness.facts.set(coexistence: Self.facts(rows, processes: Self.scriptParented))
    let engine = try harness.direct(mode: .live)
    #expect(await Self.twoSamples(clock: harness.clock, engine: engine))
    let snapshot = await engine.currentSnapshot()
    #expect(snapshot.otherTools == ["caffeinate", "caffeinate (started by python3)"])
    #expect(
      Self.hints(for: snapshot).first { $0.priority == Self.otherToolPriority }?.text
        == "caffeinate (started by python3) is also managing sleep. Running both is unsupported.")
    let others = Hints.visible(HintInputs(otherTools: ["caffeinate", "Lungo", "caffeinate (started by python3)"]))
    #expect(others.map(\.text) == ["Lungo is also managing sleep. Running both is unsupported."])
  }

  @Test func aCaffeinateStartedFromAShellLetsTheSelfTestPass() async throws {
    let harness = try EngineSelfTestTests.Harness()
    harness.facts.set(coexistence: Self.facts(try Self.ordinaryRows(), processes: Self.shellParented))
    let engine = try harness.composed()
    #expect(await EngineSelfTestTests.finishes { await engine.step(.tick(EngineSelfTestTests.lidOpen)) })
    harness.recorder.reset()
    #expect(await EngineSelfTestTests.finishes { await engine.requestSelfTest() })
    let snapshot = await engine.currentSnapshot()
    #expect(snapshot.selfTest == .passed)
    #expect(snapshot.selfTestRuns == 1)
  }
}
