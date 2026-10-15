import Foundation
import Testing

@testable import OvertimeCore

@Suite("Override persistence (HOLD-14)")
struct OverridePersistenceTests {
  static let boot = "11111111-2222-3333-4444-555555555555"
  static let otherBoot = "99999999-8888-7777-6666-555555555555"

  static func override(_ verb: String, _ fields: [DecisionField] = []) -> Decision {
    Decision(keyword: .override, verb: verb, fields: fields)
  }

  static func persists(_ effects: [Effect]) -> [PersistedState] {
    effects.compactMap { effect in
      if case .persist(let state) = effect { return state }
      return nil
    }
  }

  static func launch(
    _ harness: inout ScenarioHarness, _ persisted: PersistedSnapshot, boot: String? = OverridePersistenceTests.boot,
    at seconds: Double = 0
  ) -> [Effect] {
    harness.send(.launched(LaunchFacts(persisted: persisted, bootSessionUUID: boot)), at: seconds)
  }

  static func saved(_ build: (inout PersistedState) -> Void) -> PersistedSnapshot {
    var state = PersistedState(bootSessionUUID: boot)
    build(&state)
    return .state(state)
  }

  @Test func sameBootRestoresATimedPauseWithItsMonoDeadline() {
    var harness = ScenarioHarness()
    let wall = harness.wall0.addingTimeInterval(3600)
    let snapshot = Self.saved {
      $0.pause = PersistedPause(
        kind: PersistedPause.timed, monoDeadlineNanoseconds: harness.instant(3600).nanoseconds, wallDeadline: wall)
    }
    let effects = Self.launch(&harness, snapshot)
    #expect(harness.state.want.pause == .untilMono(harness.instant(3600), wall: wall))
    #expect(ScenarioHarness.decisions(effects).isEmpty)
    #expect(Self.persists(effects).count == 1)
    #expect(Self.persists(effects).first?.pause?.kind == PersistedPause.timed)
  }

  @Test func sameBootRestoresReleaseUntilIdle() {
    var harness = ScenarioHarness()
    let effects = Self.launch(&harness, Self.saved { $0.releaseUntilIdle = true })
    #expect(harness.state.want.override)
    #expect(ScenarioHarness.decisions(effects).isEmpty)
    #expect(Self.persists(effects).first?.releaseUntilIdle == true)
  }

  @Test func sameBootDropsAPersistedForceAndLogsItOnce() {
    var harness = ScenarioHarness()
    let effects = Self.launch(&harness, Self.saved { $0.forceActive = true })
    #expect(harness.state.want.force == nil)
    #expect(
      ScenarioHarness.decisions(effects) == [
        Self.override("forceDropped", [DecisionField(key: "reason", value: "relaunch")])
      ])
    #expect(Self.persists(effects) == [PersistedState(bootSessionUUID: Self.boot)])
  }

  @Test func differentBootKeepsAFutureWallDeadlineAsAPauseUntilThatDate() {
    var harness = ScenarioHarness()
    let wall = harness.wall0.addingTimeInterval(3600)
    let snapshot = Self.saved {
      $0.pause = PersistedPause(kind: PersistedPause.timed, monoDeadlineNanoseconds: 42, wallDeadline: wall)
    }
    let effects = Self.launch(&harness, snapshot, boot: Self.otherBoot)
    #expect(harness.state.want.pause == .untilWall(wall))
    #expect(ScenarioHarness.decisions(effects).isEmpty)
    #expect(Self.persists(effects).first?.pause == PersistedPause(kind: PersistedPause.until, wallDeadline: wall))
    #expect(Self.persists(effects).first?.bootSessionUUID == Self.otherBoot)
  }

  @Test func differentBootDropsAnExpiredPause() {
    var harness = ScenarioHarness()
    let wall = harness.wall0.addingTimeInterval(-10)
    let effects = Self.launch(
      &harness, Self.saved { $0.pause = PersistedPause(kind: PersistedPause.until, wallDeadline: wall) },
      boot: Self.otherBoot)
    #expect(harness.state.want.pause == nil)
    #expect(ScenarioHarness.decisions(effects) == [Self.override("pauseExpired")])
    #expect(Self.persists(effects).first?.pause == nil)
  }

  @Test func differentBootKeepsAnIndefinitePause() {
    var harness = ScenarioHarness()
    let effects = Self.launch(
      &harness, Self.saved { $0.pause = PersistedPause(kind: PersistedPause.indefinite) }, boot: Self.otherBoot)
    #expect(harness.state.want.pause == .indefinite)
    #expect(ScenarioHarness.decisions(effects).isEmpty)
  }

  @Test func differentBootDropsReleaseUntilIdleAndForceAndLogsEach() {
    var harness = ScenarioHarness()
    let snapshot = Self.saved {
      $0.releaseUntilIdle = true
      $0.forceActive = true
    }
    let effects = Self.launch(&harness, snapshot, boot: Self.otherBoot)
    #expect(harness.state.want.override == false)
    #expect(harness.state.want.force == nil)
    #expect(
      ScenarioHarness.decisions(effects) == [
        Self.override("releaseUntilIdleDropped", [DecisionField(key: "reason", value: "reboot")]),
        Self.override("forceDropped", [DecisionField(key: "reason", value: "reboot")]),
      ])
    #expect(Self.persists(effects) == [PersistedState(bootSessionUUID: Self.otherBoot)])
  }

  @Test func anUnknownBootSessionCountsAsADifferentBoot() {
    var harness = ScenarioHarness()
    var state = PersistedState(bootSessionUUID: nil)
    state.releaseUntilIdle = true
    _ = Self.launch(&harness, .state(state), boot: nil)
    #expect(harness.state.want.override == false)
  }

  @Test func aSameBootPauseWhoseDeadlinePassedIsDroppedAtLaunch() {
    var harness = ScenarioHarness()
    let snapshot = Self.saved {
      $0.pause = PersistedPause(
        kind: PersistedPause.timed, monoDeadlineNanoseconds: harness.instant(-1).nanoseconds,
        wallDeadline: harness.wall0.addingTimeInterval(-1))
    }
    let effects = Self.launch(&harness, snapshot)
    #expect(harness.state.want.pause == nil)
    #expect(ScenarioHarness.decisions(effects) == [Self.override("pauseExpired")])
  }

  @Test func aMissingFileRestoresNothing() {
    var harness = ScenarioHarness()
    let effects = Self.launch(&harness, .missing)
    #expect(harness.state.want == WantState())
    #expect(ScenarioHarness.decisions(effects).isEmpty)
    #expect(Self.persists(effects) == [PersistedState(bootSessionUUID: Self.boot)])
    #expect(harness.state.bootSessionUUID == Self.boot)
  }

  @Test func aCorruptFileRestoresNothingAndLogsIt() {
    var harness = ScenarioHarness()
    let effects = Self.launch(&harness, .corrupt)
    #expect(harness.state.want == WantState())
    #expect(ScenarioHarness.decisions(effects) == [Decision(keyword: .error, verb: "state corrupt")])
    #expect(Self.persists(effects) == [PersistedState(bootSessionUUID: Self.boot)])
  }

  @Test func sameBootHoldFieldsAreCarriedThroughUnchanged() {
    var harness = ScenarioHarness()
    let snapshot = Self.saved {
      $0.ownsHold = true
      $0.sentinelArmed = true
      $0.switchedToHotspot = true
    }
    let effects = Self.launch(&harness, snapshot)
    let persisted = Self.persists(effects).first
    #expect(persisted?.ownsHold == true)
    #expect(persisted?.sentinelArmed == true)
    #expect(persisted?.switchedToHotspot == true)
  }

  @Test func anotherBootDropsHoldOwnershipAndKeepsTheOtherFields() {
    var harness = ScenarioHarness()
    let snapshot = Self.saved {
      $0.ownsHold = true
      $0.sentinelArmed = true
      $0.switchedToHotspot = true
    }
    let effects = Self.launch(&harness, snapshot, boot: Self.otherBoot)
    let persisted = Self.persists(effects).first
    #expect(persisted?.ownsHold == false)
    #expect(persisted?.sentinelArmed == false)
    #expect(persisted?.switchedToHotspot == true)
  }

  @Test func identicalLaunchFactsGiveIdenticalStatesAndEffects() {
    let snapshot = Self.saved {
      $0.forceActive = true
      $0.releaseUntilIdle = true
      $0.pause = PersistedPause(kind: PersistedPause.indefinite)
    }
    var first = ScenarioHarness()
    var second = ScenarioHarness()
    let firstEffects = Self.launch(&first, snapshot)
    let secondEffects = Self.launch(&second, snapshot)
    #expect(first.state == second.state)
    #expect(firstEffects == secondEffects)
    #expect(
      ScenarioHarness.decisions(firstEffects).filter { $0.verb == "forceDropped" }.count == 1)
  }

  @Test func encodingEqualStatesGivesIdenticalBytes() throws {
    let wall = Date(timeIntervalSince1970: 1_800_000_000)
    let make = {
      PersistedState(
        bootSessionUUID: Self.boot, ownsHold: true,
        pause: PersistedPause(kind: PersistedPause.timed, monoDeadlineNanoseconds: 7, wallDeadline: wall),
        releaseUntilIdle: true)
    }
    let first = try StateCodec.encode(make())
    #expect(!first.isEmpty)
    #expect(try first == StateCodec.encode(make()))
  }

  @Test func overrideChangesArePersistedAndUnchangedStepsAreNot() {
    var harness = ScenarioHarness()
    _ = Self.launch(&harness, .missing)
    #expect(Self.persists(harness.tick(at: 1)).isEmpty)
    let paused = Self.persists(harness.send(.command(.pause(.indefinite)), at: 2))
    #expect(paused.map(\.pause) == [PersistedPause(kind: PersistedPause.indefinite)])
    #expect(Self.persists(harness.tick(at: 3)).isEmpty)
    let forced = Self.persists(harness.send(.command(.force(.indefinite)), at: 4))
    #expect(forced.map(\.forceActive) == [true])
    #expect(forced.first?.pause == nil)
    let resumed = Self.persists(harness.send(.command(.resume), at: 5))
    #expect(resumed == [PersistedState(bootSessionUUID: Self.boot)])
  }
}
