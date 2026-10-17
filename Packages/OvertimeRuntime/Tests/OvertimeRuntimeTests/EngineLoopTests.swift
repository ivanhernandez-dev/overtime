import Foundation
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing
import os

struct EngineLoopTests {
  struct Harness {
    let temp: TempDirectory
    let paths: Paths
    let logger: FileLogger
    let clock = SystemClock()

    init() throws {
      temp = try TempDirectory()
      paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path], homeDirectory: "/Users/dev")
      try paths.createDirectories()
      logger = try FileLogger(decisionLog: paths.decisionLog(.shadow), errorLog: paths.errorLog(.shadow))
    }

    func engine(
      _ sources: EngineSources, sampleTimeoutSeconds: Double = Timing.systemCallTimeoutSeconds,
      settings: Settings = Settings()
    ) -> Engine {
      Engine(
        mode: .shadow,
        settings: settings,
        clock: clock,
        interpreter: RecordingInterpreter(logger: logger, timeZone: TimeZone(secondsFromGMT: 0)!),
        sources: sources,
        sampleTimeoutSeconds: sampleTimeoutSeconds
      )
    }

    func lines() -> [String] {
      guard let text = try? String(contentsOf: paths.decisionLog(.shadow), encoding: .utf8) else { return [] }
      return text.split(separator: "\n").map(String.init)
    }

    func waitForLine(containing needle: String, timeout: Double) async -> Bool {
      let deadline = ContinuousClock.now + .milliseconds(Int(timeout * 1000))
      while ContinuousClock.now < deadline {
        if lines().contains(where: { $0.contains(needle) }) { return true }
        try? await Task.sleep(for: .milliseconds(50))
      }
      return lines().contains { $0.contains(needle) }
    }

    func waitForLines(endingWith suffix: String, count: Int, timeout: Double) async -> Bool {
      let deadline = ContinuousClock.now + .milliseconds(Int(timeout * 1000))
      while ContinuousClock.now < deadline {
        if lines().filter({ $0.hasSuffix(suffix) }).count >= count { return true }
        try? await Task.sleep(for: .milliseconds(50))
      }
      return lines().filter { $0.hasSuffix(suffix) }.count >= count
    }
  }

  static let lineSeconds: Double = 10

  @Test func runLogsWantOffThenWantOnAfterAnActivityAndStopsWithAStopLine() async throws {
    let harness = try Harness()
    let (stream, continuation) = AsyncStream.makeStream(of: Event.self)
    let engine = harness.engine(
      EngineSources(
        transcriptSeed: { [] },
        sampleTick: { TickFacts() },
        transcriptStream: { stream }
      ))
    let running = Task { await engine.run() }
    #expect(await harness.waitForLine(containing: " WANT off reason=idle", timeout: Self.lineSeconds))
    let pushedAt = ContinuousClock.now
    continuation.yield(.transcriptActivity(TranscriptActivity(at: harness.clock.mono())))
    #expect(await harness.waitForLine(containing: " WANT on reason=busy", timeout: Self.lineSeconds))
    #expect(ContinuousClock.now - pushedAt < .seconds(Self.lineSeconds))
    let stoppedAt = ContinuousClock.now
    await engine.stop()
    await running.value
    #expect(ContinuousClock.now - stoppedAt < .seconds(Self.lineSeconds))
    let lines = harness.lines()
    let off = lines.firstIndex { $0.contains(" WANT off ") }
    let on = lines.firstIndex { $0.contains(" WANT on ") }
    let stop = lines.firstIndex { $0.hasSuffix(" STOP shadow") }
    #expect(off != nil && on != nil && stop != nil)
    if let off, let on, let stop {
      #expect(off < on && on < stop)
    }
    continuation.finish()
  }

  @Test func stopBeforeRunReturnsAtOnceWithAStopLine() async throws {
    let harness = try Harness()
    let engine = harness.engine(EngineSources(transcriptSeed: { [] }, sampleTick: { TickFacts() }))
    await engine.stop()
    await engine.run()
    #expect(harness.lines().filter { $0.hasSuffix(" STOP shadow") }.count == 1)
    #expect(harness.lines().filter { $0.contains(" WANT ") }.isEmpty)
  }

  @Test func hungSamplerFailsTowardReleaseAndLogsOncePerEpisode() async throws {
    let harness = try Harness()
    let busy = AgentSignals(busyProcessCount: 1, sessionCount: 1)
    let samples = OSAllocatedUnfairLock(initialState: 0)
    let engine = harness.engine(
      EngineSources(
        transcriptSeed: { [] },
        sampleTick: {
          samples.withLock { $0 += 1 }
          Thread.sleep(forTimeInterval: 3)
          return TickFacts(agents: busy)
        }
      ),
      sampleTimeoutSeconds: 0.2
    )
    let running = Task { await engine.run() }
    #expect(await harness.waitForLine(containing: " ERROR sampler timedOut", timeout: Self.lineSeconds))
    #expect(await OffPool.eventually(seconds: 30) { samples.withLock { $0 } >= 2 })
    await engine.stop()
    await running.value
    let lines = harness.lines()
    #expect(lines.filter { $0.hasSuffix(" ERROR sampler timedOut") }.count == 1)
    #expect(lines.contains { $0.hasSuffix(" WANT off reason=idle") })
    #expect(!lines.contains { $0.contains(" WANT on ") })
  }

  @Test func runOnceAppliesTheBatteryFloorBeforeTheFirstTick() async throws {
    let harness = try Harness()
    let recent = harness.clock.mono()
    let engine = harness.engine(
      EngineSources(
        transcriptSeed: { [TranscriptActivity(at: recent)] },
        sampleTick: { TickFacts() },
        powerRead: { .battery(percent: 5) }
      ))
    await engine.runOnce()
    let lines = harness.lines()
    #expect(lines.contains { $0.contains(" BATTERY block source=battery percent=5 ") })
    #expect(lines.filter { $0.contains(" WANT ") }.count == 1)
    #expect(lines.contains { $0.hasSuffix(" WANT off reason=battery") })
    #expect(!lines.contains { $0.contains(" WANT on ") })
  }

  @Test func unreadablePowerIsLoggedOncePerEpisodeAndKeepsTheBatteryState() async throws {
    let harness = try Harness()
    let (stream, continuation) = AsyncStream.makeStream(of: PowerReading?.self)
    let engine = harness.engine(
      EngineSources(
        transcriptSeed: { [] },
        sampleTick: { TickFacts() },
        powerRead: { .battery(percent: 8) },
        powerStream: { stream }
      ))
    let running = Task { await engine.run() }
    #expect(await harness.waitForLine(containing: " BATTERY block ", timeout: Self.lineSeconds))
    continuation.yield(nil)
    continuation.yield(nil)
    #expect(await harness.waitForLine(containing: " ERROR power unreadable", timeout: Self.lineSeconds))
    #expect(await engine.state.battery.blocked)
    continuation.yield(.ac(percent: 8))
    #expect(await harness.waitForLine(containing: " BATTERY unblock source=ac ", timeout: Self.lineSeconds))
    continuation.yield(nil)
    #expect(await harness.waitForLines(endingWith: " ERROR power unreadable", count: 2, timeout: Self.lineSeconds))
    await engine.stop()
    await running.value
    continuation.finish()
    #expect(harness.lines().filter { $0.hasSuffix(" ERROR power unreadable") }.count == 2)
  }
}
