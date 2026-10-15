import Foundation
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing

struct NetworkProbeAdmissionTests {
  static let busyJoin = " ERROR net failed action=joinHotspot result=busy"

  @Test func aProbeThatRanPastItsBoundCountsAsOffline() async throws {
    let port = BlockingNetworkPort(blocking: [.probe])
    defer { port.release() }
    port.answerProbes([], otherwise: true)
    let harness = try NetworkLaneHarness(port: port)
    _ = harness.enqueue([.net(.probe)])
    #expect(await harness.collector.waitFor(count: 1))
    #expect(harness.collector.events == [.netProbeResult(online: false)])
    #expect(port.count(.probe) == 1)
    #expect(port.finished.isEmpty)
    withExtendedLifetime(harness.interpreter) {}
  }

  @Test func whileAProbeStillRunsTheNextProbeYieldsNothingAndAJoinLogsBusy() async throws {
    let port = BlockingNetworkPort(blocking: [.probe, .join])
    defer { port.release() }
    port.answerProbes([], otherwise: true)
    let harness = try NetworkLaneHarness(port: port)
    _ = harness.enqueue([.net(.probe)])
    #expect(await harness.collector.waitFor(count: 1))
    let linesBefore = harness.lines
    _ = harness.enqueue([.net(.probe)])
    _ = harness.enqueue([.net(.joinHotspot("Test iPhone"))])
    #expect(await harness.logged(Self.busyJoin))
    #expect(harness.lines == linesBefore + harness.lines.filter { $0.hasSuffix(Self.busyJoin) })
    #expect(harness.lines.filter { $0.hasSuffix(Self.busyJoin) }.count == 1)
    #expect(harness.collector.events == [.netProbeResult(online: false)])
    #expect(port.count(.probe) == 1)
    #expect(port.count(.join) == 0)
    withExtendedLifetime(harness.interpreter) {}
  }

  @Test func onceTheEarlierCallEndsTheNextProbeIsAdmittedAndItsAnswerIsYielded() async throws {
    let port = BlockingNetworkPort(blocking: [.join])
    defer { port.release() }
    port.answerProbes([], otherwise: true)
    let bounds = LiveInterpreter.NetworkBounds(probe: 30, join: 0.2, cycle: 30)
    let harness = try NetworkLaneHarness(port: port, bounds: bounds)
    _ = harness.enqueue([.net(.joinHotspot("Test iPhone"))])
    #expect(await harness.logged(" ERROR net failed action=joinHotspot result=timedOut"))
    #expect(port.finished.isEmpty)
    port.release()
    #expect(await OffPool.eventually { port.finished.count == 1 })
    var admitted = false
    let deadline = ContinuousClock.now + .seconds(10)
    while !admitted, ContinuousClock.now < deadline {
      _ = harness.enqueue([.net(.probe)])
      admitted = await harness.collector.waitFor(count: 1, seconds: 0.25)
    }
    #expect(admitted)
    #expect(harness.collector.events.allSatisfy { $0 == .netProbeResult(online: true) })
    #expect(port.count(.probe) >= 1)
    withExtendedLifetime(harness.interpreter) {}
  }
}
