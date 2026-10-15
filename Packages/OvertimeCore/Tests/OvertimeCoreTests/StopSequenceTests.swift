import Foundation
import Testing

@testable import OvertimeCore

@Suite("Watchdog lost and graceful stop")
struct StopSequenceTests {
  enum Step: Equatable {
    case persist(ownsHold: Bool)
    case sentinel(SentinelCommand)
    case clamshell(on: Bool, why: ClamshellWhy)
    case idle(release: Bool)
    case display(release: Bool)
    case displaySleepNow
    case requestSleep
    case helper(HelperAction)
  }

  static func steps(_ batches: ArraySlice<[Effect]>) -> [Step] {
    batches.flatMap { $0 }.compactMap { effect in
      switch effect {
      case .persist(let state): .persist(ownsHold: state.ownsHold)
      case .sentinel(let command): .sentinel(command)
      case .clamshell(let on, _, let why): .clamshell(on: on, why: why)
      case .idleAssertion(let action, _): .idle(release: action == .release)
      case .displayAssertion(let action, _): .display(release: action == .release)
      case .displaySleepNow: .displaySleepNow
      case .requestSleep: .requestSleep
      case .helper(let action, _): .helper(action)
      case .log, .net: nil
      }
    }
  }

  static func actuators(_ batches: ArraySlice<[Effect]>) -> [Step] {
    steps(batches).filter { if case .persist = $0 { false } else { true } }
  }

  static func send(_ driver: inout HoldDriver, _ event: Event, at seconds: Double) -> ArraySlice<[Effect]> {
    let start = driver.batches.count
    driver.send(event, at: seconds)
    return driver.batches[start...]
  }

  static func decisions(_ batches: ArraySlice<[Effect]>) -> [Decision] {
    batches.flatMap { $0 }.compactMap { effect in
      if case .log(let decision) = effect { return decision }
      return nil
    }
  }

  static let sentinelLost = Decision(keyword: .sentinel, verb: "lost")

  @Test func aLostWatchdogWhileHeldClearsRespawnsRearmsAndReasserts() {
    var driver = HoldDriver.engaged()
    let batches = Self.send(&driver, .sentinelLost, at: 1)
    #expect(
      Self.actuators(batches) == [
        .clamshell(on: false, why: .watchdogLost), .sentinel(.respawn), .sentinel(.arm),
        .clamshell(on: true, why: .reassert),
      ])
    let decisions = Self.decisions(batches)
    #expect(decisions.first == Self.sentinelLost)
    #expect(decisions.contains(HoldDriver.reassertLine("watchdogLost")))
    #expect(driver.harness.state.hold.lidClose == .held)
    #expect(driver.harness.state.persisted.ownsHold)
  }

  @Test func aLostWatchdogWithoutAFullWakeClearsAndRespawnsArmedWithoutReasserting() {
    var driver = HoldDriver.engaged()
    driver.tick(at: 1, fullWake: false)
    let batches = Self.send(&driver, .sentinelLost, at: 2)
    #expect(
      Self.actuators(batches) == [
        .clamshell(on: false, why: .watchdogLost), .sentinel(.respawn), .sentinel(.arm), .sentinel(.disarm),
      ])
    #expect(driver.harness.state.hold.lidClose == .released)
    #expect(driver.harness.state.persisted.ownsHold == false)
    let later = Self.send(&driver, .tick(TickFacts(agents: HoldDriver.busyAgents, fullWake: true)), at: 3)
    #expect(Self.actuators(later).contains(.clamshell(on: true, why: .engage)))
    #expect(Self.actuators(later).firstIndex(of: .sentinel(.arm)).map { $0 == 0 } == true)
  }

  @Test func aLostWatchdogWithAnOwnedFailedReleaseClearsWithoutReasserting() {
    var driver = HoldDriver.engaged()
    driver.clamshellOutcome = .failed(code: 5)
    driver.tick(at: 200, fullWake: true, agents: .none)
    guard case .failed = driver.harness.state.hold.lidClose else {
      Issue.record("expected a failed release, got \(driver.harness.state.hold.lidClose)")
      return
    }
    #expect(driver.harness.state.persisted.ownsHold)
    driver.clamshellOutcome = .succeeded
    let batches = Self.send(&driver, .sentinelLost, at: 201)
    #expect(
      Self.actuators(batches) == [
        .clamshell(on: false, why: .watchdogLost), .sentinel(.respawn), .sentinel(.arm), .sentinel(.disarm),
      ])
    #expect(driver.harness.state.persisted.ownsHold == false)
  }

  @Test func aLostWatchdogWhileNotHoldingOnlyRespawns() {
    var driver = HoldDriver()
    driver.tick(at: 0, fullWake: true, agents: .none)
    let batches = Self.send(&driver, .sentinelLost, at: 1)
    #expect(Self.actuators(batches) == [.sentinel(.respawn)])
    #expect(Self.decisions(batches) == [Self.sentinelLost])
  }

  @Test func stopWhileHeldClearsThenDisarmsThenSaysBye() {
    var driver = HoldDriver.engaged()
    let batches = Self.send(&driver, .stop, at: 1)
    #expect(
      Self.steps(batches) == [
        .clamshell(on: false, why: .release), .idle(release: true), .sentinel(.disarm), .sentinel(.bye),
        .persist(ownsHold: false),
      ])
    #expect(driver.harness.state.hold.lidClose == .released)
    #expect(driver.harness.state.hold.idle == .released)
    #expect(driver.harness.state.persisted.ownsHold == false)
    #expect(driver.harness.state.persisted.sentinelArmed == false)
  }

  @Test func stopReleasesTheDisplayAssertionToo() {
    var driver = HoldDriver()
    driver.harness.settings.keepDisplayOn = true
    driver.tick(at: -2, fullWake: true)
    driver.send(.transcriptActivity(TranscriptActivity(at: driver.harness.instant(0))), at: 0)
    #expect(driver.harness.state.hold.display == .held)
    let batches = Self.send(&driver, .stop, at: 1)
    #expect(Self.actuators(batches).contains(.display(release: true)))
    #expect(driver.harness.state.hold.display == .released)
    #expect(Self.actuators(batches).last == .sentinel(.bye))
  }

  @Test(arguments: [EffectOutcome.failed(code: 5), .timedOut])
  func aFailedStopClearNeverSaysBye(_ outcome: EffectOutcome) {
    var driver = HoldDriver.engaged()
    driver.clamshellOutcome = outcome
    var batches = Self.send(&driver, .stop, at: 1)
    for second in stride(from: 3.0, through: 400.0, by: 2.0) {
      batches += Self.send(&driver, .tick(TickFacts(agents: HoldDriver.busyAgents, fullWake: true)), at: second)
    }
    #expect(!Self.steps(batches).contains(.sentinel(.bye)))
    #expect(!Self.steps(batches).contains(.sentinel(.disarm)))
    #expect(
      Self.actuators(batches).filter { if case .clamshell = $0 { true } else { false } } == [
        .clamshell(on: false, why: .release), .clamshell(on: false, why: .release),
      ])
    #expect(Self.actuators(batches).suffix(2) == [.sentinel(.respawn), .sentinel(.arm)])
    #expect(driver.harness.state.persisted.ownsHold)
    guard case .failed = driver.harness.state.hold.lidClose else {
      Issue.record("expected a failed stop clear, got \(driver.harness.state.hold.lidClose)")
      return
    }
  }

  @Test func aFailedStopClearIsRetriedOnceAtOnce() {
    var retried = HoldDriver.engaged()
    let first = retried.harness.send(.stop, at: 1)
    guard case .clamshell(false, let id, _)? = first.first(where: { if case .clamshell = $0 { true } else { false } })
    else {
      Issue.record("no stop clear in \(first)")
      return
    }
    let retry = retried.harness.send(.effectResult(id, .failed(code: 5)), at: 1)
    guard case .clamshell(false, let again, .release)? = retry.last else {
      Issue.record("no immediate retry in \(retry)")
      return
    }
    let done = retried.harness.send(.effectResult(again, .succeeded), at: 1)
    #expect(done.contains(.sentinel(.disarm)))
    #expect(done.contains(.sentinel(.bye)))
    #expect(!retried.harness.state.persisted.ownsHold)
  }

  @Test func aLostSentinelDuringAStopWithTheBitMaybeSetGetsAFreshArmedWatchdogAndAClear() {
    var driver = HoldDriver.engaged()
    driver.clamshellOutcome = .failed(code: 5)
    _ = driver.harness.send(.stop, at: 1)
    let lost = driver.harness.send(.sentinelLost, at: 1)
    #expect(lost.first == .log(Self.sentinelLost))
    #expect(Array(lost.dropFirst().prefix(2)) == [.sentinel(.respawn), .sentinel(.arm)])
    guard case .clamshell(false, _, .watchdogLost)? = lost.last else {
      Issue.record("no watchdog-lost clear in \(lost)")
      return
    }
  }

  @Test func aLostSentinelAfterASuccessfulStopClearOnlyLogs() {
    var driver = HoldDriver.engaged()
    _ = Self.send(&driver, .stop, at: 1)
    #expect(driver.harness.send(.sentinelLost, at: 2) == [.log(Self.sentinelLost)])
  }

  @Test func stopWhileReleasedReleasesTheAssertionsAndSaysBye() {
    var driver = HoldDriver()
    driver.tick(at: -2, fullWake: nil)
    driver.send(.transcriptActivity(TranscriptActivity(at: driver.harness.instant(0))), at: 0)
    #expect(driver.harness.state.hold.idle == .held)
    #expect(driver.harness.state.hold.lidClose == .released)
    let batches = Self.send(&driver, .stop, at: 1)
    #expect(Self.actuators(batches) == [.idle(release: true), .sentinel(.bye)])
  }

  @Test func stopWithNothingHeldOnlySaysBye() {
    var driver = HoldDriver()
    driver.tick(at: 0, fullWake: true, agents: .none)
    let batches = Self.send(&driver, .stop, at: 1)
    #expect(Self.actuators(batches) == [.sentinel(.bye)])
  }

  @Test func stopWithAnUnresolvedLaunchClearsTheBit() {
    var driver = HoldDriver()
    driver.send(
      .launched(
        LaunchFacts(
          persisted: .state(PersistedState(bootSessionUUID: "b", ownsHold: true, sentinelArmed: true)),
          bootSessionUUID: "b")), at: 0)
    let batches = Self.send(&driver, .stop, at: 1)
    #expect(Self.actuators(batches) == [.clamshell(on: false, why: .release), .sentinel(.disarm), .sentinel(.bye)])
    #expect(driver.harness.state.hold.pendingLaunch == nil)
  }

  @Test func nothingReengagesAfterAStop() {
    var driver = HoldDriver.engaged()
    _ = Self.send(&driver, .stop, at: 1)
    var batches = Self.send(&driver, .transcriptActivity(TranscriptActivity(at: driver.harness.instant(2))), at: 2)
    batches += Self.send(&driver, .tick(TickFacts(agents: HoldDriver.busyAgents, fullWake: true)), at: 3)
    batches += Self.send(&driver, .systemHasPoweredOn, at: 4)
    batches += Self.send(&driver, .stop, at: 5)
    #expect(Self.actuators(batches).isEmpty)
  }

  @Test func aLostWatchdogDuringAStopDoesNotRespawn() {
    var driver = HoldDriver.engaged()
    _ = Self.send(&driver, .stop, at: 1)
    let batches = Self.send(&driver, .sentinelLost, at: 2)
    #expect(Self.actuators(batches).isEmpty)
  }
}
