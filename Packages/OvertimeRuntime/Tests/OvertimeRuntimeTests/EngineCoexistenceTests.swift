import Foundation
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing
import os

struct EngineCoexistenceTests {
  static let foreign = ForeignAssertion(pid: 4242, type: "PreventUserIdleSystemSleep", processName: "Keeper")

  struct Harness {
    let temp: TempDirectory
    let paths: Paths
    let clock = FakeClock()
    let port = FakeAssertionPort()
    let recorder: HoldRecorder
    let samples = OSAllocatedUnfairLock(initialState: 0)
    let engine: Engine

    init() throws {
      temp = try TempDirectory()
      paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path], homeDirectory: temp.path)
      try paths.createDirectories()
      recorder = HoldRecorder(stateFile: paths.stateFile(.live))
      port.seedForeign([EngineCoexistenceTests.foreign])
      let logger = try FileLogger(decisionLog: paths.decisionLog(.live), errorLog: paths.errorLog(.live))
      let ports = LivePorts(
        assertions: port, tools: NoTools(), clamshell: FakeClamshellPort(recorder: recorder),
        stateFile: paths.stateFile(.live), makeSentinel: { [recorder] in FakeSentinelPort(recorder: recorder) })
      let sentinel = FakeSentinelPort(recorder: recorder)
      try sentinel.start()
      let interpreter = LiveInterpreter(
        ports: ports, logger: logger, sentinel: sentinel, timeZone: TimeZone(secondsFromGMT: 0)!)
      let port = port
      let samples = samples
      engine = Engine(
        mode: .live,
        settings: Settings(transcriptRoots: [temp.path + "/projects"]),
        clock: clock,
        interpreter: interpreter,
        sources: EngineSources(
          transcriptSeed: { [] },
          sampleTick: { TickFacts(fullWake: true) },
          coexistence: {
            samples.withLock { $0 += 1 }
            return CoexistenceFacts(
              amphetamineRunning: true, sleepDisabled: false, foreignAssertions: port.foreignTable)
          }
        )
      )
    }

    var sampleCount: Int {
      samples.withLock { $0 }
    }

    func lines() -> [String] {
      guard let text = try? String(contentsOf: paths.decisionLog(.live), encoding: .utf8) else { return [] }
      return text.split(separator: "\n").map(String.init)
    }

    func advancedTick(_ seconds: Double) async {
      clock.advance(seconds: seconds)
      await engine.tick()
    }
  }

  @Test func runOnceSamplesCoexistenceWhenTheSeedMakesItWanted() async throws {
    let temp = try TempDirectory()
    let paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path], homeDirectory: temp.path)
    try paths.createDirectories()
    let logger = try FileLogger(decisionLog: paths.decisionLog(.shadow), errorLog: paths.errorLog(.shadow))
    let clock = FakeClock()
    let engine = Engine(
      mode: .shadow,
      settings: Settings(transcriptRoots: [temp.path + "/projects"]),
      clock: clock,
      interpreter: RecordingInterpreter(logger: logger, timeZone: TimeZone(secondsFromGMT: 0)!),
      sources: EngineSources(
        transcriptSeed: { [TranscriptActivity(at: clock.mono())] },
        sampleTick: { TickFacts() },
        coexistence: { CoexistenceFacts(sleepDisabled: true) }
      )
    )
    await engine.runOnce()
    let text = try String(contentsOf: paths.decisionLog(.shadow), encoding: .utf8)
    #expect(text.contains(" WARN coexistence amphetamine=false sleepDisabled=true foreign=0 names=none"))
  }

  @Test func scenarios21And22LeaveTheForeignEntryUntouchedAndActOnlyOnTheOwnHold() async throws {
    let harness = try Harness()
    await harness.engine.step(.tick(TickFacts(fullWake: true)))
    #expect(await harness.engine.state.want.wanted == false)
    await harness.engine.tick()
    #expect(harness.sampleCount == 0)
    await harness.engine.step(.transcriptActivity(TranscriptActivity(at: harness.clock.mono())))
    #expect(await harness.engine.state.hold.lidClose == .held)
    await harness.advancedTick(2)
    #expect(harness.sampleCount == 1)
    await harness.advancedTick(2)
    #expect(harness.sampleCount == 1)
    await harness.advancedTick(30)
    #expect(harness.sampleCount == 2)
    let warnings = harness.lines().filter { $0.contains(" WARN coexistence") }
    #expect(warnings.count == 1)
    #expect(
      warnings.first?.hasSuffix(" WARN coexistence amphetamine=true sleepDisabled=false foreign=0 names=none") == true)

    await harness.advancedTick(200)
    #expect(await harness.engine.state.want.wanted == false)
    #expect(await harness.engine.state.hold.lidClose == .released)
    #expect(await harness.engine.state.hold.idle == .released)
    let afterRelease = harness.sampleCount
    await harness.advancedTick(30)
    #expect(harness.sampleCount == afterRelease)

    #expect(harness.port.foreignTable == [Self.foreign])
    #expect(harness.port.calls.first == .acquireOrRenew(.preventUserIdleSystemSleep, 300))
    #expect(harness.port.calls.last == .release(.preventUserIdleSystemSleep))
    #expect(
      harness.port.calls.allSatisfy { call in
        switch call {
        case .acquireOrRenew(let kind, _), .release(let kind):
          kind == .preventUserIdleSystemSleep || kind == .preventUserIdleDisplaySleep
        }
      })
    let clamshell = harness.recorder.all.compactMap { entry -> Bool? in
      if case .clamshell(let on, _) = entry { return on }
      return nil
    }
    #expect(clamshell.first == true)
    #expect(clamshell.last == false)
    let lines = harness.lines()
    #expect(lines.filter { $0.contains(" WARN coexistence") }.count == 1)
    #expect(!lines.contains { $0.contains("coexistence cleared") })
    #expect(!lines.contains { $0.contains("4242") })
  }
}
