import Foundation
import OvertimeCore
import OvertimeEngine
import Testing

@testable import OvertimeSystem

struct NetworkMarkerReleaseTests {
  typealias PortFixture = NetworkCompositionTests.PortFixture

  static func stillOff(recoveryWaitSeconds: Double = WiFiController.actuationWaitSeconds) async throws -> PortFixture {
    let failure = CycleFixture.failure
    let fixture = try await PortFixture(
      FakeWiFiRadio.Script(setPowerResults: [.success(()), failure, failure]),
      recoveryWaitSeconds: recoveryWaitSeconds)
    let port = fixture.port
    #expect(port.facts(lidClosed: true)?.wifiPowered == true)
    #expect(await OffPool.bounded(seconds: 10) { port.cycleWifi() } == WiFiController.Code.stillOff.outcome)
    #expect(fixture.marker.read() == .present(interface: "en0"))
    #expect(fixture.radio.powered == false)
    return fixture
  }

  static func turnedOffByTheUser(_ fixture: PortFixture) throws {
    fixture.radio.update { $0.powered = false }
    try NetworkRecoveryTriggerTests.serve("wifiOff", on: fixture)
  }

  @Test func aMarkerKeptByAFailedCycleIsRemovedOnceWiFiIsSeenOnSoALaterUserOffIsNeverUndone() async throws {
    let fixture = try await Self.stillOff()
    let port = fixture.port
    let writes = fixture.radio.writes
    let tools = fixture.toolCalls
    fixture.radio.update { $0.powered = true }
    try NetworkRecoveryTriggerTests.serve(NetworkCompositionTests.deadNetworkCase, on: fixture)
    #expect(port.facts(lidClosed: true)?.wifiPowered == true)
    #expect(await OffPool.eventually(seconds: 5) { fixture.marker.read() == .absent })
    #expect(fixture.radio.writes == writes)
    #expect(fixture.toolCalls == tools)

    try Self.turnedOffByTheUser(fixture)
    for _ in 0..<3 {
      #expect(port.facts(lidClosed: true)?.wifiPowered == false)
      fixture.clock.advance(seconds: 31)
    }
    try await NetworkCompositionTests.settle()
    #expect(fixture.radio.powered == false)
    #expect(fixture.radio.writes == writes)

    #expect(fixture.marker.write(interface: "en0", startedAt: fixture.clock.wall()))
    #expect(port.facts(lidClosed: true)?.wifiPowered == false)
    #expect(await OffPool.eventually(seconds: 5) { fixture.radio.powered == true })
  }

  @Test func aMarkerKeptForAnOffCallStillPendingStaysWhileWiFiReadsOnAndGoesOnceTheCallReturned() async throws {
    let fixture = try await PortFixture(WiFiMarkerSettleTests.timedOutOff(pending: true))
    let port = fixture.port
    #expect(port.facts(lidClosed: true)?.wifiPowered == true)
    #expect(await OffPool.bounded(seconds: 10) { port.cycleWifi() } == .succeeded)
    #expect(fixture.marker.read() == .present(interface: "en0"))
    let reads = fixture.radio.calls.count
    #expect(port.facts(lidClosed: true)?.wifiPowered == true)
    #expect(await OffPool.eventually(seconds: 5) { fixture.radio.calls.count > reads })
    #expect(await OffPool.bounded(seconds: 30) { port.recoverIfLeftOff(waitSeconds: 20) } == .succeeded)
    #expect(fixture.marker.read() == .present(interface: "en0"))

    let writes = fixture.radio.writes
    fixture.radio.update { $0.powerCallPending = false }
    fixture.clock.advance(seconds: 31)
    #expect(port.facts(lidClosed: true)?.wifiPowered == true)
    #expect(await OffPool.eventually(seconds: 5) { fixture.marker.read() == .absent })
    #expect(fixture.radio.writes == writes)
  }

  @Test func theRemovalNeverTouchesTheMarkerOfACycleStillRunning() async throws {
    let fixture = try await Self.stillOff(recoveryWaitSeconds: 0.2)
    let port = fixture.port
    let radio = fixture.radio
    defer {
      if radio.isHolding { radio.release() }
    }
    radio.update { script in
      script.powered = true
      script.setPowerResults = []
      script.holdNext = .setPower
    }
    let cycle = Task { await OffPool.bounded(seconds: 10) { port.cycleWifi() } }
    #expect(await OffPool.eventually(seconds: 5) { radio.isHolding })
    #expect(fixture.marker.read() == .present(interface: "en0"))
    let started = try #require(fixture.marker.readWithStart().startedAt)
    for _ in 0..<3 {
      #expect(port.facts(lidClosed: true)?.wifiPowered == true)
      try await Task.sleep(for: .milliseconds(400))
      #expect(fixture.marker.readWithStart().startedAt == started)
    }
    radio.release()
    #expect(await cycle.value == .succeeded)
    #expect(fixture.marker.read() == .absent)
    #expect(radio.powered == true)
  }

  @Test func aMarkerFoundAtLaunchIsRemovedOnTheFirstReadThatShowsWiFiOn() async throws {
    let fixture = try await PortFixture()
    #expect(fixture.marker.write(interface: "en0", startedAt: fixture.clock.wall()))
    #expect(fixture.port.facts(lidClosed: false)?.wifiPowered == true)
    #expect(await OffPool.eventually(seconds: 5) { fixture.marker.read() == .absent })
    #expect(fixture.radio.writes.isEmpty)
    #expect(fixture.toolCalls.isEmpty)
  }

  @Test func withWiFiOnAndNoMarkerKeptTheMarkerFileIsNotReadOnEachTick() async throws {
    let fixture = try await PortFixture()
    let port = fixture.port
    #expect(port.facts(lidClosed: false)?.wifiPowered == true)
    #expect(fixture.marker.write(interface: "en0", startedAt: fixture.clock.wall()))
    for _ in 0..<5 {
      #expect(port.facts(lidClosed: true)?.wifiPowered == true)
      fixture.clock.advance(seconds: 31)
    }
    try await NetworkCompositionTests.settle()
    #expect(fixture.marker.read() == .present(interface: "en0"))
    #expect(fixture.radio.calls.isEmpty)
  }
}
