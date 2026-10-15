import Darwin
import Foundation
import OvertimeClamshell
import OvertimeEngine
import OvertimeSystem
import os

final class FakeSentinelPort: SentinelPort {
  enum StartFailure: Error {
    case refused
  }

  private struct Script: Sendable {
    var results: [String: [SentinelSendResult]] = [:]
    var failStart = false
    var startQueueLabel: String?
    var retirement = SentinelRetirement.terminated
    var dead = false
    var delivered: [String] = []
    var closed = false
    var holdStart = false
    var holdRetire = false
    var released = false
    var heldReturned = 0
  }

  static let heldSeconds: Double = 120

  private let recorder: HoldRecorder
  private let script = OSAllocatedUnfairLock(initialState: Script())
  private let startGate = DispatchSemaphore(value: 0)

  init(recorder: HoldRecorder) {
    self.recorder = recorder
  }

  func holdNextStart() {
    script.withLock { $0.holdStart = true }
  }

  func holdNextRetire() {
    script.withLock { $0.holdRetire = true }
  }

  func releaseHeld() {
    let signal = script.withLock { script -> Bool in
      defer { script.released = true }
      return !script.released
    }
    if signal { startGate.signal() }
  }

  var heldReturned: Int {
    script.withLock { $0.heldReturned }
  }

  func queue(_ result: SentinelSendResult, for line: SentinelLine) {
    script.withLock { $0.results[line.rawValue, default: []].append(result) }
  }

  func refuseStart() {
    script.withLock { $0.failStart = true }
  }

  func retireAs(_ retirement: SentinelRetirement) {
    script.withLock { $0.retirement = retirement }
  }

  var startQueueLabel: String? {
    script.withLock { $0.startQueueLabel }
  }

  var delivered: [String] {
    script.withLock { $0.delivered }
  }

  var closed: Bool {
    script.withLock { $0.closed }
  }

  var armedWhenClosed: Bool {
    script.withLock { script in
      script.closed && script.delivered.last { $0 == "ARM" || $0 == "DISARM" } == "ARM"
    }
  }

  func start() throws {
    let label = String(cString: __dispatch_queue_get_label(nil))
    let held = script.withLock { script -> Bool in
      script.startQueueLabel = label
      defer { script.holdStart = false }
      return script.holdStart
    }
    if held {
      _ = startGate.wait(timeout: .now() + Self.heldSeconds)
      script.withLock { $0.heldReturned += 1 }
    }
    if script.withLock({ $0.failStart }) { throw StartFailure.refused }
    recorder.append(.sentinelStart)
  }

  func send(_ line: SentinelLine) -> SentinelSendResult {
    recorder.append(.sentinel(line.rawValue, fileOwnsHold: recorder.fileOwnsHold()))
    return script.withLock { script in
      guard !script.dead else { return .lost(errno: EPIPE) }
      var result = SentinelSendResult.sent
      if var queued = script.results[line.rawValue], !queued.isEmpty {
        result = queued.removeFirst()
        script.results[line.rawValue] = queued
      }
      if result == .lost(errno: EPIPE) { script.dead = true }
      if result == .sent { script.delivered.append(line.rawValue) }
      return result
    }
  }

  func close() {
    script.withLock { $0.closed = true }
    recorder.append(.sentinelClose)
  }

  func retire() async -> SentinelRetirement {
    recorder.append(.sentinelRetire)
    let (retirement, held) = script.withLock { script -> (SentinelRetirement, Bool) in
      script.closed = true
      defer { script.holdRetire = false }
      return (script.retirement, script.holdRetire)
    }
    if held {
      let deadline = ContinuousClock.now + .seconds(Self.heldSeconds)
      while !script.withLock({ $0.released }), ContinuousClock.now < deadline {
        do { try await Task.sleep(for: .milliseconds(20)) } catch { break }
      }
      script.withLock { $0.heldReturned += 1 }
    }
    return retirement
  }
}
