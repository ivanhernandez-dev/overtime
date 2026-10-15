import Darwin
import Foundation
import OvertimeClamshell
import Testing

@testable import OvertimeSystem

@Suite(.serialized)
struct SentinelLinkTests {
  static let eventSeconds = SentinelProcessTests.eventSeconds
  static let sentinelPath = ExecutableLocator.url(named: "overtime-sentinel").path(percentEncoded: false)

  static func makeLink(in temp: TempDirectory) -> SentinelLink {
    let record = temp.url.appendingPathComponent("record").path(percentEncoded: false)
    return SentinelLink(
      executableURL: URL(fileURLWithPath: sentinelPath),
      timeoutSeconds: 3_600,
      logURL: temp.url.appendingPathComponent("sentinel.log"),
      extraArguments: ["--clear-backend", "record:\(record)"])
  }

  static func log(in temp: TempDirectory) -> String {
    (try? String(contentsOf: temp.url.appendingPathComponent("sentinel.log"), encoding: .utf8)) ?? ""
  }

  static func stopAndReap(_ link: SentinelLink) {
    if let pid = link.processIdentifier {
      ProcessProbe.signalIfOwn(pid, executable: sentinelPath, signal: SIGCONT)
      ProcessProbe.signalIfOwn(pid, executable: sentinelPath, signal: SIGKILL)
    }
    link.close()
  }

  @Test func sendBeforeStartIsNotRunning() throws {
    let temp = try TempDirectory()
    let link = Self.makeLink(in: temp)
    #expect(link.send(.heartbeat) == .notRunning)
    #expect(link.writeDescriptor == nil)
    #expect(link.processIdentifier == nil)
  }

  @Test func theWriteEndIsCloseOnExecAndNonBlocking() throws {
    let temp = try TempDirectory()
    let link = Self.makeLink(in: temp)
    try link.start()
    defer { Self.stopAndReap(link) }
    let descriptor = try #require(link.writeDescriptor)
    #expect(fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0)
    #expect(fcntl(descriptor, F_GETFL) & O_NONBLOCK != 0)
    #expect(link.send(.heartbeat) == .sent)
  }

  @Test func aSecondStartThrows() throws {
    let temp = try TempDirectory()
    let link = Self.makeLink(in: temp)
    try link.start()
    defer { Self.stopAndReap(link) }
    #expect(throws: SentinelLinkError.alreadyStarted) { try link.start() }
  }

  @Test func aStoppedSentinelIsLostWithEAGAINWithoutBlockingThenEPIPEOnceItDies() throws {
    let temp = try TempDirectory()
    let link = Self.makeLink(in: temp)
    try link.start()
    defer { Self.stopAndReap(link) }
    let pid = try #require(link.processIdentifier)
    try #require(ProcessProbe.poll(within: Self.eventSeconds) { Self.log(in: temp).contains(" start ") })
    ProcessProbe.signalIfOwn(pid, executable: Self.sentinelPath, signal: SIGSTOP)
    let deadline = ProcessProbe.uptime() + 2
    var result = SentinelSendResult.sent
    var slowest = 0.0
    while result == .sent && ProcessProbe.uptime() < deadline {
      let before = ProcessProbe.uptime()
      result = link.send(.heartbeat)
      slowest = max(slowest, ProcessProbe.uptime() - before)
    }
    #expect(result == .lost(errno: EAGAIN))
    #expect(slowest < 1)
    ProcessProbe.signalIfOwn(pid, executable: Self.sentinelPath, signal: SIGCONT)
    ProcessProbe.signalIfOwn(pid, executable: Self.sentinelPath, signal: SIGKILL)
    try #require(ProcessProbe.poll(within: Self.eventSeconds) { ProcessProbe.isGone(pid) })
    #expect(link.send(.heartbeat) == .lost(errno: EPIPE))
    #expect(kill(getpid(), 0) == 0)
  }

  @Test func closeStopsSendingAndLetsTheSentinelExit() throws {
    let temp = try TempDirectory()
    let link = Self.makeLink(in: temp)
    try link.start()
    let pid = try #require(link.processIdentifier)
    link.close()
    #expect(link.send(.heartbeat) == .notRunning)
    #expect(link.writeDescriptor == nil)
    #expect(ProcessProbe.poll(within: Self.eventSeconds) { ProcessProbe.isGone(pid) })
    ProcessProbe.signalIfOwn(pid, executable: Self.sentinelPath, signal: SIGKILL)
  }

  static func record(in temp: TempDirectory) -> String {
    (try? String(contentsOf: temp.url.appendingPathComponent("record"), encoding: .utf8)) ?? ""
  }

  @Test func retiringAnArmedSentinelClearsBeforeItReturns() async throws {
    let temp = try TempDirectory()
    let link = Self.makeLink(in: temp)
    try link.start()
    let pid = try #require(link.processIdentifier)
    defer { ProcessProbe.signalIfOwn(pid, executable: Self.sentinelPath, signal: SIGKILL) }
    #expect(link.send(.arm) == .sent)
    try #require(ProcessProbe.poll(within: Self.eventSeconds) { Self.log(in: temp).contains(" armed") })
    let retired = await link.retire()
    #expect(retired == .terminated || retired == .exited)
    #expect(Self.record(in: temp).contains("clear "))
    #expect(ProcessProbe.isGone(pid))
    #expect(link.send(.heartbeat) == .notRunning)
  }

  @Test func retiringASentinelThatAlreadyExitedSendsNoSignal() async throws {
    let temp = try TempDirectory()
    let link = Self.makeLink(in: temp)
    try link.start()
    let pid = try #require(link.processIdentifier)
    #expect(link.send(.arm) == .sent)
    try #require(ProcessProbe.poll(within: Self.eventSeconds) { Self.log(in: temp).contains(" armed") })
    ProcessProbe.signalIfOwn(pid, executable: Self.sentinelPath, signal: SIGKILL)
    try #require(ProcessProbe.poll(within: Self.eventSeconds) { ProcessProbe.isGone(pid) })
    try await Task.sleep(for: .milliseconds(100))
    #expect(await link.retire() == .exited)
    #expect(Self.record(in: temp).isEmpty)
    #expect(link.send(.heartbeat) == .notRunning)
  }

  @Test func retiringAStoppedSentinelKillsItWithinTheGrace() async throws {
    let temp = try TempDirectory()
    let link = Self.makeLink(in: temp)
    try link.start()
    let pid = try #require(link.processIdentifier)
    defer {
      ProcessProbe.signalIfOwn(pid, executable: Self.sentinelPath, signal: SIGCONT)
      ProcessProbe.signalIfOwn(pid, executable: Self.sentinelPath, signal: SIGKILL)
    }
    #expect(link.send(.arm) == .sent)
    try #require(ProcessProbe.poll(within: Self.eventSeconds) { Self.log(in: temp).contains(" armed") })
    ProcessProbe.signalIfOwn(pid, executable: Self.sentinelPath, signal: SIGSTOP)
    let started = ProcessProbe.uptime()
    #expect(await link.retire() == .killed)
    #expect(ProcessProbe.uptime() - started < 1.5)
    #expect(ProcessProbe.isGone(pid))
    #expect(Self.record(in: temp).isEmpty)
  }

  static func makeFailingClearLink(
    in temp: TempDirectory, budgetSeconds: Int, retireClearGraceSeconds: Double
  ) -> SentinelLink {
    let record = temp.url.appendingPathComponent("later/record").path(percentEncoded: false)
    return SentinelLink(
      executableURL: URL(fileURLWithPath: sentinelPath),
      timeoutSeconds: 3_600,
      logURL: temp.url.appendingPathComponent("sentinel.log"),
      extraArguments: ["--clear-backend", "record:\(record)", "--clear-budget", String(budgetSeconds)],
      retireClearGraceSeconds: retireClearGraceSeconds)
  }

  static func laterRecord(in temp: TempDirectory) -> String {
    (try? String(contentsOf: temp.url.appendingPathComponent("later/record"), encoding: .utf8)) ?? ""
  }

  @Test func retiringAnArmedSentinelWaitsForItsRetriedClearBeyondTheStopGrace() async throws {
    let temp = try TempDirectory()
    let link = Self.makeFailingClearLink(in: temp, budgetSeconds: 10, retireClearGraceSeconds: 11)
    try link.start()
    let pid = try #require(link.processIdentifier)
    defer { ProcessProbe.signalIfOwn(pid, executable: Self.sentinelPath, signal: SIGKILL) }
    #expect(link.send(.arm) == .sent)
    try #require(ProcessProbe.poll(within: Self.eventSeconds) { Self.log(in: temp).contains(" armed") })
    let later = temp.url.appendingPathComponent("later")
    let unblock = Task {
      try? await Task.sleep(for: .seconds(1))
      try? FileManager.default.createDirectory(at: later, withIntermediateDirectories: false)
    }
    let started = ProcessProbe.uptime()
    let retired = await link.retire()
    await unblock.value
    #expect(retired == .terminated)
    #expect(ProcessProbe.uptime() - started > SentinelLink.retireGraceSeconds * 2)
    #expect(Self.laterRecord(in: temp).contains("clear eof"))
    #expect(Self.log(in: temp).contains("exit reason=eof\n"))
    #expect(ProcessProbe.isGone(pid))
  }

  @Test func retiringAnArmedSentinelWhoseClearKeepsFailingLetsItExitWithClearFailed() async throws {
    let temp = try TempDirectory()
    let link = Self.makeFailingClearLink(in: temp, budgetSeconds: 1, retireClearGraceSeconds: 3)
    try link.start()
    let pid = try #require(link.processIdentifier)
    defer { ProcessProbe.signalIfOwn(pid, executable: Self.sentinelPath, signal: SIGKILL) }
    #expect(link.send(.arm) == .sent)
    try #require(ProcessProbe.poll(within: Self.eventSeconds) { Self.log(in: temp).contains(" armed") })
    #expect(await link.retire() == .terminated)
    #expect(Self.log(in: temp).contains("exit reason=eof clearFailed"))
    #expect(ProcessProbe.isGone(pid))
  }

  @Test func theDefaultRetireGraceCoversTheSentinelsWholeClearBudget() {
    #expect(SentinelLink.defaultRetireClearGraceSeconds > Double(SentinelWatch.defaultClearBudgetSeconds))
  }

  @Test func aSentinelThatExitsAtStartupMakesStartThrow() throws {
    let temp = try TempDirectory()
    let link = SentinelLink(
      executableURL: URL(fileURLWithPath: "/usr/bin/false"), timeoutSeconds: 3_600,
      logURL: temp.url.appendingPathComponent("sentinel.log"), extraArguments: [])
    let started = ProcessProbe.uptime()
    #expect(throws: SentinelLinkError.notReady) { try link.start() }
    #expect(ProcessProbe.uptime() - started < 1.5)
    #expect(link.send(.arm) == .notRunning)
  }

  @Test func aSentinelThatNeverReportsReadyTimesOutAndIsKilled() throws {
    let temp = try TempDirectory()
    let script = temp.url.appendingPathComponent("silent.sh")
    let pidFile = temp.url.appendingPathComponent("pid").path(percentEncoded: false)
    try "#!/bin/sh\necho $$ > '\(pidFile)'\nexec /bin/sleep 30\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path(percentEncoded: false))
    let link = SentinelLink(
      executableURL: script, timeoutSeconds: 3_600, logURL: temp.url.appendingPathComponent("sentinel.log"),
      extraArguments: [], readyTimeoutSeconds: 0.5)
    #expect(throws: SentinelLinkError.notReady) { try link.start() }
    #expect(link.send(.arm) == .notRunning)
    var text = ""
    _ = ProcessProbe.poll(within: 1) {
      text = (try? String(contentsOfFile: pidFile, encoding: .utf8)) ?? ""
      return !text.isEmpty
    }
    guard let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
    defer { ProcessProbe.signalIfOwn(pid, executable: "/bin/sleep", signal: SIGKILL) }
    #expect(ProcessProbe.poll(within: Self.eventSeconds) { ProcessProbe.isGone(pid) })
  }

  @Test func theRealSentinelReportsReadyBeforeStartReturns() throws {
    let temp = try TempDirectory()
    let link = Self.makeLink(in: temp)
    try link.start()
    defer { Self.stopAndReap(link) }
    #expect(Self.log(in: temp).contains(" start "))
  }
}
