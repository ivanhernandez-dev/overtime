import Foundation
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing
import os

struct LoggerMirrorTests {
  final class Mirror: Sendable {
    private let lines = OSAllocatedUnfairLock<[String]>(initialState: [])

    var sink: @Sendable (String) -> Void {
      { line in self.lines.withLock { $0.append(line) } }
    }

    var all: [String] {
      lines.withLock { $0 }
    }
  }

  struct Fixture {
    let temp: TempDirectory
    let decisionLog: URL
    let errorLog: URL
    let mirror = Mirror()
    let logger: FileLogger
    let wall = Date(timeIntervalSince1970: 1_790_000_000)
    let zone = TimeZone(secondsFromGMT: 0)!

    init(rotateAtBytes: Int = Timing.logRotateBytes) throws {
      temp = try TempDirectory()
      decisionLog = temp.url.appendingPathComponent("overtimed.log")
      errorLog = temp.url.appendingPathComponent("overtimed-error.log")
      logger = try FileLogger(
        decisionLog: decisionLog, errorLog: errorLog, rotateAtBytes: rotateAtBytes, errorMirror: mirror.sink)
    }

    func lines(_ url: URL) -> [String] {
      guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
      return text.split(separator: "\n").map(String.init)
    }

    func size(_ url: URL) -> Int {
      (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? Int) ?? 0
    }

    func exists(_ url: URL) -> Bool {
      FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }
  }

  @Test func aNonErrorDecisionGoesOnlyToTheDecisionLog() throws {
    let fixture = try Fixture()
    let want = Decision(keyword: .want, verb: "on", fields: [DecisionField(key: "reason", value: "busy")])
    fixture.logger.log(want, wall: fixture.wall, timeZone: fixture.zone)
    #expect(
      fixture.lines(fixture.decisionLog) == [DecisionFormatter.line(want, wall: fixture.wall, timeZone: fixture.zone)])
    #expect(fixture.lines(fixture.errorLog).isEmpty)
    #expect(fixture.mirror.all.isEmpty)
  }

  @Test func anErrorDecisionGoesToBothLogsAndTheMirror() throws {
    let fixture = try Fixture()
    let error = Decision(keyword: .error, verb: "hold failed", fields: [DecisionField(key: "code", value: "5")])
    fixture.logger.log(error, wall: fixture.wall, timeZone: fixture.zone)
    let line = DecisionFormatter.line(error, wall: fixture.wall, timeZone: fixture.zone)
    #expect(fixture.lines(fixture.decisionLog) == [line])
    #expect(fixture.lines(fixture.errorLog) == [line])
    #expect(fixture.mirror.all == [line])
  }

  @Test func anErrorWithNoFieldsIsACompleteLineInBothLogs() throws {
    let fixture = try Fixture()
    let error = Decision(keyword: .error, verb: "sampler timedOut")
    fixture.logger.log(error, wall: fixture.wall, timeZone: fixture.zone)
    let expected = DecisionFormatter.line(error, wall: fixture.wall, timeZone: fixture.zone)
    #expect(expected.hasSuffix(" ERROR sampler timedOut"))
    #expect(fixture.lines(fixture.decisionLog) == [expected])
    #expect(fixture.lines(fixture.errorLog) == [expected])
  }

  @Test func errorLinesKeepReducerOrderThroughTheInterpreter() async throws {
    let fixture = try Fixture()
    let interpreter = RecordingInterpreter(logger: fixture.logger, timeZone: fixture.zone)
    _ = await interpreter.perform(
      [
        .log(Decision(keyword: .error, verb: "a")),
        .log(Decision(keyword: .want, verb: "on")),
        .log(Decision(keyword: .error, verb: "b")),
      ], wall: fixture.wall)
    let errors = fixture.lines(fixture.errorLog)
    #expect(errors.count == 2)
    #expect(errors.first?.hasSuffix(" ERROR a") == true)
    #expect(errors.last?.hasSuffix(" ERROR b") == true)
    let decisions = fixture.lines(fixture.decisionLog)
    #expect(
      decisions.map { $0.split(separator: " ").dropFirst().joined(separator: " ") } == [
        "ERROR a", "WANT on", "ERROR b",
      ])
  }

  @Test func concurrentWritersNeverInterleaveWithinALine() async throws {
    let fixture = try Fixture()
    let logger = fixture.logger
    let wall = fixture.wall
    let zone = fixture.zone
    await withTaskGroup(of: Void.self) { group in
      for writer in 0..<8 {
        group.addTask {
          for index in 0..<100 {
            let decision = Decision(
              keyword: writer.isMultiple(of: 2) ? .error : .want, verb: "line",
              fields: [
                DecisionField(key: "writer", value: String(writer)), DecisionField(key: "index", value: String(index)),
              ])
            logger.log(decision, wall: wall, timeZone: zone)
          }
        }
      }
    }
    let lines = fixture.lines(fixture.decisionLog)
    #expect(lines.count == 800)
    var seen = Set<String>()
    for line in lines {
      let parts = line.split(separator: " ")
      #expect(parts.count == 5)
      #expect(parts[2] == "line")
      seen.insert(parts[3...].joined(separator: " "))
    }
    #expect(seen.count == 800)
    #expect(fixture.lines(fixture.errorLog).count == 400)
  }

  @Test func theErrorLogRotatesOnTheFirstWriteAfterPassingTheLimit() throws {
    let fixture = try Fixture(rotateAtBytes: 1_024)
    let rotated = URL(fileURLWithPath: fixture.errorLog.path(percentEncoded: false) + ".1")
    let error = Decision(
      keyword: .error, verb: "x", fields: [DecisionField(key: "pad", value: String(repeating: "p", count: 60))])
    while fixture.size(fixture.errorLog) <= 1_024 {
      fixture.logger.log(error, wall: fixture.wall, timeZone: fixture.zone)
      #expect(!fixture.exists(rotated))
    }
    #expect(!fixture.exists(rotated))
    fixture.logger.log(error, wall: fixture.wall, timeZone: fixture.zone)
    #expect(fixture.exists(rotated))
    #expect(fixture.lines(fixture.errorLog).count == 1)
  }
}
