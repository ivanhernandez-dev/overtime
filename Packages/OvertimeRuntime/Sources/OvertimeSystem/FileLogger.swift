import Foundation
import OvertimeCore
import os

public enum FileLoggerError: Error, Equatable {
  case open(path: String, errno: Int32)
}

public final class FileLogger: Sendable {
  private struct Channel: Sendable {
    var path: String
    var descriptor: Int32
  }

  private struct Channels: Sendable {
    var decision: Channel
    var error: Channel
  }

  public static let logSubsystem = "io.github.ivanhernandez-dev.overtime"

  public static let consoleMirror: @Sendable (String) -> Void = { line in
    Logger(subsystem: logSubsystem, category: "decisions").error("\(line, privacy: .public)")
  }

  private let channels: OSAllocatedUnfairLock<Channels>
  private let rotateAtBytes: Int
  private let errorMirror: (@Sendable (String) -> Void)?

  public init(
    decisionLog: URL,
    errorLog: URL,
    rotateAtBytes: Int = Timing.logRotateBytes,
    errorMirror: (@Sendable (String) -> Void)? = FileLogger.consoleMirror
  ) throws {
    let decisionPath = decisionLog.path(percentEncoded: false)
    let errorPath = errorLog.path(percentEncoded: false)
    let decision = try FileLogger.openAppending(decisionPath)
    let errorDescriptor: Int32
    do {
      errorDescriptor = try FileLogger.openAppending(errorPath)
    } catch {
      close(decision)
      throw error
    }
    self.rotateAtBytes = rotateAtBytes
    self.errorMirror = errorMirror
    self.channels = OSAllocatedUnfairLock(
      initialState: Channels(
        decision: Channel(path: decisionPath, descriptor: decision),
        error: Channel(path: errorPath, descriptor: errorDescriptor)
      ))
  }

  deinit {
    channels.withLock { channels in
      if channels.decision.descriptor >= 0 { close(channels.decision.descriptor) }
      if channels.error.descriptor >= 0 { close(channels.error.descriptor) }
    }
  }

  public func log(_ decision: Decision, wall: Date, timeZone: TimeZone) {
    let line = DecisionFormatter.line(decision, wall: wall, timeZone: timeZone)
    let isError = decision.keyword == .error
    let limit = rotateAtBytes
    channels.withLock { channels in
      FileLogger.append(line, to: &channels.decision, rotateAtBytes: limit)
      if isError {
        FileLogger.append(line, to: &channels.error, rotateAtBytes: limit)
      }
    }
    if isError {
      errorMirror?(line)
    }
  }

  public func write(_ line: String) {
    let limit = rotateAtBytes
    channels.withLock { channels in
      FileLogger.append(line, to: &channels.decision, rotateAtBytes: limit)
    }
  }

  public func writeError(_ line: String) {
    let limit = rotateAtBytes
    channels.withLock { channels in
      FileLogger.append(line, to: &channels.error, rotateAtBytes: limit)
    }
  }

  private static func openAppending(_ path: String) throws -> Int32 {
    let descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw FileLoggerError.open(path: path, errno: errno) }
    _ = fchmod(descriptor, 0o600)
    return descriptor
  }

  private static func append(_ line: String, to channel: inout Channel, rotateAtBytes: Int) {
    if channel.descriptor >= 0 {
      var info = stat()
      if fstat(channel.descriptor, &info) == 0, Int(info.st_size) > rotateAtBytes,
        rename(channel.path, channel.path + ".1") == 0
      {
        close(channel.descriptor)
        channel.descriptor = -1
      }
    }
    if channel.descriptor < 0 {
      guard let reopened = try? openAppending(channel.path) else { return }
      channel.descriptor = reopened
    }
    let bytes = Array((line.hasSuffix("\n") ? line : line + "\n").utf8)
    _ = bytes.withUnsafeBytes { buffer in
      Darwin.write(channel.descriptor, buffer.baseAddress, buffer.count)
    }
  }
}
