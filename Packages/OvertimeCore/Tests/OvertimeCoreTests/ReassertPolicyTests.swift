import Foundation
import Testing

@testable import OvertimeCore

struct HoldDriver {
  static let busyAgents = ScenarioHarness.claudeCaffeinate.agents

  var harness: ScenarioHarness
  var writes: [(at: Double, why: ClamshellWhy)] = []
  var decisions: [(at: Double, decision: Decision)] = []
  var batches: [[Effect]] = []
  var clamshellOutcome: EffectOutcome = .succeeded
  var helperOutcome: EffectOutcome = .succeeded

  init() {
    harness = ScenarioHarness(mode: .live)
    harness.includeActuators = true
  }

  static func reassertLine(_ why: String) -> Decision {
    Decision(keyword: .hold, verb: "reassert", fields: [DecisionField(key: "why", value: why)])
  }

  static func engaged() -> HoldDriver {
    var driver = HoldDriver()
    driver.tick(at: -2, fullWake: true)
    driver.send(.transcriptActivity(TranscriptActivity(at: driver.harness.instant(0))), at: 0)
    return driver
  }

  @discardableResult
  mutating func tick(at seconds: Double, fullWake: Bool?, agents: AgentSignals = busyAgents) -> [Effect] {
    send(.tick(TickFacts(agents: agents, fullWake: fullWake)), at: seconds)
  }

  @discardableResult
  mutating func send(_ event: Event, at seconds: Double) -> [Effect] {
    var queue = [event]
    var first: [Effect]?
    while !queue.isEmpty {
      let effects = harness.send(queue.removeFirst(), at: seconds)
      first = first ?? effects
      batches.append(effects)
      for effect in effects {
        switch effect {
        case .clamshell(let on, let id, let why):
          if on { writes.append((seconds, why)) }
          queue.append(.effectResult(id, clamshellOutcome))
        case .idleAssertion(_, let id), .displayAssertion(_, let id), .displaySleepNow(let id), .requestSleep(let id):
          queue.append(.effectResult(id, .succeeded))
        case .helper(_, let id):
          queue.append(.effectResult(id, helperOutcome))
        case .log(let decision):
          decisions.append((seconds, decision))
        case .persist, .sentinel, .net:
          break
        }
      }
    }
    return first ?? []
  }

  func writeTimes(_ why: ClamshellWhy? = nil) -> [Double] {
    writes.filter { why == nil || $0.why == why }.map(\.at)
  }

  func lines(_ decision: Decision) -> [Double] {
    decisions.filter { $0.decision == decision }.map(\.at)
  }
}

@Suite("ADR 0004 re-assert policy")
struct ReassertPolicyTests {
  @Test func heldWithAFullWakeReassertsEveryTenSecondsAndLogsOnlyTheFirst() {
    var driver = HoldDriver.engaged()
    #expect(driver.harness.state.hold.lidClose == .held)
    for second in stride(from: 2.0, through: 30.0, by: 2.0) {
      driver.tick(at: second, fullWake: true)
    }
    #expect(driver.writeTimes(.reassert) == [10, 20, 30])
    #expect(driver.lines(HoldDriver.reassertLine("periodic")) == [10])
    #expect(driver.harness.state.want.override == false)
  }

  @Test func withoutTheGraphicsCapabilityNothingIsWritten() {
    var driver = HoldDriver.engaged()
    for second in stride(from: 2.0, through: 40.0, by: 2.0) {
      driver.tick(at: second, fullWake: false)
    }
    #expect(driver.writeTimes(.reassert).isEmpty)
    #expect(driver.writeTimes(.reassertAfterWake).isEmpty)
    driver.tick(at: 42, fullWake: nil)
    #expect(driver.writes.count == 1)
  }

  @Test func everyBitWriteIsPrecededByAnArmInTheSameBatch() {
    var driver = HoldDriver.engaged()
    for second in stride(from: 2.0, through: 30.0, by: 2.0) {
      driver.tick(at: second, fullWake: true)
    }
    for batch in driver.batches {
      for (index, effect) in batch.enumerated() {
        guard case .clamshell(on: true, _, _) = effect else { continue }
        #expect(index > 0 && batch[index - 1] == .sentinel(.arm), "batch \(batch)")
      }
    }
  }

  @Test func afterAWakeTheBurstWaitsForGraphicsThenWritesOncePerSecondToPlusSix() {
    var driver = HoldDriver.engaged()
    for second in stride(from: 2.0, through: 94.0, by: 2.0) {
      driver.tick(at: second, fullWake: true)
    }
    let wake = 95.0
    let before = driver.writes.count
    driver.send(.systemHasPoweredOn, at: wake)
    for offset in stride(from: 0.5, through: 12.0, by: 0.5) {
      driver.tick(at: wake + offset, fullWake: offset >= 3.2)
    }
    let after = Array(driver.writes.dropFirst(before))
    #expect(after.map(\.at) == [wake + 3.5, wake + 4, wake + 5, wake + 6])
    #expect(after.allSatisfy { $0.why == .reassertAfterWake })
    #expect(driver.lines(HoldDriver.reassertLine("afterWake")) == [wake + 3.5, wake + 4, wake + 5, wake + 6])
    #expect(driver.harness.state.hold.wakeBurst.isEmpty)
    driver.tick(at: wake + 16, fullWake: true)
    #expect(driver.writeTimes(.reassert).last == wake + 16)
  }

  @Test func aBurstWithoutGraphicsByPlusSixAndAHalfIsDroppedWithoutAWrite() {
    var driver = HoldDriver.engaged()
    let wake = 50.0
    for second in stride(from: 2.0, through: 48.0, by: 2.0) {
      driver.tick(at: second, fullWake: true)
    }
    let before = driver.writes.count
    driver.send(.systemHasPoweredOn, at: wake)
    for offset in stride(from: 0.5, through: 6.5, by: 0.5) {
      driver.tick(at: wake + offset, fullWake: false)
    }
    #expect(driver.writes.count == before)
    driver.tick(at: wake + 7, fullWake: true)
    #expect(driver.writeTimes(.reassertAfterWake).isEmpty)
    #expect(driver.harness.state.hold.wakeBurst.isEmpty)
  }

  @Test func theNextDeadlineIsEachBurstInstant() {
    var driver = HoldDriver.engaged()
    let wake = 3.0
    driver.send(.systemHasPoweredOn, at: wake)
    var visited: [Double] = []
    while let deadline = Reducer.nextDeadline(driver.harness.state, driver.harness.settings),
      driver.harness.seconds(deadline) <= wake + 6
    {
      let at = driver.harness.seconds(deadline)
      visited.append(at)
      driver.tick(at: at, fullWake: true)
    }
    #expect(visited == [wake + 1, wake + 2, wake + 3, wake + 4, wake + 5, wake + 6])
    #expect(driver.writeTimes(.reassertAfterWake) == visited)
  }

  @Test func aFailedReassertBacksOffLikeAnEngage() {
    var driver = HoldDriver.engaged()
    for second in stride(from: 2.0, through: 8.0, by: 2.0) {
      driver.tick(at: second, fullWake: true)
    }
    driver.clamshellOutcome = .failed(code: 5)
    driver.tick(at: 10, fullWake: true)
    #expect(driver.harness.state.hold.lidClose == .failed(attempts: 1, retryAt: driver.harness.instant(30)))
    #expect(driver.harness.state.hold.errorActive)
    let failed = Decision(
      keyword: .hold, verb: "failed",
      fields: [
        .init(key: "backend", value: "lidClose"), .init(key: "attempt", value: "1"), .init(key: "retryIn", value: "20"),
      ])
    #expect(driver.lines(failed) == [10])
    driver.clamshellOutcome = .succeeded
    for second in stride(from: 12.0, through: 28.0, by: 2.0) {
      driver.tick(at: second, fullWake: true)
    }
    #expect(driver.writeTimes().filter { $0 > 10 }.isEmpty)
    driver.tick(at: 30, fullWake: true)
    #expect(driver.writeTimes(.engage).last == 30)
    #expect(driver.harness.state.hold.lidClose == .held)
    #expect(driver.harness.state.hold.errorActive == false)
  }
}
