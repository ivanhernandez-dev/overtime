import Foundation
import Testing

@testable import OvertimeCore

@Suite("HOLD-10 and HOLD-03 display assertion gating")
struct DisplayAssertionGatingTests {
  static func harness(keepDisplayOn: Bool) -> ScenarioHarness {
    var harness = ScenarioHarness(settings: Settings(keepDisplayOn: keepDisplayOn))
    harness.includeActuators = true
    return harness
  }

  static func facts(lidClosed: Bool?, externalDisplays: Int? = nil) -> TickFacts {
    TickFacts(lidClosed: lidClosed, externalDisplays: externalDisplays)
  }

  static func busyTick(
    _ harness: inout ScenarioHarness, at seconds: Double, lidClosed: Bool?, externalDisplays: Int? = nil
  ) -> [Effect] {
    _ = harness.activity(writtenAt: seconds, seenAt: seconds)
    let effects = harness.send(.tick(facts(lidClosed: lidClosed, externalDisplays: externalDisplays)), at: seconds)
    answer(&harness, effects, at: seconds)
    return effects
  }

  static func answer(_ harness: inout ScenarioHarness, _ effects: [Effect], at seconds: Double) {
    for effect in effects {
      switch effect {
      case .idleAssertion(_, let id), .displayAssertion(_, let id):
        _ = harness.send(.effectResult(id, .succeeded), at: seconds + 0.001)
      default:
        continue
      }
    }
  }

  static func display(_ effects: [Effect]) -> [AssertionAction] {
    effects.compactMap { effect in
      if case .displayAssertion(let action, _) = effect { return action }
      return nil
    }
  }

  static func isActuator(_ effect: Effect) -> Bool {
    ScenarioHarness.isActuator(effect)
  }

  @Test(arguments: [Optional(false), Optional(true), nil])
  func keepDisplayOnOffNeverTakesADisplayAssertion(lidClosed: Bool?) {
    var harness = Self.harness(keepDisplayOn: false)
    var all: [Effect] = []
    for second in stride(from: 0.0, through: 10.0, by: 2.0) {
      all += Self.busyTick(&harness, at: second, lidClosed: lidClosed, externalDisplays: 1)
    }
    all += harness.send(.tick(Self.facts(lidClosed: lidClosed)), at: 300)
    #expect(Self.display(all).isEmpty)
    #expect(harness.state.hold.display == .released)
  }

  @Test func wantedWithTheLidOpenAcquiresTheDisplayAssertion() {
    var harness = Self.harness(keepDisplayOn: true)
    let effects = Self.busyTick(&harness, at: 0, lidClosed: false)
    #expect(Self.display(effects) == [.acquireOrRenew(timeoutSeconds: 300)])
    #expect(harness.state.hold.display == .held)
    let renewal = Self.busyTick(&harness, at: 2, lidClosed: false)
    #expect(Self.display(renewal) == [.acquireOrRenew(timeoutSeconds: 300)])
  }

  @Test func unknownLidStateCountsAsOpen() {
    var harness = Self.harness(keepDisplayOn: true)
    let effects = Self.busyTick(&harness, at: 0, lidClosed: nil)
    #expect(Self.display(effects) == [.acquireOrRenew(timeoutSeconds: 300)])
  }

  @Test(arguments: [nil, Optional(0)])
  func closingTheLidWithoutAnExternalDisplayReleasesFirst(externalDisplays: Int?) {
    var harness = Self.harness(keepDisplayOn: true)
    _ = Self.busyTick(&harness, at: 0, lidClosed: false)
    #expect(harness.state.hold.display == .held)
    _ = harness.activity(writtenAt: 2, seenAt: 2)
    let closed = harness.send(.tick(Self.facts(lidClosed: true, externalDisplays: externalDisplays)), at: 2)
    #expect(Self.display(closed) == [.release])
    let actuators = closed.filter(Self.isActuator)
    guard case .displayAssertion(.release, let releaseID)? = actuators.first else {
      Issue.record("the display release is not the first actuator effect: \(closed)")
      return
    }
    #expect(harness.state.hold.display == .releasing(releaseID))
    #expect(
      harness.send(.effectResult(releaseID, .succeeded), at: 2.001) == [
        .log(Decision(keyword: .hold, verb: "display released"))
      ])
    let stillClosed = Self.busyTick(&harness, at: 4, lidClosed: true, externalDisplays: externalDisplays)
    #expect(Self.display(stillClosed).isEmpty)
    #expect(harness.state.hold.idle == .held)
  }

  @Test func closedLidWithAnExternalDisplayKeepsTheDisplayAssertion() {
    var harness = Self.harness(keepDisplayOn: true)
    _ = Self.busyTick(&harness, at: 0, lidClosed: false, externalDisplays: 1)
    let closed = Self.busyTick(&harness, at: 2, lidClosed: true, externalDisplays: 1)
    #expect(Self.display(closed) == [.acquireOrRenew(timeoutSeconds: 300)])
    #expect(harness.state.hold.display == .held)
    let unplugged = Self.busyTick(&harness, at: 4, lidClosed: true, externalDisplays: 0)
    #expect(Self.display(unplugged) == [.release])
  }

  @Test func reopeningTheLidReacquires() {
    var harness = Self.harness(keepDisplayOn: true)
    _ = Self.busyTick(&harness, at: 0, lidClosed: false)
    _ = Self.busyTick(&harness, at: 2, lidClosed: true)
    #expect(harness.state.hold.display == .released)
    let reopened = Self.busyTick(&harness, at: 4, lidClosed: false)
    #expect(Self.display(reopened) == [.acquireOrRenew(timeoutSeconds: 300)])
  }

  @Test func wantOffReleasesTheDisplayAssertion() {
    var harness = Self.harness(keepDisplayOn: true)
    _ = Self.busyTick(&harness, at: 0, lidClosed: false)
    let off = harness.send(.tick(Self.facts(lidClosed: false)), at: 200)
    #expect(Self.display(off) == [.release])
    #expect(off.filter(Self.isActuator).count == 2)
    Self.answer(&harness, off, at: 200)
    #expect(harness.state.hold.display == .released)
    #expect(harness.state.hold.idle == .released)
  }
}
