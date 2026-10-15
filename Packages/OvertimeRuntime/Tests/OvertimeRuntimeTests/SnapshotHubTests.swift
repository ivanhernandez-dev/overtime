import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing
import os

final class SnapshotRecorder: Sendable {
  private let received = OSAllocatedUnfairLock<[EngineSnapshot]>(initialState: [])
  private let finished = OSAllocatedUnfairLock(initialState: false)
  private let consumer = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

  init(_ stream: AsyncStream<EngineSnapshot>) {
    let received = received
    let finished = finished
    let task = Task {
      for await snapshot in stream {
        received.withLock { $0.append(snapshot) }
      }
      finished.withLock { $0 = true }
    }
    consumer.withLock { $0 = task }
  }

  var snapshots: [EngineSnapshot] {
    received.withLock { $0 }
  }

  var isFinished: Bool {
    finished.withLock { $0 }
  }

  func cancel() {
    consumer.withLock { $0 }?.cancel()
  }

  @discardableResult
  func wait(seconds: Double = 5, until predicate: @Sendable ([EngineSnapshot]) -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
      if predicate(snapshots) { return true }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return predicate(snapshots)
  }

  func waitFinished(seconds: Double = 5) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
      if isFinished { return true }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return isFinished
  }
}

final class FakeUpstream: Sendable {
  private let continuations = OSAllocatedUnfairLock<[AsyncStream<EngineSnapshot>.Continuation]>(initialState: [])
  private let pending = OSAllocatedUnfairLock<[EngineSnapshot]>(initialState: [])

  var calls: Int {
    continuations.withLock { $0.count }
  }

  func seed(_ snapshot: EngineSnapshot) {
    pending.withLock { $0.append(snapshot) }
  }

  func subscribe() -> AsyncStream<EngineSnapshot> {
    let (stream, continuation) = AsyncStream.makeStream(
      of: EngineSnapshot.self, bufferingPolicy: .bufferingNewest(1))
    let seeded = pending.withLock { current -> [EngineSnapshot] in
      defer { current.removeAll() }
      return current
    }
    for snapshot in seeded {
      continuation.yield(snapshot)
    }
    continuations.withLock { $0.append(continuation) }
    return stream
  }

  func yield(_ snapshot: EngineSnapshot) {
    continuations.withLock { $0.last }?.yield(snapshot)
  }

  func finishAll() {
    let all = continuations.withLock { $0 }
    for continuation in all {
      continuation.finish()
    }
  }
}

struct SnapshotHubTests {
  static func snapshot(_ reason: String) -> EngineSnapshot {
    EngineSnapshot(reason: reason)
  }

  static func reasons(_ snapshots: [EngineSnapshot]) -> [String] {
    snapshots.compactMap(\.reason)
  }

  @Test func twoSubscribersBothReceiveTheFirstAndLaterSnapshotsFromOneUpstreamCall() async {
    let upstream = FakeUpstream()
    defer { upstream.finishAll() }
    upstream.seed(Self.snapshot("first"))
    let hub = SnapshotHub()
    let panel = SnapshotRecorder(hub.subscribe())
    let second = SnapshotRecorder(hub.subscribe())
    defer {
      panel.cancel()
      second.cancel()
    }
    hub.start { upstream.subscribe() }
    #expect(await panel.wait { Self.reasons($0).contains("first") })
    #expect(await second.wait { Self.reasons($0).contains("first") })
    upstream.yield(Self.snapshot("later"))
    #expect(await panel.wait { Self.reasons($0).last == "later" })
    #expect(await second.wait { Self.reasons($0).last == "later" })
    #expect(upstream.calls == 1)
    #expect(!panel.isFinished)
    #expect(!second.isFinished)
  }

  @Test func startIfNeededCallsTheUpstreamOnlyOnce() async {
    let upstream = FakeUpstream()
    defer { upstream.finishAll() }
    upstream.seed(Self.snapshot("first"))
    let hub = SnapshotHub()
    hub.startIfNeeded { upstream.subscribe() }
    let panel = SnapshotRecorder(hub.subscribe())
    hub.startIfNeeded { upstream.subscribe() }
    let second = SnapshotRecorder(hub.subscribe())
    defer {
      panel.cancel()
      second.cancel()
    }
    #expect(await panel.wait { Self.reasons($0).contains("first") })
    #expect(await second.wait { Self.reasons($0).contains("first") })
    #expect(upstream.calls == 1)
    #expect(hub.isStarted)
  }

  @Test func aLateSubscriberReceivesTheLatestSnapshotAtOnce() async {
    let upstream = FakeUpstream()
    defer { upstream.finishAll() }
    upstream.seed(Self.snapshot("first"))
    let hub = SnapshotHub()
    let panel = SnapshotRecorder(hub.subscribe())
    defer { panel.cancel() }
    hub.start { upstream.subscribe() }
    #expect(await panel.wait { Self.reasons($0).contains("first") })
    upstream.yield(Self.snapshot("newest"))
    #expect(await panel.wait { Self.reasons($0).last == "newest" })
    let late = SnapshotRecorder(hub.subscribe())
    defer { late.cancel() }
    #expect(await late.wait { Self.reasons($0).first == "newest" })
    #expect(Self.reasons(late.snapshots) == ["newest"])
  }

  @Test func startingAgainResubscribesAndBothSubscribersContinue() async {
    let first = FakeUpstream()
    let replacement = FakeUpstream()
    defer {
      first.finishAll()
      replacement.finishAll()
    }
    first.seed(Self.snapshot("old"))
    replacement.seed(Self.snapshot("new"))
    let hub = SnapshotHub()
    let panel = SnapshotRecorder(hub.subscribe())
    let second = SnapshotRecorder(hub.subscribe())
    defer {
      panel.cancel()
      second.cancel()
    }
    hub.start { first.subscribe() }
    #expect(await panel.wait { Self.reasons($0).contains("old") })
    hub.start { replacement.subscribe() }
    #expect(await panel.wait { Self.reasons($0).last == "new" })
    #expect(await second.wait { Self.reasons($0).last == "new" })
    first.yield(Self.snapshot("stale"))
    replacement.yield(Self.snapshot("current"))
    #expect(await panel.wait { Self.reasons($0).last == "current" })
    #expect(await second.wait { Self.reasons($0).last == "current" })
    #expect(!Self.reasons(panel.snapshots).contains("stale"))
    #expect(!Self.reasons(second.snapshots).contains("stale"))
    #expect(first.calls == 1)
    #expect(replacement.calls == 1)
    #expect(!panel.isFinished)
  }

  @Test func aTerminatedSubscriberIsRemovedAndTheOthersKeepReceiving() async {
    let upstream = FakeUpstream()
    defer { upstream.finishAll() }
    upstream.seed(Self.snapshot("first"))
    let hub = SnapshotHub()
    let panel = SnapshotRecorder(hub.subscribe())
    let leaving = SnapshotRecorder(hub.subscribe())
    defer { panel.cancel() }
    hub.start { upstream.subscribe() }
    #expect(await leaving.wait { Self.reasons($0).contains("first") })
    #expect(hub.subscriberCount == 2)
    leaving.cancel()
    #expect(await leaving.waitFinished())
    let deadline = ContinuousClock.now + .seconds(5)
    while hub.subscriberCount != 1 && ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(hub.subscriberCount == 1)
    upstream.yield(Self.snapshot("after"))
    #expect(await panel.wait { Self.reasons($0).last == "after" })
  }

  struct LiveHarness {
    let temp: TempDirectory
    let paths: Paths
    let clock = FakeClock()
    let port = FakeAssertionPort()
    let recorder: HoldRecorder

    init() throws {
      temp = try TempDirectory()
      paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path], homeDirectory: temp.path)
      recorder = HoldRecorder(stateFile: paths.stateFile(.live))
    }

    func engine() throws -> Engine {
      try Composition.makeLiveEngine(
        paths: paths,
        settings: Settings(transcriptRoots: [temp.path + "/projects"]),
        ports: LivePorts(
          assertions: port, tools: NoTools(), clamshell: FakeClamshellPort(recorder: recorder),
          stateFile: paths.stateFile(.live), makeSentinel: { [recorder] in FakeSentinelPort(recorder: recorder) }),
        environment: [:],
        homeDirectory: temp.path,
        once: true,
        clock: clock
      )
    }
  }

  @Test func aHoldErrorWhileBusyReachesBothHostSubscribersAndThePanelKeepsItsStream() async throws {
    let harness = try LiveHarness()
    let engine = try harness.engine()
    let host = LiveEngineHost(engine: engine, clock: harness.clock)
    let panel = SnapshotRecorder(await host.snapshots())
    let notifications = SnapshotRecorder(await host.snapshots())
    defer {
      panel.cancel()
      notifications.cancel()
    }
    #expect(await panel.wait { !$0.isEmpty })
    #expect(await notifications.wait { !$0.isEmpty })

    harness.port.queueAcquireOutcomes([.failed(code: 1)])
    let now = harness.clock.mono()
    let finished = await Engine.bounded(seconds: 5) {
      await engine.step(.transcriptActivity(TranscriptActivity(at: now)))
      await engine.step(.tick(TickFacts()))
    }
    #expect(finished)
    #expect(await engine.state.hold.errorActive)
    #expect(await panel.wait { $0.last?.events.holdErrorsWhileBusy == 1 })
    #expect(await notifications.wait { $0.last?.events.holdErrorsWhileBusy == 1 })
    #expect(panel.snapshots.last?.events.holdErrorEpisodes == 1)

    let resumed = await Engine.bounded(seconds: 5) {
      _ = await engine.handle(.pause(.indefinite))
    }
    #expect(resumed)
    #expect(await panel.wait { $0.last?.pause == .indefinite })
    #expect(await notifications.wait { $0.last?.pause == .indefinite })
    #expect(!panel.isFinished)
    #expect(!notifications.isFinished)
    #expect(host.hub.subscriberCount == 2)
  }
}
