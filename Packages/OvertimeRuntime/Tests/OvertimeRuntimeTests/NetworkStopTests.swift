import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeSystem
import Testing
import os

@testable import OvertimeEngine

struct NetworkStopTests {
  @Test func closingTheLaneLetsTheInFlightActionFinishAndDropsEveryQueuedOrLaterAction() async throws {
    let harness = try EngineNetworkLaneTests.Harness()
    let port = BlockingNetworkPort(facts: EngineNetworkLaneTests.facts, blocking: [.cycle])
    defer { port.release() }
    let interpreter = try harness.interpreter(network: port)
    _ = interpreter.enqueue([.net(.cycleWifi)], wall: Date())
    _ = interpreter.enqueue([.net(.joinHotspot("Test iPhone"))], wall: Date())
    #expect(await OffPool.eventually { port.started == [.cycle] })
    interpreter.closeNetwork()
    _ = interpreter.enqueue([.net(.probe), .net(.cycleWifi)], wall: Date())
    port.release()
    #expect(await Engine.bounded(seconds: 5) { await interpreter.drainNetwork() })
    try await Task.sleep(for: .milliseconds(200))
    #expect(port.started == [.cycle])
    #expect(port.finished == [.cycle])
    withExtendedLifetime(interpreter) {}
  }

  @Test func anEngineStopClosesItsNetworkLane() async throws {
    let harness = try EngineNetworkLaneTests.Harness()
    let port = BlockingNetworkPort(facts: EngineNetworkLaneTests.facts, blocking: [])
    let interpreter = try harness.interpreter(network: port)
    let engine = harness.engine(interpreter, live: interpreter)
    #expect(await Engine.bounded(seconds: 10) { await engine.stop() })
    _ = interpreter.enqueue([.net(.cycleWifi), .net(.joinHotspot("Test iPhone"))], wall: Date())
    #expect(await Engine.bounded(seconds: 5) { await engine.networkLaneDrained() })
    try await Task.sleep(for: .milliseconds(200))
    #expect(port.started.isEmpty)
    withExtendedLifetime(interpreter) {}
  }

  @Test(arguments: [(0.0, 6.0), (1.0, 6.0), (2.0, 5.5), (6.0, 1.5), (7.5, 0.0), (20.0, 0.0)])
  func theStopRecoveryGetsUpToSixSecondsOfWhatTheTerminationBoundLeaves(_ elapsed: Double, _ budget: Double) {
    #expect(AppHost.stopRecoveryBudget(elapsed: elapsed, outerBound: 8) == budget)
  }

  struct HostFixture {
    let host: AppHost
    let lane: EngineNetworkLaneTests.Harness
    let interpreter: LiveInterpreter
    let network: NetworkCompositionTests.PortFixture
    let app: AppHostTests.Fixture

    init() async throws {
      app = try AppHostTests.Fixture()
      lane = try EngineNetworkLaneTests.Harness()
      network = try await NetworkCompositionTests.PortFixture(FakeWiFiRadio.Script(holdNext: .setPower))
      let interpreter = try lane.interpreter(network: network.port)
      self.interpreter = interpreter
      let engine = lane.engine(interpreter, live: interpreter)
      let lock = app.locks.primary
      host = AppHost(
        paths: app.paths, version: "0.1.0", environment: [:], homeDirectory: "/Users/dev", network: network.port,
        launcher: { _ in RunningInstance(engine: engine, lock: lock, server: nil) })
    }

    var decisionLog: String {
      (try? String(contentsOf: lane.paths.decisionLog(.live), encoding: .utf8)) ?? ""
    }

    func startCycleAndWaitUntilWiFiIsGoingOff() async -> Bool {
      guard case .running = await host.start(locks: app.locks) else { return false }
      _ = interpreter.enqueue([.net(.cycleWifi)], wall: Date())
      let radio = network.radio
      return await OffPool.eventually(seconds: 5) { radio.isHolding }
    }
  }

  @Test func aQuitDuringTheOffWindowWaitsForTheCycleThenRecoversBeforeTheProcessEnds() async throws {
    let fixture = try await HostFixture()
    let radio = fixture.network.radio
    defer {
      if radio.isHolding { radio.release() }
    }
    #expect(await fixture.startCycleAndWaitUntilWiFiIsGoingOff())
    #expect(fixture.network.marker.read() == .present(interface: "en0"))
    let releaser = Task {
      try? await Task.sleep(for: .seconds(3))
      radio.release()
    }
    #expect(await fixture.host.terminate())
    #expect(fixture.network.marker.read() == .absent)
    #expect(radio.powered == true)
    #expect(radio.writes == [.setPower(interface: "en0", on: false), .setPower(interface: "en0", on: true)])
    #expect(!fixture.decisionLog.contains("ERROR net failed"))
    await releaser.value
  }

  @Test func aCycleStillHungWhenTheStopBudgetEndsLogsTheRecoveryResultAndKeepsTheMarker() async throws {
    let fixture = try await HostFixture()
    let radio = fixture.network.radio
    defer {
      if radio.isHolding { radio.release() }
    }
    #expect(await fixture.startCycleAndWaitUntilWiFiIsGoingOff())
    #expect(await fixture.host.terminate())
    #expect(
      await OffPool.eventually(seconds: 5) {
        fixture.decisionLog.contains(" ERROR net failed action=wifiOn result=-31")
      })
    #expect(fixture.network.marker.read() == .present(interface: "en0"))
    radio.release()
  }
}
