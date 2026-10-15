import Darwin
import Foundation
import Testing
import os

final class RespawnFixtureRun: SpawnedProcesses, @unchecked Sendable {
  let process = Process()
  let temp: TempDirectory
  let sentinelPath = ExecutableLocator.url(named: "overtime-sentinel").path(percentEncoded: false)
  private let output = OSAllocatedUnfairLock(initialState: [UInt8]())

  init(pause: String, oldClearFails: Bool) throws {
    temp = try TempDirectory()
    process.executableURL = ExecutableLocator.url(named: "SentinelHolderFixture")
    process.arguments =
      ["respawn", "--sentinel", sentinelPath, "--dir", temp.path, "--pause", pause]
      + (oldClearFails ? ["--old-clear-fails"] : [])
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    pipe.fileHandleForReading.readabilityHandler = { [output] handle in
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
        return
      }
      output.withLock { $0.append(contentsOf: data) }
    }
    try process.run()
    ProcessCleanup.track(self)
  }

  var lines: [String] {
    let text = output.withLock { String(decoding: $0, as: UTF8.self) }
    return text.split(separator: "\n").map(String.init)
  }

  func waitFor(_ line: String, within seconds: Double) -> Bool {
    ProcessProbe.poll(within: seconds) { lines.contains(line) }
  }

  var sentinelPIDs: [pid_t] {
    lines.compactMap { line in
      let parts = line.split(separator: " ")
      guard parts.count == 3, parts[0] == "SENTINEL" else { return nil }
      return pid_t(parts[2])
    }
  }

  func file(_ name: String) -> String {
    (try? String(contentsOf: temp.url.appendingPathComponent(name), encoding: .utf8)) ?? ""
  }

  var clears: Int {
    ["old.record", "fresh.record", "missing/old.record"].reduce(0) { count, name in
      count + file(name).split(separator: "\n").filter { $0.hasPrefix("clear ") }.count
    }
  }

  func killHolder() {
    guard process.isRunning else { return }
    kill(process.processIdentifier, SIGKILL)
  }

  func signalEnd() {
    killHolder()
    for pid in sentinelPIDs where pid > 1 {
      ProcessProbe.signalIfOwn(pid, executable: sentinelPath, signal: SIGKILL)
    }
  }

  var survivors: [String] {
    let holder = process.isRunning ? ["holder \(process.processIdentifier)"] : []
    let sentinels = sentinelPIDs.filter { $0 > 1 && !ProcessProbe.hasEnded($0, executable: sentinelPath) }
    return holder + sentinels.map { "sentinel \($0)" }
  }
}

@Suite(.serialized, .processCleanup)
struct RespawnKillTests {
  static let eventSeconds = SentinelProcessTests.eventSeconds
  @Test(arguments: ["starting", "ready", "armed", "done"])
  func aHolderKilledAtAnyPointOfARespawnLeavesAnArmedSentinelThatClears(_ pause: String) throws {
    let run = try RespawnFixtureRun(pause: pause, oldClearFails: false)
    try #require(run.waitFor("PAUSED \(pause)", within: 10))
    let before = run.clears
    run.killHolder()
    #expect(ProcessProbe.poll(within: Self.eventSeconds) { run.clears > before })
    #expect(ProcessProbe.poll(within: Self.eventSeconds) { run.sentinelPIDs.allSatisfy { ProcessProbe.isGone($0) } })
  }

  @Test func aHolderKilledWhileTheOldSentinelsClearKeepsFailingLeavesTheArmedReplacementToClear() throws {
    let run = try RespawnFixtureRun(pause: "retiring", oldClearFails: true)
    try #require(run.waitFor("PAUSED retiring", within: 10))
    try #require(ProcessProbe.poll(within: Self.eventSeconds) { run.file("old.log").contains(" retry") })
    run.killHolder()
    #expect(ProcessProbe.poll(within: Self.eventSeconds) { run.file("fresh.record").contains("clear eof") })
    #expect(run.file("fresh.log").contains(" armed"))
  }

  @Test func aRespawnRunListsItsLiveHolderAndSentinelUntilEndAllHasEndedThem() async throws {
    let cleanup = try #require(ProcessCleanup.current)
    let run = try RespawnFixtureRun(pause: "armed", oldClearFails: false)
    try #require(await OffPool.run { run.waitFor("PAUSED armed", within: 10) })
    let alive = run.survivors
    #expect(alive.first == "holder \(run.process.processIdentifier)")
    #expect(alive.contains { $0.hasPrefix("sentinel ") })
    await cleanup.endAll()
    #expect(run.survivors.isEmpty)
  }
}
