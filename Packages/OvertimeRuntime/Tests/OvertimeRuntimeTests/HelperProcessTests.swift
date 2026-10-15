import Darwin
import Foundation
import Testing

struct HelperProcessTests {
  static let refusal = "overtime-helper must be started by launchd as root\n"
  static let refusalStatus: Int32 = 77

  struct Outcome: Sendable, Equatable {
    var exitedByItself = false
    var status: Int32 = -1
    var output = ""
    var errors = ""
  }

  final class Launch: @unchecked Sendable {
    static let reapSeconds: Double = 5
    static let maxBytes = 65_536

    private let path = ExecutableLocator.url(named: "overtime-helper").path(percentEncoded: false)
    private let process = Process()
    private let output = Pipe()
    private let errors = Pipe()

    func complete(boundSeconds: Double) throws -> Outcome {
      process.executableURL = URL(fileURLWithPath: path)
      process.arguments = []
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = output
      process.standardError = errors
      var outcome = Outcome()
      try process.run()
      outcome.exitedByItself = ProcessProbe.poll(within: boundSeconds) { !process.isRunning }
      if !outcome.exitedByItself {
        ProcessProbe.signalIfOwn(process.processIdentifier, executable: path, signal: SIGKILL)
        _ = ProcessProbe.poll(within: Self.reapSeconds) { !process.isRunning }
      }
      if !process.isRunning, process.terminationReason == .exit {
        outcome.status = process.terminationStatus
      }
      outcome.output = Self.drain(output.fileHandleForReading)
      outcome.errors = Self.drain(errors.fileHandleForReading)
      return outcome
    }

    static func drain(_ handle: FileHandle) -> String {
      let descriptor = handle.fileDescriptor
      _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
      var bytes: [UInt8] = []
      var chunk = [UInt8](repeating: 0, count: 4_096)
      while bytes.count < maxBytes {
        let count = chunk.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
        guard count > 0 else { break }
        bytes.append(contentsOf: chunk[0..<count])
      }
      return String(decoding: bytes, as: UTF8.self)
    }
  }

  static func startAsTheCurrentUser(boundSeconds: Double) async throws -> Outcome {
    let launch = Launch()
    return try await withCheckedThrowingContinuation { continuation in
      Thread.detachNewThread {
        continuation.resume(with: Result { try launch.complete(boundSeconds: boundSeconds) })
      }
    }
  }

  @Test func startedByANormalUserTheHelperRefusesWithOneLineAndStatus77() async throws {
    try #require(getuid() != 0)
    let outcome = try await Self.startAsTheCurrentUser(boundSeconds: 5)
    #expect(outcome.exitedByItself)
    #expect(outcome.status == Self.refusalStatus)
    #expect(outcome.errors == Self.refusal)
    #expect(outcome.output.isEmpty)
  }
}
