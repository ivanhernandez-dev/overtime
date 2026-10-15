import Foundation
import OvertimeCore
import OvertimeEngine
import Testing
import os

@testable import OvertimeSystem

struct NetworkCompositionTests {
  static let hotspot = "Test iPhone"
  static let deadNetworkCase = "routerMismatch"

  enum FixtureError: Error {
    case missingCase(String)
  }

  struct PortFixture {
    let temp: TempDirectory
    let paths: Paths
    let store: FakeNetworkStore
    let stubbed: StubbedProbe
    let radio: FakeWiFiRadio
    let tools: ToolFactoryRecorder
    let grant: LocationGrant
    let clock = FakeClock()
    let port: LiveNetworkPort

    init(
      _ script: FakeWiFiRadio.Script = FakeWiFiRadio.Script(),
      networkCase: String = NetworkCompositionTests.deadNetworkCase,
      location: Bool = false,
      recoveryWaitSeconds: Double = WiFiController.actuationWaitSeconds
    ) async throws {
      temp = try TempDirectory()
      paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path], homeDirectory: temp.path)
      try paths.createDirectories()
      guard let fixture = try NetworkFixture.synthetic()[networkCase] else {
        throw FixtureError.missingCase(networkCase)
      }
      store = FakeNetworkStore(fixture)
      stubbed = StubbedProbe(primary: .fail, captive: .fail)
      var script = script
      script.markerURL = paths.wifiCycleMarker
      radio = FakeWiFiRadio(script, clock: clock)
      tools = ToolFactoryRecorder(FakeToolPort())
      grant = LocationGrant(authorized: location)
      port = LiveNetworkPort.compose(
        paths: paths, location: grant, source: store, knownNetworks: { [NetworkCompositionTests.hotspot] },
        probe: stubbed.probe, radio: radio, clock: clock, makeTools: tools.make, sleep: { _ in },
        recoveryWaitSeconds: recoveryWaitSeconds)
      _ = await port.start().value
    }

    var marker: WiFiCycleMarker {
      WiFiCycleMarker(url: paths.wifiCycleMarker)
    }

    var toolCalls: [FakeToolPort.Call] {
      tools.tool.calls
    }
  }

  static func joinCall(_ name: String) -> FakeToolPort.Call {
    FakeToolPort.Call(executable: "/usr/sbin/networksetup", arguments: ["-setairportnetwork", "en0", name])
  }

  @Test func aClosedDeadNetworkEpisodeProbesThreeTimesAndJoinsTheHotspotThroughTheLivePort() async throws {
    let fixture = try await PortFixture()
    let port = fixture.port
    #expect(port.facts(lidClosed: false)?.onHotspot == false)
    let harness = try EngineNetworkLaneTests.Harness()
    let interpreter = try harness.interpreter(network: port)
    let engine = harness.engine(
      interpreter, live: interpreter,
      sampleTick: {
        TickFacts(lidClosed: true, externalDisplays: 0, fullWake: true, network: port.facts(lidClosed: true))
      })
    let collector = NetworkEventCollector(try #require(interpreter.networkEvents))
    await engine.step(.transcriptActivity(TranscriptActivity(at: harness.clock.mono())))
    await engine.step(.tick(TickFacts(lidClosed: false)))
    var stepped = 0
    var probes = 0
    for _ in 0..<40 {
      let before = await engine.state.network.nextProbe
      #expect(await Engine.bounded(seconds: 5) { await engine.tick() })
      if await engine.state.network.nextProbe != before {
        probes += 1
        #expect(await collector.waitFor(count: probes))
      }
      let events = collector.events
      while stepped < events.count {
        await engine.step(events[stepped])
        stepped += 1
      }
      if await engine.state.network.fails >= Timing.netFailsNeeded { break }
      harness.clock.advance(seconds: Timing.tickSeconds)
    }
    #expect(probes == Timing.netFailsNeeded)
    #expect(collector.events == Array(repeating: .netProbeResult(online: false), count: Timing.netFailsNeeded))
    #expect(StubURLProtocol.requests(to: fixture.stubbed.primaryHost).count == Timing.netFailsNeeded)
    #expect(await OffPool.eventually(seconds: 5) { !fixture.toolCalls.isEmpty })
    try await Task.sleep(for: .milliseconds(200))
    #expect(fixture.toolCalls == [Self.joinCall(Self.hotspot)])
    #expect(!fixture.radio.calls.contains { $0.kind == .joinSaved })
    withExtendedLifetime(interpreter) {}
  }

  @Test func theFirstLidCloseAfterLaunchCanArmFailoverAndStartsNoProcess() async throws {
    let temp = try TempDirectory()
    let paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path], homeDirectory: temp.path)
    try paths.createDirectories()
    let fixture = try #require(try NetworkFixture.synthetic()[Self.deadNetworkCase])
    let store = FakeNetworkStore(fixture)
    let stubbed = StubbedProbe(primary: .fail, captive: .fail)
    let clock = FakeClock()
    var script = FakeWiFiRadio.Script()
    script.markerURL = paths.wifiCycleMarker
    let radio = FakeWiFiRadio(script, clock: clock)
    let tools = ToolFactoryRecorder(FakeToolPort())
    let port = LiveNetworkPort.compose(
      paths: paths, location: LocationGrant(authorized: false), source: store,
      knownNetworks: { [NetworkCompositionTests.hotspot] }, probe: stubbed.probe, radio: radio, clock: clock,
      makeTools: tools.make, sleep: { _ in }, recoveryWaitSeconds: WiFiController.actuationWaitSeconds)
    _ = await port.start().value
    let facts = try #require(port.facts(lidClosed: true))
    var state = AppState(mode: .shadow)
    state.network.facts = facts
    let settings = Settings(hotspot: NetworkCompositionTests.hotspot)
    #expect(NetworkFailover.readiness(state, settings: settings) == .armed(.configured))
    #expect(tools.timeouts.isEmpty)
    #expect(tools.tool.calls.isEmpty)
    withExtendedLifetime((temp, store, stubbed, radio)) {}
  }

  @Test func aChangedNetworkStoreRebuildsTheProbeSessionAndAnUnchangedOneKeepsIt() async throws {
    let fixture = try await PortFixture()
    let port = fixture.port
    let probe = fixture.stubbed.probe
    #expect(await OffPool.bounded(seconds: 5) { port.probe() } == false)
    #expect(probe.sessionGeneration == 1)
    fixture.store.fire([])
    #expect(await OffPool.bounded(seconds: 5) { port.probe() } == false)
    #expect(probe.sessionGeneration == 1)
    let hotspot = try #require(try NetworkFixture.synthetic()["hotspotOnly"])
    fixture.store.serve(hotspot)
    fixture.store.fire([])
    #expect(await OffPool.bounded(seconds: 5) { port.probe() } == false)
    #expect(probe.sessionGeneration == 2)
    withExtendedLifetime(port) {}
  }

  static let leftOff = FakeWiFiRadio.Script(powered: false)

  final class Sink: Sendable {
    private let box = OSAllocatedUnfairLock<[Decision]>(initialState: [])

    var decisions: [Decision] {
      box.withLock { $0 }
    }

    func append(_ decision: Decision) {
      box.withLock { $0.append(decision) }
    }
  }

  static func seconds(_ body: () -> Void) -> Double {
    let start = ContinuousClock.now
    body()
    let elapsed = ContinuousClock.now - start
    return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
  }

  static func settle() async throws {
    try await Task.sleep(for: .milliseconds(300))
  }

  static func plantUnkept(_ fixture: PortFixture) -> Bool {
    _ = fixture.port.facts(lidClosed: nil)
    return fixture.marker.write(interface: "en0", startedAt: Date())
  }

  @Test func aLidOpeningTurnsBackOnWiFiThatACycleLeftOffAndRemovesTheMarker() async throws {
    let fixture = try await PortFixture(Self.leftOff)
    #expect(Self.plantUnkept(fixture))
    _ = fixture.port.facts(lidClosed: true)
    try await Self.settle()
    #expect(fixture.radio.calls.isEmpty)
    _ = fixture.port.facts(lidClosed: false)
    #expect(await OffPool.eventually(seconds: 5) { fixture.marker.read() == .absent })
    #expect(fixture.radio.powered == true)
    #expect(fixture.radio.writes == [.setPower(interface: "en0", on: true)])
    #expect(fixture.toolCalls.isEmpty)
  }

  @Test func withNoMarkerALidOpeningMakesNoRadioCall() async throws {
    let fixture = try await PortFixture(Self.leftOff)
    _ = fixture.port.facts(lidClosed: true)
    _ = fixture.port.facts(lidClosed: false)
    try await Self.settle()
    #expect(fixture.radio.calls.isEmpty)
    #expect(fixture.toolCalls.isEmpty)
  }

  @Test func aRecoveryThatCannotTurnWiFiOnLogsTheActionAndItsCodeThroughTheSink() async throws {
    let fixture = try await PortFixture(FakeWiFiRadio.Script(powered: false, powerFollowsWrites: false))
    let sink = Sink()
    fixture.port.attachLog { sink.append($0) }
    #expect(fixture.marker.write(interface: "en0", startedAt: Date()))
    _ = fixture.port.facts(lidClosed: true)
    _ = fixture.port.facts(lidClosed: false)
    #expect(await OffPool.eventually(seconds: 5) { !sink.decisions.isEmpty })
    try await Self.settle()
    let code = String(WiFiController.Code.stillOff.rawValue)
    #expect(sink.decisions == [LiveNetworkPort.recoveryFailure(result: code)])
    let line = DecisionFormatter.line(try #require(sink.decisions.first), wall: Date(), timeZone: .current)
    #expect(line.hasSuffix(" ERROR net failed action=wifiOn result=-29"))
    #expect(fixture.marker.read() != .absent)
  }

  @Test func laterOpenReadsStartNothingUntilTheLidClosesAndOpensAgain() async throws {
    let fixture = try await PortFixture(Self.leftOff)
    let port = fixture.port
    #expect(Self.plantUnkept(fixture))
    _ = port.facts(lidClosed: true)
    _ = port.facts(lidClosed: false)
    #expect(await OffPool.eventually(seconds: 5) { fixture.marker.read() == .absent })
    #expect(fixture.radio.writes.count == 1)
    #expect(fixture.marker.write(interface: "en0", startedAt: Date()))
    fixture.radio.update { $0.powered = false }
    _ = port.facts(lidClosed: false)
    _ = port.facts(lidClosed: nil)
    _ = port.facts(lidClosed: false)
    try await Self.settle()
    #expect(fixture.radio.writes.count == 1)
    #expect(fixture.marker.read() == .present(interface: "en0"))
    _ = port.facts(lidClosed: true)
    _ = port.facts(lidClosed: false)
    #expect(await OffPool.eventually(seconds: 5) { fixture.marker.read() == .absent })
    #expect(fixture.radio.writes.count == 2)
  }

  @Test func aLidReadThatIsUnknownBetweenTheCloseAndTheOpenStillCountsAsAnOpening() async throws {
    let fixture = try await PortFixture(Self.leftOff)
    #expect(Self.plantUnkept(fixture))
    _ = fixture.port.facts(lidClosed: true)
    _ = fixture.port.facts(lidClosed: nil)
    try await Self.settle()
    #expect(fixture.radio.calls.isEmpty)
    _ = fixture.port.facts(lidClosed: false)
    #expect(await OffPool.eventually(seconds: 5) { fixture.marker.read() == .absent })
    #expect(fixture.radio.powered == true)
  }

  @Test func theOpenReadReturnsAtOnceWhileItsRecoveryIsStillRunning() async throws {
    var script = Self.leftOff
    script.holdNext = .powerOn
    let fixture = try await PortFixture(script)
    let port = fixture.port
    let radio = fixture.radio
    defer {
      if radio.isHolding { radio.release() }
    }
    #expect(fixture.marker.write(interface: "en0", startedAt: Date()))
    let closing = await OffPool.bounded(seconds: 30) { Self.seconds { _ = port.facts(lidClosed: true) } }
    #expect(try #require(closing) < 3)
    let opening = await OffPool.bounded(seconds: 30) { Self.seconds { _ = port.facts(lidClosed: false) } }
    #expect(try #require(opening) < 3)
    #expect(await OffPool.eventually(seconds: 5) { radio.isHolding })
    let during = await OffPool.bounded(seconds: 30) { Self.seconds { _ = port.facts(lidClosed: false) } }
    #expect(try #require(during) < 3)
    #expect(fixture.marker.read() == .present(interface: "en0"))
    radio.release()
    #expect(await OffPool.eventually(seconds: 5) { fixture.marker.read() == .absent })
  }

  @Test func theLidOpenRecoveryIsNotHeldBackByTheAdministratorFlags() async throws {
    let fixture = try await PortFixture(
      FakeWiFiRadio.Script(admin: AdminRequirements(power: true, association: true), powered: false))
    #expect(fixture.marker.write(interface: "en0", startedAt: Date()))
    _ = fixture.port.facts(lidClosed: true)
    _ = fixture.port.facts(lidClosed: false)
    #expect(await OffPool.eventually(seconds: 5) { fixture.marker.read() == .absent })
    #expect(fixture.radio.writes == [.setPower(interface: "en0", on: true)])
  }

  @Test func withoutLocationAJoinUsesTheToolAndOnceGrantedTheNextJoinUsesTheRadio() async throws {
    let fixture = try await PortFixture()
    let port = fixture.port
    #expect(await OffPool.bounded(seconds: 5) { port.joinHotspot(Self.hotspot) } == .succeeded)
    #expect(fixture.toolCalls == [Self.joinCall(Self.hotspot)])
    #expect(!fixture.radio.calls.contains { $0.kind == .joinSaved })
    fixture.grant.set(true)
    #expect(fixture.grant.isAuthorized)
    #expect(await OffPool.bounded(seconds: 5) { port.joinHotspot(Self.hotspot) } == .succeeded)
    #expect(fixture.radio.calls.contains(.joinSaved(interface: "en0", ssid: Self.hotspot)))
    #expect(fixture.toolCalls == [Self.joinCall(Self.hotspot)])
  }

  @Test func shadowAndOnceRunsBuiltWithTheDefaultPortsCarryNoNetworkFacts() async throws {
    let harness = try EngineLidTests.Harness()
    let shadow = try harness.shadowEngine()
    await shadow.tick()
    #expect(await shadow.state.network.facts == nil)
    let once = try harness.liveEngine()
    await once.tick()
    #expect(await once.state.network.facts == nil)
    let recorder = HoldRecorder(stateFile: harness.paths.stateFile(.live))
    let ports = LivePorts(
      assertions: FakeAssertionPort(), tools: FakeToolPort(), clamshell: FakeClamshellPort(recorder: recorder),
      stateFile: harness.paths.stateFile(.live), makeSentinel: { FakeSentinelPort(recorder: recorder) })
    #expect(ports.network is NoNetworkPort)
  }

  @Test func onlyTheAppBuildsTheLivePortAndNoOtherEntryPointNamesIt() throws {
    let files = try NetworkSourceGateTests.corpus()
    let own = "Packages/OvertimeRuntime/Sources/OvertimeSystem/LiveNetworkPort.swift"
    let systemBuilders = files.filter { $0.text.contains("LiveNetworkPort.system(") }.map(\.path)
    #expect(systemBuilders == ["Sources/Overtime/AppDelegate.swift"])
    let delegate = try #require(files.first { $0.path == "Sources/Overtime/AppDelegate.swift" })
    #expect(delegate.text.components(separatedBy: "LiveNetworkPort.system(").count == 2)
    let otherBuilders = files.filter {
      $0.text.contains("LiveNetworkPort(") || $0.text.contains("LiveNetworkPort.compose(")
        || $0.text.contains(".compose(paths:")
    }.map(\.path)
    #expect(otherBuilders == [own])
    for prefix in ["Packages/OvertimeRuntime/Sources/overtimed/", "Packages/OvertimeRuntime/Sources/OvertimeEngine/"] {
      let scoped = files.filter { $0.path.hasPrefix(prefix) }
      #expect(!scoped.isEmpty, "no sources under \(prefix)")
      #expect(!scoped.contains { $0.text.contains("LiveNetworkPort") }, "\(prefix) names the live port")
    }
    let package = files.filter { $0.path.hasPrefix("Packages/OvertimeRuntime/Sources/") }
    #expect(!package.contains { $0.text.contains("CoreLocation") })
  }
}
