import Foundation
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing
import os

struct EngineLidTests {
  final class DisplaySource: Sendable {
    private let count: OSAllocatedUnfairLock<Int?>
    private let reads = OSAllocatedUnfairLock(initialState: 0)

    init(_ count: Int?) {
      self.count = OSAllocatedUnfairLock(initialState: count)
    }

    var readCount: Int {
      reads.withLock { $0 }
    }

    func read() -> Int? {
      reads.withLock { $0 += 1 }
      return count.withLock { $0 }
    }
  }

  struct Harness {
    let temp: TempDirectory
    let paths: Paths
    let clock = FakeClock()
    let assertions = FakeAssertionPort()
    let tools = FakeToolPort()
    let recorder: HoldRecorder
    let displays: DisplaySource

    init(externalDisplays: Int? = 0) throws {
      temp = try TempDirectory()
      paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path], homeDirectory: temp.path)
      recorder = HoldRecorder(stateFile: paths.stateFile(.live))
      displays = DisplaySource(externalDisplays)
    }

    func liveEngine() throws -> Engine {
      let displays = displays
      return try Composition.makeLiveEngine(
        paths: paths,
        settings: Settings(transcriptRoots: [temp.path + "/projects"]),
        ports: LivePorts(
          assertions: assertions, tools: tools, clamshell: FakeClamshellPort(recorder: recorder),
          stateFile: paths.stateFile(.live), makeSentinel: { [recorder] in FakeSentinelPort(recorder: recorder) }),
        environment: [:],
        homeDirectory: temp.path,
        once: true,
        clock: clock,
        externalDisplays: { displays.read() }
      )
    }

    func shadowEngine() throws -> Engine {
      let displays = displays
      return try Composition.makeShadowEngine(
        paths: paths,
        settings: Settings(transcriptRoots: [temp.path + "/projects"]),
        environment: [:],
        homeDirectory: temp.path,
        once: true,
        externalDisplays: { displays.read() }
      )
    }

    func lines(_ mode: RunMode) -> [String] {
      guard let text = try? String(contentsOf: paths.decisionLog(mode), encoding: .utf8) else { return [] }
      return text.split(separator: "\n").map(String.init)
    }

    func wanted(_ engine: Engine, at mono: Instant) async {
      await engine.step(.transcriptActivity(TranscriptActivity(at: mono)))
      await engine.step(.tick(TickFacts(lidClosed: false)))
    }
  }

  static let close = Event.lidChanged(closed: true, sleepBit: false, externalDisplays: nil)
  static let displaySleep = FakeToolPort.Call(executable: "/usr/bin/pmset", arguments: ["displaysleepnow"])

  @Test func aHeldLidCloseFillsTheDisplayCountAndRunsDisplaySleepNowThroughTheToolPort() async throws {
    let harness = try Harness(externalDisplays: 0)
    let engine = try harness.liveEngine()
    await harness.wanted(engine, at: harness.clock.mono())
    #expect(harness.tools.calls.isEmpty)
    await engine.step(Self.close)
    #expect(harness.displays.readCount == 1)
    #expect(harness.tools.calls == [Self.displaySleep])
    #expect(await engine.state.lid.closed == true)
    #expect(harness.lines(.live).contains { $0.hasSuffix(" LID closed ext=0") })
  }

  @Test func anExternalDisplayAtCloseLeavesTheDisplayAlone() async throws {
    let harness = try Harness(externalDisplays: 1)
    let engine = try harness.liveEngine()
    await harness.wanted(engine, at: harness.clock.mono())
    await engine.step(Self.close)
    #expect(harness.tools.calls.isEmpty)
    #expect(harness.lines(.live).contains { $0.hasSuffix(" LID closed ext=1") })
  }

  @Test func aReportedCountIsNotReRead() async throws {
    let harness = try Harness(externalDisplays: 1)
    let engine = try harness.liveEngine()
    await harness.wanted(engine, at: harness.clock.mono())
    await engine.step(.lidChanged(closed: true, sleepBit: false, externalDisplays: 0))
    #expect(harness.displays.readCount == 0)
    #expect(harness.tools.calls == [Self.displaySleep])
  }

  @Test func aFailedDisplaySleepIsLoggedAsAnError() async throws {
    let harness = try Harness(externalDisplays: 0)
    harness.tools.setOutcome(.finished(exitCode: 1, stdout: "", stderr: "denied"))
    let engine = try harness.liveEngine()
    await harness.wanted(engine, at: harness.clock.mono())
    await engine.step(Self.close)
    #expect(harness.tools.calls == [Self.displaySleep])
    #expect(harness.lines(.live).contains { $0.hasSuffix(" ERROR pmset failed command=displaysleepnow") })
  }

  static let sleepNow = FakeToolPort.Call(executable: "/usr/bin/pmset", arguments: ["sleepnow"])
  static let closedTick = TickFacts(lidClosed: true, externalDisplays: 0, fullWake: true)

  static func releaseWithTheLidClosed(_ engine: Engine, clock: FakeClock) async {
    await engine.step(.transcriptActivity(TranscriptActivity(at: clock.mono())))
    await engine.step(.tick(TickFacts(lidClosed: false, fullWake: true)))
    await engine.step(close)
    clock.advance(seconds: 200)
    await engine.step(.tick(closedTick))
  }

  @Test func anUnverifiedLidClosedReleaseRunsSleepNowOnceThroughTheToolPort() async throws {
    let harness = try Harness(externalDisplays: 0)
    let engine = try harness.liveEngine()
    await Self.releaseWithTheLidClosed(engine, clock: harness.clock)
    #expect(harness.recorder.all.contains(.clamshell(on: false, fileOwnsHold: true)))
    #expect(await engine.state.verification != .idle)
    #expect(harness.tools.calls == [Self.displaySleep])
    harness.clock.advance(seconds: 30)
    await engine.step(.tick(Self.closedTick))
    harness.clock.advance(seconds: 30)
    await engine.step(.tick(Self.closedTick))
    #expect(harness.tools.calls == [Self.displaySleep, Self.sleepNow])
    let lines = harness.lines(.live)
    #expect(lines.contains { $0.hasSuffix(" VERIFY sleep failed action=requestSleep") })
    #expect(lines.contains { $0.hasSuffix(" ERROR sleep not observed") })
  }

  @Test func aWillSleepAfterTheReleaseNeverRunsSleepNow() async throws {
    let harness = try Harness(externalDisplays: 0)
    let engine = try harness.liveEngine()
    await Self.releaseWithTheLidClosed(engine, clock: harness.clock)
    harness.clock.advance(seconds: 1)
    await engine.step(.systemWillSleep)
    harness.clock.advance(seconds: 40)
    await engine.step(.tick(Self.closedTick))
    #expect(harness.tools.calls == [Self.displaySleep])
    #expect(harness.lines(.live).contains { $0.hasSuffix(" VERIFY sleep ok") })
  }

  @Test func theShadowRecorderAnswersASleepRequestWithoutATool() async throws {
    let harness = try Harness(externalDisplays: 0)
    try harness.paths.createDirectories()
    let logger = try FileLogger(
      decisionLog: harness.paths.decisionLog(.shadow), errorLog: harness.paths.errorLog(.shadow),
      rotateAtBytes: Timing.logRotateBytes)
    let displays = harness.displays
    let engine = Engine(
      mode: .shadow, settings: Settings(), clock: harness.clock,
      interpreter: RecordingInterpreter(logger: logger, timeZone: .current),
      sources: EngineSources(
        transcriptSeed: { [] }, sampleTick: { TickFacts() }, externalDisplays: { displays.read() }))
    await Self.releaseWithTheLidClosed(engine, clock: harness.clock)
    harness.clock.advance(seconds: 30)
    await engine.step(.tick(Self.closedTick))
    #expect(harness.tools.calls.isEmpty)
    #expect(await engine.state.verification == .idle)
    let lines = harness.lines(.shadow)
    #expect(lines.contains { $0.hasSuffix(" LID closed ext=0") })
    #expect(lines.contains { $0.hasSuffix(" VERIFY sleep failed action=requestSleep") })
  }

  @Test func theShadowEngineRecordsTheCloseAndNeverCallsATool() async throws {
    let harness = try Harness(externalDisplays: 0)
    let engine = try harness.shadowEngine()
    await harness.wanted(engine, at: SystemClock().mono())
    await engine.step(Self.close)
    #expect(harness.displays.readCount == 1)
    #expect(harness.tools.calls.isEmpty)
    #expect(await engine.state.lid.closed == true)
    #expect(harness.lines(.shadow).contains { $0.hasSuffix(" LID closed ext=0") })
  }
}
