import Foundation
import Testing

@testable import OvertimeCore

@Suite("HOLD-11 idle assertion")
struct IdleAssertionTests {
  typealias H = ScenarioHarness

  static let acquired = Effect.log(Decision(keyword: .hold, verb: "idle acquired"))
  static let released = Effect.log(Decision(keyword: .hold, verb: "idle released"))

  static func harness(mode: RunMode = .shadow) -> ScenarioHarness {
    var harness = ScenarioHarness(mode: mode)
    harness.includeActuators = true
    return harness
  }

  static func idleEffects(_ effects: [Effect]) -> [(AssertionAction, EffectID)] {
    effects.compactMap { effect in
      if case .idleAssertion(let action, let id) = effect { return (action, id) }
      return nil
    }
  }

  static func busyAt(_ harness: inout ScenarioHarness, _ seconds: Double) -> [Effect] {
    _ = harness.activity(writtenAt: seconds, seenAt: seconds)
    return harness.tick(at: seconds)
  }

  @Test func wantOnEmitsATimedAcquireAndEntersAcquiring() {
    var harness = Self.harness()
    let effects = Self.busyAt(&harness, 0)
    guard case .idleAssertion(let action, let id)? = effects.last else {
      Issue.record("the step does not end with an idle assertion effect: \(effects)")
      return
    }
    #expect(action == .acquireOrRenew(timeoutSeconds: 300))
    #expect(harness.state.hold.idle == .acquiring(id))
    #expect(effects == [H.busy(true, source: "transcript"), H.want(true), .idleAssertion(action, id: id)])
  }

  @Test func successfulAcquireMovesToHeldAndLogsIt() {
    var harness = Self.harness()
    let effects = Self.busyAt(&harness, 0)
    guard let (_, id) = Self.idleEffects(effects).first else {
      Issue.record("no idle acquire")
      return
    }
    let result = harness.send(.effectResult(id, .succeeded), at: 0.01)
    #expect(result == [Self.acquired])
    #expect(harness.state.hold.idle == .held)
  }

  @Test func everyTickWhileWantedRenewsWithAFreshID() {
    var harness = Self.harness()
    let first = Self.idleEffects(Self.busyAt(&harness, 0))
    guard let (_, acquireID) = first.first else {
      Issue.record("no idle acquire")
      return
    }
    _ = harness.send(.effectResult(acquireID, .succeeded), at: 0.01)
    var seen: Set<EffectID> = [acquireID]
    for second in stride(from: 2.0, through: 10.0, by: 2.0) {
      let renewals = Self.idleEffects(Self.busyAt(&harness, second))
      #expect(renewals.count == 1)
      guard let (action, id) = renewals.first else { continue }
      #expect(action == .acquireOrRenew(timeoutSeconds: 300))
      #expect(!seen.contains(id))
      seen.insert(id)
      #expect(harness.state.hold.idle == .held)
      #expect(harness.send(.effectResult(id, .succeeded), at: second + 0.01).isEmpty)
      #expect(harness.state.hold.idle == .held)
    }
  }

  @Test func wantOffReleasesAndTheSuccessLogsReleased() {
    var harness = Self.harness()
    guard let (_, acquireID) = Self.idleEffects(Self.busyAt(&harness, 0)).first else {
      Issue.record("no idle acquire")
      return
    }
    _ = harness.send(.effectResult(acquireID, .succeeded), at: 0.01)
    let off = harness.tick(at: 200)
    #expect(H.wantLines(off) == [Decision(keyword: .want, verb: "off", fields: [.init(key: "reason", value: "idle")])])
    let releases = Self.idleEffects(off)
    #expect(releases.count == 1)
    guard let (action, releaseID) = releases.first else { return }
    #expect(action == .release)
    #expect(harness.state.hold.idle == .releasing(releaseID))
    #expect(harness.send(.effectResult(releaseID, .succeeded), at: 200.01) == [Self.released])
    #expect(harness.state.hold.idle == .released)
    #expect(Self.idleEffects(harness.tick(at: 202)).isEmpty)
  }

  @Test func wantOffWhileAcquiringReleasesAndIgnoresTheLateAcquireResult() {
    var harness = Self.harness()
    guard let (_, acquireID) = Self.idleEffects(Self.busyAt(&harness, 0)).first else {
      Issue.record("no idle acquire")
      return
    }
    let paused = harness.send(.command(.pause(.indefinite)), at: 1)
    guard let (action, releaseID) = Self.idleEffects(paused).first else {
      Issue.record("no release on pause")
      return
    }
    #expect(action == .release)
    #expect(harness.send(.effectResult(acquireID, .succeeded), at: 1.01).isEmpty)
    #expect(harness.state.hold.idle == .releasing(releaseID))
    #expect(harness.send(.effectResult(releaseID, .succeeded), at: 1.02) == [Self.released])
  }

  @Test func noAssertionEffectBeforeWantOrWhileIdle() {
    var harness = Self.harness()
    #expect(Self.idleEffects(harness.tick(at: 0)).isEmpty)
    #expect(Self.idleEffects(harness.tick(at: 2)).isEmpty)
    #expect(harness.state.hold.idle == .released)
  }

  @Test func shadowAndLiveProduceIdenticalEffects() {
    func replay(_ mode: RunMode) -> [Effect] {
      var harness = Self.harness(mode: mode)
      var effects = Self.busyAt(&harness, 0)
      for effect in effects {
        if case .idleAssertion(_, let id) = effect {
          effects += harness.send(.effectResult(id, .succeeded), at: 0.01)
        }
      }
      effects += Self.busyAt(&harness, 2)
      effects += harness.tick(at: 200)
      return effects
    }
    let shadow = replay(.shadow)
    #expect(shadow == replay(.live))
    #expect(Self.idleEffects(shadow).count == 3)
  }
}
