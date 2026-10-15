import Foundation
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing

struct NetworkCycleOutcomeTests {
  struct Case: Sendable, CustomTestStringConvertible {
    let label: String
    let answer: EffectOutcome
    let expected: NetCycleOutcome

    var testDescription: String { label }
  }

  static func code(_ code: WiFiController.Code) -> EffectOutcome {
    code.outcome
  }

  static let cases: [Case] = [
    Case(label: "succeeded", answer: .succeeded, expected: .succeeded),
    Case(label: "admin required", answer: code(.adminRequired), expected: .adminRequired),
    Case(label: "off failed but on confirmed", answer: code(.offFailed), expected: .failed),
    Case(label: "still off", answer: code(.stillOff), expected: .failed),
    Case(label: "controller busy", answer: code(.busy), expected: .refused),
    Case(label: "no Wi-Fi interface", answer: code(.invalidInterface), expected: .refused),
    Case(label: "marker not written", answer: code(.markerFailed), expected: .refused),
    Case(label: "Wi-Fi off", answer: code(.wifiOff), expected: .refused),
    Case(label: "Wi-Fi power unreadable", answer: code(.powerUnknown), expected: .powerUnknown),
    Case(label: "no port", answer: .failed(code: NoNetworkPort.disabledCode), expected: .refused),
    Case(label: "port timed out", answer: .timedOut, expected: .failed),
  ]

  @Test(arguments: cases)
  func everyCycleReportsItsOutcomeOnTheNetworkStream(_ testCase: Case) async throws {
    let answer = testCase.answer
    let harness = try NetworkLaneHarness(port: ClosureNetworkPort(onCycle: { answer }), bounds: .standard)
    _ = harness.enqueue([.net(.cycleWifi)])
    #expect(await harness.collector.waitFor(count: 1))
    #expect(harness.collector.events == [.netCycleDone(testCase.expected)])
    withExtendedLifetime(harness.interpreter) {}
  }

  @Test func aCycleThatOutlivesTheLaneBoundCountsAsRunAndOneTheLaneCannotAdmitAsRefused() async throws {
    let port = BlockingNetworkPort(blocking: [.cycle])
    defer { port.release() }
    let harness = try NetworkLaneHarness(port: port)
    _ = harness.enqueue([.net(.cycleWifi)])
    #expect(await harness.collector.waitFor(count: 1))
    _ = harness.enqueue([.net(.cycleWifi)])
    #expect(await harness.collector.waitFor(count: 2))
    #expect(harness.collector.events == [.netCycleDone(.failed), .netCycleDone(.refused)])
    withExtendedLifetime(harness.interpreter) {}
  }

  @Test func aJoinStillYieldsNoEvent() async throws {
    let harness = try NetworkLaneHarness(
      port: ClosureNetworkPort(onJoin: { _ in .succeeded }, onCycle: { .succeeded }), bounds: .standard)
    _ = harness.enqueue([.net(.joinHotspot("Test iPhone")), .net(.cycleWifi)])
    #expect(await harness.collector.waitFor(count: 1))
    try await Task.sleep(for: .milliseconds(100))
    #expect(harness.collector.events == [.netCycleDone(.succeeded)])
    withExtendedLifetime(harness.interpreter) {}
  }
}
