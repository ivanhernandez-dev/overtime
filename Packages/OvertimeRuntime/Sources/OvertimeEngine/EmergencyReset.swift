import Foundation
import OvertimeClamshell
import OvertimeCore
import OvertimeSystem
import os

public enum EmergencyOutcome: Sendable, Equatable {
  case restored(released: Int, helperCleared: Bool)
  case clearFailed(String, helperCleared: Bool)
  case inProgress
}

public protocol EmergencyResetting: Sendable {
  func run() async -> EmergencyOutcome
}

public final class EmergencyReset: EmergencyResetting {
  public static let queueLabel = "io.github.ivanhernandez-dev.overtime.emergency"
  public static let clearRunnerKey = "emergency"
  public static let assertionRunnerKey = "emergency-assertion"
  public static let helperRunnerKey = "emergency-helper"
  public static let openFailedCode: Int32 = -1
  static let timedOutReason = "timedOut"

  private let opener: @Sendable () throws -> any ClamshellSelector
  private let registry: AssertionRegistry
  private let release: @Sendable (UInt32) -> Int32
  private let log: @Sendable (Decision) -> Void
  private let helperClear: (@Sendable () -> Bool)?
  private let runner: DeadlineRunner
  private let timeoutSeconds: Double
  private let queue = DispatchQueue(label: EmergencyReset.queueLabel)
  private let running = OSAllocatedUnfairLock(initialState: false)

  public init(
    opener: @escaping @Sendable () throws -> any ClamshellSelector,
    registry: AssertionRegistry,
    release: @escaping @Sendable (UInt32) -> Int32,
    log: @escaping @Sendable (Decision) -> Void,
    runner: DeadlineRunner = DeadlineRunner(),
    timeoutSeconds: Double = Timing.systemCallTimeoutSeconds,
    helperClear: (@Sendable () -> Bool)? = nil
  ) {
    self.opener = opener
    self.registry = registry
    self.release = release
    self.log = log
    self.helperClear = helperClear
    self.runner = runner
    self.timeoutSeconds = timeoutSeconds
  }

  public func run() async -> EmergencyOutcome {
    let admitted = running.withLock { running -> Bool in
      guard !running else { return false }
      running = true
      return true
    }
    guard admitted else { return .inProgress }
    return await withCheckedContinuation { continuation in
      queue.async {
        let outcome = self.perform()
        self.running.withLock { $0 = false }
        continuation.resume(returning: outcome)
      }
    }
  }

  private func perform() -> EmergencyOutcome {
    let helperCleared = clearHelper()
    let clear = clearClamshell()
    let released = releaseAssertions()
    guard case .cleared = clear else {
      var fields = [DecisionField(key: "clear", value: clear.isTimeout ? Self.timedOutReason : "failed")]
      if case .failed(let code) = clear {
        fields.append(DecisionField(key: "code", value: String(code)))
      }
      fields.append(DecisionField(key: "released", value: String(released)))
      log(Decision(keyword: .error, verb: "emergency", fields: fields))
      return .clearFailed(clear.reason, helperCleared: helperCleared)
    }
    log(
      Decision(
        keyword: .hold, verb: "emergency",
        fields: [
          DecisionField(key: "clear", value: "succeeded"),
          DecisionField(key: "released", value: String(released)),
        ]))
    return .restored(released: released, helperCleared: helperCleared)
  }

  private func clearHelper() -> Bool {
    guard let helperClear else { return true }
    let outcome = runner.run(timeout: timeoutSeconds, key: Self.helperRunnerKey) { helperClear() }
    guard outcome != .value(true) else { return true }
    let reason = outcome == .timedOut ? Self.timedOutReason : "failed"
    log(Decision(keyword: .error, verb: "emergency helper", fields: [DecisionField(key: "clear", value: reason)]))
    return false
  }

  private enum ClearResult {
    case cleared
    case failed(Int32)
    case timedOut

    var isTimeout: Bool {
      if case .timedOut = self { return true }
      return false
    }

    var reason: String {
      switch self {
      case .cleared: ""
      case .failed(let code): String(code)
      case .timedOut: EmergencyReset.timedOutReason
      }
    }
  }

  private func clearClamshell() -> ClearResult {
    let opener = opener
    let outcome = runner.run(timeout: timeoutSeconds, key: Self.clearRunnerKey) { () -> Int32 in
      let writer: any ClamshellSelector
      do {
        writer = try opener()
      } catch ClamshellWriterError.openFailed(let code) {
        return code
      } catch {
        return Self.openFailedCode
      }
      return writer.write(on: false)
    }
    switch outcome {
    case .value(KERN_SUCCESS): return .cleared
    case .value(let code): return .failed(code)
    case .timedOut: return .timedOut
    }
  }

  private func releaseAssertions() -> Int {
    var released = 0
    let release = release
    for (kind, id) in registry.snapshot() {
      let outcome = runner.run(timeout: timeoutSeconds, key: Self.assertionRunnerKey) { release(id) }
      guard case .value(0) = outcome else { continue }
      registry.remove(kind, ifID: id)
      released += 1
    }
    return released
  }
}
