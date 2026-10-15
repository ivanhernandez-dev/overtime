import Foundation
import OvertimeCore
import OvertimeEngine
import OvertimeHelperCore
import OvertimeSystem
import os

public enum HelperReachability: Sendable, Equatable {
  case unknown
  case reachable
  case unreachable
}

public enum HelperInFlight: Sendable, Equatable {
  case installing
  case removing
}

public struct HelperMonitorState: Sendable, Equatable {
  public var installer: HelperInstallerStatus?
  public var reachability: HelperReachability
  public var status: HelperStatus?
  public var staleAttempts: Int
  public var lastError: String?
  public var inFlight: HelperInFlight?

  public init(
    installer: HelperInstallerStatus? = nil, reachability: HelperReachability = .unknown, status: HelperStatus? = nil,
    staleAttempts: Int = 0, lastError: String? = nil, inFlight: HelperInFlight? = nil
  ) {
    self.installer = installer
    self.reachability = reachability
    self.status = status
    self.staleAttempts = staleAttempts
    self.lastError = lastError
    self.inFlight = inFlight
  }
}

struct HelperTracking: Sendable, Equatable {
  struct ActionFailure: Sendable, Equatable {
    var message: String
    var status: HelperInstallerStatus?
    var action: HelperInFlight?
  }

  var state = HelperMonitorState()
  var facts: HelperFacts?
  var misses = 0
  var actionFailure: ActionFailure?
  var probeFailure: String?

  mutating func begin(_ action: HelperInFlight) {
    actionFailure = nil
    state.inFlight = action
    state.lastError = probeFailure
  }

  mutating func end(failure: ActionFailure?) {
    actionFailure = failure.map { failure in
      var failure = failure
      failure.action = failure.action ?? state.inFlight
      return failure
    }
    state.inFlight = nil
    state.lastError = failure?.message ?? probeFailure
  }

  mutating func acknowledge() {
    actionFailure = nil
    state.lastError = probeFailure
  }

  mutating func forgetRemovalFailure() {
    guard actionFailure?.action == .removing else { return }
    actionFailure = nil
    state.lastError = probeFailure
  }

  mutating func statusUnread(_ reason: String) {
    probeFailure = reason
    state.lastError = actionFailure?.message ?? probeFailure
  }

  mutating func apply(installer: HelperInstallerStatus, probe: HelperProbe?) {
    state.installer = installer
    if let failure = actionFailure, failure.status != installer {
      actionFailure = nil
    }
    defer { state.lastError = actionFailure?.message ?? probeFailure }
    guard let probe else {
      probeFailure = nil
      state.reachability = .unknown
      state.status = nil
      state.staleAttempts = 0
      facts = HelperFacts(installed: installer.isInstalled, reachable: false, current: false)
      return
    }
    switch probe {
    case .answered(let status):
      let current = status.helperVersion == HelperIdentity.version
      misses = 0
      probeFailure = nil
      state.reachability = .reachable
      state.status = status
      state.staleAttempts = current ? 0 : state.staleAttempts + 1
      facts = HelperFacts(
        installed: true, reachable: true, current: current, owns: status.owns, sleepDisabled: status.sleepDisabled)
    case .engaged(let last):
      misses = 0
      probeFailure = nil
      state.reachability = .reachable
      state.status = last ?? state.status
    case .unreachable(let reason):
      misses += 1
      let afterAnAnswer = misses == 1 && state.reachability == .reachable
      guard !afterAnAnswer else { return }
      let unreachable = HelperMonitor.isUnreachable(reason)
      state.reachability = unreachable ? .unreachable : .reachable
      state.status = nil
      probeFailure = unreachable ? nil : reason
      facts = HelperFacts(installed: true, reachable: false, current: false)
    }
  }
}

public final class HelperMonitor: Sendable {
  public static let connectionInvalidReason = "\(NSCocoaErrorDomain) \(CocoaError.Code.xpcConnectionInvalid.rawValue)"

  private struct Reading: Sendable {
    var installer: HelperInstallerStatus
    var probe: HelperProbe?
  }

  private struct Outcome: Sendable {
    var state: HelperMonitorState
    var changed: Bool
    var send: HelperFacts?
    var host: (any EngineHosting)?
  }

  private struct Stored: Sendable {
    var tracking = HelperTracking()
    var host: (any EngineHosting)?
    var sent: HelperFacts?
    var tail: Task<Void, Never>?
    var watcher: Task<Void, Never>?
  }

  public static let statusBoundSeconds = Timing.systemCallTimeoutSeconds
  public static let actionBoundSeconds: Double = 20
  public static let timedOutReason = "timedOut"
  static let statusKey = "helper-installer-status"
  static let registerKey = "helper-installer-register"
  static let unregisterKey = "helper-installer-unregister"
  static let settingsKey = "helper-installer-settings"

  private let installer: any HelperInstallerService
  private let port: XPCHelperPort
  private let onChange: @Sendable (HelperMonitorState) -> Void
  private let log: @Sendable (Decision) -> Void
  private let calls = DispatchQueue(label: "HelperMonitor.calls")
  private let stored = OSAllocatedUnfairLock(initialState: Stored())
  private let runner = DeadlineRunner()
  private let statusSeconds: Double
  private let actionSeconds: Double

  public init(
    installer: any HelperInstallerService, port: XPCHelperPort,
    statusBoundSeconds: Double = HelperMonitor.statusBoundSeconds,
    actionBoundSeconds: Double = HelperMonitor.actionBoundSeconds,
    log: @escaping @Sendable (Decision) -> Void = { _ in },
    onChange: @escaping @Sendable (HelperMonitorState) -> Void = { _ in }
  ) {
    self.installer = installer
    self.port = port
    self.log = log
    self.onChange = onChange
    statusSeconds = statusBoundSeconds
    actionSeconds = actionBoundSeconds
  }

  public var state: HelperMonitorState {
    stored.withLock { $0.tracking.state }
  }

  public var facts: HelperFacts? {
    stored.withLock { $0.tracking.facts }
  }

  public var isWatching: Bool {
    stored.withLock { $0.watcher != nil }
  }

  public static func isUnreachable(_ reason: String) -> Bool {
    reason == XPCHelperPort.timedOutReason || reason == connectionInvalidReason
  }

  public func start(host: any EngineHosting) {
    stored.withLock { stored in
      stored.host = host
      stored.sent = nil
    }
    let task = Task { [weak self] in
      await self?.refresh()
      let stream = await host.snapshots()
      var lastKnown: Bool?
      for await snapshot in stream {
        guard !Task.isCancelled else { break }
        guard let closed = snapshot.lidClosed else { continue }
        let closing = closed && lastKnown == false
        lastKnown = closed
        if closing {
          await self?.refresh()
        }
      }
    }
    let previous = stored.withLock { stored -> Task<Void, Never>? in
      defer { stored.watcher = task }
      return stored.watcher
    }
    previous?.cancel()
  }

  public func stop() {
    stored.withLock { stored -> Task<Void, Never>? in
      defer { stored.watcher = nil }
      stored.host = nil
      return stored.watcher
    }?.cancel()
  }

  deinit {
    stored.withLock { $0.watcher }?.cancel()
  }

  @discardableResult
  public func refresh() async -> HelperMonitorState {
    await serialized { [self] in
      await settle(read())
    }
  }

  @discardableResult
  public func reconnect() async -> HelperMonitorState {
    await serialized { [self] in
      await settle(read(), acknowledged: true)
    }
  }

  @discardableResult
  public func acknowledgeRemovalFailure() -> HelperMonitorState {
    let outcome = stored.withLock { stored -> (state: HelperMonitorState, changed: Bool) in
      let before = stored.tracking.state
      stored.tracking.forgetRemovalFailure()
      return (stored.tracking.state, stored.tracking.state != before)
    }
    if outcome.changed {
      onChange(outcome.state)
    }
    return outcome.state
  }

  @discardableResult
  public func install() async -> HelperMonitorState {
    let calls = BoundedCalls(runner: runner, statusSeconds: statusSeconds, actionSeconds: actionSeconds)
    return await act(.installing) { installer, previous in
      let failure = calls.action(key: Self.registerKey) { try installer.register() }
      guard let status = calls.status(of: installer) else {
        return HelperTracking.ActionFailure(message: failure ?? Self.timedOutReason, status: previous)
      }
      if status == .requiresApproval {
        calls.openSystemSettings(installer)
      }
      guard let failure, !status.isInstalled else { return nil }
      return HelperTracking.ActionFailure(message: failure, status: status)
    }
  }

  @discardableResult
  public func remove() async -> HelperMonitorState {
    let calls = BoundedCalls(runner: runner, statusSeconds: statusSeconds, actionSeconds: actionSeconds)
    let log = log
    return await act(.removing) { installer, previous in
      guard let failure = calls.action(key: Self.unregisterKey, { try installer.unregister() }) else { return nil }
      log(Self.unregisterFailed(timedOut: failure == Self.timedOutReason))
      return HelperTracking.ActionFailure(message: failure, status: calls.status(of: installer) ?? previous)
    }
  }

  public static func unregisterFailed(timedOut: Bool) -> Decision {
    Decision(
      keyword: .error, verb: "helper unregister failed",
      fields: [DecisionField(key: "reason", value: timedOut ? timedOutReason : "error")])
  }

  public func openLoginItems() async {
    let installer = installer
    let calls = BoundedCalls(runner: runner, statusSeconds: statusSeconds, actionSeconds: actionSeconds)
    await offMain { calls.openSystemSettings(installer) }
  }

  struct BoundedCalls: Sendable {
    let runner: DeadlineRunner
    let statusSeconds: Double
    let actionSeconds: Double

    func status(of installer: any HelperInstallerService) -> HelperInstallerStatus? {
      let outcome = runner.run(timeout: statusSeconds, key: HelperMonitor.statusKey) { installer.status }
      guard case .value(let status) = outcome else { return nil }
      return status
    }

    func action(key: String, _ work: @escaping @Sendable () throws -> Void) -> String? {
      let outcome = runner.run(timeout: actionSeconds, key: key) { () -> String? in
        do {
          try work()
          return nil
        } catch {
          return String(describing: error)
        }
      }
      guard case .value(let failure) = outcome else { return HelperMonitor.timedOutReason }
      return failure
    }

    func openSystemSettings(_ installer: any HelperInstallerService) {
      _ = runner.run(timeout: statusSeconds, key: HelperMonitor.settingsKey) { installer.openSystemSettings() }
    }
  }

  private func act(
    _ action: HelperInFlight,
    _ work: @escaping @Sendable (any HelperInstallerService, HelperInstallerStatus?) -> HelperTracking.ActionFailure?
  ) async -> HelperMonitorState {
    await serialized { [self] in
      let started = stored.withLock { stored -> HelperMonitorState in
        stored.tracking.begin(action)
        return stored.tracking.state
      }
      onChange(started)
      let installer = installer
      let previous = started.installer
      let failure = await offMain { work(installer, previous) }
      return await settle(read(), actionEnded: true, failure: failure)
    }
  }

  private func read() async -> Reading? {
    let installer = installer
    let port = port
    let calls = BoundedCalls(runner: runner, statusSeconds: statusSeconds, actionSeconds: actionSeconds)
    return await offMain {
      guard let status = calls.status(of: installer) else { return nil }
      let probe = status == .enabled ? port.probe() : nil
      return Reading(installer: status, probe: probe)
    }
  }

  private func settle(
    _ reading: Reading?, actionEnded: Bool = false, failure: HelperTracking.ActionFailure? = nil,
    acknowledged: Bool = false
  ) async -> HelperMonitorState {
    let outcome = stored.withLock { stored -> Outcome in
      let before = stored.tracking.state
      if acknowledged {
        stored.tracking.acknowledge()
      }
      if actionEnded {
        stored.tracking.end(failure: failure)
      }
      if let reading {
        stored.tracking.apply(installer: reading.installer, probe: reading.probe)
      } else {
        stored.tracking.statusUnread(Self.timedOutReason)
      }
      var send: HelperFacts?
      if let facts = stored.tracking.facts, facts != stored.sent {
        stored.sent = facts
        send = facts
      }
      let state = stored.tracking.state
      return Outcome(state: state, changed: state != before, send: send, host: stored.host)
    }
    if outcome.changed {
      onChange(outcome.state)
    }
    if let facts = outcome.send, let host = outcome.host {
      await host.updateHelper(facts)
    }
    return outcome.state
  }

  private func offMain<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value {
    await withCheckedContinuation { continuation in
      calls.async {
        continuation.resume(returning: work())
      }
    }
  }

  private func serialized<Value: Sendable>(_ work: @escaping @Sendable () async -> Value) async -> Value {
    let task = stored.withLock { stored -> Task<Value, Never> in
      let previous = stored.tail
      let next = Task {
        await previous?.value
        return await work()
      }
      stored.tail = Task { _ = await next.value }
      return next
    }
    return await task.value
  }
}
