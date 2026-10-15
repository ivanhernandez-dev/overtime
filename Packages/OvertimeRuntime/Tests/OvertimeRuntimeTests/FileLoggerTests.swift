import Foundation
import OvertimeCore
import OvertimeSystem
import Testing

struct FileLoggerTests {
  func lines(_ url: URL) throws -> [String] {
    try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
  }

  @Test func rotatesPastTheLimit() throws {
    let temp = try TempDirectory()
    let decision = temp.url.appendingPathComponent("overtimed-shadow.log")
    let error = temp.url.appendingPathComponent("overtimed-shadow-error.log")
    let logger = try FileLogger(decisionLog: decision, errorLog: error, rotateAtBytes: Timing.logRotateBytes)
    let line = String(repeating: "x", count: 1023)
    for _ in 0..<600 {
      logger.write(line)
    }
    let rotated = temp.url.appendingPathComponent("overtimed-shadow.log.1")
    #expect(FileManager.default.fileExists(atPath: rotated.path(percentEncoded: false)))
    let rotatedSize =
      try FileManager.default.attributesOfItem(atPath: rotated.path(percentEncoded: false))[.size] as? Int
    #expect((rotatedSize ?? 0) > Timing.logRotateBytes)
    let currentSize =
      try FileManager.default.attributesOfItem(atPath: decision.path(percentEncoded: false))[.size] as? Int
    #expect((currentSize ?? Int.max) < Timing.logRotateBytes)
    #expect(try lines(decision).allSatisfy { $0 == line })
  }

  @Test func errorLinesGoOnlyToTheErrorFile() throws {
    let temp = try TempDirectory()
    let decision = temp.url.appendingPathComponent("d.log")
    let error = temp.url.appendingPathComponent("e.log")
    let logger = try FileLogger(decisionLog: decision, errorLog: error)
    logger.write("decision one")
    logger.writeError("error one")
    logger.write("decision two")
    #expect(try lines(decision) == ["decision one", "decision two"])
    #expect(try lines(error) == ["error one"])
  }

  @Test func filesAreOwnerReadWriteOnly() throws {
    let temp = try TempDirectory()
    let decision = temp.url.appendingPathComponent("d.log")
    let error = temp.url.appendingPathComponent("e.log")
    let logger = try FileLogger(decisionLog: decision, errorLog: error)
    logger.write("line")
    for url in [decision, error] {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
      #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
  }
}
