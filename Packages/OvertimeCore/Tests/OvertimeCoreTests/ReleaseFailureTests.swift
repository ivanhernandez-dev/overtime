import Foundation
import Testing

@testable import OvertimeCore

@Suite("A failed clamshell clear retries fast and escalates")
struct ReleaseFailureTests {
  static let escalateDecision = Decision(
    keyword: .error, verb: "hold",
    fields: [
      DecisionField(key: "backend", value: "lidClose"),
      DecisionField(key: "action", value: "escalate"),
    ])
  static let escalate = Effect.log(escalateDecision)

  static func clears(_ driver: HoldDriver) -> [Double] {
    driver.decisions.filter { $0.decision.keyword == .hold && $0.decision.verb == "failed" }.map(\.at)
  }

  @Test func aFailedClearIsRetriedEveryTenSecondsNotOnTheAcquireBackoff() {
    var driver = HoldDriver.engaged()
    driver.clamshellOutcome = .failed(code: 5)
    driver.send(.command(.pause(.indefinite)), at: 1)
    #expect(driver.harness.state.hold.lidClose == .failed(attempts: 1, retryAt: driver.harness.instant(11)))
    for second in stride(from: 2.0, through: 41.0, by: 1.0) {
      driver.tick(at: second, fullWake: true)
    }
    #expect(Self.clears(driver) == [1, 11, 21, 31, 41])
    driver.clamshellOutcome = .succeeded
    driver.tick(at: 51, fullWake: true)
    #expect(driver.harness.state.hold.lidClose == .released)
    #expect(!driver.harness.state.persisted.ownsHold)
  }

  @Test func theSecondConsecutiveFailedClearEscalatesToAFreshArmedSentinelOnce() {
    var driver = HoldDriver.engaged()
    driver.clamshellOutcome = .timedOut
    driver.send(.command(.pause(.indefinite)), at: 1)
    #expect(!driver.batches.flatMap { $0 }.contains(Self.escalate))
    for second in stride(from: 2.0, through: 41.0, by: 1.0) {
      driver.tick(at: second, fullWake: true)
    }
    let everything = driver.batches.flatMap { $0 }
    #expect(everything.filter { $0 == Self.escalate }.count == 1)
    let batch = driver.batches.first { $0.contains(Self.escalate) } ?? []
    let index = batch.firstIndex(of: Self.escalate) ?? batch.endIndex
    #expect(Array(batch.dropFirst(index)) == [Self.escalate, .sentinel(.respawn), .sentinel(.arm)])
    #expect(driver.lines(Self.escalateDecision) == [11])
  }

  static func escalations(_ driver: HoldDriver) -> [Double] {
    driver.lines(escalateDecision)
  }

  @Test func aSentinelLostWhileAClearIsUnconfirmedIsReplacedArmed() {
    var driver = HoldDriver.engaged()
    driver.clamshellOutcome = .failed(code: 5)
    driver.send(.command(.pause(.indefinite)), at: 1)
    let lost = driver.harness.send(.sentinelLost, at: 2)
    let respawn = lost.firstIndex(of: .sentinel(.respawn))
    #expect(respawn.map { lost.indices.contains($0 + 1) && lost[$0 + 1] == .sentinel(.arm) } == true)
    #expect(lost.contains { if case .clamshell(false, _, .watchdogLost) = $0 { true } else { false } })
  }

  @Test func aFailureRunAfterALostSentinelEscalatesAgain() {
    var driver = HoldDriver.engaged()
    driver.clamshellOutcome = .timedOut
    driver.send(.command(.pause(.indefinite)), at: 1)
    for second in stride(from: 2.0, through: 20.0, by: 1.0) {
      driver.tick(at: second, fullWake: true)
    }
    #expect(Self.escalations(driver) == [11])
    let lost = driver.send(.sentinelLost, at: 20.5)
    #expect(Array(lost.drop { $0 != .sentinel(.respawn) }.prefix(2)) == [.sentinel(.respawn), .sentinel(.arm)])
    for second in stride(from: 21.0, through: 60.0, by: 1.0) {
      driver.tick(at: second, fullWake: true)
    }
    #expect(Self.escalations(driver) == [11, 31])
    let batch = driver.batches.last { $0.contains(Self.escalate) } ?? []
    let index = batch.firstIndex(of: Self.escalate) ?? batch.endIndex
    #expect(Array(batch.dropFirst(index)) == [Self.escalate, .sentinel(.respawn), .sentinel(.arm)])
  }

  @Test func aStopAfterALongFailureRunRetriesAtOnceThenEscalates() {
    var driver = HoldDriver.engaged()
    driver.clamshellOutcome = .failed(code: 5)
    driver.send(.command(.pause(.indefinite)), at: 1)
    for second in stride(from: 2.0, through: 31.0, by: 1.0) {
      driver.tick(at: second, fullWake: true)
    }
    #expect(driver.harness.state.hold.releaseFailures == 4)
    let start = driver.batches.count
    driver.send(.stop, at: 32)
    let stop = driver.batches[start...].flatMap { $0 }
    let clears = stop.filter { if case .clamshell(false, _, _) = $0 { true } else { false } }
    #expect(clears.count == 2)
    #expect(Array(stop.suffix(3)) == [Self.escalate, .sentinel(.respawn), .sentinel(.arm)])
    #expect(!stop.contains(.sentinel(.bye)))
  }

  @Test func acquireFailuresStillBackOffFromTwentySeconds() {
    var driver = HoldDriver()
    driver.clamshellOutcome = .failed(code: 5)
    driver.tick(at: -2, fullWake: true)
    driver.send(.transcriptActivity(TranscriptActivity(at: driver.harness.instant(0))), at: 0)
    #expect(driver.harness.state.hold.lidClose == .failed(attempts: 1, retryAt: driver.harness.instant(20)))
    #expect(!driver.batches.flatMap { $0 }.contains(Self.escalate))
  }
}
