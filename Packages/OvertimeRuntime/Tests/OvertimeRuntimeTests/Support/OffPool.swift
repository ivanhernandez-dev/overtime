import Foundation
import os

enum OffPool {
  static func run<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value {
    await withCheckedContinuation { continuation in
      Thread.detachNewThread {
        continuation.resume(returning: work())
      }
    }
  }

  static func bounded<Value: Sendable>(seconds: Double, _ work: @escaping @Sendable () -> Value) async -> Value? {
    await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
      let resumed = OSAllocatedUnfairLock(initialState: false)
      let finish: @Sendable (Value?) -> Void = { value in
        let first = resumed.withLock { done -> Bool in
          guard !done else { return false }
          done = true
          return true
        }
        if first { continuation.resume(returning: value) }
      }
      Thread.detachNewThread {
        finish(work())
      }
      DispatchQueue(label: "OffPool.bound").asyncAfter(deadline: .now() + seconds) {
        finish(nil)
      }
    }
  }

  static func eventually(seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
  }
}
