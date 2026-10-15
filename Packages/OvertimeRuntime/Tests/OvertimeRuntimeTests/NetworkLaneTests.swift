import Foundation
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing
import os

struct NetworkLaneHarness {
  static let small = LiveInterpreter.NetworkBounds(probe: 0.2, join: 0.2, cycle: 0.2)
  static let generous = LiveInterpreter.NetworkBounds(probe: 30, join: 30, cycle: 30)

  let temp: TempDirectory
  let paths: Paths
  let recorder: HoldRecorder
  let interpreter: LiveInterpreter
  let collector: NetworkEventCollector

  init(port: any NetworkPort, bounds: LiveInterpreter.NetworkBounds = Self.small) throws {
    temp = try TempDirectory()
    paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path], homeDirectory: temp.path)
    try paths.createDirectories()
    let recorder = HoldRecorder(stateFile: paths.stateFile(.live))
    self.recorder = recorder
    let logger = try FileLogger(decisionLog: paths.decisionLog(.live), errorLog: paths.errorLog(.live))
    interpreter = LiveInterpreter(
      ports: LivePorts(
        assertions: FakeAssertionPort(), tools: FakeToolPort(), clamshell: FakeClamshellPort(recorder: recorder),
        stateFile: paths.stateFile(.live), makeSentinel: { FakeSentinelPort(recorder: recorder) }, network: port),
      logger: logger,
      sentinel: FakeSentinelPort(recorder: recorder),
      timeZone: TimeZone(secondsFromGMT: 0)!,
      networkBounds: bounds)
    collector = NetworkEventCollector(try #require(interpreter.networkEvents))
  }

  var lines: [String] {
    guard let text = try? String(contentsOf: paths.decisionLog(.live), encoding: .utf8) else { return [] }
    return text.split(separator: "\n").map(String.init)
  }

  var netLines: [String] {
    lines.filter { $0.contains(" net failed") }
  }

  func logged(_ suffix: String, seconds: Double = 5) async -> Bool {
    await OffPool.eventually(seconds: seconds) { self.lines.contains { $0.hasSuffix(suffix) } }
  }

  func enqueue(_ effects: [Effect]) -> Task<[Event], Never> {
    interpreter.enqueue(effects, wall: Date())
  }
}

struct NetworkLaneTests {
  static let id = EffectID(value: 41)

  @Test func aClamshellSetQueuedAfterABlockedProbeFinishesWhileTheProbeStillRuns() async throws {
    let port = BlockingNetworkPort(blocking: [.probe])
    defer { port.release() }
    let harness = try NetworkLaneHarness(port: port, bounds: NetworkLaneHarness.generous)
    _ = harness.enqueue([.net(.probe)])
    #expect(await OffPool.eventually { port.count(.probe) == 1 })
    let batch = harness.enqueue([.sentinel(.arm), .clamshell(on: true, id: Self.id, why: .engage)])
    var results: [Event]?
    let finished = await Engine.bounded(seconds: 10) { _ = await batch.value }
    if finished { results = await batch.value }
    #expect(finished)
    #expect(results == [.effectResult(Self.id, .succeeded)])
    #expect(port.finished.isEmpty)
    #expect(harness.collector.events.isEmpty)
    withExtendedLifetime(harness.interpreter) {}
  }

  @Test func aMixedBatchReturnsOnlyTheHoldResultAndTheProbeResultComesOnTheStream() async throws {
    let port = BlockingNetworkPort(blocking: [])
    port.answerProbes([true])
    let harness = try NetworkLaneHarness(port: port, bounds: NetworkLaneHarness.generous)
    let results = await harness.enqueue([
      .log(Decision(keyword: .net, verb: "armed")), .net(.probe),
      .idleAssertion(.acquireOrRenew(timeoutSeconds: 300), id: Self.id),
    ]).value
    #expect(results == [.effectResult(Self.id, .succeeded)])
    #expect(await harness.collector.waitFor(count: 1))
    #expect(harness.collector.events == [.netProbeResult(online: true)])
    withExtendedLifetime(harness.interpreter) {}
  }

  @Test func probesAreAnsweredOnTheStreamInTheOrderTheyWereQueued() async throws {
    let port = BlockingNetworkPort(blocking: [])
    port.answerProbes([true, false])
    let harness = try NetworkLaneHarness(port: port, bounds: NetworkLaneHarness.generous)
    _ = harness.enqueue([.net(.probe)])
    _ = harness.enqueue([.net(.probe)])
    #expect(await harness.collector.waitFor(count: 2))
    #expect(harness.collector.events == [.netProbeResult(online: true), .netProbeResult(online: false)])
    withExtendedLifetime(harness.interpreter) {}
  }

  @Test func aFailedJoinLogsItsActionAndCodeOnly() async throws {
    let port = BlockingNetworkPort(blocking: [])
    port.answerJoin(.failed(code: -3930))
    let harness = try NetworkLaneHarness(port: port, bounds: NetworkLaneHarness.generous)
    _ = harness.enqueue([.net(.joinHotspot("Test iPhone"))])
    #expect(await harness.logged(" ERROR net failed action=joinHotspot result=-3930"))
    #expect(!harness.lines.contains { $0.contains("iPhone") })
    #expect(harness.collector.events.isEmpty)
    withExtendedLifetime(harness.interpreter) {}
  }

  @Test func aCycleThatOutlivesItsBoundLogsTimedOut() async throws {
    let port = BlockingNetworkPort(blocking: [.cycle])
    defer { port.release() }
    let harness = try NetworkLaneHarness(port: port)
    _ = harness.enqueue([.net(.cycleWifi)])
    #expect(await harness.logged(" ERROR net failed action=cycleWifi result=timedOut"))
    #expect(port.finished.isEmpty)
    #expect(await harness.collector.waitFor(count: 1))
    #expect(harness.collector.events == [.netCycleDone(.failed)])
    withExtendedLifetime(harness.interpreter) {}
  }

  @Test func aSuccessfulJoinOrCycleLogsNothingAndOnlyTheCycleReportsItsOutcome() async throws {
    let port = BlockingNetworkPort(blocking: [])
    let harness = try NetworkLaneHarness(port: port, bounds: NetworkLaneHarness.generous)
    _ = harness.enqueue([.net(.joinHotspot("Test iPhone")), .net(.cycleWifi)])
    #expect(await OffPool.eventually { port.finished.count == 2 })
    #expect(port.started == [.join, .cycle])
    port.answerJoin(.failed(code: -1))
    _ = harness.enqueue([.net(.joinHotspot("Test iPhone"))])
    let gate = " ERROR net failed action=joinHotspot result=-1"
    #expect(await harness.logged(gate))
    #expect(harness.netLines.count == 1)
    #expect(harness.netLines.allSatisfy { $0.hasSuffix(gate) })
    #expect(await harness.collector.waitFor(count: 1))
    #expect(harness.collector.events == [.netCycleDone(.succeeded)])
    withExtendedLifetime(harness.interpreter) {}
  }

  @Test(arguments: [BlockingNetworkPort.Action.probe, .join, .cycle])
  func eachNetworkActionIsCutAtItsOwnBound(action: BlockingNetworkPort.Action) async throws {
    let long: Double = 60
    let bounds = LiveInterpreter.NetworkBounds(
      probe: action == .probe ? 0.2 : long, join: action == .join ? 0.2 : long,
      cycle: action == .cycle ? 0.2 : long)
    let port = BlockingNetworkPort(blocking: [action])
    defer { port.release() }
    let harness = try NetworkLaneHarness(port: port, bounds: bounds)
    switch action {
    case .probe:
      _ = harness.enqueue([.net(.probe)])
      #expect(await harness.collector.waitFor(count: 1, seconds: 10))
      #expect(harness.collector.events == [.netProbeResult(online: false)])
    case .join:
      _ = harness.enqueue([.net(.joinHotspot("Test iPhone"))])
      #expect(await harness.logged(" ERROR net failed action=joinHotspot result=timedOut", seconds: 10))
    case .cycle:
      _ = harness.enqueue([.net(.cycleWifi)])
      #expect(await harness.logged(" ERROR net failed action=cycleWifi result=timedOut", seconds: 10))
    }
    #expect(port.finished.isEmpty)
    withExtendedLifetime(harness.interpreter) {}
  }

  @Test func theStandardBoundsAreFiveFifteenAndTwentyFiveSeconds() {
    let standard = LiveInterpreter.NetworkBounds.standard
    #expect(standard.probe == 5)
    #expect(standard.join == 15)
    #expect(standard.cycle == 25)
    #expect(standard.join < Timing.hotspotJoinWaitSeconds)
    #expect(LiveInterpreter.networkRunnerKey == "net")
  }

  @Test func theRecordingInterpreterHasNoNetworkStream() throws {
    let temp = try TempDirectory()
    let paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path], homeDirectory: temp.path)
    try paths.createDirectories()
    let logger = try FileLogger(decisionLog: paths.decisionLog(.shadow), errorLog: paths.errorLog(.shadow))
    #expect(RecordingInterpreter(logger: logger).networkEvents == nil)
  }
}
