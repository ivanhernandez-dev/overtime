import Foundation
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import os

public final class NotificationCoordinator: Sendable {
  private let worker: Worker
  private let consumer = OSAllocatedUnfairLock<Consumer?>(initialState: nil)
  private let saved = OSAllocatedUnfairLock<NotificationPolicyState?>(initialState: nil)
  private let tail = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
  private let relaunchHistory: URL?
  private let launchWall: Date?

  public init(
    port: any NotificationPort, preferences: @escaping @Sendable () -> AppPreferences,
    log: @escaping @Sendable (Decision) -> Void, boundSeconds: Double = Timing.systemCallTimeoutSeconds,
    relaunchHistory: URL? = nil, launchWall: Date? = nil,
    sleep: @escaping @Sendable (Double) async -> Void = { await NotificationCoordinator.sleep(seconds: $0) }
  ) {
    worker = Worker(port: port, preferences: preferences, log: log, boundSeconds: boundSeconds, sleep: sleep)
    self.relaunchHistory = relaunchHistory
    self.launchWall = launchWall
  }

  public static func sleep(seconds: Double) async {
    try? await Task.sleep(for: .seconds(seconds))
  }

  public var isRunning: Bool {
    consumer.withLock { $0 != nil }
  }

  public func start(host: any EngineHosting) {
    bind(to: host, relaunchHistory: relaunchHistory)
  }

  public func rebind(to host: any EngineHosting) {
    bind(to: host, relaunchHistory: nil)
  }

  public func preferencesChanged() {
    consumer.withLock { $0?.continuation }?.yield(.preferencesChanged)
  }

  public static func authorization(
    of port: any NotificationPort, boundSeconds: Double = Timing.systemCallTimeoutSeconds
  ) async -> NotificationAuthorization? {
    await bounded(seconds: boundSeconds, fallback: nil) { await port.authorization() }
  }

  static func bounded<T: Sendable>(
    seconds: Double, fallback: T, _ operation: @escaping @Sendable () async -> T
  ) async -> T {
    let result = OSAllocatedUnfairLock<T?>(initialState: nil)
    let finished = await Engine.bounded(seconds: seconds) {
      let value = await operation()
      result.withLock { $0 = value }
    }
    guard finished else { return fallback }
    return result.withLock { $0 } ?? fallback
  }

  private func bind(to host: any EngineHosting, relaunchHistory: URL?) {
    let worker = worker
    let launchWall = launchWall
    let saved = saved
    let (inputs, continuation) = AsyncStream.makeStream(of: Input.self)
    let previous = tail.withLock { $0 }
    let bound = 2 * worker.boundSeconds
    let task = Task {
      if let previous {
        previous.cancel()
        _ = await Engine.bounded(seconds: bound) { await previous.value }
      }
      var state = saved.withLock { $0 }?.carriedToNewEngine() ?? NotificationPolicyState()
      if let relaunchHistory {
        state.sentinelClearPending = RelaunchDetection.wasRelaunched(
          historyAt: relaunchHistory, launchWall: launchWall ?? host.clock.wall())
      }
      let stream = await host.snapshots()
      let forward = Task {
        for await snapshot in stream {
          continuation.yield(.snapshot(snapshot))
        }
        continuation.finish()
      }
      var reminder = ReminderSchedule()
      var latest: EngineSnapshot?
      for await input in inputs {
        guard !Task.isCancelled else { break }
        let woke = input == .deadline
        switch input {
        case .snapshot(let snapshot):
          latest = snapshot
        case .deadline:
          reminder.fired()
        case .preferencesChanged:
          reminder.reloadHours(worker: worker)
        }
        guard let snapshot = latest else { continue }
        state = await worker.handle(
          snapshot, state: state, now: host.clock.mono(), reminderHoursHint: woke ? nil : reminder.hours)
        let kept = state
        saved.withLock { $0 = kept }
        reminder.update(
          state: state, now: host.clock.mono(), refreshHours: woke, worker: worker, continuation: continuation)
      }
      forward.cancel()
      reminder.cancel()
    }
    tail.withLock { $0 = task }
    let replaced = consumer.withLock { current -> Consumer? in
      defer { current = Consumer(task: task, continuation: continuation) }
      return current
    }
    replaced?.task.cancel()
  }

  public func stop() {
    consumer.withLock { current -> Consumer? in
      defer { current = nil }
      return current
    }?.task.cancel()
  }

  struct Consumer: Sendable {
    let task: Task<Void, Never>
    let continuation: AsyncStream<Input>.Continuation
  }

  func handle(_ snapshot: EngineSnapshot, state: NotificationPolicyState, now: Instant) async
    -> NotificationPolicyState
  {
    await worker.handle(snapshot, state: state, now: now)
  }

  enum Input: Sendable, Equatable {
    case snapshot(EngineSnapshot)
    case deadline
    case preferencesChanged
  }

  struct ReminderSchedule {
    private var task: Task<Void, Never>?
    private var deadline: Instant?
    private var cached: (anchor: Instant, hours: Int)?

    var hours: Int? {
      cached?.hours
    }

    mutating func fired() {
      task = nil
      deadline = nil
    }

    mutating func reloadHours(worker: Worker) {
      guard let anchor = cached?.anchor else { return }
      cached = (anchor, worker.preferences().forceReminderHours)
    }

    mutating func update(
      state: NotificationPolicyState, now: Instant, refreshHours: Bool, worker: Worker,
      continuation: AsyncStream<Input>.Continuation
    ) {
      guard let anchor = state.reminderAnchor, state.reminderPostedAnchor != anchor else {
        cancel()
        return
      }
      if refreshHours || cached?.anchor != anchor {
        cached = (anchor, worker.preferences().forceReminderHours)
      }
      guard let hours = cached?.hours, let next = NotificationPolicy.nextDeadline(state, hours: hours) else {
        cancel()
        return
      }
      if next == deadline, task != nil { return }
      cancel()
      deadline = next
      let seconds = Double(next.nanoseconds(since: now)) / 1_000_000_000
      let sleep = worker.sleep
      task = Task {
        await sleep(seconds)
        guard !Task.isCancelled else { return }
        continuation.yield(.deadline)
      }
    }

    mutating func cancel() {
      task?.cancel()
      task = nil
      deadline = nil
    }
  }

  deinit {
    consumer.withLock { $0 }?.task.cancel()
  }

  struct Worker: Sendable {
    let port: any NotificationPort
    let preferences: @Sendable () -> AppPreferences
    let log: @Sendable (Decision) -> Void
    let boundSeconds: Double
    let sleep: @Sendable (Double) async -> Void

    func handle(
      _ snapshot: EngineSnapshot, state: NotificationPolicyState, now: Instant, reminderHoursHint: Int? = nil
    ) async -> NotificationPolicyState {
      var probe = state
      var permissive = AppPreferences()
      permissive.forceReminderHours = reminderHoursHint ?? AppPreferences.forceReminderHoursRange.lowerBound
      let due = NotificationPolicy.step(
        &probe, snapshot: snapshot, preferences: permissive, authorization: .authorized, now: now)
      guard !due.isEmpty else { return probe }
      let authorization =
        await NotificationCoordinator.authorization(of: port, boundSeconds: boundSeconds) ?? .notDetermined
      var next = state
      let intents = NotificationPolicy.step(
        &next, snapshot: snapshot, preferences: preferences(), authorization: authorization, now: now)
      for intent in intents {
        let posted = await bounded(false) { await port.post(intent) }
        let field = DecisionField(key: "category", value: intent.category.rawValue)
        if posted {
          log(Decision(keyword: .warn, verb: "notify", fields: [field]))
        } else {
          log(Decision(keyword: .error, verb: "notify failed", fields: [field]))
        }
      }
      return next
    }

    func bounded<T: Sendable>(_ fallback: T, _ operation: @escaping @Sendable () async -> T) async -> T {
      await NotificationCoordinator.bounded(seconds: boundSeconds, fallback: fallback, operation)
    }
  }
}
