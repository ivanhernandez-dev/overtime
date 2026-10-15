import Foundation
import Testing

@testable import OvertimeCore

@Suite("Late clamshell writes keep the watchdog until they settle")
struct LateWriteTests {
  static let lateWrite = Effect.log(
    Decision(
      keyword: .error, verb: "hold",
      fields: [
        DecisionField(key: "backend", value: "lidClose"),
        DecisionField(key: "action", value: "lateWrite"),
      ]))
  static let quarantined = Effect.log(
    Decision(keyword: .hold, verb: "release", fields: [DecisionField(key: "quarantine", value: "lateWrite")]))

  static func harness() -> ScenarioHarness {
    var harness = ScenarioHarness(mode: .live)
    harness.includeActuators = true
    _ = harness.send(.tick(TickFacts(agents: HoldDriver.busyAgents, fullWake: true)), at: -2)
    return harness
  }

  static func clamshell(_ effects: [Effect], on: Bool) -> EffectID? {
    for effect in effects {
      if case .clamshell(let isOn, let id, _) = effect, isOn == on { return id }
    }
    return nil
  }

  static func dropsOwnership(_ effects: [Effect]) -> Bool {
    effects.contains { effect in
      if case .persist(let state) = effect { return !state.ownsHold }
      return false
    }
  }

  static func timedOutEngageThenReleased() -> (harness: ScenarioHarness, write: EffectID, released: [Effect])? {
    var harness = Self.harness()
    let engage = harness.send(.transcriptActivity(TranscriptActivity(at: harness.instant(0))), at: 0)
    guard let write = clamshell(engage, on: true) else { return nil }
    _ = harness.send(.effectResult(write, .timedOut), at: 5)
    let pause = harness.send(.command(.pause(.indefinite)), at: 6)
    guard let clear = clamshell(pause, on: false) else { return nil }
    let released = harness.send(.effectResult(clear, .succeeded), at: 6)
    return (harness, write, released)
  }

  @Test func aTimedOutEngageKeepsTheSentinelArmedAndOwnershipAfterTheRelease() throws {
    let run = try #require(Self.timedOutEngageThenReleased())
    #expect(run.released.contains(Self.quarantined))
    #expect(!run.released.contains(.sentinel(.disarm)))
    #expect(!Self.dropsOwnership(run.released))
    #expect(run.harness.state.persisted.ownsHold)
    #expect(run.harness.state.hold.lidClose == .released)
    #expect(LidCloseHold.mayHold(run.harness.state))
  }

  @Test func aLateSuccessForTheTimedOutWriteClearsAtOnceThenDisarms() throws {
    var run = try #require(Self.timedOutEngageThenReleased())
    let late = run.harness.send(.effectResult(run.write, .succeeded), at: 20)
    #expect(late.first == Self.lateWrite)
    let clear = try #require(Self.clamshell(late, on: false))
    #expect(late.contains(.clamshell(on: false, id: clear, why: .release)))
    let settled = run.harness.send(.effectResult(clear, .succeeded), at: 20)
    #expect(settled.contains(.sentinel(.disarm)))
    #expect(Self.dropsOwnership(settled))
    #expect(!run.harness.state.persisted.ownsHold)
  }

  @Test func withoutALateReportFollowUpClearsRunUntilTheQuarantineEnds() throws {
    var run = try #require(Self.timedOutEngageThenReleased())
    var clears: [Double] = []
    var disarmedAt: [Double] = []
    for second in stride(from: 8.0, through: 400.0, by: 2.0) {
      var queue = [Event.tick(TickFacts(fullWake: true))]
      while !queue.isEmpty {
        let effects = run.harness.send(queue.removeFirst(), at: second)
        if let clear = Self.clamshell(effects, on: false) {
          clears.append(second)
          queue.append(.effectResult(clear, .succeeded))
        }
        if effects.contains(.sentinel(.disarm)) { disarmedAt.append(second) }
        #expect(Self.clamshell(effects, on: true) == nil)
      }
    }
    #expect(clears.first == 36)
    #expect(zip(clears.dropFirst(), clears).allSatisfy { $0 - $1 == 30 })
    #expect(disarmedAt.count == 1)
    #expect(disarmedAt.first.map { $0 >= 305 } == true)
    #expect(disarmedAt.first == clears.last)
    #expect(!run.harness.state.persisted.ownsHold)
  }

  @Test func aReassertThatLandsAfterItsReleaseIsClearedAndTheWatchdogOutlivesIt() throws {
    var driver = HoldDriver.engaged()
    driver.tick(at: 2, fullWake: true)
    #expect(driver.harness.state.hold.lidClose == .held)
    var harness = driver.harness
    let reassert = harness.send(.tick(TickFacts(agents: HoldDriver.busyAgents, fullWake: true)), at: 10)
    let write = try #require(Self.clamshell(reassert, on: true))
    let pause = harness.send(.command(.pause(.indefinite)), at: 11)
    let clear = try #require(Self.clamshell(pause, on: false))
    let released = harness.send(.effectResult(clear, .succeeded), at: 11)
    #expect(released.contains(Self.quarantined))
    #expect(!released.contains(.sentinel(.disarm)))
    let late = harness.send(.effectResult(write, .succeeded), at: 11)
    #expect(late.first == Self.lateWrite)
    let compensating = try #require(Self.clamshell(late, on: false))
    let settled = harness.send(.effectResult(compensating, .succeeded), at: 11)
    #expect(settled.contains(.sentinel(.disarm)))
    #expect(Self.dropsOwnership(settled))
  }

  @Test func aReassertAnsweredBeforeItsReleaseNeedsNoCompensation() throws {
    var driver = HoldDriver.engaged()
    driver.tick(at: 2, fullWake: true)
    var harness = driver.harness
    let reassert = harness.send(.tick(TickFacts(agents: HoldDriver.busyAgents, fullWake: true)), at: 10)
    let write = try #require(Self.clamshell(reassert, on: true))
    let pause = harness.send(.command(.pause(.indefinite)), at: 11)
    let clear = try #require(Self.clamshell(pause, on: false))
    let answered = harness.send(.effectResult(write, .succeeded), at: 11)
    #expect(!answered.contains(Self.lateWrite))
    #expect(Self.clamshell(answered, on: false) == nil)
    let released = harness.send(.effectResult(clear, .succeeded), at: 11)
    #expect(released.contains(.sentinel(.disarm)))
    #expect(!released.contains(Self.quarantined))
  }

  @Test func aStopDuringTheQuarantineNeverSaysBye() throws {
    var run = try #require(Self.timedOutEngageThenReleased())
    let stop = run.harness.send(.stop, at: 10)
    let clear = try #require(Self.clamshell(stop, on: false))
    let stopped = run.harness.send(.effectResult(clear, .succeeded), at: 10)
    #expect(!stopped.contains(.sentinel(.bye)))
    #expect(!stopped.contains(.sentinel(.disarm)))
    #expect(run.harness.state.persisted.ownsHold)
  }

  @Test func aLostSentinelDuringTheQuarantineIsReplacedArmed() throws {
    var run = try #require(Self.timedOutEngageThenReleased())
    let lost = run.harness.send(.sentinelLost, at: 10)
    let respawn = try #require(lost.firstIndex(of: .sentinel(.respawn)))
    #expect(lost.dropFirst(respawn).contains(.sentinel(.arm)))
  }
}
