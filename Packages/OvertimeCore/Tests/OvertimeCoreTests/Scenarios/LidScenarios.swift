import Foundation
import Testing

@testable import OvertimeCore

@Suite("Lid scenarios #25-#28")
struct LidScenarios {
  static func closedLog(ext: Int) -> Effect {
    .log(Decision(keyword: .lid, verb: "closed", fields: [DecisionField(key: "ext", value: String(ext))]))
  }

  static func effectID(_ effect: Effect) -> EffectID? {
    switch effect {
    case .idleAssertion(_, let id), .displayAssertion(_, let id), .clamshell(_, let id, _), .displaySleepNow(let id),
      .requestSleep(let id):
      id
    default:
      nil
    }
  }

  static func answer(_ harness: inout ScenarioHarness, _ effects: [Effect], at seconds: Double) {
    var pending = effects
    var offset = 0.001
    while !pending.isEmpty {
      let effect = pending.removeFirst()
      guard let id = effectID(effect) else { continue }
      pending += harness.send(.effectResult(id, .succeeded), at: seconds + offset)
      offset += 0.001
    }
  }

  static func wantedHarness(keepDisplayOn: Bool = false, fullWake: Bool = true) -> ScenarioHarness {
    var harness = ScenarioHarness(settings: Settings(keepDisplayOn: keepDisplayOn))
    harness.includeActuators = true
    answer(&harness, harness.activity(writtenAt: 0, seenAt: 0), at: 0)
    answer(&harness, harness.send(.tick(TickFacts(lidClosed: false, fullWake: fullWake)), at: 1), at: 1)
    return harness
  }

  static func closedTick(externalDisplays: Int? = 0, hidIdleSeconds: Double?) -> Event {
    .tick(
      TickFacts(lidClosed: true, externalDisplays: externalDisplays, fullWake: true, hidIdleSeconds: hidIdleSeconds))
  }

  static func lidLines(_ effects: [Effect]) -> [Decision] {
    ScenarioHarness.decisions(effects).filter { $0.keyword == .lid }
  }

  static func displaySleeps(_ effects: [Effect]) -> Int {
    effects.filter { effect in
      if case .displaySleepNow = effect { return true }
      return false
    }.count
  }

  static func index(of effects: [Effect], _ matches: (Effect) -> Bool) -> Int? {
    effects.firstIndex(where: matches)
  }

  @Test("#25 closing the lid turns the display off")
  func scenario25ClosingTheLidTurnsTheDisplayOff() {
    var harness = Self.wantedHarness()
    #expect(harness.state.want.wanted == true)
    let effects = harness.send(.lidChanged(closed: true, sleepBit: false, externalDisplays: 0), at: 2)
    #expect(Self.displaySleeps(effects) == 1)
    #expect(effects.contains(Self.closedLog(ext: 0)))
    #expect(harness.state.lid.closed == true)
  }

  @Test("#25 with keepDisplayOn the display assertion is released before the display is slept")
  func scenario25ReleasesTheDisplayAssertionFirst() {
    var harness = Self.wantedHarness(keepDisplayOn: true)
    #expect(harness.state.hold.display == .held)
    let effects = harness.send(.lidChanged(closed: true, sleepBit: false, externalDisplays: 0), at: 2)
    let release = Self.index(of: effects) { effect in
      if case .displayAssertion(.release, _) = effect { return true }
      return false
    }
    let sleep = Self.index(of: effects) { effect in
      if case .displaySleepNow = effect { return true }
      return false
    }
    #expect(Self.displaySleeps(effects) == 1)
    #expect(release != nil)
    #expect(sleep != nil)
    if let release, let sleep {
      #expect(release < sleep)
    }
  }

  @Test("#26 with an external display the display is left alone")
  func scenario26AnExternalDisplayIsLeftAlone() {
    var harness = Self.wantedHarness(keepDisplayOn: true)
    let effects = harness.send(.lidChanged(closed: true, sleepBit: false, externalDisplays: 1), at: 2)
    #expect(Self.displaySleeps(effects) == 0)
    #expect(effects.contains(Self.closedLog(ext: 1)))
    #expect(
      !effects.contains { effect in
        if case .displayAssertion(.release, _) = effect { return true }
        return false
      })
    #expect(harness.state.lid.externalDisplays == 1)
  }

  @Test("#27 lid closed with recent input (remote access) does not re-sleep")
  func scenario27RecentInputDoesNotReSleep() {
    var harness = Self.wantedHarness()
    let close = harness.send(.lidChanged(closed: true, sleepBit: false, externalDisplays: 0), at: 2)
    Self.answer(&harness, close, at: 2)
    #expect(harness.state.lid.nextResleep == harness.instant(12))
    let effects = harness.send(Self.closedTick(hidIdleSeconds: 5), at: 12)
    Self.answer(&harness, effects, at: 12)
    #expect(Self.displaySleeps(effects) == 0)
    #expect(Self.lidLines(effects).isEmpty)
    #expect(harness.state.lid.nextResleep == harness.instant(22))
  }

  @Test("#28 lid closed with no input for 60 s re-sleeps the display")
  func scenario28NoInputForAMinuteReSleeps() {
    var harness = Self.wantedHarness()
    let close = harness.send(.lidChanged(closed: true, sleepBit: false, externalDisplays: 0), at: 2)
    Self.answer(&harness, close, at: 2)
    let effects = harness.send(Self.closedTick(hidIdleSeconds: 120), at: 12)
    Self.answer(&harness, effects, at: 12)
    #expect(Self.displaySleeps(effects) == 1)
    #expect(Self.lidLines(effects).isEmpty)
    #expect(harness.state.lid.nextResleep == harness.instant(22))
  }
}
