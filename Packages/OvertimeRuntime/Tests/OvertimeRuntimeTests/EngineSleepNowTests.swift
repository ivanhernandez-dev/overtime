import Foundation
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing

struct EngineSleepNowTests {
  static let sleepCall = FakeToolPort.Call(executable: "/usr/bin/pmset", arguments: ["sleepnow"])

  struct Harness {
    let temp: TempDirectory
    let paths: Paths
    let clock = FakeClock()
    let tools = FakeToolPort()
    let recorder: HoldRecorder

    init() throws {
      temp = try TempDirectory()
      paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path], homeDirectory: temp.path)
      recorder = HoldRecorder(stateFile: paths.stateFile(.live))
    }

    func liveEngine() throws -> Engine {
      try Composition.makeLiveEngine(
        paths: paths,
        settings: Settings(transcriptRoots: [temp.path + "/projects"]),
        ports: LivePorts(
          assertions: FakeAssertionPort(), tools: tools, clamshell: FakeClamshellPort(recorder: recorder),
          stateFile: paths.stateFile(.live), makeSentinel: { [recorder] in FakeSentinelPort(recorder: recorder) }),
        environment: [:],
        homeDirectory: temp.path,
        once: true,
        clock: clock,
        externalDisplays: { 0 }
      )
    }

    func text(_ url: URL) -> String {
      (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    var decisionLog: String { text(paths.decisionLog(.live)) }
    var errorLog: String { text(paths.errorLog(.live)) }
  }

  static func poll(within seconds: Double = 5, _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
    while ContinuousClock.now < deadline {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
  }

  @Test func sleepNowRunsPmsetSleepnowOnceThroughTheToolPort() async throws {
    let harness = try Harness()
    let engine = try harness.liveEngine()
    await engine.step(.tick(TickFacts(fullWake: true)))
    let before = await engine.snapshot()
    let response = await engine.handle(.sleepNow)
    #expect(response.ok)
    #expect(await Self.poll { harness.tools.calls == [Self.sleepCall] })
    try? await Task.sleep(for: .milliseconds(100))
    #expect(harness.tools.calls == [Self.sleepCall])
    let after = await engine.snapshot()
    #expect(after.wanted == before.wanted)
    #expect(after.pause == before.pause)
    #expect(after.force == before.force)
    #expect(harness.decisionLog.contains(" COMMAND sleepNow"))
  }

  @Test func sleepNowWhileForcedKeepsTheForce() async throws {
    let harness = try Harness()
    let engine = try harness.liveEngine()
    await engine.step(.tick(TickFacts(fullWake: true)))
    _ = await engine.handle(.force(.indefinite))
    #expect(await Self.poll { await engine.snapshot().force == "indefinite" })
    let before = await engine.snapshot()
    _ = await engine.handle(.sleepNow)
    #expect(await Self.poll { harness.tools.calls.contains(Self.sleepCall) })
    let after = await engine.snapshot()
    #expect(after.wanted == true)
    #expect(after.force == before.force)
    #expect(after.pause == before.pause)
    #expect(harness.tools.calls.filter { $0 == Self.sleepCall }.count == 1)
  }

  @Test func aFailedSleepRequestIsLoggedInBothLogsAndChangesNothingElse() async throws {
    let harness = try Harness()
    harness.tools.setOutcome(.finished(exitCode: 1, stdout: "", stderr: "denied"))
    let engine = try harness.liveEngine()
    await engine.step(.tick(TickFacts(fullWake: true)))
    let before = await engine.snapshot()
    _ = await engine.handle(.sleepNow)
    #expect(await Self.poll { harness.errorLog.contains(" ERROR pmset failed command=sleepnow") })
    #expect(harness.decisionLog.contains(" ERROR pmset failed command=sleepnow"))
    let after = await engine.snapshot()
    #expect(after.wanted == before.wanted)
    #expect(after.pause == before.pause)
    #expect(after.force == before.force)
  }
}
