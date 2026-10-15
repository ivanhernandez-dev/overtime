import Foundation
import OvertimeCore
import os

public enum ToolOutcome: Sendable, Equatable {
  case finished(exitCode: Int32, stdout: String, stderr: String)
  case timedOut
  case launchFailed(String)
}

public protocol ToolPort: Sendable {
  func run(_ executable: String, _ arguments: [String]) -> ToolOutcome
}

public final class ToolCancellation: Sendable {
  private struct State {
    var cancelled = false
    var pid: pid_t?
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  public init() {}

  public var isCancelled: Bool {
    state.withLock { $0.cancelled }
  }

  public func cancel() {
    state.withLock { state in
      state.cancelled = true
      if let pid = state.pid { kill(pid, SIGKILL) }
    }
  }

  func attach(_ pid: pid_t) {
    state.withLock { state in
      state.pid = pid
      if state.cancelled { kill(pid, SIGKILL) }
    }
  }

  func detach() {
    state.withLock { $0.pid = nil }
  }
}

public struct ToolRunner: ToolPort {
  public static let terminateGraceSeconds: Double = 1
  public static let reapWaitSeconds: Double = 1

  public let timeoutSeconds: Double
  public let cancellation: ToolCancellation?

  public init(timeoutSeconds: Double = Timing.systemCallTimeoutSeconds, cancellation: ToolCancellation? = nil) {
    self.timeoutSeconds = timeoutSeconds
    self.cancellation = cancellation
  }

  public func run(_ executable: String, _ arguments: [String]) -> ToolOutcome {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    let deadline = DispatchTime.now() + max(0, timeoutSeconds)
    do {
      try process.run()
    } catch {
      return .launchFailed(String(describing: error))
    }
    cancellation?.attach(process.processIdentifier)
    defer { cancellation?.detach() }
    let stdout = PipeDrain(stdoutPipe.fileHandleForReading)
    let stderr = PipeDrain(stderrPipe.fileHandleForReading)
    guard exited.wait(timeout: deadline) == .success else {
      stop(process, exited: exited)
      return .timedOut
    }
    _ = stdout.wait(until: deadline)
    _ = stderr.wait(until: deadline)
    return .finished(exitCode: process.terminationStatus, stdout: stdout.text(), stderr: stderr.text())
  }

  private func stop(_ process: Process, exited: DispatchSemaphore) {
    process.terminate()
    if exited.wait(timeout: .now() + Self.terminateGraceSeconds) == .success { return }
    let pid = process.processIdentifier
    if process.isRunning, pid > 0 {
      kill(pid, SIGKILL)
    }
    _ = exited.wait(timeout: .now() + Self.reapWaitSeconds)
  }
}

final class PipeDrain: Sendable {
  private let buffer = OSAllocatedUnfairLock(initialState: Data())
  private let done = DispatchSemaphore(value: 0)

  init(_ handle: FileHandle) {
    let thread = Thread { [buffer, done] in
      while true {
        let chunk = handle.availableData
        if chunk.isEmpty { break }
        buffer.withLock { $0.append(chunk) }
      }
      done.signal()
    }
    thread.stackSize = 256 * 1024
    thread.start()
  }

  func wait(until deadline: DispatchTime) -> Bool {
    done.wait(timeout: deadline) == .success
  }

  func text() -> String {
    String(decoding: buffer.withLock { $0 }, as: UTF8.self)
  }
}
