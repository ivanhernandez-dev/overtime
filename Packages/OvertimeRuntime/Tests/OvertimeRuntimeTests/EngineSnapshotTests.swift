import Foundation
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing
import os

struct EngineSnapshotTests {
  struct Harness {
    let temp: TempDirectory
    let logger: FileLogger
    let clock = FakeClock()

    init() throws {
      temp = try TempDirectory()
      let paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path], homeDirectory: "/Users/dev")
      try paths.createDirectories()
      logger = try FileLogger(decisionLog: paths.decisionLog(.shadow), errorLog: paths.errorLog(.shadow))
    }

    func engine(sources: EngineSources? = nil) -> Engine {
      Engine(
        mode: .shadow,
        settings: Settings(),
        clock: clock,
        interpreter: RecordingInterpreter(logger: logger, timeZone: TimeZone(secondsFromGMT: 0)!),
        sources: sources ?? EngineSources(transcriptSeed: { [] }, sampleTick: { TickFacts(agents: .none) })
      )
    }
  }

  @Test func theFirstElementIsTheCurrentSnapshot() async throws {
    let harness = try Harness()
    let engine = harness.engine()
    var iterator = await engine.snapshots().makeAsyncIterator()
    let first = await iterator.next()
    #expect(first?.wanted == nil)
    #expect(first?.reason == nil)
    #expect(first?.mode == .shadow)
  }

  @Test func aTickPublishesIdle() async throws {
    let harness = try Harness()
    let engine = harness.engine()
    var iterator = await engine.snapshots().makeAsyncIterator()
    _ = await iterator.next()
    await engine.tick()
    let idle = await iterator.next()
    #expect(idle?.wanted == false)
    #expect(idle?.reason == "idle")
  }

  @Test func aForceIsPublishedBeforeHandleReturns() async throws {
    let harness = try Harness()
    let engine = harness.engine()
    var iterator = await engine.snapshots().makeAsyncIterator()
    _ = await iterator.next()
    await engine.tick()
    _ = await iterator.next()
    _ = await engine.handle(.force(.indefinite))
    let forced = await iterator.next()
    #expect(forced?.force == .indefinite)
    #expect(forced?.wanted == true)
    #expect(forced?.reason == "forced")
  }

  @Test func identicalTicksPublishOnce() async throws {
    let harness = try Harness()
    let engine = harness.engine()
    let stream = await engine.snapshots()
    var iterator = stream.makeAsyncIterator()
    _ = await iterator.next()
    await engine.tick()
    let idle = await iterator.next()
    #expect(idle?.reason == "idle")
    await engine.tick()
    _ = await engine.snapshots()
    let after = await iterator.next()
    #expect(after == nil)
  }

  @Test func anUnreadStreamYieldsTheNewestStateFirst() async throws {
    let harness = try Harness()
    let engine = harness.engine()
    var iterator = await engine.snapshots().makeAsyncIterator()
    _ = await iterator.next()
    await engine.tick()
    for index in 0..<20 {
      if index.isMultiple(of: 2) {
        _ = await engine.handle(.force(.forSeconds(Double(60 + index))))
      } else {
        _ = await engine.handle(.pause(.forSeconds(Double(60 + index))))
      }
    }
    let expected = await engine.currentSnapshot()
    let latest = await iterator.next()
    #expect(latest == expected)
    #expect(latest?.pause != nil)
    #expect(latest?.force == nil)
  }

  @Test func aSecondSubscriptionFinishesTheFirst() async throws {
    let harness = try Harness()
    let engine = harness.engine()
    var first = await engine.snapshots().makeAsyncIterator()
    _ = await first.next()
    var second = await engine.snapshots().makeAsyncIterator()
    #expect(await first.next() == nil)
    #expect(await second.next() != nil)
    await engine.tick()
    #expect(await second.next()?.reason == "idle")
  }

  @Test func sessionsFromTheSamplerArePublishedInOrderAfterTheNextTick() async throws {
    let harness = try Harness()
    let older = SessionSummary(pid: 40, cwd: "/Users/dev/a", ttyName: "ttys001", startMono: Instant(nanoseconds: 5))
    let newer = SessionSummary(pid: 41, cwd: "/Users/dev/b", ttyName: "ttys002", startMono: Instant(nanoseconds: 9))
    let latest = OSAllocatedUnfairLock<[SessionSummary]>(initialState: [])
    let engine = harness.engine(
      sources: EngineSources(
        transcriptSeed: { [] },
        sampleTick: {
          latest.withLock { $0 = [older, newer] }
          return TickFacts(agents: .none)
        },
        sessions: { latest.withLock { $0 } }))
    var iterator = await engine.snapshots().makeAsyncIterator()
    #expect(await iterator.next()?.sessions == [])
    await engine.tick()
    #expect(await iterator.next()?.sessions == [older, newer])
  }

  @Test func withoutASessionsSourceTheListIsEmpty() async throws {
    let harness = try Harness()
    let engine = harness.engine()
    await engine.tick()
    #expect(await engine.currentSnapshot().sessions.isEmpty)
  }

  @Test func aForceCarriesWantedSince() async throws {
    let harness = try Harness()
    let engine = harness.engine()
    await engine.tick()
    harness.clock.advance(seconds: 5)
    let forcedAt = harness.clock.mono()
    _ = await engine.handle(.force(.indefinite))
    #expect(await engine.currentSnapshot().wantedSince == forcedAt)
  }

  @Test func theGraceDeadlineIsLastBusyPlusTheReleaseGrace() async throws {
    let harness = try Harness()
    let engine = harness.engine()
    await engine.tick()
    await engine.step(.transcriptActivity(TranscriptActivity(at: harness.clock.mono())))
    harness.clock.advance(seconds: 100)
    await engine.tick()
    let lastBusy = harness.clock.mono()
    var busy = await engine.currentSnapshot()
    #expect(busy.busy == true)
    #expect(busy.graceDeadline == nil)
    harness.clock.advance(seconds: 30)
    await engine.tick()
    busy = await engine.currentSnapshot()
    #expect(busy.busy == false)
    #expect(busy.reason == "busy")
    #expect(busy.graceDeadline == lastBusy.adding(seconds: Settings().releaseGraceSeconds))
    harness.clock.advance(seconds: 120)
    await engine.tick()
    let idle = await engine.currentSnapshot()
    #expect(idle.reason == "idle")
    #expect(idle.graceDeadline == nil)
  }

  @Test func theSnapshotCarriesTheBatteryPercentagesFromSettings() async throws {
    let harness = try Harness()
    let engine = Engine(
      mode: .shadow,
      settings: Settings(batteryLowPercent: 15, batteryResumePercent: 35),
      clock: harness.clock,
      interpreter: RecordingInterpreter(logger: harness.logger, timeZone: TimeZone(secondsFromGMT: 0)!),
      sources: EngineSources(transcriptSeed: { [] }, sampleTick: { TickFacts(agents: .none) }))
    let snapshot = await engine.currentSnapshot()
    #expect(snapshot.batteryLowPercent == 15)
    #expect(snapshot.batteryResumePercent == 35)
  }

  static let foreign = [
    ForeignAssertion(pid: 9, type: "PreventUserIdleSystemSleep", processName: "Lungo"),
    ForeignAssertion(pid: 10, type: "PreventSystemSleep", processName: "Lungo"),
    ForeignAssertion(pid: 11, type: "PreventUserIdleSystemSleep", processName: "Caffeine"),
  ]

  @Test func theSnapshotCarriesPowerCoexistenceAndDisplays() async throws {
    let harness = try Harness()
    let engine = harness.engine(
      sources: EngineSources(
        transcriptSeed: { [] },
        sampleTick: { TickFacts(agents: .none, lidClosed: true, externalDisplays: 1) },
        coexistence: { CoexistenceFacts(amphetamineRunning: true, foreignAssertions: Self.foreign) }))
    _ = await engine.handle(.force(.indefinite))
    await engine.tick()
    await engine.stepPower(.battery(percent: 72))
    let snapshot = await engine.currentSnapshot()
    #expect(snapshot.power == .battery(percent: 72))
    #expect(snapshot.coexistenceWarned)
    #expect(snapshot.amphetamineRunning)
    #expect(snapshot.otherTools == ["Caffeine", "Lungo"])
    #expect(snapshot.externalDisplays == 1)
    #expect(snapshot.lidClosed == true)
  }

  @Test func anUnreadablePowerReadingKeepsTheLastOne() async throws {
    let harness = try Harness()
    let engine = harness.engine()
    await engine.stepPower(.ac(percent: 80))
    await engine.stepPower(nil)
    #expect(await engine.currentSnapshot().power == .ac(percent: 80))
  }

  @Test func otherToolsAreHiddenUntilTheEpisodeIsWarned() async throws {
    let harness = try Harness()
    let engine = harness.engine(
      sources: EngineSources(
        transcriptSeed: { [] },
        sampleTick: { TickFacts(agents: .none) },
        coexistence: { CoexistenceFacts(foreignAssertions: Self.foreign) }))
    _ = await engine.handle(.force(.indefinite))
    await engine.tick()
    let snapshot = await engine.currentSnapshot()
    #expect(!snapshot.coexistenceWarned)
    #expect(!snapshot.amphetamineRunning)
    #expect(snapshot.otherTools.isEmpty)
  }

  @Test func toolNamesDropControlCharactersAndAreCapped() {
    let long = String(repeating: "x", count: 40)
    let names = EngineSnapshot.toolNames([
      ForeignAssertion(pid: 1, type: "t", processName: "Evil\u{07}Tool"),
      ForeignAssertion(pid: 2, type: "t", processName: long),
      ForeignAssertion(pid: 3, type: "t", processName: "  "),
      ForeignAssertion(pid: 4, type: "t", processName: nil),
    ])
    #expect(names == ["EvilTool", String(repeating: "x", count: EngineSnapshot.maxToolNameLength)])
  }

  @Test func aKnownStarterIsNamedAfterTheProcess() {
    #expect(
      EngineSnapshot.toolNames([
        ForeignAssertion(pid: 1, type: "t", processName: "caffeinate", parentName: "python3")
      ]) == ["caffeinate (started by python3)"])
  }

  @Test func theStarterIsSanitizedAndCappedLikeTheProcessName() {
    let names = EngineSnapshot.toolNames([
      ForeignAssertion(pid: 1, type: "t", processName: "caffeinate", parentName: "py\u{07}thon3"),
      ForeignAssertion(pid: 2, type: "t", processName: "caffeinate", parentName: String(repeating: "y", count: 40)),
      ForeignAssertion(pid: 3, type: "t", processName: "caffeinate", parentName: "  "),
      ForeignAssertion(pid: 4, type: "t", processName: "caffeinate", parentName: nil),
    ])
    #expect(
      names == [
        "caffeinate", "caffeinate (started by python3)",
        "caffeinate (started by " + String(repeating: "y", count: 32) + ")",
      ])
  }

  @Test func theSnapshotCarriesTheEventCountersAndBusyEndedAt() {
    var state = AppState(mode: .live)
    state.events.holdErrorEpisodes = 3
    state.events.holdErrorsWhileBusy = 2
    state.events.forceSince = Instant(nanoseconds: 7)
    state.events.busyEndedAt = Instant(nanoseconds: 4)
    state.want.lastBusy = Instant(nanoseconds: 5)
    let snapshot = EngineSnapshot(state: state)
    #expect(snapshot.events == state.events)
    #expect(snapshot.busyEndedAt == Instant(nanoseconds: 4))
    #expect(EngineSnapshot().events == EventCounters())
    #expect(EngineSnapshot().busyEndedAt == nil)
  }

  @Test func detectionWarningsSortEveryRootByPath() {
    let paths = (0..<12).map { "/Users/dev/root-\(String(format: "%02d", $0))" }
    var state = AppState(mode: .live)
    for (index, path) in paths.reversed().enumerated() {
      state.health.rootIssues[path] = index.isMultiple(of: 2) ? .missing : .unreadable
    }
    let listed = EngineSnapshot(state: state).detectionWarnings.compactMap(\.path)
    #expect(listed == paths)
  }

  @Test func detectionWarningsListRootsSortedByPathThenTerminalSilence() {
    var state = AppState(mode: .live)
    state.health.rootIssues = [
      "/Volumes/Work/projects": .unreadable,
      "/Users/dev/.claude/projects": .missing,
      "/Users/dev/other": .unreadable,
    ]
    state.health.silenceWarned = true
    #expect(
      EngineSnapshot(state: state).detectionWarnings == [
        .rootMissing("/Users/dev/.claude/projects"),
        .rootUnreadable("/Users/dev/other"),
        .rootUnreadable("/Volumes/Work/projects"),
        .terminalSilence,
      ])
    #expect(EngineSnapshot(state: AppState(mode: .live)).detectionWarnings.isEmpty)
    #expect(EngineSnapshot().detectionWarnings.isEmpty)
    #expect(DetectionWarning.rootMissing("/a").path == "/a")
    #expect(DetectionWarning.terminalSilence.path == nil)
  }

  @Test func aMissingRootReportReachesThePublishedSnapshotAndClearsOnRecovery() async throws {
    let harness = try Harness()
    let engine = harness.engine()
    let recorder = SnapshotRecorder(await engine.snapshots())
    defer { recorder.cancel() }
    #expect(await recorder.wait { !$0.isEmpty })
    let root = "/Users/dev/.claude/projects"
    await engine.step(.transcriptRoots([RootHealth(path: root, status: .missing)]))
    #expect(await recorder.wait { $0.last?.detectionWarnings == [.rootMissing(root)] })
    await engine.step(.transcriptRoots([RootHealth(path: root, status: .unreadable)]))
    #expect(await recorder.wait { $0.last?.detectionWarnings == [.rootUnreadable(root)] })
    await engine.step(.transcriptRoots([RootHealth(path: root, status: .ok)]))
    #expect(await recorder.wait { $0.last?.detectionWarnings == [] })
    #expect(await engine.currentSnapshot().detectionWarnings.isEmpty)
  }

  @Test func aChangedCounterPublishesANewSnapshot() async throws {
    let harness = try Harness()
    let engine = harness.engine()
    let recorder = SnapshotRecorder(await engine.snapshots())
    defer { recorder.cancel() }
    #expect(await recorder.wait { !$0.isEmpty })
    await engine.tick()
    await engine.step(.transcriptActivity(TranscriptActivity(at: harness.clock.mono())))
    await engine.tick()
    #expect(await recorder.wait { $0.last?.wanted == true && $0.last?.busy == true })
    let before = recorder.snapshots.count
    await engine.step(.systemWillSleep)
    #expect(await recorder.wait { $0.last?.events.unexpectedSleeps == 1 })
    #expect(recorder.snapshots.count == before + 1)
    let published = recorder.snapshots.last
    #expect(published?.wanted == true)
    #expect(published?.reason == "busy")
  }

  @Test func theSnapshotNetworkFollowsTheStateNetwork() {
    var state = AppState(mode: .live)
    #expect(EngineSnapshot(state: state).network == nil)
    state.network.facts = NetworkFacts(wifiInterface: "en0", onHotspot: true, wired: false, wifiPowered: true)
    let settings = Settings(hotspot: "Test iPhone")
    #expect(
      EngineSnapshot(state: state, settings: settings).network
        == NetworkSummary(
          wired: false, wifiFound: true, onHotspot: true, switched: false, readiness: .armed(.configured),
          phase: .idle))
    state.persisted.switchedToHotspot = true
    #expect(EngineSnapshot(state: state, settings: settings).network?.switched == true)
    #expect(EngineSnapshot().network == nil)
  }

  @Test func unchangedNetworkFactsPublishNoNewSnapshotAndAHotspotChangePublishesOne() async throws {
    let harness = try Harness()
    let facts = OSAllocatedUnfairLock(
      initialState: NetworkFacts(wifiInterface: "en0", onHotspot: false, wired: false, wifiPowered: true))
    let engine = harness.engine(
      sources: EngineSources(
        transcriptSeed: { [] },
        sampleTick: { TickFacts(agents: .none, network: facts.withLock { $0 }) }))
    let recorder = SnapshotRecorder(await engine.snapshots())
    defer { recorder.cancel() }
    #expect(await recorder.wait { !$0.isEmpty })
    await engine.tick()
    #expect(await recorder.wait { $0.last?.network?.onHotspot == false && $0.last?.reason == "idle" })
    let before = recorder.snapshots.count
    let held = await engine.currentSnapshot()
    for _ in 0..<10 {
      harness.clock.advance(seconds: 2)
      await engine.tick()
      #expect(await engine.currentSnapshot() == held)
    }
    facts.withLock { $0.onHotspot = true }
    await engine.tick()
    #expect(await recorder.wait { $0.last?.network?.onHotspot == true })
    #expect(recorder.snapshots.count == before + 1)
  }

  @Test func consecutiveBusyTicksPublishNoNewSnapshot() async throws {
    let harness = try Harness()
    let engine = harness.engine()
    let recorder = SnapshotRecorder(await engine.snapshots())
    defer { recorder.cancel() }
    #expect(await recorder.wait { !$0.isEmpty })
    await engine.tick()
    await engine.step(.transcriptActivity(TranscriptActivity(at: harness.clock.mono())))
    await engine.tick()
    #expect(await recorder.wait { $0.last?.wanted == true && $0.last?.busy == true })
    let before = recorder.snapshots.count
    let held = await engine.currentSnapshot()
    #expect(held.busy == true)
    for _ in 0..<10 {
      harness.clock.advance(seconds: 2)
      await engine.tick()
      #expect(await engine.currentSnapshot() == held)
    }
    await engine.step(.systemWillSleep)
    #expect(await recorder.wait { $0.last?.events.unexpectedSleeps == 1 })
    #expect(recorder.snapshots.count == before + 1)
    #expect(recorder.snapshots.last?.busyEndedAt == nil)
  }

  @Test func aWorkingSessionIsPublishedOnceAcrossBusyTicks() async throws {
    let harness = try Harness()
    let reader = SessionReader(readDirectory: { _ in "/Users/dev/alpha" }, readTerminal: { _ in "ttys009" })
    let records = [
      ProcessRecord(
        pid: 40, ppid: 1, uid: getuid(), comm: "claude", ttyDevice: 0x1000_0009,
        startMono: Instant(nanoseconds: 5_000_000_000), argv0: "claude"),
      ProcessRecord(pid: 41, ppid: 40, uid: getuid(), comm: "caffeinate", argv0: "caffeinate"),
    ]
    let clock = harness.clock
    let latest = OSAllocatedUnfairLock<[SessionSummary]>(initialState: [])
    let engine = harness.engine(
      sources: EngineSources(
        transcriptSeed: { [] },
        sampleTick: {
          let sessions = reader.sessions(from: records, at: clock.mono())
          latest.withLock { $0 = sessions }
          return TickFacts(agents: .none)
        },
        sessions: { latest.withLock { $0 } }))
    let recorder = SnapshotRecorder(await engine.snapshots())
    defer { recorder.cancel() }
    #expect(await recorder.wait { !$0.isEmpty })
    let firstTick = clock.mono()
    await engine.tick()
    let published = await engine.currentSnapshot()
    #expect(published.sessions.first?.workingSince == firstTick)
    #expect(await recorder.wait { $0.last == published })
    let before = recorder.snapshots.count
    for _ in 0..<10 {
      clock.advance(seconds: 2)
      await engine.tick()
      #expect(await engine.currentSnapshot() == published)
    }
    _ = await engine.handle(.force(.indefinite))
    #expect(await recorder.wait { $0.last?.force == .indefinite })
    #expect(recorder.snapshots.dropFirst(before).allSatisfy { $0.force == .indefinite })
  }

  @Test func aWaitingSessionIsPublishedOnceAcrossTicks() async throws {
    let harness = try Harness()
    let reader = SessionReader(readDirectory: { _ in "/Users/dev/alpha" }, readTerminal: { _ in "ttys009" })
    let records = [
      ProcessRecord(
        pid: 40, ppid: 1, uid: getuid(), comm: "claude", ttyDevice: 0x1000_0009,
        startMono: Instant(nanoseconds: 5_000_000_000), argv0: "claude")
    ]
    let work = LongRunningWork(waitingSessionPIDs: [40])
    let clock = harness.clock
    let latest = OSAllocatedUnfairLock<[SessionSummary]>(initialState: [])
    let engine = harness.engine(
      sources: EngineSources(
        transcriptSeed: { [] },
        sampleTick: {
          let sessions = reader.sessions(from: records, at: clock.mono(), work: work)
          latest.withLock { $0 = sessions }
          return TickFacts(agents: .none)
        },
        sessions: { latest.withLock { $0 } }))
    let recorder = SnapshotRecorder(await engine.snapshots())
    defer { recorder.cancel() }
    #expect(await recorder.wait { !$0.isEmpty })
    let firstTick = clock.mono()
    await engine.tick()
    let published = await engine.currentSnapshot()
    #expect(published.sessions.first?.waitingSince == firstTick)
    #expect(await recorder.wait { $0.last == published })
    let before = recorder.snapshots.count
    for _ in 0..<9 {
      clock.advance(seconds: 2)
      await engine.tick()
      #expect(await engine.currentSnapshot() == published)
    }
    _ = await engine.handle(.force(.indefinite))
    #expect(await recorder.wait { $0.last?.force == .indefinite })
    #expect(recorder.snapshots.dropFirst(before).allSatisfy { $0.force == .indefinite })
    #expect(recorder.snapshots.filter { $0.sessions.first?.isWaiting == true }.count >= 1)
  }

  @Test func theSnapshotCarriesTheLongRunningSettingsAndHolding() {
    var state = AppState(mode: .shadow)
    let quiet = EngineSnapshot(state: state, settings: Settings())
    #expect(quiet.backgroundCommandsKeepAwake)
    #expect(quiet.printRunsKeepAwake)
    #expect(quiet.longRunningLimitMinutes == nil)
    #expect(!quiet.backgroundCommandsHolding)
    #expect(!quiet.printRunsHolding)
    state.busy.backgroundHolding = true
    state.busy.printHolding = true
    let settings = Settings(
      backgroundCommandsKeepAwake: false, printRunsKeepAwake: false, longRunningLimitEnabled: true,
      longRunningLimitMinutes: 120)
    let holding = EngineSnapshot(state: state, settings: settings)
    #expect(!holding.backgroundCommandsKeepAwake)
    #expect(!holding.printRunsKeepAwake)
    #expect(holding.longRunningLimitMinutes == 120)
    #expect(holding.backgroundCommandsHolding)
    #expect(holding.printRunsHolding)
  }
}
