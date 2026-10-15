import Foundation
import OvertimeCore
import OvertimeSystem
import os

final class HoldRecorder: Sendable {
  enum Entry: Sendable, Equatable {
    case sentinelStart
    case sentinel(String, fileOwnsHold: Bool?)
    case clamshell(on: Bool, fileOwnsHold: Bool?)
    case sentinelClose
    case sentinelRetire
  }

  private let entries = OSAllocatedUnfairLock<[Entry]>(initialState: [])
  let stateFile: URL

  init(stateFile: URL) {
    self.stateFile = stateFile
  }

  var all: [Entry] {
    entries.withLock { $0 }
  }

  func fileOwnsHold() -> Bool? {
    guard case .state(let state) = StateStore.read(at: stateFile) else { return nil }
    return state.ownsHold
  }

  func append(_ entry: Entry) {
    entries.withLock { $0.append(entry) }
  }

  func reset() {
    entries.withLock { $0.removeAll() }
  }
}

final class FakeClamshellPort: ClamshellPort {
  private struct Holds: Sendable {
    var next = 0
    var requested = 0
    var signaled = 0
    var returned = 0
  }

  static let heldSeconds: Double = 120

  private let recorder: HoldRecorder
  private let outcomes = OSAllocatedUnfairLock<[EffectOutcome]>(initialState: [])
  private let blocks = OSAllocatedUnfairLock<[Double]>(initialState: [])
  private let holds = OSAllocatedUnfairLock(initialState: Holds())
  private let gate = DispatchSemaphore(value: 0)

  init(recorder: HoldRecorder) {
    self.recorder = recorder
  }

  var heldWritesReturned: Int {
    holds.withLock { $0.returned }
  }

  func queueOutcomes(_ queued: [EffectOutcome]) {
    outcomes.withLock { $0 += queued }
  }

  func blockNextWrite(seconds: Double) {
    blocks.withLock { $0.append(seconds) }
  }

  func holdNextWrite() {
    holds.withLock {
      $0.next += 1
      $0.requested += 1
    }
  }

  func releaseHeldWrites() {
    let pending = holds.withLock { holds -> Int in
      defer { holds.signaled = holds.requested }
      return holds.requested - holds.signaled
    }
    for _ in 0..<pending {
      gate.signal()
    }
  }

  func write(on: Bool) -> EffectOutcome {
    recorder.append(.clamshell(on: on, fileOwnsHold: recorder.fileOwnsHold()))
    if let seconds = blocks.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) {
      Thread.sleep(forTimeInterval: seconds)
    }
    let held = holds.withLock { holds -> Bool in
      guard holds.next > 0 else { return false }
      holds.next -= 1
      return true
    }
    if held {
      _ = gate.wait(timeout: .now() + Self.heldSeconds)
      holds.withLock { $0.returned += 1 }
    }
    return outcomes.withLock { $0.isEmpty ? .succeeded : $0.removeFirst() }
  }
}
