import Darwin
import Foundation
import OvertimeClamshell
import os

public enum SentinelSendResult: Sendable, Equatable {
  case sent
  case lost(errno: Int32)
  case notRunning
}

public enum SentinelRetirement: String, Sendable, Equatable {
  case notRunning
  case exited = "none"
  case terminated = "TERM"
  case killed = "KILL"
}

public enum SentinelLinkError: Error, Equatable {
  case alreadyStarted
  case notReady
}

public final class SentinelLink: @unchecked Sendable {
  private struct Running {
    let process: Process
    let pipe: Pipe
    let descriptor: Int32
  }

  private enum Phase {
    case idle
    case starting
    case running(Running)
    case closed
  }

  public static let readyLine = "READY"
  public static let defaultReadyTimeoutSeconds: Double = 2

  private let executableURL: URL
  private let timeoutSeconds: Int
  private let logURL: URL
  private let extraArguments: [String]
  private let readyTimeoutSeconds: Double
  private let retireClearGraceSeconds: Double
  private let phase = OSAllocatedUnfairLock<Phase>(uncheckedState: .idle)

  public init(
    executableURL: URL, timeoutSeconds: Int, logURL: URL, extraArguments: [String],
    readyTimeoutSeconds: Double = SentinelLink.defaultReadyTimeoutSeconds,
    retireClearGraceSeconds: Double = SentinelLink.defaultRetireClearGraceSeconds
  ) {
    self.executableURL = executableURL
    self.timeoutSeconds = timeoutSeconds
    self.logURL = logURL
    self.extraArguments = extraArguments
    self.readyTimeoutSeconds = readyTimeoutSeconds
    self.retireClearGraceSeconds = retireClearGraceSeconds
  }

  public static func siblingExecutable(named name: String) -> URL {
    let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    return executable.deletingLastPathComponent().appendingPathComponent(name)
  }

  public var processIdentifier: Int32? {
    phase.withLockUnchecked { phase in
      if case .running(let running) = phase { return running.process.processIdentifier }
      return nil
    }
  }

  var writeDescriptor: Int32? {
    phase.withLockUnchecked { phase in
      if case .running(let running) = phase { return running.descriptor }
      return nil
    }
  }

  public func start() throws {
    try phase.withLockUnchecked { phase in
      guard case .idle = phase else { throw SentinelLinkError.alreadyStarted }
      phase = .starting
    }
    signal(SIGPIPE, SIG_IGN)
    let child = Process()
    child.executableURL = executableURL
    child.arguments =
      [
        "--timeout", String(timeoutSeconds), "--parent", String(getpid()), "--log",
        logURL.path(percentEncoded: false),
      ] + extraArguments
    let pipe = Pipe()
    let writeEnd = pipe.fileHandleForWriting.fileDescriptor
    _ = fcntl(writeEnd, F_SETFD, fcntl(writeEnd, F_GETFD) | FD_CLOEXEC)
    _ = fcntl(writeEnd, F_SETFL, fcntl(writeEnd, F_GETFL) | O_NONBLOCK)
    let ready = Pipe()
    let readyEnd = ready.fileHandleForReading.fileDescriptor
    _ = fcntl(readyEnd, F_SETFD, fcntl(readyEnd, F_GETFD) | FD_CLOEXEC)
    child.standardInput = pipe
    child.standardOutput = ready
    child.standardError = FileHandle.nullDevice
    do {
      try child.run()
    } catch {
      phase.withLockUnchecked { $0 = .closed }
      throw error
    }
    let isReady = Self.awaitReady(on: readyEnd, seconds: readyTimeoutSeconds)
    try? ready.fileHandleForReading.close()
    let started = phase.withLockUnchecked { phase -> Bool in
      guard isReady, case .starting = phase else {
        phase = .closed
        return false
      }
      phase = .running(Running(process: child, pipe: pipe, descriptor: writeEnd))
      return true
    }
    guard started else {
      try? pipe.fileHandleForWriting.close()
      if child.isRunning { kill(child.processIdentifier, SIGKILL) }
      throw SentinelLinkError.notReady
    }
  }

  static func awaitReady(on descriptor: Int32, seconds: Double) -> Bool {
    let deadline = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + UInt64(max(0, seconds) * 1e9)
    var received: [UInt8] = []
    let expected = Array((readyLine + "\n").utf8)
    while true {
      let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
      guard now < deadline else { return false }
      var entry = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      let waitMilliseconds = Int32(clamping: (deadline - now) / 1_000_000 + 1)
      let polled = poll(&entry, 1, waitMilliseconds)
      if polled < 0 && errno == EINTR { continue }
      guard polled > 0 else { return false }
      var chunk = [UInt8](repeating: 0, count: 64)
      let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
      if count < 0 && errno == EINTR { continue }
      guard count > 0 else { return false }
      received += chunk[0..<count]
      if received.starts(with: expected) { return true }
      guard received.count < expected.count, expected.starts(with: received) else { return false }
    }
  }

  public func send(_ line: SentinelLine) -> SentinelSendResult {
    phase.withLockUnchecked { phase in
      guard case .running(let running) = phase else { return .notRunning }
      let text = line.rawValue + "\n"
      let length = text.utf8.count
      let written = text.withCString { Darwin.write(running.descriptor, $0, length) }
      if written == length { return .sent }
      if written < 0 { return .lost(errno: errno) }
      return .lost(errno: EAGAIN)
    }
  }

  public func close() {
    phase.withLockUnchecked { phase in
      guard case .running(let running) = phase else { return }
      try? running.pipe.fileHandleForWriting.close()
      phase = .closed
    }
  }

  public static let retireGraceSeconds: Double = 0.5
  public static let defaultRetireClearGraceSeconds = Double(SentinelWatch.defaultClearBudgetSeconds) + 1

  @discardableResult
  public func retire() async -> SentinelRetirement {
    let process = phase.withLockUnchecked { phase -> Process? in
      guard case .running(let running) = phase else { return nil }
      try? running.pipe.fileHandleForWriting.close()
      phase = .closed
      return running.process
    }
    guard let process else { return .notRunning }
    guard process.isRunning else { return .exited }
    let pid = process.processIdentifier
    let grace = Self.isStopped(pid) ? Self.retireGraceSeconds : retireClearGraceSeconds
    kill(pid, SIGTERM)
    if await Self.waitForExit(process, seconds: grace) { return .terminated }
    if process.isRunning { kill(pid, SIGKILL) }
    _ = await Self.waitForExit(process, seconds: Self.retireGraceSeconds)
    return .killed
  }

  static func isStopped(_ pid: pid_t) -> Bool {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
    return info.pbi_status == UInt32(SSTOP)
  }

  static func waitForExit(_ process: Process, seconds: Double) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while process.isRunning {
      guard ContinuousClock.now < deadline else { return false }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return true
  }
}
