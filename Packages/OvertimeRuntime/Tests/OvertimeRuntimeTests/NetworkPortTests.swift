import Foundation
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing

struct NetworkPortTests {
  @Test func theNoNetworkPortReportsNothingAndDoesNothing() {
    let port = NoNetworkPort()
    #expect(port.facts(lidClosed: true) == nil)
    #expect(port.facts(lidClosed: false) == nil)
    #expect(port.facts(lidClosed: nil) == nil)
    #expect(port.probe() == false)
    #expect(port.joinHotspot("Test iPhone") == .failed(code: NoNetworkPort.disabledCode))
    #expect(port.cycleWifi() == .failed(code: NoNetworkPort.disabledCode))
  }

  @Test func theNoNetworkPortHasNoWiFiLeftOffToRecover() {
    #expect(NoNetworkPort().recoverIfLeftOff() == .succeeded)
    #expect(ClosureNetworkPort().recoverIfLeftOff() == .succeeded)
    let port = ClosureNetworkPort(onRecover: { WiFiController.Code.stillOff.outcome })
    #expect(port.recoverIfLeftOff() == .failed(code: -29))
  }

  @Test func theNoNetworkPortIgnoresAutoDetectInUse() {
    let port = NoNetworkPort()
    port.autoDetectInUse(true)
    #expect(port.facts(lidClosed: true) == nil)
    port.autoDetectInUse(false)
    #expect(port.facts(lidClosed: true) == nil)
  }

  @Test func theLiveInterpreterRoutesNetEffectsToThePortAndLogsFailedActions() async throws {
    let temp = try TempDirectory()
    let paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path], homeDirectory: temp.path)
    try paths.createDirectories()
    let logger = try FileLogger(decisionLog: paths.decisionLog(.live), errorLog: paths.errorLog(.live))
    let recorder = HoldRecorder(stateFile: paths.stateFile(.live))
    let ports = LivePorts(
      assertions: FakeAssertionPort(), tools: NoTools(), clamshell: FakeClamshellPort(recorder: recorder),
      stateFile: paths.stateFile(.live), makeSentinel: { [recorder] in FakeSentinelPort(recorder: recorder) })
    let interpreter = LiveInterpreter(ports: ports, logger: logger, timeZone: TimeZone(secondsFromGMT: 0)!)
    let collector = NetworkEventCollector(try #require(interpreter.networkEvents))
    let results = await interpreter.perform(
      [.net(.probe), .net(.joinHotspot("Test iPhone")), .net(.cycleWifi)], wall: Date())
    #expect(results.isEmpty)
    #expect(await collector.waitFor(count: 2))
    #expect(collector.events == [.netProbeResult(online: false), .netCycleDone(.refused)])
    let logged = await OffPool.eventually {
      let text = (try? String(contentsOf: paths.decisionLog(.live), encoding: .utf8)) ?? ""
      return text.contains(" ERROR net failed action=joinHotspot")
        && text.contains(" ERROR net failed action=cycleWifi")
    }
    #expect(logged)
    withExtendedLifetime(interpreter) {}
  }

  @Test func aProbeOnlyBatchFinishesEmptyAndItsResultComesOnTheStream() async throws {
    let temp = try TempDirectory()
    let paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path], homeDirectory: temp.path)
    try paths.createDirectories()
    let logger = try FileLogger(decisionLog: paths.decisionLog(.live), errorLog: paths.errorLog(.live))
    let recorder = HoldRecorder(stateFile: paths.stateFile(.live))
    let ports = LivePorts(
      assertions: FakeAssertionPort(), tools: NoTools(), clamshell: FakeClamshellPort(recorder: recorder),
      stateFile: paths.stateFile(.live), makeSentinel: { [recorder] in FakeSentinelPort(recorder: recorder) },
      network: ClosureNetworkPort(onProbe: { true }))
    let interpreter = LiveInterpreter(ports: ports, logger: logger, timeZone: TimeZone(secondsFromGMT: 0)!)
    let collector = NetworkEventCollector(try #require(interpreter.networkEvents))
    let results = await interpreter.perform([.net(.probe)], wall: Date())
    #expect(results.isEmpty)
    #expect(await collector.waitFor(count: 1))
    #expect(collector.events == [.netProbeResult(online: true)])
    withExtendedLifetime(interpreter) {}
  }

  @Test func theShadowRecorderNeverAnswersANetEffect() async throws {
    let temp = try TempDirectory()
    let paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path], homeDirectory: temp.path)
    try paths.createDirectories()
    let logger = try FileLogger(decisionLog: paths.decisionLog(.shadow), errorLog: paths.errorLog(.shadow))
    let interpreter = RecordingInterpreter(logger: logger, timeZone: TimeZone(secondsFromGMT: 0)!)
    let results = await interpreter.perform([.net(.probe), .net(.cycleWifi)], wall: Date())
    #expect(results.isEmpty)
  }

  @Test func aShadowEngineTickCarriesNoNetworkFacts() async throws {
    let temp = try TempDirectory()
    let paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path], homeDirectory: temp.path)
    let engine = try Composition.makeShadowEngine(
      paths: paths,
      settings: Settings(transcriptRoots: [temp.path + "/projects"], hotspot: "Test iPhone"),
      environment: [:],
      homeDirectory: temp.path,
      once: true,
      externalDisplays: { 0 },
      tools: FakeToolPort()
    )
    await engine.tick()
    #expect(await engine.state.network.facts == nil)
  }

  @Test func aLiveEngineWithTheDefaultPortCarriesNoNetworkFacts() async throws {
    let temp = try TempDirectory()
    let paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path], homeDirectory: temp.path)
    let recorder = HoldRecorder(stateFile: paths.stateFile(.live))
    let engine = try Composition.makeLiveEngine(
      paths: paths,
      settings: Settings(transcriptRoots: [temp.path + "/projects"], hotspot: "Test iPhone"),
      ports: LivePorts(
        assertions: FakeAssertionPort(), tools: FakeToolPort(), clamshell: FakeClamshellPort(recorder: recorder),
        stateFile: paths.stateFile(.live), makeSentinel: { [recorder] in FakeSentinelPort(recorder: recorder) }),
      environment: [:],
      homeDirectory: temp.path,
      once: true,
      clock: FakeClock(),
      externalDisplays: { 0 }
    )
    await engine.tick()
    #expect(await engine.state.network.facts == nil)
  }
}
