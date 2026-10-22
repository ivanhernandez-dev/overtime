import Foundation
import Testing

@testable import OvertimeCore

struct LongRunningBusyTests {
  struct Step {
    var at: Double
    var effects: [Effect]

    var decisions: [Decision] {
      ScenarioHarness.decisions(effects)
    }
  }

  static let limited = Settings(longRunningLimitEnabled: true, longRunningLimitMinutes: 120)

  static func at(_ seconds: Double) -> Instant {
    ScenarioHarness().instant(seconds)
  }

  static func facts(background: Int = 0, print: [Double] = [], caffeinate: Bool = false) -> TickFacts {
    TickFacts(
      agents: AgentSignals(
        busyProcessCount: caffeinate ? 1 : 0, sessionCount: caffeinate ? 1 : 0, backgroundCommandSessions: background,
        printRunStarts: print.map(at)))
  }

  static func run(
    _ harness: inout ScenarioHarness, from start: Double = 0, to end: Double, transcripts: [Double] = [],
    facts: (Double) -> TickFacts
  ) -> [Step] {
    var steps: [Step] = []
    var index = 0
    while true {
      let now = start + Double(index) * 2
      guard now <= end else { break }
      var effects: [Effect] = []
      if transcripts.contains(now) {
        effects += harness.activity(writtenAt: now, seenAt: now)
      }
      effects += harness.send(.tick(facts(now)), at: now)
      steps.append(Step(at: now, effects: effects))
      index += 1
    }
    return steps
  }

  static func text(_ decision: Decision) -> String {
    ([decision.verb] + decision.fields.map { "\($0.key)=\($0.value)" }).joined(separator: " ")
  }

  static func lines(_ steps: [Step], _ keyword: DecisionKeyword) -> [String] {
    steps.flatMap { step in
      step.decisions.filter { $0.keyword == keyword }.map { "\(Int(step.at)) " + text($0) }
    }
  }

  static func busyLines(_ steps: [Step]) -> [String] {
    lines(steps, .busy)
  }

  static func wantLines(_ steps: [Step]) -> [String] {
    lines(steps, .want)
  }

  @Test func aBackgroundCommandKeepsClaudeBusyAfterTheTurn() {
    var harness = ScenarioHarness()
    let steps = Self.run(&harness, to: 10800, transcripts: [0]) { _ in Self.facts(background: 1) }
    #expect(Self.busyLines(steps) == ["0 on source=transcript", "120 continues source=background"])
    #expect(Self.wantLines(steps) == ["0 on reason=busy"])
    #expect(harness.state.want.wanted == true)
  }

  @Test func theCommandEndingStartsTheReleaseGrace() {
    var harness = ScenarioHarness()
    let steps = Self.run(&harness, to: 5200, transcripts: [0]) { now in Self.facts(background: now < 5000 ? 1 : 0) }
    #expect(
      Self.busyLines(steps) == [
        "0 on source=transcript", "120 continues source=background", "5000 off source=transcript",
      ])
    #expect(Self.wantLines(steps) == ["0 on reason=busy", "5058 off reason=idle"])
  }

  @Test func aPrintRunHoldsForItsLifetime() {
    var harness = ScenarioHarness()
    let steps = Self.run(&harness, to: 1100) { now in Self.facts(print: now < 900 ? [-40] : []) }
    #expect(Self.busyLines(steps) == ["0 on source=print", "900 off source=transcript"])
    #expect(Self.wantLines(steps) == ["0 on reason=busy", "958 off reason=idle"])
  }

  @Test func severalPrintRunsReleaseWhenTheLastEnds() {
    var harness = ScenarioHarness()
    let steps = Self.run(&harness, to: 800) { now in
      Self.facts(print: (now < 300 ? [-40] : []) + (now < 600 ? [-10] : []))
    }
    #expect(Self.busyLines(steps) == ["0 on source=print", "600 off source=transcript"])
  }

  @Test func eachSwitchDecidesForItsSignal() {
    var noBackground = ScenarioHarness(settings: Settings(backgroundCommandsKeepAwake: false))
    let background = Self.run(&noBackground, to: 400) { _ in Self.facts(background: 1) }
    #expect(Self.busyLines(background) == ["0 off source=background"])
    var noPrint = ScenarioHarness(settings: Settings(printRunsKeepAwake: false))
    let print = Self.run(&noPrint, to: 400) { _ in Self.facts(print: [-40]) }
    #expect(Self.busyLines(print) == ["0 off source=print"])
    var printOnly = ScenarioHarness(settings: Settings(backgroundCommandsKeepAwake: false))
    let printHeld = Self.run(&printOnly, to: 400) { _ in Self.facts(background: 1, print: [-40]) }
    #expect(Self.busyLines(printHeld) == ["0 on source=print"])
    var backgroundOnly = ScenarioHarness(settings: Settings(printRunsKeepAwake: false))
    let backgroundHeld = Self.run(&backgroundOnly, to: 400) { _ in Self.facts(background: 1, print: [-40]) }
    #expect(Self.busyLines(backgroundHeld) == ["0 on source=background"])
  }

  @Test func theLimitStopsABackgroundCommandAfterTheLastActivity() {
    var harness = ScenarioHarness(settings: Self.limited)
    let steps = Self.run(&harness, to: 7400, transcripts: [0]) { _ in Self.facts(background: 1) }
    #expect(
      Self.busyLines(steps) == [
        "0 on source=transcript", "120 continues source=background", "7200 limit source=background minutes=120",
        "7200 off source=background",
      ])
    #expect(Self.wantLines(steps) == ["0 on reason=busy", "7258 off reason=idle"])
  }

  @Test func newActivityRestartsTheBackgroundLimit() {
    var harness = ScenarioHarness(settings: Self.limited)
    let steps = Self.run(&harness, to: 11000, transcripts: [0, 3600]) { _ in Self.facts(background: 1) }
    #expect(
      Self.busyLines(steps) == [
        "0 on source=transcript", "120 continues source=background", "3720 continues source=background",
        "10800 limit source=background minutes=120", "10800 off source=background",
      ])
  }

  @Test func theBackgroundLimitCountsFromTheFirstSightingWithoutActivity() {
    var harness = ScenarioHarness(settings: Self.limited)
    let steps = Self.run(&harness, to: 7400) { now in Self.facts(background: now >= 100 ? 1 : 0) }
    #expect(
      Self.busyLines(steps) == [
        "0 off source=transcript", "100 on source=background", "7300 limit source=background minutes=120",
        "7300 off source=background",
      ])
  }

  @Test func theLimitStopsAPrintRunAfterItStarted() {
    var harness = ScenarioHarness(settings: Self.limited)
    let steps = Self.run(&harness, to: 6400) { _ in Self.facts(print: [-1000]) }
    #expect(
      Self.busyLines(steps) == [
        "0 on source=print", "6200 limit source=print minutes=120", "6200 off source=print",
      ])
  }

  @Test func theLimitLineIsLoggedOncePerEpisode() {
    var harness = ScenarioHarness(settings: Settings(longRunningLimitEnabled: true, longRunningLimitMinutes: 15))
    let steps = Self.run(&harness, to: 3200) { now in
      Self.facts(background: now < 2000 || now >= 2010 ? 1 : 0)
    }
    let limits = Self.busyLines(steps).filter { $0.contains(" limit ") }
    #expect(limits == ["900 limit source=background minutes=15", "2910 limit source=background minutes=15"])
  }

  static func edges(from seconds: Double) -> [Instant] {
    Reducer.windowEdges(from: at(seconds), seconds: 7200)
  }

  @Test func theNextDeadlineIncludesTheLimitEdges() {
    let noBackground = Settings(backgroundCommandsKeepAwake: false, longRunningLimitEnabled: true)
    let noPrint = Settings(printRunsKeepAwake: false, longRunningLimitEnabled: true)
    var state = AppState(mode: .shadow)
    state.lastEventAt = Self.at(100)
    #expect(Reducer.nextDeadline(state, Self.limited) == nil)
    state.busy.backgroundCommandSessions = 1
    state.busy.backgroundSince = Self.at(0)
    #expect(Reducer.nextDeadline(state, Settings()) == nil)
    #expect(Reducer.nextDeadline(state, noBackground) == nil)
    #expect(Reducer.longRunningDeadlines(state, Self.limited) == Self.edges(from: 0))
    #expect(Reducer.nextDeadline(state, Self.limited) == Self.edges(from: 0).first)
    state.busy.lastEligibleTranscript = Self.at(50)
    #expect(Reducer.longRunningDeadlines(state, Self.limited) == Self.edges(from: 50))
    state.busy.lastEligibleTranscript = nil
    state.busy.backgroundCommandSessions = 0
    state.busy.backgroundSince = nil
    state.busy.printRunStarts = [Self.at(-1000)]
    #expect(Reducer.longRunningDeadlines(state, Self.limited) == Self.edges(from: -1000))
    #expect(Reducer.nextDeadline(state, Self.limited) == Self.edges(from: -1000).first)
    #expect(Reducer.nextDeadline(state, Settings()) == nil)
    #expect(Reducer.nextDeadline(state, noPrint) == nil)
  }

  @Test func theHoldingFlagsFollowTheSignals() {
    var harness = ScenarioHarness(settings: Self.limited)
    _ = Self.run(&harness, to: 10) { _ in Self.facts(background: 1, print: [-40]) }
    #expect(harness.state.busy.backgroundHolding)
    #expect(harness.state.busy.printHolding)
    _ = Self.run(&harness, from: 12, to: 20) { _ in Self.facts() }
    #expect(!harness.state.busy.backgroundHolding)
    #expect(!harness.state.busy.printHolding)
    _ = Self.run(&harness, from: 22, to: 7300) { _ in Self.facts(background: 1, print: [20]) }
    #expect(!harness.state.busy.backgroundHolding)
    #expect(!harness.state.busy.printHolding)
    var switchedOff = ScenarioHarness(
      settings: Settings(backgroundCommandsKeepAwake: false, printRunsKeepAwake: false))
    _ = Self.run(&switchedOff, to: 10) { _ in Self.facts(background: 1, print: [-40]) }
    #expect(!switchedOff.state.busy.backgroundHolding)
    #expect(!switchedOff.state.busy.printHolding)
  }

  static func holding(settings: Settings = Settings()) -> ScenarioHarness {
    var harness = ScenarioHarness(settings: settings)
    _ = run(&harness, to: 10) { _ in facts(background: 1) }
    return harness
  }

  @Test func theProtectionsStillWinOverALongRunningHold() {
    var battery = Self.holding()
    #expect(battery.state.want.wanted == true)
    _ = battery.send(.power(.battery(percent: 5)), at: 11)
    _ = Self.run(&battery, from: 12, to: 20) { _ in Self.facts(background: 1) }
    #expect(battery.state.want.wanted == false)
    #expect(battery.state.want.reason == "battery")

    var temperature = Self.holding(settings: Settings(temperatureProtectionEnabled: true))
    #expect(temperature.state.want.wanted == true)
    _ = temperature.send(.batteryTemperature(.celsius(50)), at: 11)
    _ = Self.run(&temperature, from: 12, to: 20) { _ in Self.facts(background: 1) }
    #expect(temperature.state.want.wanted == false)
    #expect(temperature.state.want.reason == "temperature")

    var paused = Self.holding()
    _ = paused.send(.command(.pause(.forSeconds(600))), at: 11)
    _ = Self.run(&paused, from: 12, to: 20) { _ in Self.facts(background: 1) }
    #expect(paused.state.want.wanted == false)
    #expect(paused.state.want.reason == "paused")

    var released = Self.holding()
    _ = released.send(.command(.releaseUntilIdle), at: 11)
    _ = Self.run(&released, from: 12, to: 400) { _ in Self.facts(background: 1) }
    #expect(released.state.want.wanted == false)
    #expect(released.state.want.reason == "override")

    var sleepNow = Self.holding()
    sleepNow.includeActuators = true
    let sleepEffects = sleepNow.send(.command(.sleepNow), at: 11)
    #expect(sleepEffects.contains { if case .requestSleep = $0 { true } else { false } })

    var forced = Self.holding()
    _ = forced.send(.command(.force(.forSeconds(600))), at: 11)
    #expect(forced.state.want.reason == "forced")
    _ = forced.send(.command(.resume), at: 12)
    _ = Self.run(&forced, from: 14, to: 20) { _ in Self.facts(background: 1) }
    #expect(forced.state.want.wanted == true)
    #expect(forced.state.want.reason == "busy")
  }

  @Test func includingCopiesTheWorkIntoTheSignals() {
    let work = LongRunningWork(waitingSessionPIDs: [10, 11], printRunStarts: [20: Self.at(50), 21: Self.at(10)])
    let base = AgentSignals(busyProcessCount: 1, sessionCount: 1, terminalAgentStarts: [Self.at(1)])
    let included = base.including(work)
    #expect(included.backgroundCommandSessions == 2)
    #expect(included.printRunStarts == [Self.at(10), Self.at(50)])
    #expect(included.busyProcessCount == 1)
    #expect(included.terminalAgentStarts == [Self.at(1)])
    let merged = AgentSignals.merged([
      AgentSignals(backgroundCommandSessions: 1, printRunStarts: [Self.at(5)]),
      AgentSignals(backgroundCommandSessions: 2, printRunStarts: [Self.at(3)]),
    ])
    #expect(merged.backgroundCommandSessions == 3)
    #expect(merged.printRunStarts == [Self.at(5), Self.at(3)])
  }

  typealias Scenario = @Sendable (inout ScenarioHarness) -> [Effect]

  static let corpus: [Scenario] = [
    { harness in
      run(&harness, to: 400, transcripts: [0]) { _ in facts() }.flatMap(\.effects)
    },
    { harness in
      run(&harness, to: 600, transcripts: [0]) { now in facts(caffeinate: now < 300) }.flatMap(\.effects)
    },
    { harness in
      run(&harness, to: 2100, transcripts: [0]) { _ in facts(caffeinate: true) }.flatMap(\.effects)
    },
    { harness in
      run(&harness, to: 300, transcripts: [0, 100]) { _ in facts() }.flatMap(\.effects)
    },
    { harness in
      var effects = run(&harness, to: 20, transcripts: [0]) { _ in facts(caffeinate: true) }.flatMap(\.effects)
      effects += harness.send(.command(.pause(.forSeconds(60))), at: 21)
      effects += run(&harness, from: 22, to: 100) { _ in facts(caffeinate: true) }.flatMap(\.effects)
      effects += harness.send(.command(.force(.forSeconds(30))), at: 101)
      effects += run(&harness, from: 102, to: 160) { _ in facts(caffeinate: true) }.flatMap(\.effects)
      effects += harness.send(.command(.releaseUntilIdle), at: 161)
      effects += run(&harness, from: 162, to: 400, transcripts: [200]) { _ in facts() }.flatMap(\.effects)
      return effects
    },
    { harness in
      var effects = run(&harness, to: 20, transcripts: [0]) { _ in facts(caffeinate: true) }.flatMap(\.effects)
      effects += harness.send(.power(.battery(percent: 5)), at: 21)
      effects += run(&harness, from: 22, to: 200) { _ in facts(caffeinate: true) }.flatMap(\.effects)
      return effects
    },
  ]

  @Test func withoutLongRunningSignalsTheDefaultBehavesAsBefore() {
    let variants = [
      Settings(),
      Settings(backgroundCommandsKeepAwake: false, printRunsKeepAwake: false),
      Settings(longRunningLimitEnabled: true, longRunningLimitMinutes: 15),
    ]
    for (index, sequence) in Self.corpus.enumerated() {
      var runs: [(effects: [Effect], state: AppState)] = []
      for settings in variants {
        var harness = ScenarioHarness(settings: settings)
        let effects = sequence(&harness)
        runs.append((effects, harness.state))
      }
      #expect(!runs[0].effects.isEmpty, "sequence \(index)")
      for other in runs.dropFirst() {
        #expect(other.effects == runs[0].effects, "sequence \(index)")
        #expect(other.state == runs[0].state, "sequence \(index)")
      }
    }
  }

  @Test func anEmptySignalNeverHolds() {
    let variants = [
      Settings(),
      Settings(backgroundCommandsKeepAwake: false, printRunsKeepAwake: false),
      Settings(longRunningLimitEnabled: true, longRunningLimitMinutes: 15),
    ]
    for settings in variants {
      var harness = ScenarioHarness(settings: settings)
      let steps = Self.run(&harness, to: 400) { _ in Self.facts(background: 0, print: []) }
      #expect(Self.busyLines(steps) == ["0 off source=transcript"])
      #expect(!harness.state.busy.backgroundHolding)
      #expect(!harness.state.busy.printHolding)
    }
  }
}
