import Foundation
import Testing

@testable import OvertimeCore

@Suite("Launch reclaim (HOLD-04)")
struct LaunchReclaimTests {
  static let boot = "11111111-2222-3333-4444-555555555555"
  static let otherBoot = "99999999-8888-7777-6666-555555555555"

  enum Step: Equatable {
    case persist(ownsHold: Bool)
    case sentinel(SentinelCommand)
    case clamshell(on: Bool, why: ClamshellWhy)
  }

  static func owned(boot: String? = LaunchReclaimTests.boot) -> PersistedSnapshot {
    .state(PersistedState(bootSessionUUID: boot, ownsHold: true, sentinelArmed: true))
  }

  static func launched(
    _ snapshot: PersistedSnapshot, boot: String? = LaunchReclaimTests.boot, mode: RunMode = .live
  ) -> HoldDriver {
    var driver = HoldDriver()
    driver.harness = ScenarioHarness(mode: mode)
    driver.harness.includeActuators = true
    driver.send(.launched(LaunchFacts(persisted: snapshot, bootSessionUUID: boot)), at: 0)
    return driver
  }

  static func steps(_ driver: HoldDriver) -> [Step] {
    driver.batches.flatMap { $0 }.compactMap { effect in
      switch effect {
      case .persist(let state): .persist(ownsHold: state.ownsHold)
      case .sentinel(let command): .sentinel(command)
      case .clamshell(let on, _, let why): .clamshell(on: on, why: why)
      default: nil
      }
    }
  }

  static func clears(_ driver: HoldDriver) -> [Step] {
    steps(driver).filter {
      if case .clamshell(on: false, _) = $0 { return true }
      return false
    }
  }

  static func holdVerbs(_ driver: HoldDriver) -> [String] {
    driver.decisions.map(\.decision).filter { $0.keyword == .hold }.map(\.verb).filter {
      !$0.hasPrefix(HoldBackend.idle.rawValue) && !$0.hasPrefix(HoldBackend.display.rawValue)
    }
  }

  static func busyAt(_ driver: inout HoldDriver, _ seconds: Double) {
    driver.send(.transcriptActivity(TranscriptActivity(at: driver.harness.instant(seconds))), at: seconds)
  }

  @Test func sameBootOwnedAndWantedReclaimsWithoutClearingFirst() {
    var driver = Self.launched(Self.owned())
    #expect(driver.harness.state.hold.pendingLaunch == .reclaim)
    #expect(driver.harness.state.persisted.ownsHold)
    Self.busyAt(&driver, 0.5)
    #expect(Self.steps(driver) == [.persist(ownsHold: true)])
    driver.tick(at: 1, fullWake: true)
    #expect(
      Self.steps(driver) == [
        .persist(ownsHold: true), .persist(ownsHold: true), .sentinel(.arm), .clamshell(on: true, why: .reclaim),
      ])
    #expect(Self.clears(driver).isEmpty)
    #expect(driver.harness.state.hold.lidClose == .held)
    #expect(driver.harness.state.hold.pendingLaunch == nil)
    #expect(Self.holdVerbs(driver).contains("reclaim"))
    #expect(!Self.holdVerbs(driver).contains("engage"))
  }

  @Test func aReclaimedHoldKeepsTheReassertCadence() {
    var driver = Self.launched(Self.owned())
    Self.busyAt(&driver, 0.5)
    for second in stride(from: 1.0, through: 21.0, by: 2.0) {
      driver.tick(at: second, fullWake: true)
    }
    #expect(driver.writeTimes(.reclaim) == [1])
    #expect(driver.writeTimes(.reassert) == [11, 21])
    #expect(Self.clears(driver).isEmpty)
  }

  @Test func sameBootOwnedAndNotWantedClearsTheStaleHoldThenDisarms() {
    var driver = Self.launched(Self.owned())
    driver.tick(at: 1, fullWake: true, agents: .none)
    #expect(
      Self.steps(driver) == [
        .persist(ownsHold: true), .clamshell(on: false, why: .clearStale), .sentinel(.disarm),
        .persist(ownsHold: false),
      ])
    #expect(Self.holdVerbs(driver) == ["clearStale"])
    #expect(driver.harness.state.hold.lidClose == .released)
    #expect(driver.harness.state.persisted.ownsHold == false)
    #expect(driver.harness.state.persisted.sentinelArmed == false)
    driver.tick(at: 3, fullWake: true, agents: .none)
    #expect(Self.clears(driver).count == 1)
  }

  @Test func aStaleClearDoesNotWaitForAFullWake() {
    var driver = Self.launched(Self.owned())
    driver.tick(at: 1, fullWake: nil, agents: .none)
    #expect(Self.clears(driver) == [.clamshell(on: false, why: .clearStale)])
  }

  @Test func theReclaimWaitsWithoutWritingWhileTheWakeIsNotFull() {
    var driver = Self.launched(Self.owned())
    Self.busyAt(&driver, 0.5)
    driver.tick(at: 1, fullWake: false)
    driver.tick(at: 3, fullWake: nil)
    #expect(Self.steps(driver) == [.persist(ownsHold: true)])
    #expect(driver.harness.state.hold.pendingLaunch == .reclaim)
    driver.tick(at: 5, fullWake: true)
    #expect(driver.writeTimes(.reclaim) == [5])
    #expect(Self.clears(driver).isEmpty)
  }

  @Test func aDifferentBootDropsOwnershipWithoutWriting() {
    var driver = Self.launched(Self.owned(boot: Self.otherBoot))
    #expect(Self.steps(driver) == [.persist(ownsHold: false)])
    #expect(driver.harness.state.hold.pendingLaunch == nil)
    driver.tick(at: 1, fullWake: true, agents: .none)
    driver.tick(at: 3, fullWake: true, agents: .none)
    #expect(Self.steps(driver) == [.persist(ownsHold: false)])
    guard case .persist(let stored)? = driver.batches.first?.last else {
      Issue.record("expected the launch persist")
      return
    }
    #expect(stored.sentinelArmed == false)
    #expect(stored.bootSessionUUID == Self.boot)
  }

  @Test func sameBootWithoutOwnershipDoesNothing() {
    var driver = Self.launched(.state(PersistedState(bootSessionUUID: Self.boot)))
    #expect(driver.harness.state.hold.pendingLaunch == nil)
    driver.tick(at: 1, fullWake: true, agents: .none)
    #expect(Self.clears(driver).isEmpty)
  }

  @Test(arguments: [PersistedSnapshot.missing, .corrupt])
  func anUnknownHoldIsClearedOnceAndDisarmsTheLaunchArmWhenNotWanted(_ snapshot: PersistedSnapshot) {
    var driver = Self.launched(snapshot)
    #expect(driver.harness.state.hold.pendingLaunch == .clearIfUnwanted)
    driver.tick(at: 1, fullWake: true, agents: .none)
    driver.tick(at: 3, fullWake: true, agents: .none)
    driver.tick(at: 5, fullWake: true, agents: .none)
    #expect(Self.clears(driver) == [.clamshell(on: false, why: .clearStale)])
    let sentinel = Self.steps(driver).filter { if case .sentinel = $0 { true } else { false } }
    #expect(sentinel == [.sentinel(.disarm)])
    #expect(Self.holdVerbs(driver) == ["clearStale"])
    #expect(driver.harness.state.hold.lidClose == .released)
  }

  @Test func ownershipFromAnUnreadableBootIsAmbiguousAndClears() {
    var driver = Self.launched(Self.owned(), boot: nil)
    #expect(driver.harness.state.hold.pendingLaunch == .clearIfUnwanted)
    #expect(driver.harness.state.persisted.ownsHold == false)
    driver.tick(at: 1, fullWake: true, agents: .none)
    #expect(Self.clears(driver) == [.clamshell(on: false, why: .clearStale)])
    #expect(!Self.steps(driver).contains(.sentinel(.arm)))
  }

  @Test func aMissingStateFileWithKeepAwakeWantedEngagesNormally() {
    var driver = Self.launched(.missing)
    Self.busyAt(&driver, 0.5)
    driver.tick(at: 1, fullWake: true)
    #expect(Self.clears(driver).isEmpty)
    #expect(driver.writeTimes(.engage) == [1])
    #expect(driver.writeTimes(.reclaim).isEmpty)
    #expect(Self.holdVerbs(driver) == ["engage"])
    #expect(driver.harness.state.hold.pendingLaunch == nil)
    let lidSteps = Self.steps(driver).filter { if case .persist = $0 { false } else { true } }
    #expect(lidSteps == [.sentinel(.arm), .clamshell(on: true, why: .engage)])
  }

  @Test func aFailedReclaimKeepsOwnershipAndRetriesAsAnEngage() {
    var driver = Self.launched(Self.owned())
    driver.clamshellOutcome = .timedOut
    Self.busyAt(&driver, 0.5)
    driver.tick(at: 1, fullWake: true)
    guard case .failed(let attempts, _) = driver.harness.state.hold.lidClose else {
      Issue.record("expected a failed hold, got \(driver.harness.state.hold.lidClose)")
      return
    }
    #expect(attempts == 1)
    #expect(driver.harness.state.persisted.ownsHold)
    #expect(driver.harness.state.hold.pendingLaunch == nil)
    driver.clamshellOutcome = .succeeded
    driver.tick(at: 21, fullWake: true)
    #expect(driver.writeTimes(.engage) == [21])
    #expect(Self.clears(driver).isEmpty)
  }

  @Test(arguments: [true, false])
  func shadowModeProducesTheSameEffects(_ wanted: Bool) {
    func run(_ mode: RunMode) -> [[Effect]] {
      var driver = Self.launched(Self.owned(), mode: mode)
      if wanted { Self.busyAt(&driver, 0.5) }
      driver.tick(at: 1, fullWake: true, agents: wanted ? HoldDriver.busyAgents : .none)
      return driver.batches
    }
    #expect(run(.live) == run(.shadow))
  }

  @Test(arguments: [PersistedSnapshot.corrupt, .missing])
  func anUnresolvedLaunchCountsAsMayHold(_ snapshot: PersistedSnapshot) {
    var driver = Self.launched(snapshot)
    Self.busyAt(&driver, 0.5)
    driver.tick(at: 1, fullWake: nil)
    #expect(driver.harness.state.hold.pendingLaunch == .clearIfUnwanted)
    #expect(driver.harness.state.hold.lidClose == .released)
    #expect(!driver.harness.state.persisted.ownsHold)
    #expect(LidCloseHold.mayHold(driver.harness.state))
  }

  @Test(arguments: [PersistedSnapshot.corrupt, .missing])
  func aSentinelLostBeforeTheLaunchResolvesIsReplacedArmedAndTheBitCleared(_ snapshot: PersistedSnapshot) {
    var driver = Self.launched(snapshot)
    Self.busyAt(&driver, 0.5)
    driver.tick(at: 1, fullWake: nil)
    let lost = driver.harness.send(.sentinelLost, at: 2)
    let respawn = lost.firstIndex(of: .sentinel(.respawn))
    #expect(respawn != nil)
    #expect(respawn.map { lost.indices.contains($0 + 1) && lost[$0 + 1] == .sentinel(.arm) } == true)
    let clears = lost.compactMap { effect -> ClamshellWhy? in
      if case .clamshell(false, _, let why) = effect { return why }
      return nil
    }
    #expect(clears == [.watchdogLost])
  }

  @Test func aLostSentinelWithNoLaunchPendingAndNothingHeldOnlyRespawns() {
    var driver = Self.launched(.state(PersistedState(bootSessionUUID: Self.boot)))
    let lost = driver.harness.send(.sentinelLost, at: 1)
    #expect(lost == [.log(Decision(keyword: .sentinel, verb: "lost")), .sentinel(.respawn)])
  }
}
