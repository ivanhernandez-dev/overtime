import Darwin
import Foundation
import OvertimeClamshell
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing
import os

final class SentinelFactory: Sendable {
  let recorder: HoldRecorder
  let first: FakeSentinelPort
  private let made = OSAllocatedUnfairLock<[FakeSentinelPort]>(initialState: [])

  init(recorder: HoldRecorder) {
    self.recorder = recorder
    first = FakeSentinelPort(recorder: recorder)
  }

  var count: Int {
    made.withLock { $0.count }
  }

  var latest: FakeSentinelPort? {
    made.withLock { $0.last }
  }

  private let refuseLater = OSAllocatedUnfairLock(initialState: false)
  private let queued = OSAllocatedUnfairLock<FakeSentinelPort?>(initialState: nil)

  var nextPort: FakeSentinelPort? {
    get { queued.withLock { $0 } }
    set { queued.withLock { $0 = newValue } }
  }

  func refuseLaterStarts() {
    refuseLater.withLock { $0 = true }
  }

  func allowLaterStarts() {
    refuseLater.withLock { $0 = false }
  }

  func make() -> any SentinelPort {
    let refuse = refuseLater.withLock { $0 }
    let next = queued.withLock { next -> FakeSentinelPort? in
      defer { next = nil }
      return next
    }
    return made.withLock { made in
      let port = made.isEmpty ? first : next ?? FakeSentinelPort(recorder: recorder)
      if !made.isEmpty && refuse {
        port.refuseStart()
      }
      made.append(port)
      return port
    }
  }
}

@Suite(.serialized)
struct EngineClamshellTests {
  struct Harness {
    let temp: TempDirectory
    let paths: Paths
    let clock = FakeClock()
    let assertions = FakeAssertionPort()
    let recorder: HoldRecorder
    let clamshell: FakeClamshellPort
    let sentinels: SentinelFactory

    var sentinel: FakeSentinelPort { sentinels.first }

    init() throws {
      temp = try TempDirectory()
      paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path], homeDirectory: temp.path)
      recorder = HoldRecorder(stateFile: paths.stateFile(.live))
      clamshell = FakeClamshellPort(recorder: recorder)
      sentinels = SentinelFactory(recorder: recorder)
    }

    func engine(
      callTimeoutSeconds: Double = Timing.systemCallTimeoutSeconds, stopWaitSeconds: Double = Engine.stopWaitSeconds
    ) throws -> Engine {
      let sentinels = sentinels
      return try Composition.makeLiveEngine(
        paths: paths,
        settings: Settings(transcriptRoots: [temp.path + "/projects"]),
        ports: LivePorts(
          assertions: assertions, tools: NoTools(), clamshell: clamshell, stateFile: paths.stateFile(.live),
          makeSentinel: { sentinels.make() }),
        environment: [:],
        homeDirectory: temp.path,
        once: true,
        clock: clock,
        callTimeoutSeconds: callTimeoutSeconds,
        stopWaitSeconds: stopWaitSeconds
      )
    }

    func lines() -> [String] {
      guard let text = try? String(contentsOf: paths.decisionLog(.live), encoding: .utf8) else { return [] }
      return text.split(separator: "\n").map(String.init)
    }

    func engaged(
      callTimeoutSeconds: Double = Timing.systemCallTimeoutSeconds, stopWaitSeconds: Double = Engine.stopWaitSeconds
    ) async throws -> Engine {
      let engine = try engine(callTimeoutSeconds: callTimeoutSeconds, stopWaitSeconds: stopWaitSeconds)
      await engine.step(.tick(TickFacts(fullWake: true)))
      await engine.step(.transcriptActivity(TranscriptActivity(at: clock.mono())))
      return engine
    }
  }

  @Test func engageWritesOwnershipThenArmsThenSetsTheBit() async throws {
    let harness = try Harness()
    let engine = try harness.engine()
    #expect(harness.recorder.all == [.sentinelStart, .sentinel("ARM", fileOwnsHold: nil)])
    await engine.step(.tick(TickFacts(fullWake: true)))
    harness.recorder.reset()
    await engine.step(.transcriptActivity(TranscriptActivity(at: harness.clock.mono())))
    #expect(
      harness.recorder.all == [
        .sentinel("ARM", fileOwnsHold: true),
        .clamshell(on: true, fileOwnsHold: true),
        .sentinel("HB", fileOwnsHold: true),
      ])
    #expect(await engine.state.hold.lidClose == .held)
    #expect(harness.lines().contains { $0.hasSuffix(" HOLD engage") })
  }

  @Test func releaseClearsThenDisarmsThenDropsOwnership() async throws {
    let harness = try Harness()
    let engine = try await harness.engaged()
    harness.recorder.reset()
    harness.clock.advance(seconds: 200)
    await engine.step(.tick(TickFacts(fullWake: true)))
    #expect(
      harness.recorder.all == [
        .clamshell(on: false, fileOwnsHold: true),
        .sentinel("DISARM", fileOwnsHold: true),
        .sentinel("HB", fileOwnsHold: false),
      ])
    #expect(await engine.state.hold.lidClose == .released)
    #expect(harness.lines().contains { $0.hasSuffix(" HOLD release") })
    guard case .state(let stored) = StateStore.read(at: harness.paths.stateFile(.live)) else {
      Issue.record("no state file")
      return
    }
    #expect(stored.ownsHold == false)
    #expect(stored.sentinelArmed == false)
  }

  @Test func aHeartbeatFollowsEveryStep() async throws {
    let harness = try Harness()
    let engine = try harness.engine()
    harness.recorder.reset()
    await engine.step(.tick(TickFacts()))
    await engine.step(.tick(TickFacts()))
    await engine.step(.transcriptRoots([]))
    let heartbeats = harness.recorder.all.filter {
      if case .sentinel("HB", _) = $0 { return true }
      return false
    }
    #expect(heartbeats.count == 3)
    #expect(harness.recorder.all.last.map { if case .sentinel("HB", _) = $0 { true } else { false } } == true)
  }

  @Test func aLostArmNeverSetsTheBitBeforeARespawnedSentinelIsArmed() async throws {
    let harness = try Harness()
    let engine = try harness.engine()
    harness.sentinel.queue(.lost(errno: EPIPE), for: .arm)
    await engine.step(.tick(TickFacts(fullWake: true)))
    await engine.step(.transcriptActivity(TranscriptActivity(at: harness.clock.mono())))
    let entries = harness.recorder.all
    let lostArm = try #require(entries.firstIndex(of: .sentinel("ARM", fileOwnsHold: true)))
    let restart = try #require(entries.lastIndex(of: .sentinelStart))
    let set = try #require(entries.firstIndex(of: .clamshell(on: true, fileOwnsHold: true)))
    #expect(lostArm < restart)
    #expect(
      Array(entries[restart...].prefix(4)) == [
        .sentinelStart, .sentinel("ARM", fileOwnsHold: true), .sentinelRetire, .clamshell(on: true, fileOwnsHold: true),
      ])
    #expect(set == restart + 3)
    #expect(entries.filter { $0 == .clamshell(on: true, fileOwnsHold: true) }.count == 1)
    #expect(entries[lostArm + 1] == .clamshell(on: false, fileOwnsHold: true))
    #expect(harness.sentinels.count == 2)
    #expect(await engine.state.hold.lidClose == .held)
    #expect(await engine.state.persisted.ownsHold)
    #expect(harness.lines().contains { $0.hasSuffix(" SENTINEL lost") })
  }

  @Test func liveLaunchWithOwnedHoldArmsBeforeFirstReduce() async throws {
    let harness = try Harness()
    let boot = try #require(BootSession.current())
    let stateFile = harness.paths.stateFile(.live)
    try harness.paths.createDirectories()
    try StateStore.write(PersistedState(bootSessionUUID: boot, ownsHold: true, sentinelArmed: true), to: stateFile)
    let engine = try harness.engine()
    #expect(harness.recorder.all == [.sentinelStart, .sentinel("ARM", fileOwnsHold: true)])
    await engine.step(.launched(LaunchFacts(persisted: StateStore.read(at: stateFile), bootSessionUUID: boot)))
    await engine.step(.transcriptActivity(TranscriptActivity(at: harness.clock.mono())))
    await engine.step(.tick(TickFacts(fullWake: true)))
    let writes = harness.recorder.all.compactMap { entry -> Bool? in
      if case .clamshell(let on, _) = entry { return on }
      return nil
    }
    #expect(writes == [true])
    let firstArm = harness.recorder.all.firstIndex(of: .sentinel("ARM", fileOwnsHold: true))
    let set = harness.recorder.all.firstIndex(of: .clamshell(on: true, fileOwnsHold: true))
    #expect(firstArm == 1)
    #expect(set != nil)
    #expect(await engine.state.hold.lidClose == .held)
    #expect(harness.lines().contains { $0.hasSuffix(" HOLD reclaim") })
    #expect(!harness.lines().contains { $0.hasSuffix(" HOLD engage") })
  }

  @Test(arguments: ["missing", "corrupt", "unreadableBoot", "ambiguousArmed"])
  func liveLaunchArmsWheneverTheBitMayBeSet(_ variant: String) async throws {
    let harness = try Harness()
    let stateFile = harness.paths.stateFile(.live)
    try harness.paths.createDirectories()
    switch variant {
    case "corrupt":
      try Data("{not json".utf8).write(to: stateFile)
    case "unreadableBoot":
      try StateStore.write(PersistedState(bootSessionUUID: nil, ownsHold: true, sentinelArmed: true), to: stateFile)
    case "ambiguousArmed":
      try StateStore.write(
        PersistedState(bootSessionUUID: "any", ownsHold: false, sentinelArmed: true), to: stateFile)
    default:
      break
    }
    let engine = try harness.engine()
    let launch = harness.recorder.all.map { entry -> String in
      if case .sentinel(let line, _) = entry { return line }
      return entry == .sentinelStart ? "start" : "other"
    }
    #expect(launch == ["start", "ARM"])
    await engine.step(.launched(LaunchFacts(persisted: StateStore.read(at: stateFile), bootSessionUUID: "boot")))
    harness.recorder.reset()
    await engine.step(.tick(TickFacts(fullWake: true)))
    let entries = harness.recorder.all
    let clear = try #require(entries.firstIndex { if case .clamshell(on: false, _) = $0 { true } else { false } })
    let disarm = try #require(entries.firstIndex { if case .sentinel("DISARM", _) = $0 { true } else { false } })
    #expect(clear < disarm)
  }

  @Test func liveLaunchAfterACleanStopDoesNotArm() async throws {
    let harness = try Harness()
    try harness.paths.createDirectories()
    try StateStore.write(
      PersistedState(bootSessionUUID: BootSession.current(), ownsHold: false, sentinelArmed: false),
      to: harness.paths.stateFile(.live))
    _ = try harness.engine()
    #expect(harness.recorder.all == [.sentinelStart])
  }

  @Test func liveLaunchFromAnotherBootDoesNotArm() async throws {
    let harness = try Harness()
    try harness.paths.createDirectories()
    try StateStore.write(
      PersistedState(bootSessionUUID: "not-this-boot", ownsHold: true, sentinelArmed: true),
      to: harness.paths.stateFile(.live))
    _ = try harness.engine()
    #expect(harness.recorder.all == [.sentinelStart])
  }

  @Test func stopClearsBeforeBye() async throws {
    let harness = try Harness()
    let engine = try await harness.engaged()
    harness.recorder.reset()
    await engine.stop()
    #expect(
      harness.recorder.all == [
        .clamshell(on: false, fileOwnsHold: true),
        .sentinel("DISARM", fileOwnsHold: true),
        .sentinel("BYE", fileOwnsHold: true),
        .sentinelClose,
      ])
    #expect(await engine.state.hold.lidClose == .released)
    #expect(await engine.state.hold.idle == .released)
    #expect(harness.lines().last?.hasSuffix(" STOP live") == true)
    guard case .state(let stored) = StateStore.read(at: harness.paths.stateFile(.live)) else {
      Issue.record("no state file")
      return
    }
    #expect(stored.ownsHold == false)
  }

  @Test func aFailedStopClearIsRetriedAtOnce() async throws {
    let harness = try Harness()
    let engine = try await harness.engaged()
    harness.recorder.reset()
    harness.clamshell.queueOutcomes([.failed(code: 5)])
    await engine.stop()
    #expect(
      harness.recorder.all == [
        .clamshell(on: false, fileOwnsHold: true),
        .clamshell(on: false, fileOwnsHold: true),
        .sentinel("DISARM", fileOwnsHold: true),
        .sentinel("BYE", fileOwnsHold: true),
        .sentinelClose,
      ])
    #expect(await engine.state.hold.lidClose == .released)
    #expect(harness.recorder.fileOwnsHold() == false)
  }

  @Test func aHungStopClearIsNotStackedAndEscalatesWithoutBye() async throws {
    let harness = try Harness()
    let engine = try await harness.engaged(stopWaitSeconds: Self.roomyStopWaitSeconds)
    harness.recorder.reset()
    harness.clamshell.holdNextWrite()
    defer { harness.clamshell.releaseHeldWrites() }
    #expect(await Engine.bounded(seconds: 40) { await engine.stop() })
    #expect(harness.clamshell.heldWritesReturned == 0, "the stop went on while the clear is still blocked")
    let entries = harness.recorder.all
    #expect(entries.first == .clamshell(on: false, fileOwnsHold: true))
    #expect(entries.filter { $0 == .clamshell(on: false, fileOwnsHold: true) }.count == 1)
    let start = try #require(entries.firstIndex(of: .sentinelStart))
    #expect(Array(entries[start...].prefix(3)) == Self.armedReplacementThenRetire)
    #expect(!entries.contains(.sentinel("BYE", fileOwnsHold: true)))
    #expect(!entries.contains(.sentinel("DISARM", fileOwnsHold: true)))
    #expect(entries.last == .sentinelClose)
    guard case .failed = await engine.state.hold.lidClose else {
      Issue.record("expected a failed stop clear, got \(await engine.state.hold.lidClose)")
      return
    }
    #expect(harness.recorder.fileOwnsHold() == true)
    #expect(harness.lines().last?.hasSuffix(" STOP live") == true)
  }

  static let armedReplacementThenRetire: [HoldRecorder.Entry] = [
    .sentinelStart, .sentinel("ARM", fileOwnsHold: true), .sentinelRetire,
  ]
  static let shortStopWaitSeconds = 0.4
  static let boundedStopWaitSeconds = 5.0
  static let roomyStopWaitSeconds = 20.0

  func escalatingStop(_ harness: Harness) async throws -> Engine {
    let engine = try await harness.engaged(stopWaitSeconds: Self.boundedStopWaitSeconds)
    harness.recorder.reset()
    harness.clamshell.queueOutcomes([.failed(code: 5), .failed(code: 5)])
    #expect(await Engine.bounded(seconds: 30) { await engine.stop() })
    return engine
  }

  @Test func aStopDuringASlowRetireIsBoundedAndClosesTheArmedReplacement() async throws {
    let harness = try Harness()
    harness.sentinel.holdNextRetire()
    defer { harness.sentinel.releaseHeld() }
    _ = try await escalatingStop(harness)
    #expect(harness.sentinel.heldReturned == 0, "the stop ended while the old sentinel's retire is still blocked")
    #expect(harness.lines().contains { $0.hasSuffix(" STOP live") })
    let fresh = try #require(harness.sentinels.latest)
    #expect(harness.sentinels.count == 2)
    #expect(fresh.delivered == ["ARM"])
    #expect(fresh.armedWhenClosed)
    let entries = harness.recorder.all
    let start = try #require(entries.firstIndex(of: .sentinelStart))
    #expect(Array(entries[start...].prefix(3)) == Self.armedReplacementThenRetire)
    #expect(entries.last == .sentinelClose)
    harness.sentinel.releaseHeld()
    #expect(await OffPool.eventually(seconds: 10) { harness.sentinel.heldReturned == 1 })
    try await Task.sleep(for: .seconds(1))
    #expect(harness.sentinels.count == 2)
    #expect(Self.starts(harness.recorder.all) == 1)
  }

  @Test func aStopDuringASlowStartClosesTheOldSentinelAndTheArmedReplacement() async throws {
    let harness = try Harness()
    let engine = try await harness.engaged(stopWaitSeconds: Self.boundedStopWaitSeconds)
    harness.recorder.reset()
    harness.clamshell.queueOutcomes([.failed(code: 5), .failed(code: 5)])
    let slow = FakeSentinelPort(recorder: harness.recorder)
    slow.holdNextStart()
    defer { slow.releaseHeld() }
    harness.sentinels.nextPort = slow
    #expect(await Engine.bounded(seconds: 30) { await engine.stop() })
    #expect(slow.heldReturned == 0, "the stop ended while the replacement's start is still blocked")
    #expect(harness.lines().contains { $0.hasSuffix(" STOP live") })
    #expect(harness.sentinel.armedWhenClosed)
    slow.releaseHeld()
    #expect(await OffPool.eventually(seconds: 10) { slow.closed })
    #expect(slow.delivered == ["ARM"])
    #expect(slow.armedWhenClosed)
    #expect(!harness.recorder.all.contains(.sentinelRetire))
    #expect(Self.starts(harness.recorder.all) == 1)
  }

  @Test func aClosedSentinelIsNotReportedLostOrRespawnedByTheStopThatOutlivesItsBound() async throws {
    let harness = try Harness()
    let engine = try await harness.engaged(stopWaitSeconds: Self.shortStopWaitSeconds)
    harness.recorder.reset()
    harness.clamshell.blockNextWrite(seconds: 1)
    await engine.stop()
    #expect(harness.recorder.all.last == .sentinelClose)
    #expect(ProcessProbe.poll(within: 3) { harness.recorder.fileOwnsHold() == false })
    try await Task.sleep(for: .milliseconds(300))
    #expect(harness.sentinels.count == 1)
    #expect(!harness.lines().contains { $0.hasSuffix(" SENTINEL lost") })
    #expect(!harness.lines().contains { $0.hasSuffix(" ERROR sentinel respawn failed") })
  }

  @Test func liveOnceStopsTheEngineBeforeReleasingTheLock() async throws {
    let harness = try Harness()
    let sentinels = harness.sentinels
    let instance = try Composition.launchLive(
      paths: harness.paths,
      settings: Settings(transcriptRoots: [harness.temp.path + "/projects"]),
      ports: LivePorts(
        assertions: harness.assertions, tools: NoTools(), clamshell: harness.clamshell,
        stateFile: harness.paths.stateFile(.live), makeSentinel: { sentinels.make() }),
      environment: [:], homeDirectory: harness.temp.path, once: true)
    await instance.runOnceAndFinish()
    #expect(harness.recorder.all.last == .sentinelClose)
    #expect(harness.recorder.fileOwnsHold() != true)
    #expect(harness.lines().last?.hasSuffix(" STOP live") == true)
    let relock = try InstanceLock.acquire(at: harness.paths.lockFile(.live))
    relock.release()
  }

  @Test func stopTwiceRunsTheSequenceOnce() async throws {
    let harness = try Harness()
    let engine = try await harness.engaged()
    harness.recorder.reset()
    await engine.stop()
    await engine.stop()
    #expect(harness.recorder.all.filter { $0 == .sentinel("BYE", fileOwnsHold: true) }.count == 1)
    #expect(harness.lines().filter { $0.hasSuffix(" STOP live") }.count == 1)
  }

  @Test func respawnReplacesTheSentinel() async throws {
    let harness = try Harness()
    let engine = try await harness.engaged()
    harness.recorder.reset()
    harness.sentinel.queue(.lost(errno: EPIPE), for: .heartbeat)
    await engine.step(.tick(TickFacts(fullWake: true)))
    #expect(
      harness.recorder.all == [
        .sentinel("HB", fileOwnsHold: true),
        .clamshell(on: false, fileOwnsHold: true),
        .sentinelStart,
        .sentinel("ARM", fileOwnsHold: true),
        .sentinelRetire,
        .clamshell(on: true, fileOwnsHold: true),
      ])
    #expect(harness.sentinels.count == 2)
    #expect(await engine.state.hold.lidClose == .held)
    #expect(harness.lines().contains { $0.hasSuffix(" SENTINEL lost") })
    #expect(harness.lines().contains { $0.hasSuffix(" HOLD reassert why=watchdogLost") })
    #expect(harness.lines().contains { $0.hasSuffix(" SENTINEL retired signal=TERM") })
    #expect(harness.sentinels.latest?.startQueueLabel == LiveInterpreter.sentinelStartQueueLabel)
    harness.recorder.reset()
    await engine.step(.tick(TickFacts(fullWake: true)))
    #expect(harness.recorder.all == [.sentinel("HB", fileOwnsHold: true)])
  }

  @Test func retiringASentinelThatWasAlreadyGoneLogsThatNoSignalWasSent() async throws {
    let harness = try Harness()
    let engine = try await harness.engaged()
    harness.sentinel.retireAs(.exited)
    harness.sentinel.queue(.lost(errno: EPIPE), for: .heartbeat)
    await engine.step(.tick(TickFacts(fullWake: true)))
    #expect(harness.sentinels.count == 2)
    #expect(harness.lines().contains { $0.hasSuffix(" SENTINEL retired signal=none") })
    #expect(!harness.lines().contains { $0.hasSuffix(" SENTINEL retired signal=TERM") })
  }

  @Test func aSentinelThatCannotRespawnNeverSetsTheBit() async throws {
    let harness = try Harness()
    let engine = try await harness.engaged()
    harness.recorder.reset()
    harness.sentinel.queue(.lost(errno: EPIPE), for: .heartbeat)
    harness.sentinels.refuseLaterStarts()
    await engine.step(.tick(TickFacts(fullWake: true)))
    let sets = harness.recorder.all.filter { $0 == .clamshell(on: true, fileOwnsHold: true) }
    #expect(sets.isEmpty)
    #expect(harness.recorder.all.contains(.clamshell(on: false, fileOwnsHold: true)))
    #expect(harness.lines().contains { $0.hasSuffix(" ERROR sentinel respawn failed") })
    guard case .failed = await engine.state.hold.lidClose else {
      Issue.record("expected a failed hold, got \(await engine.state.hold.lidClose)")
      return
    }
  }

  static func starts(_ entries: [HoldRecorder.Entry]) -> Int {
    entries.filter { $0 == .sentinelStart }.count
  }

  @Test func aFailedRespawnIsRetriedOnABackoffUntilASentinelIsArmed() async throws {
    let harness = try Harness()
    let engine = try await harness.engaged()
    harness.sentinel.queue(.lost(errno: EPIPE), for: .heartbeat)
    harness.sentinels.refuseLaterStarts()
    await engine.step(.tick(TickFacts(fullWake: true)))
    #expect(harness.sentinels.count == 2)
    await engine.step(.tick(TickFacts(fullWake: true)))
    #expect(harness.sentinels.count == 2)
    harness.clock.advance(seconds: Timing.sentinelRespawnRetryBaseSeconds)
    await engine.step(.tick(TickFacts(fullWake: true)))
    #expect(harness.sentinels.count == 3)
    harness.clock.advance(seconds: Timing.sentinelRespawnRetryBaseSeconds)
    await engine.step(.tick(TickFacts(fullWake: true)))
    #expect(harness.sentinels.count == 3)
    harness.sentinels.allowLaterStarts()
    harness.recorder.reset()
    harness.clock.advance(seconds: Timing.sentinelRespawnRetryBaseSeconds * 2)
    await engine.step(.tick(TickFacts(fullWake: true)))
    #expect(harness.sentinels.count == 4)
    let entries = harness.recorder.all
    let start = try #require(entries.firstIndex(of: .sentinelStart))
    #expect(entries[start + 1] == .sentinel("ARM", fileOwnsHold: true))
    #expect(entries.contains(.clamshell(on: true, fileOwnsHold: true)))
    #expect(await engine.state.hold.lidClose == .held)
    #expect(harness.lines().filter { $0.hasSuffix(" SENTINEL lost") }.count == 3)
    harness.recorder.reset()
    harness.clock.advance(seconds: Timing.sentinelRespawnRetryCapSeconds)
    await engine.step(.tick(TickFacts(fullWake: true)))
    #expect(Self.starts(harness.recorder.all) == 0)
  }

  @Test func aSentinelLostAgainAfterASuccessfulRespawnIsReportedAgain() async throws {
    let harness = try Harness()
    let engine = try await harness.engaged()
    harness.sentinel.queue(.lost(errno: EPIPE), for: .heartbeat)
    await engine.step(.tick(TickFacts(fullWake: true)))
    #expect(harness.sentinels.count == 2)
    let second = try #require(harness.sentinels.latest)
    second.queue(.lost(errno: EPIPE), for: .heartbeat)
    harness.clock.advance(seconds: Timing.sentinelRespawnRetryBaseSeconds)
    await engine.step(.tick(TickFacts(fullWake: true)))
    #expect(harness.sentinels.count == 3)
  }

  @Test func theRespawnRetryBacksOffToACap() {
    #expect(Engine.sentinelRetrySeconds(afterReports: 1) == Timing.sentinelRespawnRetryBaseSeconds)
    #expect(Engine.sentinelRetrySeconds(afterReports: 2) == Timing.sentinelRespawnRetryBaseSeconds * 2)
    #expect(Engine.sentinelRetrySeconds(afterReports: 40) == Timing.sentinelRespawnRetryCapSeconds)
  }

  @Test func anUnpersistedOwnershipNeverSetsTheBit() async throws {
    let harness = try Harness()
    let engine = try harness.engine()
    await engine.step(.tick(TickFacts(fullWake: true)))
    try FileManager.default.createDirectory(at: harness.paths.stateFile(.live), withIntermediateDirectories: false)
    harness.recorder.reset()
    await engine.step(.transcriptActivity(TranscriptActivity(at: harness.clock.mono())))
    #expect(!harness.recorder.all.contains { if case .clamshell(on: true, _) = $0 { true } else { false } })
    #expect(harness.lines().contains { $0.hasSuffix(" ERROR state write failed") })
    guard case .failed = await engine.state.hold.lidClose else {
      Issue.record("expected a failed hold, got \(await engine.state.hold.lidClose)")
      return
    }
  }

  @Test func aSentinelThatCannotStartRefusesTheLiveEngine() throws {
    let harness = try Harness()
    try harness.paths.createDirectories()
    try StateStore.write(
      PersistedState(bootSessionUUID: BootSession.current(), ownsHold: false, sentinelArmed: false),
      to: harness.paths.stateFile(.live))
    harness.sentinel.refuseStart()
    #expect(throws: CompositionError.self) {
      _ = try harness.engine()
    }
    #expect(harness.recorder.all.isEmpty)
  }

  @Test(arguments: ["missing", "owned"])
  func aSentinelThatCannotStartStillClearsABitTheLaunchMayFindSet(_ variant: String) throws {
    let harness = try Harness()
    let stateFile = harness.paths.stateFile(.live)
    try harness.paths.createDirectories()
    if variant == "owned" {
      try StateStore.write(
        PersistedState(bootSessionUUID: BootSession.current(), ownsHold: true, sentinelArmed: true), to: stateFile)
    }
    harness.sentinel.refuseStart()
    #expect(throws: CompositionError.self) {
      _ = try harness.engine()
    }
    #expect(harness.recorder.all == [.clamshell(on: false, fileOwnsHold: variant == "owned" ? true : nil)])
    #expect(harness.lines().contains { $0.hasSuffix(" ERROR sentinel unavailable clearStale=succeeded") })
    #expect(harness.recorder.fileOwnsHold() == (variant == "owned" ? true : nil))
  }

  @Test func theClearWithoutASentinelIsBounded() async throws {
    let harness = try Harness()
    harness.sentinel.refuseStart()
    harness.clamshell.holdNextWrite()
    defer { harness.clamshell.releaseHeldWrites() }
    let refused = await OffPool.bounded(seconds: 30) { () -> Bool in
      do {
        _ = try harness.engine()
        return false
      } catch {
        return error is CompositionError
      }
    }
    #expect(refused == true)
    #expect(harness.clamshell.heldWritesReturned == 0, "the launch gave up while the clear is still blocked")
    #expect(harness.lines().contains { $0.hasSuffix(" ERROR sentinel unavailable clearStale=timedOut") })
  }

  @Test func theShadowRecorderNeverTouchesTheSentinelOrTheBit() async throws {
    let harness = try Harness()
    let engine = try Composition.makeShadowEngine(
      paths: harness.paths,
      settings: Settings(transcriptRoots: [harness.temp.path + "/projects"]),
      environment: [:],
      homeDirectory: harness.temp.path,
      once: true
    )
    await engine.step(.tick(TickFacts(fullWake: true)))
    await engine.step(.transcriptActivity(TranscriptActivity(at: SystemClock().mono())))
    #expect(await engine.state.hold.lidClose == .held)
    #expect(harness.recorder.all.isEmpty)
    let text = try String(contentsOf: harness.paths.decisionLog(.shadow), encoding: .utf8)
    #expect(text.contains(" HOLD engage"))
  }
}
