import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing

struct EngineLearnedRootsTests {
  static let home = "/tmp/ot-sr6-home/.claude/projects"
  static let configA = "/tmp/ot-sr6-config-a"
  static let projectsA = "/tmp/ot-sr6-config-a/projects"
  static let configured = "/tmp/ot-sr6-configured"
  static let boundSeconds: Double = 10
  static let quietMilliseconds = 300

  struct Harness {
    let temp: TempDirectory
    let paths: Paths
    let logger: FileLogger
    let clock = FakeClock()
    let transcripts = FakeTranscripts()

    init() throws {
      temp = try TempDirectory()
      paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path], homeDirectory: temp.path)
      try paths.createDirectories()
      logger = try FileLogger(decisionLog: paths.decisionLog(.shadow), errorLog: paths.errorLog(.shadow))
    }

    func engine(
      settings: Settings = Settings(), rebuilds: Bool = true,
      sampleTimeoutSeconds: Double = Timing.systemCallTimeoutSeconds
    ) -> Engine {
      let transcripts = transcripts
      var rebuild: (@Sendable ([TranscriptRoot]) -> TranscriptSource)?
      if rebuilds {
        rebuild = { transcripts.source(for: $0) }
      }
      let resolve: @Sendable (Settings) -> [TranscriptRoot] = { settings in
        settings.transcriptRoots.map { roots in roots.map { TranscriptRoot(path: $0, origin: .configured) } }
          ?? [TranscriptRoot(path: EngineLearnedRootsTests.home, origin: .inferred)]
      }
      return Engine(
        mode: .shadow,
        settings: settings,
        clock: clock,
        interpreter: RecordingInterpreter(logger: logger, timeZone: TimeZone(secondsFromGMT: 0)!),
        sources: EngineSources(
          transcriptSeed: { [] },
          sampleTick: { TickFacts() },
          transcriptStream: { transcripts.stream(0) },
          rebuildTranscripts: rebuild,
          resolveRoots: resolve
        ),
        sampleTimeoutSeconds: sampleTimeoutSeconds
      )
    }

    func tick(_ engine: Engine, _ directories: [String]) async {
      await engine.step(.tick(TickFacts(agents: AgentSignals(claudeConfigDirectories: directories))))
    }

    func tick(_ engine: Engine, _ directories: [String], until condition: () async -> Bool) async -> Bool {
      await waitUntil {
        await tick(engine, directories)
        return await condition()
      }
    }

    func lines() -> [String] {
      guard let text = try? String(contentsOf: paths.decisionLog(.shadow), encoding: .utf8) else { return [] }
      return text.split(separator: "\n").map(String.init)
    }

    func count(endingWith suffix: String) -> Int {
      lines().filter { $0.hasSuffix(suffix) }.count
    }

    func waitUntil(timeout: Double = 5, _ condition: () async -> Bool) async -> Bool {
      let deadline = ContinuousClock.now + .milliseconds(Int(timeout * 1000))
      while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
      }
      return await condition()
    }

    func quietly() async {
      try? await Task.sleep(for: .milliseconds(EngineLearnedRootsTests.quietMilliseconds))
    }

    func finish(_ engine: Engine) async -> Bool {
      await Engine.bounded(seconds: EngineLearnedRootsTests.boundSeconds) { await engine.stop() }
    }
  }

  static let learnedA = " CHECK transcriptRoot learned root=" + projectsA
  static let forgottenA = " CHECK transcriptRoot forgotten root=" + projectsA
  static let absentA = " CHECK transcriptRoot absent root=" + projectsA

  @Test func aRunningSessionsConfigFolderIsWatchedAtOnce() async throws {
    let harness = try Harness()
    let engine = harness.engine()
    await harness.tick(engine, [Self.configA])
    #expect(await harness.waitUntil { harness.transcripts.log.contains("stream1") })
    #expect(harness.transcripts.builds == [[Self.home, Self.projectsA]])
    #expect(await harness.waitUntil { harness.count(endingWith: Self.learnedA) == 1 })
    harness.clock.advance(seconds: 2)
    await harness.tick(engine, [Self.configA])
    harness.clock.advance(seconds: 2)
    await harness.tick(engine, [Self.configA])
    await harness.quietly()
    #expect(harness.transcripts.builds.count == 1)
    #expect(harness.count(endingWith: Self.learnedA) == 1)
    #expect(await harness.finish(engine))
  }

  @Test func theLearnedFolderIsDroppedOnlyAfterTheLinger() async throws {
    let harness = try Harness()
    let engine = harness.engine()
    await harness.tick(engine, [Self.configA])
    #expect(await harness.waitUntil { harness.transcripts.log.contains("stream1") })
    harness.clock.advance(seconds: Timing.learnedRootLingerSeconds - 1)
    await harness.tick(engine, [])
    await harness.quietly()
    #expect(harness.transcripts.builds.count == 1)
    #expect(harness.count(endingWith: Self.forgottenA) == 0)
    harness.clock.advance(seconds: 1)
    #expect(await harness.tick(engine, []) { harness.transcripts.builds.count == 2 })
    #expect(harness.transcripts.builds.last == [Self.home])
    #expect(await harness.waitUntil { harness.count(endingWith: Self.forgottenA) == 1 })
    #expect(await harness.waitUntil { harness.transcripts.log.contains("stream2") })
    #expect(await harness.tick(engine, [Self.configA]) { harness.transcripts.builds.count == 3 })
    #expect(harness.transcripts.builds.last == [Self.home, Self.projectsA])
    #expect(harness.count(endingWith: Self.forgottenA) == 1)
    #expect(await harness.finish(engine))
  }

  @Test func learnedFoldersAreAddedToConfiguredOnes() async throws {
    let harness = try Harness()
    let engine = harness.engine(settings: Settings(transcriptRoots: [Self.configured]))
    await harness.tick(engine, [Self.configA])
    #expect(await harness.waitUntil { harness.transcripts.log.contains("stream1") })
    #expect(harness.transcripts.builds == [[Self.configured, Self.projectsA]])
    #expect(await harness.finish(engine))
  }

  @Test func aLearnedFolderWhoseRebuildTimesOutIsReportedAndLeftToTheRetry() async throws {
    let harness = try Harness()
    harness.transcripts.holdBuilds()
    defer { harness.transcripts.releaseBuilds() }
    let engine = harness.engine(sampleTimeoutSeconds: 1)
    await harness.tick(engine, [Self.configA])
    #expect(
      await harness.waitUntil {
        harness.lines().contains { $0.contains(" ERROR settings roots notRebuilt reason=timedOut retryIn=10") }
      })
    #expect(await harness.waitUntil { await engine.state.health.rootIssues[Self.projectsA] == .unreadable })
    #expect(await harness.finish(engine))
  }

  @Test func anEngineThatCannotRebuildLearnsNothing() async throws {
    let harness = try Harness()
    let engine = harness.engine(rebuilds: false)
    await harness.tick(engine, [Self.configA])
    await harness.quietly()
    #expect(!harness.lines().contains { $0.contains(" CHECK transcriptRoot ") })
    #expect(harness.transcripts.builds.isEmpty)
    #expect(await harness.finish(engine))
  }

  @Test func aForgottenFolderThatIsLearnedAgainWhileMissingIsLoggedAbsentAgain() async throws {
    let harness = try Harness()
    let engine = harness.engine()
    await harness.tick(engine, [Self.configA])
    #expect(await harness.waitUntil { harness.count(endingWith: Self.absentA) == 1 })
    harness.clock.advance(seconds: Timing.learnedRootLingerSeconds)
    #expect(await harness.tick(engine, []) { harness.transcripts.builds.count == 2 })
    #expect(await harness.waitUntil { harness.transcripts.log.contains("health2") })
    #expect(await harness.tick(engine, [Self.configA]) { harness.transcripts.builds.count == 3 })
    #expect(await harness.waitUntil { harness.count(endingWith: Self.absentA) == 2 })
    #expect(await harness.finish(engine))
  }
}
