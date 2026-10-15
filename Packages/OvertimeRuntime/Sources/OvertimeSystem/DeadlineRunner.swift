import Foundation
import OvertimeCore
import os

public final class DeadlineRunner: Sendable {
  public enum Outcome<T: Sendable>: Sendable {
    case value(T)
    case timedOut
  }

  private struct Outstanding: Sendable {
    var count = 0
    var keys: Set<String> = []
  }

  public static let defaultMaxOutstanding = 16

  private let queue: DispatchQueue
  private let maxOutstanding: Int
  private let outstanding = OSAllocatedUnfairLock(initialState: Outstanding())

  public init(maxOutstanding: Int = DeadlineRunner.defaultMaxOutstanding) {
    queue = DispatchQueue(label: "io.github.ivanhernandez-dev.overtime.deadline-runner", attributes: .concurrent)
    self.maxOutstanding = max(1, maxOutstanding)
  }

  public var outstandingCount: Int {
    outstanding.withLock { $0.count }
  }

  public func isOutstanding(key: String) -> Bool {
    outstanding.withLock { $0.keys.contains(key) }
  }

  public func run<T: Sendable>(
    timeout: Double = Timing.systemCallTimeoutSeconds,
    key: String? = nil,
    _ body: @escaping @Sendable () -> T
  ) -> Outcome<T> {
    switch admitAndRun(timeout: timeout, key: key, body) {
    case .value(let value): .value(value)
    case .timedOut, .notAdmitted: .timedOut
    }
  }

  private func admitAndRun<T: Sendable>(
    timeout: Double,
    key: String?,
    _ body: @escaping @Sendable () -> T
  ) -> Admission<T> {
    let limit = maxOutstanding
    let admitted = outstanding.withLock { outstanding -> Bool in
      guard outstanding.count < limit else { return false }
      if let key {
        guard !outstanding.keys.contains(key) else { return false }
        outstanding.keys.insert(key)
      }
      outstanding.count += 1
      return true
    }
    guard admitted else { return .notAdmitted }
    let box = OSAllocatedUnfairLock<T?>(initialState: nil)
    let done = DispatchSemaphore(value: 0)
    let outstanding = outstanding
    let thread = Thread {
      let value = body()
      box.withLock { $0 = value }
      outstanding.withLock { outstanding in
        outstanding.count -= 1
        if let key { outstanding.keys.remove(key) }
      }
      done.signal()
    }
    thread.stackSize = 512 * 1024
    thread.start()
    if done.wait(timeout: .now() + max(0, timeout)) == .timedOut {
      return .timedOut
    }
    return box.withLock { $0 }.map { .value($0) } ?? .timedOut
  }

  public func perform<T: Sendable>(
    timeout: Double = Timing.systemCallTimeoutSeconds,
    key: String? = nil,
    _ body: @escaping @Sendable () -> T
  ) async -> Outcome<T> {
    await withCheckedContinuation { continuation in
      queue.async {
        continuation.resume(returning: self.run(timeout: timeout, key: key, body))
      }
    }
  }

  public func runIfAdmitted<T: Sendable>(
    timeout: Double = Timing.systemCallTimeoutSeconds,
    key: String? = nil,
    _ body: @escaping @Sendable () -> T
  ) -> Admission<T> {
    admitAndRun(timeout: timeout, key: key, body)
  }

  public func performIfAdmitted<T: Sendable>(
    timeout: Double = Timing.systemCallTimeoutSeconds,
    key: String? = nil,
    _ body: @escaping @Sendable () -> T
  ) async -> Admission<T> {
    await withCheckedContinuation { continuation in
      queue.async {
        continuation.resume(returning: self.runIfAdmitted(timeout: timeout, key: key, body))
      }
    }
  }
}

extension DeadlineRunner {
  public enum Admission<T: Sendable>: Sendable {
    case notAdmitted
    case value(T)
    case timedOut
  }
}

extension DeadlineRunner.Outcome: Equatable where T: Equatable {}

extension DeadlineRunner.Admission: Equatable where T: Equatable {}
