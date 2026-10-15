import Foundation
import Testing

@testable import OvertimeCore

@Suite("HOLD-12 post-release sleep verification")
struct ReleaseVerificationTests {
  typealias L = LidScenarios

  static let releaseAt: Double = 200
  static let sleepOK = Decision(keyword: .verify, verb: "sleep ok")
  static let sleepFailed = Decision(
    keyword: .verify, verb: "sleep failed", fields: [DecisionField(key: "action", value: "requestSleep")])
  static let notObserved = Decision(keyword: .error, verb: "sleep not observed")

  static func cancelled(_ reason: String) -> Decision {
    Decision(keyword: .verify, verb: "cancelled", fields: [DecisionField(key: "reason", value: reason)])
  }

  static func facts(lidClosed: Bool, externalDisplays: Int? = 0) -> TickFacts {
    TickFacts(lidClosed: lidClosed, externalDisplays: lidClosed ? externalDisplays : nil, fullWake: true)
  }

  static func requests(_ effects: [Effect]) -> Int {
    effects.filter { effect in
      if case .requestSleep = effect { return true }
      return false
    }.count
  }

  static func clears(_ effects: [Effect]) -> [ClamshellWhy] {
    effects.compactMap { effect in
      if case .clamshell(false, _, let why) = effect { return why }
      return nil
    }
  }

  static func verifyLines(_ effects: [Effect]) -> [Decision] {
    ScenarioHarness.decisions(effects).filter { $0.keyword == .verify || $0 == notObserved }
  }

  static func released(lidClosed: Bool = true, externalDisplays: Int = 0) -> (ScenarioHarness, [Effect]) {
    var harness = L.wantedHarness()
    #expect(harness.state.hold.lidClose == .held)
    if lidClosed {
      let close = harness.send(
        .lidChanged(closed: true, sleepBit: false, externalDisplays: externalDisplays), at: 2)
      L.answer(&harness, close, at: 2)
    }
    let effects = harness.send(
      .tick(facts(lidClosed: lidClosed, externalDisplays: externalDisplays)), at: releaseAt)
    L.answer(&harness, effects, at: releaseAt)
    #expect(harness.state.want.wanted == false)
    #expect(clears(effects) == [.release])
    return (harness, effects)
  }

  @Test func aLidClosedReleaseStartsAThirtySecondVerification() {
    let (harness, _) = Self.released()
    #expect(harness.state.verification == .pending(deadline: harness.instant(Self.releaseAt + 30)))
    #expect(Reducer.nextDeadline(harness.state, harness.settings) == harness.instant(Self.releaseAt + 30))
  }

  @Test func willSleepBeforeTheDeadlineMarksItVerified() {
    var (harness, _) = Self.released()
    let effects = harness.send(.systemWillSleep, at: Self.releaseAt + 5)
    #expect(Self.verifyLines(effects) == [Self.sleepOK])
    #expect(harness.state.verification == .idle)
    let later = harness.send(.tick(Self.facts(lidClosed: true)), at: Self.releaseAt + 30)
    #expect(Self.requests(later) == 0)
    #expect(Self.verifyLines(later).isEmpty)
  }

  @Test func noWillSleepByTheDeadlineRequestsSleepExactlyOnce() {
    var (harness, _) = Self.released()
    var requests: [Double] = []
    var lines: [Decision] = []
    for second in stride(from: Self.releaseAt + 2, through: Self.releaseAt + 60, by: 2) {
      let effects = harness.send(.tick(Self.facts(lidClosed: true)), at: second)
      L.answer(&harness, effects, at: second)
      if Self.requests(effects) > 0 { requests.append(second) }
      lines += Self.verifyLines(effects)
    }
    #expect(requests == [Self.releaseAt + 30])
    #expect(lines == [Self.sleepFailed, Self.notObserved])
    #expect(harness.state.verification == .idle)
  }

  @Test func theFailureIsLoggedBeforeTheSleepRequest() {
    var (harness, _) = Self.released()
    let effects = harness.send(.tick(Self.facts(lidClosed: true)), at: Self.releaseAt + 30)
    let request = effects.firstIndex { effect in
      if case .requestSleep = effect { return true }
      return false
    }
    let failed = effects.firstIndex(of: .log(Self.sleepFailed))
    #expect(request != nil)
    #expect(failed != nil)
    if let request, let failed {
      #expect(failed < request)
    }
  }

  @Test func theLidOpeningCancelsItAndNothingIsRequestedLater() {
    var (harness, _) = Self.released()
    let open = harness.send(.lidChanged(closed: false, sleepBit: false, externalDisplays: nil), at: Self.releaseAt + 10)
    #expect(Self.verifyLines(open) == [Self.cancelled("lidOpened")])
    #expect(harness.state.verification == .idle)
    let later = harness.send(.tick(Self.facts(lidClosed: false)), at: Self.releaseAt + 30)
    #expect(Self.requests(later) == 0)
  }

  @Test func aTickSeeingTheLidOpenCancelsIt() {
    var (harness, _) = Self.released()
    let open = harness.send(.tick(Self.facts(lidClosed: false)), at: Self.releaseAt + 10)
    #expect(Self.verifyLines(open) == [Self.cancelled("lidOpened")])
    #expect(harness.state.verification == .idle)
  }

  @Test func wantTurningOnAgainCancelsIt() {
    var (harness, _) = Self.released()
    let effects = harness.activity(writtenAt: Self.releaseAt + 5, seenAt: Self.releaseAt + 5)
    L.answer(&harness, effects, at: Self.releaseAt + 5)
    #expect(harness.state.want.wanted == true)
    #expect(Self.verifyLines(effects) == [Self.cancelled("wanted")])
    #expect(harness.state.verification == .idle)
    let later = harness.send(.tick(Self.facts(lidClosed: true)), at: Self.releaseAt + 30)
    #expect(Self.requests(later) == 0)
  }

  @Test func aReleaseWithTheLidOpenStartsNoVerification() {
    let (harness, effects) = Self.released(lidClosed: false)
    #expect(harness.state.verification == .idle)
    #expect(Self.verifyLines(effects).isEmpty)
  }

  @Test func aReleaseWithAnExternalDisplayStartsNoVerification() {
    let (harness, _) = Self.released(externalDisplays: 1)
    #expect(harness.state.verification == .idle)
  }

  @Test func aClearStaleWithTheLidClosedStartsOne() {
    var harness = ScenarioHarness(mode: .live)
    harness.includeActuators = true
    _ = harness.send(.launched(LaunchFacts(persisted: .missing, bootSessionUUID: "boot")), at: 0)
    let effects = harness.send(.tick(Self.facts(lidClosed: true)), at: 1)
    #expect(Self.clears(effects) == [.clearStale])
    #expect(harness.state.verification == .pending(deadline: harness.instant(31)))
  }

  @Test func aWatchdogLostClearStartsNone() {
    var harness = L.wantedHarness()
    L.answer(&harness, harness.send(.lidChanged(closed: true, sleepBit: false, externalDisplays: 0), at: 2), at: 2)
    let effects = harness.send(.sentinelLost, at: 5)
    #expect(Self.clears(effects) == [.watchdogLost])
    #expect(harness.state.verification == .idle)
  }

  @Test func aDeadlineAfterVerificationDoesNothing() {
    var (harness, _) = Self.released()
    _ = harness.send(.systemWillSleep, at: Self.releaseAt + 1)
    _ = harness.send(.systemHasPoweredOn, at: Self.releaseAt + 20)
    let effects = harness.send(.tick(Self.facts(lidClosed: true)), at: Self.releaseAt + 31)
    #expect(Self.requests(effects) == 0)
    #expect(Self.verifyLines(effects).isEmpty)
  }
}
