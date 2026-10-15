import Foundation
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing

struct NoTools: ToolPort {
  func run(_ executable: String, _ arguments: [String]) -> ToolOutcome {
    .launchFailed("no tools in this test")
  }
}

struct EngineLiveAssertionTests {
  struct Harness {
    let temp: TempDirectory
    let paths: Paths
    let clock = FakeClock()
    let port = FakeAssertionPort()
    let recorder: HoldRecorder

    init() throws {
      temp = try TempDirectory()
      paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path], homeDirectory: temp.path)
      recorder = HoldRecorder(stateFile: paths.stateFile(.live))
    }

    func engine(callTimeoutSeconds: Double = Timing.systemCallTimeoutSeconds) throws -> Engine {
      try Composition.makeLiveEngine(
        paths: paths,
        settings: Settings(transcriptRoots: [temp.path + "/projects"]),
        ports: LivePorts(
          assertions: port, tools: NoTools(), clamshell: FakeClamshellPort(recorder: recorder),
          stateFile: paths.stateFile(.live), makeSentinel: { [recorder] in FakeSentinelPort(recorder: recorder) }),
        environment: [:],
        homeDirectory: temp.path,
        once: true,
        clock: clock,
        callTimeoutSeconds: callTimeoutSeconds
      )
    }

    func lines() -> [String] {
      guard let text = try? String(contentsOf: paths.decisionLog(.live), encoding: .utf8) else { return [] }
      return text.split(separator: "\n").map(String.init)
    }

    func busyTick(_ engine: Engine) async {
      await engine.step(.transcriptActivity(TranscriptActivity(at: clock.mono())))
      await engine.step(.tick(TickFacts()))
    }
  }

  @Test func busyTickAcquiresRenewsAndIdleReleasesThroughTheLiveInterpreter() async throws {
    let harness = try Harness()
    let engine = try harness.engine()
    await harness.busyTick(engine)
    #expect(harness.port.calls == [.acquireOrRenew(.preventUserIdleSystemSleep, 300)])
    #expect(await engine.state.hold.idle == .held)
    #expect(harness.lines().contains { $0.hasSuffix(" HOLD idle acquired") })

    harness.clock.advance(seconds: 2)
    await harness.busyTick(engine)
    #expect(harness.port.calls.count == 2)
    #expect(harness.port.calls.last == .acquireOrRenew(.preventUserIdleSystemSleep, 300))

    harness.clock.advance(seconds: 200)
    await engine.step(.tick(TickFacts()))
    #expect(harness.port.calls.last == .release(.preventUserIdleSystemSleep))
    #expect(await engine.state.hold.idle == .released)
    let lines = harness.lines()
    #expect(lines.contains { $0.hasSuffix(" WANT off reason=idle") })
    #expect(lines.contains { $0.hasSuffix(" HOLD idle released") })
    #expect(!FileManager.default.fileExists(atPath: harness.paths.decisionLog(.shadow).path(percentEncoded: false)))
  }

  @Test func theShadowRecorderAnswersTheSameEffectsWithoutAPort() async throws {
    let harness = try Harness()
    let engine = try Composition.makeShadowEngine(
      paths: harness.paths,
      settings: Settings(transcriptRoots: [harness.temp.path + "/projects"]),
      environment: [:],
      homeDirectory: harness.temp.path,
      once: true
    )
    await engine.step(.transcriptActivity(TranscriptActivity(at: SystemClock().mono())))
    await engine.step(.tick(TickFacts()))
    #expect(await engine.state.hold.idle == .held)
    #expect(harness.port.calls.isEmpty)
    let text = try String(contentsOf: harness.paths.decisionLog(.shadow), encoding: .utf8)
    #expect(text.contains(" HOLD idle acquired"))
  }

  @Test func aHungAcquireTimesOutWithinTheCallBoundAndBacksOff() async throws {
    let harness = try Harness()
    harness.port.blockAcquires(forSeconds: 120)
    defer { harness.port.releaseBlockedCalls() }
    let engine = try harness.engine(callTimeoutSeconds: 5)
    let clock = harness.clock
    let ticked = await Engine.bounded(seconds: 30) {
      await engine.step(.transcriptActivity(TranscriptActivity(at: clock.mono())))
      await engine.step(.tick(TickFacts()))
    }
    #expect(ticked)
    #expect(harness.port.calls == [.acquireOrRenew(.preventUserIdleSystemSleep, 300)])
    #expect(harness.port.blockedCallsReturned == 0)
    let phase = await engine.state.hold.idle
    guard case .failed(let attempts, let retryAt) = phase else {
      Issue.record("expected failed, got \(phase)")
      return
    }
    #expect(attempts == 1)
    #expect(retryAt == harness.clock.mono().adding(seconds: 20))
    #expect(await engine.state.hold.errorActive)
    let status = await engine.snapshot()
    #expect(status.holdIdle == "failed attempts=1")
    #expect(status.holdError == true)
    let lines = harness.lines()
    #expect(lines.contains { $0.hasSuffix(" HOLD failed backend=idle attempt=1 retryIn=20") })
    #expect(lines.contains { $0.hasSuffix(" ERROR hold backend=idle") })
  }
}
