import Foundation
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing
import os

struct EngineNetworkLaneTests {
  static let facts = NetworkFacts(wifiInterface: "en0", onHotspot: false, wired: false, wifiPowered: true)
  static let settings = Settings(hotspot: "Test iPhone")
  static let tickBoundSeconds: Double = 30

  @Sendable static func closedTick() -> TickFacts {
    TickFacts(lidClosed: true, externalDisplays: 0, fullWake: true, network: facts)
  }

  struct Harness {
    let temp: TempDirectory
    let paths: Paths
    let clock = FakeClock()
    let recorder: HoldRecorder
    let heartbeats = OSAllocatedUnfairLock(initialState: 0)

    init() throws {
      temp = try TempDirectory()
      paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path], homeDirectory: temp.path)
      try paths.createDirectories()
      recorder = HoldRecorder(stateFile: paths.stateFile(.live))
    }

    var heartbeatCount: Int {
      heartbeats.withLock { $0 }
    }

    func interpreter(network: any NetworkPort) throws -> LiveInterpreter {
      let recorder = recorder
      let logger = try FileLogger(decisionLog: paths.decisionLog(.live), errorLog: paths.errorLog(.live))
      return LiveInterpreter(
        ports: LivePorts(
          assertions: FakeAssertionPort(), tools: FakeToolPort(), clamshell: FakeClamshellPort(recorder: recorder),
          stateFile: paths.stateFile(.live), makeSentinel: { FakeSentinelPort(recorder: recorder) },
          network: network),
        logger: logger,
        sentinel: FakeSentinelPort(recorder: recorder),
        timeZone: TimeZone(secondsFromGMT: 0)!)
    }

    func engine(
      _ interpreter: any EffectInterpreter, live: LiveInterpreter,
      transcriptSeed: @escaping @Sendable () -> [TranscriptActivity] = { [] },
      sampleTick: (@Sendable () -> TickFacts)? = nil
    ) -> Engine {
      let heartbeats = heartbeats
      let tick: @Sendable () -> TickFacts =
        sampleTick ?? EngineNetworkLaneTests.closedTick
      return Engine(
        mode: .live,
        settings: EngineNetworkLaneTests.settings,
        clock: clock,
        interpreter: interpreter,
        sources: EngineSources(transcriptSeed: transcriptSeed, sampleTick: tick, samplesFullWake: true),
        heartbeat: {
          heartbeats.withLock { $0 += 1 }
          return await live.heartbeat()
        },
        closeSentinel: { live.closeSentinel() })
    }

    func closeUntilStable(_ engine: Engine) async -> Bool {
      let clock = clock
      await engine.step(.transcriptActivity(TranscriptActivity(at: clock.mono())))
      guard await Engine.bounded(seconds: EngineNetworkLaneTests.tickBoundSeconds, { await engine.tick() }) else {
        return false
      }
      clock.advance(seconds: Timing.lidStableSeconds)
      return true
    }
  }

  static func isProbeResult(_ event: Event) -> Bool {
    if case .netProbeResult = event { return true }
    return false
  }

  @Test func aProbeFromTheReducerRunsOnItsLaneAndItsFailureReachesTheReducerThroughTheStream() async throws {
    let harness = try Harness()
    let stubbed = StubbedProbe(primary: .fail, captive: .fail)
    let probe = stubbed.probe
    let port = ClosureNetworkPort(onFacts: { _ in EngineNetworkLaneTests.facts }, onProbe: { probe.probe() })
    let interpreter = try harness.interpreter(network: port)
    let engine = harness.engine(interpreter, live: interpreter)
    let collector = NetworkEventCollector(try #require(interpreter.networkEvents))
    #expect(await harness.closeUntilStable(engine))
    #expect(await engine.state.network.nextProbe == nil)
    #expect(await Engine.bounded(seconds: Self.tickBoundSeconds) { await engine.tick() })
    #expect(await engine.state.network.nextProbe != nil)
    #expect(await collector.waitFor(count: 1))
    #expect(collector.events == [.netProbeResult(online: false)])
    #expect(StubURLProtocol.requests(to: stubbed.primaryHost).count == 1)
    #expect(StubURLProtocol.requests(to: stubbed.captiveHost).count == 1)
    #expect(await engine.state.network.fails == 0)
    for event in collector.events {
      await engine.step(event)
    }
    #expect(await engine.state.network.fails == 1)
    withExtendedLifetime(interpreter) {}
  }

  @Test func aTickThatEmitsAProbeReturnsWhileTheProbeIsBlockedAndTheResultComesOnlyOnTheStream() async throws {
    let harness = try Harness()
    let port = BlockingNetworkPort(facts: Self.facts, blocking: [.probe])
    defer { port.release() }
    let interpreter = try harness.interpreter(network: port)
    let recording = BatchRecordingInterpreter(interpreter)
    let engine = harness.engine(recording, live: interpreter)
    let collector = NetworkEventCollector(try #require(interpreter.networkEvents))
    #expect(await harness.closeUntilStable(engine))

    let beforeProbeTick = harness.heartbeatCount
    #expect(await Engine.bounded(seconds: Self.tickBoundSeconds) { await engine.tick() })
    #expect(await OffPool.eventually(seconds: 10) { port.count(.probe) == 1 })
    #expect(port.finished.isEmpty)
    #expect(harness.heartbeatCount > beforeProbeTick)

    harness.clock.advance(seconds: Timing.tickSeconds)
    let beforeNextTick = harness.heartbeatCount
    #expect(await Engine.bounded(seconds: Self.tickBoundSeconds) { await engine.tick() })
    #expect(harness.heartbeatCount > beforeNextTick)
    #expect(port.finished.isEmpty)
    #expect(port.count(.probe) == 1)
    #expect(collector.events.isEmpty)

    port.release()
    #expect(await collector.waitFor(count: 1))
    #expect(collector.events == [.netProbeResult(online: false)])
    #expect(!recording.batchResults.joined().contains(where: Self.isProbeResult))
    withExtendedLifetime(interpreter) {}
  }

  @Test func theRunningEngineStepsEveryOfflineProbeUntilItJoinsTheHotspotAndStops() async throws {
    let harness = try Harness()
    let port = BlockingNetworkPort(facts: Self.facts, blocking: [])
    port.answerProbes([], otherwise: false)
    let interpreter = try harness.interpreter(network: port)
    let clock = harness.clock
    let engine = harness.engine(
      interpreter, live: interpreter,
      transcriptSeed: { [TranscriptActivity(at: clock.mono())] },
      sampleTick: {
        Thread.sleep(forTimeInterval: 0.02)
        clock.advance(seconds: Timing.tickSeconds)
        return EngineNetworkLaneTests.closedTick()
      })
    let running = Task { await engine.run() }
    let joined = await OffPool.eventually(seconds: 10) { port.count(.join) >= 1 }
    #expect(joined)
    #expect(port.count(.probe) >= Timing.netFailsNeeded)
    #expect(await Engine.bounded(seconds: 10) { await engine.stop() })
    #expect(await Engine.bounded(seconds: 5) { await running.value })
    let lines = (try? String(contentsOf: harness.paths.decisionLog(.live), encoding: .utf8)) ?? ""
    let quote = "\""
    #expect(lines.contains(" NET join msg=" + quote + NetworkFailover.joiningMessage + quote + " hotspot=configured"))
    withExtendedLifetime(interpreter) {}
  }
}
