import Foundation
import OvertimeEngine
import os

public final class SnapshotHub: Sendable {
  public typealias Upstream = @Sendable () async -> AsyncStream<EngineSnapshot>

  private struct State {
    var latest: EngineSnapshot?
    var subscribers: [UInt64: AsyncStream<EngineSnapshot>.Continuation] = [:]
    var nextSubscriber: UInt64 = 0
    var generation: UInt64 = 0
    var started = false
    var pump: Task<Void, Never>?
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  public init() {}

  public var latest: EngineSnapshot? {
    state.withLock { $0.latest }
  }

  public var subscriberCount: Int {
    state.withLock { $0.subscribers.count }
  }

  public var isStarted: Bool {
    state.withLock { $0.started }
  }

  public func startIfNeeded(upstream: @escaping Upstream) {
    let claimed = state.withLock { current -> Bool in
      guard !current.started else { return false }
      current.started = true
      return true
    }
    guard claimed else { return }
    start(upstream: upstream)
  }

  public func start(upstream: @escaping Upstream) {
    let (generation, previous) = state.withLock { current -> (UInt64, Task<Void, Never>?) in
      current.generation &+= 1
      current.started = true
      let previous = current.pump
      current.pump = nil
      return (current.generation, previous)
    }
    previous?.cancel()
    let pump = Task { [weak self] in
      let stream = await upstream()
      for await snapshot in stream {
        guard let self, self.publish(snapshot, generation: generation) else { return }
      }
    }
    let stale = state.withLock { current -> Bool in
      guard current.generation == generation else { return true }
      current.pump = pump
      return false
    }
    if stale {
      pump.cancel()
    }
  }

  public func subscribe() -> AsyncStream<EngineSnapshot> {
    let (stream, continuation) = AsyncStream.makeStream(
      of: EngineSnapshot.self, bufferingPolicy: .bufferingNewest(1))
    let id = state.withLock { current -> UInt64 in
      let id = current.nextSubscriber
      current.nextSubscriber &+= 1
      current.subscribers[id] = continuation
      if let latest = current.latest {
        continuation.yield(latest)
      }
      return id
    }
    continuation.onTermination = { [weak self] _ in
      self?.remove(id)
    }
    return stream
  }

  private func publish(_ snapshot: EngineSnapshot, generation: UInt64) -> Bool {
    state.withLock { current -> Bool in
      guard current.generation == generation else { return false }
      current.latest = snapshot
      for subscriber in current.subscribers.values {
        subscriber.yield(snapshot)
      }
      return true
    }
  }

  private func remove(_ id: UInt64) {
    _ = state.withLock { current in
      current.subscribers.removeValue(forKey: id)
    }
  }
}
