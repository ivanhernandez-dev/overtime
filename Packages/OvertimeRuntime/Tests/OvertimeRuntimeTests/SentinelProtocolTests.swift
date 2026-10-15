import OvertimeClamshell
import Testing

struct SentinelProtocolTests {
  static let timeout: UInt64 = 2_000_000_000

  @Test func theBufferSplitsLinesAcrossChunks() {
    var buffer = SentinelLineBuffer()
    #expect(buffer.append(Array("AR".utf8)) == [])
    #expect(buffer.append(Array("M\nHB\nDIS".utf8)) == ["ARM", "HB"])
    #expect(buffer.append(Array("ARM\n".utf8)) == ["DISARM"])
    #expect(buffer.pendingCount == 0)
  }

  @Test func anOversizedTailIsDiscardedUpToTheNextNewline() {
    var buffer = SentinelLineBuffer()
    #expect(buffer.append([UInt8](repeating: UInt8(ascii: "x"), count: 5_000)) == [])
    #expect(buffer.pendingCount <= SentinelLineBuffer.maximumLineLength)
    #expect(buffer.append(Array("xx\nARM\n".utf8)) == ["ARM"])
  }

  @Test func armArmsAndResetsTheHeartbeat() {
    var watch = SentinelWatch(timeoutNanoseconds: Self.timeout, nowUptime: 0)
    #expect(watch.receive("ARM", nowUptime: 10_000_000_000) == .none)
    #expect(watch.armed)
    #expect(watch.check(nowUptime: 10_000_000_000 + Self.timeout) == .none)
  }

  @Test func aHeartbeatResetsTheTimeout() {
    var watch = SentinelWatch(timeoutNanoseconds: Self.timeout, nowUptime: 0)
    _ = watch.receive("ARM", nowUptime: 0)
    #expect(watch.receive("HB", nowUptime: 1_500_000_000) == .none)
    #expect(watch.check(nowUptime: 3_000_000_000) == .none)
    #expect(watch.check(nowUptime: 3_500_000_001) == .clearThenTerminateParent(reason: "heartbeat-timeout"))
  }

  @Test func disarmDisarms() {
    var watch = SentinelWatch(timeoutNanoseconds: Self.timeout, nowUptime: 0)
    _ = watch.receive("ARM", nowUptime: 0)
    #expect(watch.receive("DISARM", nowUptime: 1) == .none)
    #expect(!watch.armed)
    #expect(watch.check(nowUptime: 60_000_000_000) == .none)
    #expect(watch.endOfInput() == .exitWithoutClear)
  }

  @Test func byeExitsWithoutClearing() {
    var watch = SentinelWatch(timeoutNanoseconds: Self.timeout, nowUptime: 0)
    _ = watch.receive("ARM", nowUptime: 0)
    #expect(watch.receive("BYE", nowUptime: 1) == .exitWithoutClear)
  }

  @Test(arguments: ["", "arm", "ARM ", "SET", "CLEAR", "HB\r"])
  func anUnknownLineDoesNothing(_ line: String) {
    var watch = SentinelWatch(timeoutNanoseconds: Self.timeout, nowUptime: 0)
    #expect(watch.receive(line, nowUptime: 1) == .none)
    #expect(!watch.armed)
  }

  @Test func theTimeoutIsStrictlyGreaterWhileArmed() {
    var watch = SentinelWatch(timeoutNanoseconds: Self.timeout, nowUptime: 0)
    _ = watch.receive("ARM", nowUptime: 5)
    #expect(watch.check(nowUptime: 5 + Self.timeout) == .none)
    #expect(watch.check(nowUptime: 5 + Self.timeout + 1) == .clearThenTerminateParent(reason: "heartbeat-timeout"))
    #expect(!watch.armed)
  }

  @Test func theTimeoutNeverFiresWhileUnarmed() {
    var watch = SentinelWatch(timeoutNanoseconds: Self.timeout, nowUptime: 0)
    #expect(watch.check(nowUptime: Self.timeout + 1) == .none)
    #expect(watch.check(nowUptime: UInt64.max) == .none)
  }

  @Test func aClockBehindTheLastHeartbeatNeverFires() {
    var watch = SentinelWatch(timeoutNanoseconds: Self.timeout, nowUptime: 0)
    _ = watch.receive("ARM", nowUptime: 10_000_000_000)
    #expect(watch.check(nowUptime: 1) == .none)
  }

  @Test func endOfInputClearsOnlyWhileArmed() {
    var armed = SentinelWatch(timeoutNanoseconds: Self.timeout, nowUptime: 0)
    _ = armed.receive("ARM", nowUptime: 0)
    #expect(armed.endOfInput() == .clearAndExit(reason: "eof"))
    var unarmed = SentinelWatch(timeoutNanoseconds: Self.timeout, nowUptime: 0)
    #expect(unarmed.endOfInput() == .exitWithoutClear)
  }

  @Test func aSignalClearsOnlyWhileArmed() {
    var armed = SentinelWatch(timeoutNanoseconds: Self.timeout, nowUptime: 0)
    _ = armed.receive("ARM", nowUptime: 0)
    #expect(armed.signalReceived() == .clearAndExit(reason: "signal"))
    var unarmed = SentinelWatch(timeoutNanoseconds: Self.timeout, nowUptime: 0)
    #expect(unarmed.signalReceived() == .exitWithoutClear)
  }

  static func timedOut() -> SentinelWatch {
    var watch = SentinelWatch(timeoutNanoseconds: Self.timeout, nowUptime: 0)
    _ = watch.receive("ARM", nowUptime: 0)
    _ = watch.check(nowUptime: Self.timeout + 1)
    return watch
  }

  @Test func aTimeoutStartsTerminationAndFiresOnce() {
    var watch = Self.timedOut()
    #expect(watch.terminating)
    #expect(!watch.armed)
    _ = watch.receive("ARM", nowUptime: Self.timeout + 2)
    #expect(watch.check(nowUptime: 10 * Self.timeout) == .none)
  }

  @Test func anArmInsideTheTerminationWindowStillEndsInAClear() {
    var watch = Self.timedOut()
    #expect(watch.receive("ARM", nowUptime: Self.timeout + 2) == .none)
    #expect(watch.armed)
    #expect(watch.parentTerminated() == .clearAndExit(reason: "post-terminate"))
  }

  @Test func theTerminationDeadlineClearsEvenWhenNothingWasRearmed() {
    var watch = Self.timedOut()
    #expect(watch.parentTerminated() == .clearAndExit(reason: "post-terminate"))
  }

  @Test func everyExitInsideTheTerminationWindowClears() {
    var eof = Self.timedOut()
    #expect(eof.endOfInput() == .clearAndExit(reason: "eof"))
    var signal = Self.timedOut()
    #expect(signal.signalReceived() == .clearAndExit(reason: "signal"))
    var bye = Self.timedOut()
    _ = bye.receive("DISARM", nowUptime: Self.timeout + 2)
    #expect(bye.receive("BYE", nowUptime: Self.timeout + 3) == .clearAndExit(reason: "bye"))
  }

  @Test func noLineSetsTheBit() {
    let lines = [SentinelLine.arm, .heartbeat, .disarm, .bye].map(\.rawValue)
    #expect(lines == ["ARM", "HB", "DISARM", "BYE"])
  }
}
