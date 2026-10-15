import Darwin
import Foundation
import Testing
import os

final class Unkillable: SpawnedProcesses {
  private let signals = OSAllocatedUnfairLock(initialState: 0)

  var signalCount: Int { signals.withLock { $0 } }

  func signalEnd() {
    signals.withLock { $0 += 1 }
  }

  var survivors: [String] { ["unkillable"] }
}

struct ScopeFailure: Error {}

enum Sleeper {
  static func start() throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["60"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    return process
  }
}

@Suite(.serialized, .processCleanup)
struct ProcessCleanupTests {
  static let testsRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

  static func swiftFiles(under root: URL, containing needle: String, excluding own: String) -> (
    scanned: [String], matching: [String]
  ) {
    guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
      return ([], [])
    }
    let ownPath = URL(fileURLWithPath: own).standardizedFileURL.path
    var scanned: [String] = []
    var matching: [String] = []
    for case let url as URL in walker where url.pathExtension == "swift" {
      guard url.standardizedFileURL.path != ownPath else { continue }
      scanned.append(url.lastPathComponent)
      if let text = try? String(contentsOf: url, encoding: .utf8), text.contains(needle) {
        matching.append(url.lastPathComponent)
      }
    }
    return (scanned, matching)
  }

  @Test func noTestWaitsForAProcessWithWaitUntilExit() async {
    let root = Self.testsRoot
    let own = #filePath
    let waits = await OffPool.run { Self.swiftFiles(under: root, containing: "waitUntilExit", excluding: own) }
    let tracks = await OffPool.run { Self.swiftFiles(under: root, containing: "ProcessCleanup.track(", excluding: own) }
    #expect(waits.scanned.contains("SentinelRelaunchProcessTests.swift"))
    #expect(tracks.matching.contains("SentinelProcessTests.swift"))
    #expect(waits.matching.isEmpty, "\(waits.matching)")
  }

  @Test func endAllKillsAndReapsAProcessLaunchedOnAnotherThread() async throws {
    let tracked = try await OffPool.run { Result { TrackedProcess(try Sleeper.start()) } }.get()
    let pid = tracked.process.processIdentifier
    let cleanup = ProcessCleanup()
    ProcessCleanup.$current.withValue(cleanup) { ProcessCleanup.track(tracked) }
    await cleanup.endAll()
    #expect(!tracked.process.isRunning)
    #expect(ProcessProbe.isGone(pid))
  }

  @Test func endAllReportsASurvivorWithinItsBoundInsteadOfWaitingForIt() async {
    let cleanup = ProcessCleanup()
    let unkillable = Unkillable()
    ProcessCleanup.$current.withValue(cleanup) { ProcessCleanup.track(unkillable) }
    let start = ContinuousClock.now
    await withKnownIssue { await cleanup.endAll(within: 0.2) }
    #expect(ContinuousClock.now - start < .seconds(10))
    #expect(unkillable.signalCount == 1)
  }

  @Test(arguments: [false, true])
  func theTraitEndsWhatATestStartedWhetherOrNotTheTestThrows(_ throwing: Bool) async throws {
    let test = try #require(Test.current)
    let started = OSAllocatedUnfairLock<TrackedProcess?>(initialState: nil)
    var threw = false
    do {
      try await ProcessCleanupTrait().provideScope(for: test, testCase: Test.Case.current) {
        let tracked = TrackedProcess(try Sleeper.start())
        ProcessCleanup.track(tracked)
        started.withLock { $0 = tracked }
        if throwing { throw ScopeFailure() }
      }
    } catch is ScopeFailure {
      threw = true
    }
    #expect(threw == throwing)
    let tracked = try #require(started.withLock { $0 })
    #expect(!tracked.process.isRunning)
    #expect(ProcessProbe.isGone(tracked.process.processIdentifier))
  }

  @Test func aProcessTrackedOutsideTheTraitIsEndedAndReported() async throws {
    let tracked = TrackedProcess(try Sleeper.start())
    ProcessCleanup.$current.withValue(nil) {
      withKnownIssue { ProcessCleanup.track(tracked) }
    }
    #expect(await OffPool.eventually(seconds: ProcessCleanup.boundSeconds) { !tracked.process.isRunning })
  }

  @Test func aFixtureRunListsItsLiveProcessesUntilEndAllHasEndedThem() async throws {
    let cleanup = try #require(ProcessCleanup.current)
    let run = try FixtureRun(["--arm", "--spawn-child"])
    let pids = try #require(await OffPool.run { run.ready() })
    let child = try #require(await OffPool.run { run.child() })
    #expect(run.survivors == ["fixture \(pids.parent)", "sentinel \(pids.sentinel)", "child \(child)"])
    await cleanup.endAll()
    #expect(run.survivors.isEmpty)
    #expect(ProcessProbe.isGone(pids.parent))
  }
}
