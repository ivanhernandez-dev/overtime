import Foundation
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import os

public protocol EngineHosting: Sendable {
  var clock: any ClockPort { get }
  var engineToken: UUID { get }
  func snapshots() async -> AsyncStream<EngineSnapshot>
  func send(_ request: CtlRequest) async -> CtlResponse?
  func probe() async -> EngineSnapshot?
  func apply(settings: Settings) async -> Bool
  func requestSelfTest() async
  func updateHelper(_ facts: HelperFacts) async
}

public struct LiveEngineHost: EngineHosting {
  public let engine: Engine
  public let clock: any ClockPort
  public let hub: SnapshotHub
  public let engineToken: UUID
  private let boundSeconds: Double

  public init(engine: Engine, clock: any ClockPort, boundSeconds: Double = Timing.systemCallTimeoutSeconds) {
    self.engine = engine
    self.clock = clock
    self.boundSeconds = boundSeconds
    self.hub = SnapshotHub()
    self.engineToken = UUID()
  }

  public func snapshots() async -> AsyncStream<EngineSnapshot> {
    let engine = engine
    hub.startIfNeeded { await engine.snapshots() }
    return hub.subscribe()
  }

  public func send(_ request: CtlRequest) async -> CtlResponse? {
    let result = OSAllocatedUnfairLock<CtlResponse?>(initialState: nil)
    let engine = engine
    let finished = await Engine.bounded(seconds: boundSeconds) {
      let response = await engine.handle(request)
      result.withLock { $0 = response }
    }
    guard finished else { return nil }
    return result.withLock { $0 }
  }

  public func probe() async -> EngineSnapshot? {
    let result = OSAllocatedUnfairLock<EngineSnapshot?>(initialState: nil)
    let engine = engine
    let finished = await Engine.bounded(seconds: boundSeconds) {
      let snapshot = await engine.currentSnapshot()
      result.withLock { $0 = snapshot }
    }
    guard finished else { return nil }
    return result.withLock { $0 }
  }

  public func apply(settings: Settings) async -> Bool {
    let result = OSAllocatedUnfairLock(initialState: false)
    let engine = engine
    let finished = await Engine.bounded(seconds: boundSeconds) {
      let applied = await engine.apply(settings: settings)
      result.withLock { $0 = applied }
    }
    guard finished else {
      engine.logImmediately(Decision(keyword: .error, verb: "settings apply timedOut"))
      return false
    }
    return result.withLock { $0 }
  }

  public func requestSelfTest() async {
    let engine = engine
    _ = await Engine.bounded(seconds: boundSeconds) {
      await engine.requestSelfTest()
    }
  }

  public func updateHelper(_ facts: HelperFacts) async {
    let engine = engine
    _ = await Engine.bounded(seconds: boundSeconds) {
      await engine.updateHelper(facts)
    }
  }
}
