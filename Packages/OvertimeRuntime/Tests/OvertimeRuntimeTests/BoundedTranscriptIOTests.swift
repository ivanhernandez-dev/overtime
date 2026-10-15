import Darwin
import Foundation
import OvertimeCore
import OvertimeEngine
import Testing

@testable import OvertimeSystem

struct BoundedTranscriptIOTests {
  @Test func aFifoIsRefusedWithoutBlocking() throws {
    let temp = try TempDirectory()
    let fifo = temp.url.appendingPathComponent("session.jsonl").path(percentEncoded: false)
    try #require(mkfifo(fifo, 0o600) == 0)
    let outcome = DeadlineRunner().run(timeout: 2) { TranscriptHeaderReader.readHeader(at: fifo) }
    #expect(outcome == .value(nil))
    #expect(TranscriptHeaderReader().entrypoint(forFileAt: fifo) == nil)
  }

  @Test func aSymlinkIsNotFollowed() throws {
    let temp = try TempDirectory()
    let target = temp.url.appendingPathComponent("real.jsonl")
    try Data(#"{"entrypoint":"cli"}"#.utf8).write(to: target)
    let link = temp.url.appendingPathComponent("link.jsonl").path(percentEncoded: false)
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target.path(percentEncoded: false))
    #expect(TranscriptHeaderReader.readHeader(at: link) == nil)
    #expect(
      TranscriptHeaderReader.readHeader(at: target.path(percentEncoded: false)) == Array(#"{"entrypoint":"cli"}"#.utf8))
  }

  @Test func aFileReplacedAfterItsLstatIsIgnored() throws {
    let temp = try TempDirectory()
    let path = temp.url.appendingPathComponent("a.jsonl").path(percentEncoded: false)
    try Data(#"{"entrypoint":"cli"}"#.utf8).write(to: URL(fileURLWithPath: path))
    var info = stat()
    try #require(lstat(path, &info) == 0)
    #expect(TranscriptHeaderReader.readHeader(at: path, expecting: (info.st_dev, UInt64(info.st_ino))) != nil)
    #expect(TranscriptHeaderReader.readHeader(at: path, expecting: (info.st_dev, UInt64(info.st_ino) + 1)) == nil)
  }

  @Test func theScannerStopsAfterItsEntryBudget() throws {
    let temp = try TempDirectory()
    for index in 0..<6 {
      try Data("{}".utf8).write(to: temp.url.appendingPathComponent("s\(index).jsonl"))
    }
    let clock = FakeClock(wall: Date().addingTimeInterval(1))
    let unbounded = TranscriptScanner(roots: [temp.path]).recentActivity(withinSeconds: 600, clock: clock)
    #expect(unbounded.count == 6)
    let bounded = TranscriptScanner(roots: [temp.path], maxEntries: 2).recentActivity(withinSeconds: 600, clock: clock)
    #expect(bounded.count == 2)
  }

  @Test func aHungTranscriptSeedIsBoundedAndLogged() async throws {
    let interpreter = CapturingInterpreter()
    let release = DispatchSemaphore(value: 0)
    let engine = Engine(
      mode: .shadow,
      settings: Settings(),
      clock: FakeClock(),
      interpreter: interpreter,
      sources: EngineSources(
        transcriptSeed: {
          _ = release.wait(timeout: .now() + 12)
          return []
        },
        sampleTick: { TickFacts(fullWake: true) },
        rootHealth: {
          _ = release.wait(timeout: .now() + 12)
          return []
        }),
      sampleTimeoutSeconds: 0.2
    )
    let started = ContinuousClock.now
    await engine.runOnce()
    let elapsed = ContinuousClock.now - started
    release.signal()
    release.signal()
    #expect(elapsed < .seconds(6), "both reads are cut at the 0.2 s bound, not at the 12 s hang")
    let errors = interpreter.recorded.flatMap { $0 }.compactMap { effect -> String? in
      guard case .log(let decision) = effect, decision.keyword == .error else { return nil }
      return decision.verb
    }
    #expect(errors.contains("transcript seed timedOut"))
    #expect(errors.contains("transcript roots timedOut"))
  }
}
