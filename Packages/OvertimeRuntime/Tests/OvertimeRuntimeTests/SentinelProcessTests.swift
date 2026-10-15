import Darwin
import Foundation
import Testing
import os

enum ProcessProbe {
  static func uptime() -> Double {
    Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9
  }

  static func poll(within seconds: Double, _ condition: () -> Bool) -> Bool {
    let deadline = uptime() + seconds
    while true {
      if condition() { return true }
      if uptime() >= deadline { return false }
      usleep(50_000)
    }
  }

  static func isGone(_ pid: pid_t) -> Bool {
    kill(pid, 0) == -1 && errno == ESRCH
  }

  static func executablePath(of pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard count > 0 else { return nil }
    return String(decoding: buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  static func canonical(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().path(percentEncoded: false)
  }

  static func signalIfOwn(_ pid: pid_t, executable: String, signal: Int32) {
    guard pid > 1, let actual = executablePath(of: pid), canonical(actual) == canonical(executable) else { return }
    kill(pid, signal)
  }

  static func hasEnded(_ pid: pid_t, executable: String) -> Bool {
    guard let actual = executablePath(of: pid) else { return true }
    return canonical(actual) != canonical(executable)
  }

  static let isolationCheckLevel = ["SWIFT_UNEXPECTED_EXECUTOR_LOG_LEVEL": "2"]

  static var environmentWithTrappingIsolationChecks: [String: String] {
    ProcessInfo.processInfo.environment.merging(isolationCheckLevel) { _, strict in strict }
  }
}

final class FixtureRun: SpawnedProcesses, @unchecked Sendable {
  let process = Process()
  let temp: TempDirectory
  let recordPath: String
  let logPath: String
  let sentinelPath = ExecutableLocator.url(named: "overtime-sentinel").path(percentEncoded: false)
  private let output = OSAllocatedUnfairLock(initialState: [UInt8]())
  private var sentinelPid: pid_t = 0
  private var childPid: pid_t = 0

  init(
    _ flags: [String], in directory: TempDirectory? = nil, executable: URL? = nil, launcher: [String] = [],
    sourceLocation: SourceLocation = #_sourceLocation
  ) throws {
    temp = try directory ?? TempDirectory()
    recordPath = temp.url.appendingPathComponent("record").path(percentEncoded: false)
    logPath = temp.url.appendingPathComponent("sentinel.log").path(percentEncoded: false)
    let program = executable ?? ExecutableLocator.url(named: "SentinelHolderFixture")
    let arguments = ["--sentinel", sentinelPath, "--record", recordPath, "--log", logPath] + flags
    if let tool = launcher.first {
      process.executableURL = URL(fileURLWithPath: tool)
      process.arguments = Array(launcher.dropFirst()) + [program.path(percentEncoded: false)] + arguments
    } else {
      process.executableURL = program
      process.arguments = arguments
    }
    process.environment = ProcessProbe.environmentWithTrappingIsolationChecks
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
    ProcessCleanup.track(self, sourceLocation: sourceLocation)
  }

  var lines: [String] {
    let text = output.withLock { String(decoding: $0, as: UTF8.self) }
    return text.split(separator: "\n").map(String.init)
  }

  func line(startingWith prefix: String, within seconds: Double) -> String? {
    var found: String?
    _ = ProcessProbe.poll(within: seconds) {
      found = lines.first { $0.hasPrefix(prefix) }
      return found != nil
    }
    return found
  }

  func ready() -> (parent: pid_t, sentinel: pid_t)? {
    guard let line = line(startingWith: "READY ", within: 5) else { return nil }
    var values: [String: pid_t] = [:]
    for field in line.split(separator: " ").dropFirst() {
      let pair = field.split(separator: "=")
      if pair.count == 2, let pid = pid_t(pair[1]) { values[String(pair[0])] = pid }
    }
    guard let parent = values["parent"], let sentinel = values["sentinel"], sentinel > 1 else { return nil }
    sentinelPid = sentinel
    return (parent, sentinel)
  }

  func child() -> pid_t? {
    guard let line = line(startingWith: "CHILD ", within: 5), let pid = pid_t(line.dropFirst("CHILD ".count)) else {
      return nil
    }
    childPid = pid
    return pid
  }

  func signalFixture(_ signal: Int32) {
    guard process.isRunning else { return }
    kill(process.processIdentifier, signal)
  }

  func signalSentinel(_ signal: Int32) {
    ProcessProbe.signalIfOwn(sentinelPid, executable: sentinelPath, signal: signal)
  }

  var record: String {
    (try? String(contentsOfFile: recordPath, encoding: .utf8)) ?? ""
  }

  var log: String {
    (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
  }

  func signalEnd() {
    if process.isRunning {
      kill(process.processIdentifier, SIGCONT)
      kill(process.processIdentifier, SIGKILL)
    }
    if sentinelPid > 1 { ProcessProbe.signalIfOwn(sentinelPid, executable: sentinelPath, signal: SIGKILL) }
    if childPid > 1 { ProcessProbe.signalIfOwn(childPid, executable: "/bin/sleep", signal: SIGKILL) }
  }

  var survivors: [String] {
    var alive: [String] = []
    if process.isRunning { alive.append("fixture \(process.processIdentifier)") }
    if sentinelPid > 1 && !ProcessProbe.hasEnded(sentinelPid, executable: sentinelPath) {
      alive.append("sentinel \(sentinelPid)")
    }
    if childPid > 1 && !ProcessProbe.hasEnded(childPid, executable: "/bin/sleep") { alive.append("child \(childPid)") }
    return alive
  }
}

@Suite(.serialized, .processCleanup)
struct SentinelProcessTests {
  static let eventSeconds: Double = 10

  @Test func killNineOfArmedHolderClearsWithinOneSecond() throws {
    let run = try FixtureRun(["--arm"])
    let pids = try #require(run.ready())
    try #require(pids.parent == run.process.processIdentifier)
    run.signalFixture(SIGKILL)
    #expect(ProcessProbe.poll(within: Self.eventSeconds) { run.record.contains("clear eof") })
    #expect(ProcessProbe.poll(within: Self.eventSeconds) { ProcessProbe.isGone(pids.sentinel) })
    #expect(run.log.contains(" start "))
    #expect(run.log.contains(" armed"))
    #expect(run.log.contains(" clear eof kr=0"))
    #expect(run.log.contains(" exit "))
  }

  @Test func stoppedHolderTimesOutAndIsTerminated() throws {
    let run = try FixtureRun(["--arm", "--timeout", "2"])
    let pids = try #require(run.ready())
    try #require(ProcessProbe.poll(within: Self.eventSeconds) { run.log.contains(" armed") })
    run.signalFixture(SIGSTOP)
    #expect(ProcessProbe.poll(within: 4) { run.record.contains("clear heartbeat-timeout") })
    #expect(ProcessProbe.poll(within: 3) { !run.process.isRunning })
    #expect(run.process.terminationReason == .uncaughtSignal)
    #expect(run.log.contains(" parentTerm"))
    #expect(ProcessProbe.poll(within: 3) { ProcessProbe.isGone(pids.sentinel) })
  }

  @Test func aHolderThatRearmsAfterTheTimeoutIsKilledAndClearedAgain() throws {
    let run = try FixtureRun(["--arm", "--no-heartbeat", "--timeout", "1", "--rearm-on-term"])
    let pids = try #require(run.ready())
    #expect(ProcessProbe.poll(within: 4) { run.record.contains("clear heartbeat-timeout") })
    #expect(run.line(startingWith: "REARMED", within: 3) != nil)
    #expect(ProcessProbe.poll(within: 5) { !run.process.isRunning })
    #expect(run.process.terminationReason == .uncaughtSignal)
    #expect(ProcessProbe.poll(within: 3) { ProcessProbe.isGone(pids.sentinel) })
    let clears = run.record.split(separator: "\n").map(String.init)
    #expect(clears.first == "clear heartbeat-timeout")
    #expect(clears.count >= 2)
    #expect(clears.last == "clear post-terminate" || clears.last == "clear eof")
    #expect(run.log.contains(" parentKill"))
  }

  @Test func unarmedHolderDeathDoesNotClear() throws {
    let run = try FixtureRun([])
    let pids = try #require(run.ready())
    try #require(ProcessProbe.poll(within: Self.eventSeconds) { run.log.contains(" start ") })
    run.signalFixture(SIGKILL)
    #expect(ProcessProbe.poll(within: Self.eventSeconds) { ProcessProbe.isGone(pids.sentinel) })
    #expect(run.record.isEmpty)
    #expect(run.log.contains(" exit reason=eof"))
  }

  @Test func disarmThenKillDoesNotClear() throws {
    let run = try FixtureRun(["--arm", "--disarm-after", "1"])
    let pids = try #require(run.ready())
    try #require(ProcessProbe.poll(within: 3) { run.log.contains(" disarmed") })
    run.signalFixture(SIGKILL)
    #expect(ProcessProbe.poll(within: Self.eventSeconds) { ProcessProbe.isGone(pids.sentinel) })
    #expect(run.record.isEmpty)
  }

  @Test func byeExitsWithoutClear() throws {
    let run = try FixtureRun(["--arm", "--bye-after", "1"])
    let pids = try #require(run.ready())
    #expect(ProcessProbe.poll(within: 3) { ProcessProbe.isGone(pids.sentinel) })
    #expect(run.record.isEmpty)
    #expect(run.log.contains(" exit reason=bye"))
    #expect(run.process.isRunning)
  }

  @Test func sigtermToArmedSentinelClearsAndHolderSeesLost() throws {
    let run = try FixtureRun(["--arm"])
    let pids = try #require(run.ready())
    try #require(ProcessProbe.poll(within: Self.eventSeconds) { run.log.contains(" armed") })
    run.signalSentinel(SIGTERM)
    #expect(ProcessProbe.poll(within: Self.eventSeconds) { run.record.contains("clear signal") })
    #expect(run.line(startingWith: "LOST 32", within: 2) != nil)
    #expect(ProcessProbe.poll(within: Self.eventSeconds) { ProcessProbe.isGone(pids.sentinel) })
    #expect(run.process.isRunning)
  }

  @Test(arguments: [SIGHUP, SIGINT])
  func otherTerminationSignalsAlsoClear(_ signal: Int32) throws {
    let run = try FixtureRun(["--arm"])
    _ = try #require(run.ready())
    try #require(ProcessProbe.poll(within: Self.eventSeconds) { run.log.contains(" armed") })
    run.signalSentinel(signal)
    #expect(ProcessProbe.poll(within: Self.eventSeconds) { run.record.contains("clear signal") })
  }

  @Test func childOfHolderDoesNotHoldPipeOpen() throws {
    let run = try FixtureRun(["--arm", "--spawn-child"])
    _ = try #require(run.ready())
    let child = try #require(run.child())
    #expect(!ProcessProbe.isGone(child))
    run.signalFixture(SIGKILL)
    #expect(ProcessProbe.poll(within: Self.eventSeconds) { run.record.contains("clear eof") })
    #expect(!ProcessProbe.isGone(child))
  }

  static func armedDirectSentinel(
    in temp: TempDirectory, recordPath: String, extra: [String]
  ) throws -> (Process, Pipe, String) {
    let sentinel = Process()
    sentinel.executableURL = ExecutableLocator.url(named: "overtime-sentinel")
    let logPath = temp.url.appendingPathComponent("s.log").path(percentEncoded: false)
    sentinel.arguments =
      ["--parent", String(getpid()), "--log", logPath, "--clear-backend", "record:" + recordPath] + extra
    let input = Pipe()
    sentinel.standardInput = input
    sentinel.standardOutput = FileHandle.nullDevice
    sentinel.standardError = FileHandle.nullDevice
    try sentinel.run()
    ProcessCleanup.track(sentinel)
    input.fileHandleForWriting.write(Data("ARM\n".utf8))
    return (sentinel, input, logPath)
  }

  @Test func aFailingClearIsRetriedUntilItSucceeds() throws {
    let temp = try TempDirectory()
    let recordPath = temp.url.appendingPathComponent("record").path(percentEncoded: false)
    try FileManager.default.createDirectory(atPath: recordPath, withIntermediateDirectories: false)
    let (sentinel, input, logPath) = try Self.armedDirectSentinel(in: temp, recordPath: recordPath, extra: [])
    let log = { (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "" }
    try #require(ProcessProbe.poll(within: 3) { log().contains(" armed") })
    try input.fileHandleForWriting.close()
    try #require(ProcessProbe.poll(within: 3) { log().contains(" clear eof kr=5 retry") })
    usleep(600_000)
    #expect(sentinel.isRunning)
    try FileManager.default.removeItem(atPath: recordPath)
    try #require(ProcessProbe.poll(within: 3) { !sentinel.isRunning })
    #expect(sentinel.terminationStatus == 0)
    #expect(((try? String(contentsOfFile: recordPath, encoding: .utf8)) ?? "").contains("clear eof"))
    #expect(log().contains(" clear eof kr=0 attempts="))
  }

  @Test func aClearThatNeverSucceedsExitsNonZeroAfterTheBudget() throws {
    let temp = try TempDirectory()
    let recordPath = temp.url.appendingPathComponent("record").path(percentEncoded: false)
    try FileManager.default.createDirectory(atPath: recordPath, withIntermediateDirectories: false)
    let (sentinel, input, logPath) = try Self.armedDirectSentinel(
      in: temp, recordPath: recordPath, extra: ["--clear-budget", "1"])
    let log = { (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "" }
    try #require(ProcessProbe.poll(within: 3) { log().contains(" armed") })
    let closedAt = ProcessProbe.uptime()
    try input.fileHandleForWriting.close()
    try #require(ProcessProbe.poll(within: 4) { !sentinel.isRunning })
    #expect(ProcessProbe.uptime() - closedAt >= 0.9)
    #expect(sentinel.terminationStatus == 70)
    #expect(log().contains(" exit reason=eof clearFailed"))
  }

  @Test func aParentMismatchIsAUsageError() throws {
    let temp = try TempDirectory()
    let sentinel = Process()
    sentinel.executableURL = ExecutableLocator.url(named: "overtime-sentinel")
    let logPath = temp.url.appendingPathComponent("s.log").path(percentEncoded: false)
    let recordPath = temp.url.appendingPathComponent("record").path(percentEncoded: false)
    sentinel.arguments = [
      "--timeout", "2", "--parent", "99999", "--log", logPath, "--clear-backend", "record:" + recordPath,
    ]
    sentinel.standardInput = Pipe()
    sentinel.standardOutput = FileHandle.nullDevice
    sentinel.standardError = FileHandle.nullDevice
    try sentinel.run()
    ProcessCleanup.track(sentinel)
    try #require(ProcessProbe.poll(within: 3) { !sentinel.isRunning })
    #expect(sentinel.terminationStatus == 64)
  }

  @Test(arguments: [["--bogus"], ["--parent"], ["--timeout", "0"], ["--clear-backend", "fake"]])
  func badArgumentsAreAUsageError(_ extra: [String]) throws {
    let temp = try TempDirectory()
    let sentinel = Process()
    sentinel.executableURL = ExecutableLocator.url(named: "overtime-sentinel")
    sentinel.arguments =
      [
        "--parent", String(getpid()), "--log", temp.url.appendingPathComponent("s.log").path(percentEncoded: false),
        "--clear-backend", "record:" + temp.url.appendingPathComponent("record").path(percentEncoded: false),
      ] + extra
    sentinel.standardInput = Pipe()
    sentinel.standardOutput = FileHandle.nullDevice
    sentinel.standardError = FileHandle.nullDevice
    try sentinel.run()
    ProcessCleanup.track(sentinel)
    try #require(ProcessProbe.poll(within: 3) { !sentinel.isRunning })
    #expect(sentinel.terminationStatus == 64)
  }
}
