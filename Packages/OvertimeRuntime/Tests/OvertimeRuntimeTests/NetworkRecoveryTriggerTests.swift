import Foundation
import OvertimeCore
import OvertimeEngine
import Testing

@testable import OvertimeSystem

struct NetworkRecoveryTriggerTests {
  typealias PortFixture = NetworkCompositionTests.PortFixture

  static func serve(_ name: String, on fixture: PortFixture) throws {
    let synthetic = try NetworkFixture.synthetic()
    fixture.store.serve(try #require(synthetic[name]))
    fixture.store.fire([])
  }

  static func attempts(_ fixture: PortFixture) -> Int {
    fixture.radio.calls.filter { $0 == .interfaceName }.count
  }

  @Test func wiFiThatACycleLeftOffWithTheLidClosedComesBackOnWithoutALidOpen() async throws {
    let fixture = try await PortFixture(NetworkCompositionTests.leftOff, networkCase: "wifiOff")
    #expect(fixture.marker.write(interface: "en0", startedAt: fixture.clock.wall()))
    #expect(fixture.port.facts(lidClosed: true)?.wifiPowered == false)
    #expect(await OffPool.eventually(seconds: 5) { fixture.marker.read() == .absent })
    #expect(fixture.radio.powered == true)
    #expect(fixture.radio.writes == [.setPower(interface: "en0", on: true)])
    #expect(fixture.toolCalls.isEmpty)
  }

  @Test func aCycleThatCouldNotTurnWiFiBackOnIsUndoneWhileTheLidStaysClosed() async throws {
    let failure = CycleFixture.failure
    let fixture = try await PortFixture(FakeWiFiRadio.Script(setPowerResults: [.success(()), failure, failure]))
    let port = fixture.port
    #expect(port.facts(lidClosed: true)?.wifiPowered == true)
    #expect(await OffPool.bounded(seconds: 10) { port.cycleWifi() } == WiFiController.Code.stillOff.outcome)
    #expect(fixture.marker.read() == .present(interface: "en0"))
    #expect(fixture.radio.powered == false)
    try Self.serve("wifiOff", on: fixture)
    #expect(port.facts(lidClosed: true)?.wifiPowered == false)
    #expect(await OffPool.eventually(seconds: 5) { fixture.radio.powered == true })
    #expect(await OffPool.eventually(seconds: 5) { fixture.marker.read() == .absent })
  }

  @Test func anOffThatLandsAfterTheCycleWatchedItIsUndoneWhileTheLidStaysClosed() async throws {
    let fixture = try await PortFixture(WiFiMarkerSettleTests.timedOutOff(pending: true))
    let port = fixture.port
    #expect(port.facts(lidClosed: true)?.wifiPowered == true)
    #expect(await OffPool.bounded(seconds: 10) { port.cycleWifi() } == .succeeded)
    #expect(fixture.radio.powered == true)
    #expect(fixture.marker.read() == .present(interface: "en0"))
    fixture.radio.update { script in
      script.powered = false
      script.powerCallPending = false
    }
    try Self.serve("wifiOff", on: fixture)
    #expect(port.facts(lidClosed: true)?.wifiPowered == false)
    #expect(await OffPool.eventually(seconds: 5) { fixture.marker.read() == .absent })
    #expect(fixture.radio.powered == true)
  }

  @Test func anUnreadablePowerStateWithAMarkerAlsoTurnsWiFiBackOn() async throws {
    let fixture = try await PortFixture(NetworkCompositionTests.leftOff, networkCase: "wifiOff")
    fixture.store.failReads(true)
    fixture.store.fire([])
    #expect(fixture.marker.write(interface: "en0", startedAt: fixture.clock.wall()))
    #expect(fixture.port.facts(lidClosed: true) == nil)
    #expect(await OffPool.eventually(seconds: 5) { fixture.marker.read() == .absent })
    #expect(fixture.radio.powered == true)
  }

  @Test func withNoMarkerWiFiTheUserTurnedOffIsNeverTouched() async throws {
    let fixture = try await PortFixture(NetworkCompositionTests.leftOff, networkCase: "wifiOff")
    let port = fixture.port
    for _ in 0..<3 {
      _ = port.facts(lidClosed: true)
      fixture.clock.advance(seconds: 31)
    }
    try await NetworkCompositionTests.settle()
    #expect(fixture.radio.calls.isEmpty)
    #expect(fixture.toolCalls.isEmpty)
  }

  @Test func aLidOpenRecoveryThatMeetsARunningCycleIsNotLoggedAndRunsAgainAfterIt() async throws {
    let failure = CycleFixture.failure
    var script = FakeWiFiRadio.Script(setPowerResults: [.success(()), failure, failure])
    script.holdNext = .setPower
    let fixture = try await PortFixture(script, recoveryWaitSeconds: 0.2)
    let port = fixture.port
    let radio = fixture.radio
    defer {
      if radio.isHolding { radio.release() }
    }
    let sink = NetworkCompositionTests.Sink()
    port.attachLog { sink.append($0) }
    let cycle = Task { await OffPool.bounded(seconds: 10) { port.cycleWifi() } }
    #expect(await OffPool.eventually(seconds: 5) { radio.isHolding })
    _ = port.facts(lidClosed: true)
    _ = port.facts(lidClosed: false)
    try await Task.sleep(for: .milliseconds(600))
    _ = port.facts(lidClosed: false)
    try await Task.sleep(for: .milliseconds(600))
    #expect(sink.decisions.isEmpty)
    radio.release()
    #expect(await cycle.value == WiFiController.Code.stillOff.outcome)
    #expect(fixture.marker.read() == .present(interface: "en0"))
    #expect(radio.powered == false)
    let deadline = ContinuousClock.now + .seconds(5)
    while fixture.marker.read() != .absent, ContinuousClock.now < deadline {
      _ = port.facts(lidClosed: false)
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(fixture.marker.read() == .absent)
    #expect(radio.powered == true)
    #expect(sink.decisions.isEmpty)
  }

  @Test func aRecoveryThatKeepsFailingLogsOncePerStreakAndRetriesOnAChangeOrEveryThirtySeconds() async throws {
    let fixture = try await PortFixture(
      FakeWiFiRadio.Script(powered: false, powerFollowsWrites: false), networkCase: "wifiOff")
    let port = fixture.port
    let sink = NetworkCompositionTests.Sink()
    port.attachLog { sink.append($0) }
    #expect(fixture.marker.write(interface: "en0", startedAt: fixture.clock.wall()))
    _ = port.facts(lidClosed: true)
    #expect(await OffPool.eventually(seconds: 5) { sink.decisions.count == 1 })
    #expect(Self.attempts(fixture) == 1)
    let code = String(WiFiController.Code.stillOff.rawValue)
    #expect(sink.decisions == [LiveNetworkPort.recoveryFailure(result: code)])

    _ = port.facts(lidClosed: true)
    fixture.clock.advance(seconds: 29)
    _ = port.facts(lidClosed: true)
    try await NetworkCompositionTests.settle()
    #expect(Self.attempts(fixture) == 1)

    fixture.clock.advance(seconds: 1)
    _ = port.facts(lidClosed: true)
    #expect(await OffPool.eventually(seconds: 5) { Self.attempts(fixture) == 2 })

    fixture.store.failReads(true)
    fixture.store.fire([])
    _ = port.facts(lidClosed: true)
    #expect(await OffPool.eventually(seconds: 5) { Self.attempts(fixture) == 3 })
    try await NetworkCompositionTests.settle()
    #expect(sink.decisions.count == 1)
    #expect(fixture.marker.read() == .present(interface: "en0"))

    fixture.radio.update { $0.powerFollowsWrites = true }
    fixture.clock.advance(seconds: 30)
    _ = port.facts(lidClosed: true)
    #expect(await OffPool.eventually(seconds: 5) { fixture.marker.read() == .absent })

    fixture.radio.update { script in
      script.powered = false
      script.powerFollowsWrites = false
    }
    #expect(fixture.marker.write(interface: "en0", startedAt: fixture.clock.wall()))
    fixture.clock.advance(seconds: 30)
    _ = port.facts(lidClosed: true)
    #expect(await OffPool.eventually(seconds: 5) { sink.decisions.count == 2 })
  }
}
