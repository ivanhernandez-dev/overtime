import Foundation
import Testing

@testable import OvertimeCore

@Suite("LID-05 gate, closed-lid display re-check and lid stability")
struct LidGateTests {
  typealias L = LidScenarios

  static let close = Event.lidChanged(closed: true, sleepBit: false, externalDisplays: 0)

  static func idleHarness() -> ScenarioHarness {
    var harness = ScenarioHarness()
    harness.includeActuators = true
    return harness
  }

  @Test func aLidCloseOutsideTheGateIsIgnoredAndForgotten() {
    var harness = Self.idleHarness()
    let effects = harness.send(Self.close, at: 0)
    #expect(L.displaySleeps(effects) == 0)
    #expect(L.lidLines(effects).isEmpty)
    #expect(harness.state.lid.closed == nil)
    let tick = harness.send(L.closedTick(hidIdleSeconds: 120), at: 20)
    #expect(L.displaySleeps(tick) == 0)
    #expect(harness.state.lid == LidState())
  }

  @Test func theGateTurningOnWithTheLidAlreadyClosedAndRecentInputLeavesTheDisplayOn() {
    var harness = Self.idleHarness()
    _ = harness.send(L.closedTick(hidIdleSeconds: 0), at: 0)
    #expect(harness.state.lid.closed == nil)
    L.answer(&harness, harness.activity(writtenAt: 1, seenAt: 1), at: 1)
    #expect(harness.state.want.wanted == true)
    let effects = harness.send(L.closedTick(hidIdleSeconds: 0), at: 2)
    #expect(L.displaySleeps(effects) == 0)
    #expect(L.lidLines(effects).isEmpty)
    #expect(harness.state.lid.closed == true)
    #expect(harness.state.lid.since == harness.instant(2))
    #expect(L.displaySleeps(harness.send(L.closedTick(hidIdleSeconds: 30), at: 12)) == 0)
    #expect(L.displaySleeps(harness.send(L.closedTick(hidIdleSeconds: 60), at: 22)) == 1)
  }

  @Test func theGateTurningOnWithTheLidAlreadyClosedAndNoInputSleepsTheDisplayByTheIdleRule() {
    var harness = Self.idleHarness()
    L.answer(&harness, harness.activity(writtenAt: 1, seenAt: 1), at: 1)
    let effects = harness.send(L.closedTick(hidIdleSeconds: 120), at: 2)
    #expect(L.displaySleeps(effects) == 1)
    #expect(L.lidLines(effects).isEmpty)
    #expect(harness.state.lid.nextResleep == harness.instant(12))
  }

  @Test func aRealCloseNotificationAfterTheGateOpensStillSleepsTheDisplay() {
    var harness = Self.idleHarness()
    _ = harness.tick(at: 0)
    L.answer(&harness, harness.activity(writtenAt: 1, seenAt: 1), at: 1)
    let effects = harness.send(Self.close, at: 2)
    #expect(L.displaySleeps(effects) == 1)
    #expect(effects.contains(L.closedLog(ext: 0)))
  }

  @Test func theGateOffAfterACloseForgetsTheLid() {
    var harness = L.wantedHarness(fullWake: false)
    L.answer(&harness, harness.send(Self.close, at: 2), at: 2)
    #expect(harness.state.lid.closed == true)
    let effects = harness.send(L.closedTick(hidIdleSeconds: 120), at: 400)
    L.answer(&harness, effects, at: 400)
    #expect(harness.state.want.wanted == false)
    #expect(L.displaySleeps(effects) == 0)
    #expect(harness.state.lid == LidState())
  }

  @Test func anOwnedHoldAloneKeepsTheLidWatched() {
    var harness = Self.idleHarness()
    harness.state.persisted.ownsHold = true
    let effects = harness.send(Self.close, at: 0)
    #expect(L.displaySleeps(effects) == 1)
    #expect(effects.contains(L.closedLog(ext: 0)))
  }

  @Test func aHotspotSwitchAloneKeepsTheLidWatched() {
    var harness = Self.idleHarness()
    harness.state.persisted.switchedToHotspot = true
    let effects = harness.send(Self.close, at: 0)
    #expect(L.displaySleeps(effects) == 1)
    #expect(harness.state.lid.closed == true)
  }

  @Test func anOpenAfterACloseLogsLidOpened() {
    var harness = L.wantedHarness(fullWake: false)
    L.answer(&harness, harness.send(Self.close, at: 2), at: 2)
    let effects = harness.send(.lidChanged(closed: false, sleepBit: false, externalDisplays: nil), at: 5)
    #expect(L.lidLines(effects) == [Decision(keyword: .lid, verb: "opened")])
    #expect(harness.state.lid.nextResleep == nil)
    #expect(harness.state.lid.nextDisplayCheck == nil)
  }

  @Test func theDisplayCountIsReReadOnlyWhenTheCheckIsDue() {
    var harness = L.wantedHarness(fullWake: false)
    L.answer(&harness, harness.send(Self.close, at: 2), at: 2)
    #expect(harness.state.lid.nextDisplayCheck == harness.instant(32))
    let early = harness.send(L.closedTick(externalDisplays: 1, hidIdleSeconds: 120), at: 20)
    L.answer(&harness, early, at: 20)
    #expect(harness.state.lid.externalDisplays == 0)
    #expect(L.displaySleeps(early) == 1)
    let due = harness.send(L.closedTick(externalDisplays: 1, hidIdleSeconds: 120), at: 32)
    L.answer(&harness, due, at: 32)
    #expect(harness.state.lid.externalDisplays == 1)
    #expect(harness.state.lid.nextDisplayCheck == harness.instant(62))
    #expect(L.displaySleeps(due) == 0)
    let later = harness.send(L.closedTick(externalDisplays: 0, hidIdleSeconds: 120), at: 50)
    #expect(L.displaySleeps(later) == 0)
    #expect(harness.state.lid.externalDisplays == 1)
  }

  @Test func anUnreadableCountAtTheCheckKeepsTheLastCount() {
    var harness = L.wantedHarness(fullWake: false)
    L.answer(&harness, harness.send(.lidChanged(closed: true, sleepBit: false, externalDisplays: 1), at: 2), at: 2)
    _ = harness.send(L.closedTick(externalDisplays: nil, hidIdleSeconds: 120), at: 32)
    #expect(harness.state.lid.externalDisplays == 1)
    #expect(harness.state.lid.nextDisplayCheck == harness.instant(62))
  }

  @Test func anUnreadableHIDIdleTimeNeverReSleeps() {
    var harness = L.wantedHarness(fullWake: false)
    L.answer(&harness, harness.send(Self.close, at: 2), at: 2)
    var sleeps = 0
    for second in stride(from: 12.0, through: 60.0, by: 2.0) {
      let effects = harness.send(L.closedTick(hidIdleSeconds: nil), at: second)
      L.answer(&harness, effects, at: second)
      sleeps += L.displaySleeps(effects)
    }
    #expect(sleeps == 0)
  }

  @Test func aReSleepIsAtMostOncePerTenSeconds() {
    var harness = L.wantedHarness(fullWake: false)
    L.answer(&harness, harness.send(Self.close, at: 2), at: 2)
    var sleeps: [Double] = []
    for second in stride(from: 4.0, through: 40.0, by: 2.0) {
      let effects = harness.send(L.closedTick(hidIdleSeconds: 120), at: second)
      L.answer(&harness, effects, at: second)
      if L.displaySleeps(effects) > 0 { sleeps.append(second) }
    }
    #expect(sleeps == [12, 22, 32])
  }

  @Test func theLidIsStableAfterExactlyFourSecondsClosed() {
    let since = Instant(nanoseconds: 50_000_000_000)
    let lid = LidState(closed: true, since: since)
    #expect(!LidDisplay.isClosedStable(lid, now: since.adding(seconds: 3.999)))
    #expect(LidDisplay.isClosedStable(lid, now: since.adding(seconds: 4)))
    #expect(!LidDisplay.isClosedStable(LidState(closed: false, since: since), now: since.adding(seconds: 60)))
    #expect(!LidDisplay.isClosedStable(LidState(), now: since.adding(seconds: 60)))
  }

  @Test func theNextDeadlineIncludesTheReSleepWhileClosedWithoutAnExternalDisplay() {
    var harness = L.wantedHarness(fullWake: false)
    L.answer(&harness, harness.send(Self.close, at: 2), at: 2)
    #expect(Reducer.nextDeadline(harness.state, harness.settings) == harness.instant(12))
  }

  @Test func theNextDeadlineIncludesTheDisplayCheckWhileClosed() {
    var harness = L.wantedHarness(fullWake: false)
    let close = harness.send(.lidChanged(closed: true, sleepBit: false, externalDisplays: 1), at: 2)
    L.answer(&harness, close, at: 2)
    #expect(Reducer.nextDeadline(harness.state, harness.settings) == harness.instant(32))
  }

  @Test func theNextDeadlineIgnoresTheLidWhileOpen() {
    var harness = L.wantedHarness(fullWake: false)
    L.answer(&harness, harness.send(Self.close, at: 2), at: 2)
    L.answer(&harness, harness.send(.lidChanged(closed: false, sleepBit: false, externalDisplays: nil), at: 3), at: 3)
    let deadline = Reducer.nextDeadline(harness.state, harness.settings)
    #expect(deadline != harness.instant(12))
    #expect(deadline != harness.instant(32))
  }
}
