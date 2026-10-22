import Darwin
import Foundation
import OvertimeCore
import os

public struct SessionSummary: Sendable, Equatable {
  public var pid: Int32
  public var cwd: String?
  public var ttyName: String?
  public var startMono: Instant?
  public var workingSince: Instant?
  public var waitingSince: Instant?
  public var printRun: Bool
  public var terminal: Bool

  public init(
    pid: Int32, cwd: String?, ttyName: String?, startMono: Instant?, workingSince: Instant? = nil,
    waitingSince: Instant? = nil, printRun: Bool = false, terminal: Bool = true
  ) {
    self.pid = pid
    self.cwd = cwd
    self.ttyName = ttyName
    self.startMono = startMono
    self.workingSince = workingSince
    self.waitingSince = waitingSince
    self.printRun = printRun
    self.terminal = terminal
  }

  public var isWorking: Bool {
    workingSince != nil
  }

  public var isWaiting: Bool {
    waitingSince != nil
  }
}

public final class SessionReader: Sendable {
  public static let sameStartToleranceSeconds: Double = 1

  private struct Entry: Sendable {
    var summary: SessionSummary
  }

  private let readDirectory: @Sendable (Int32) -> String?
  private let readTerminal: @Sendable (UInt32) -> String?
  private let entries = OSAllocatedUnfairLock(initialState: [Int32: Entry]())
  private let activity = OSAllocatedUnfairLock(initialState: SessionActivity())
  private let waiting = OSAllocatedUnfairLock(initialState: SessionActivity())

  public init(
    readDirectory: @escaping @Sendable (Int32) -> String? = SessionReader.currentDirectory,
    readTerminal: @escaping @Sendable (UInt32) -> String? = SessionReader.terminalName
  ) {
    self.readDirectory = readDirectory
    self.readTerminal = readTerminal
  }

  public func summary(for record: ProcessRecord) -> SessionSummary {
    if let cached = entries.withLock({ $0[record.pid] }), Self.sameStart(cached.summary.startMono, record.startMono) {
      return cached.summary
    }
    let summary = SessionSummary(
      pid: record.pid,
      cwd: readDirectory(record.pid),
      ttyName: record.hasControllingTerminal ? readTerminal(record.ttyDevice) : nil,
      startMono: record.startMono,
      terminal: record.hasControllingTerminal
    )
    entries.withLock { $0[record.pid] = Entry(summary: summary) }
    return summary
  }

  public func sessions(
    from records: [ProcessRecord], at now: Instant, work: LongRunningWork = LongRunningWork()
  ) -> [SessionSummary] {
    let listed = records.filter { record in
      guard ClaudeCodeDetector.isClaude(record) else { return false }
      return record.hasControllingTerminal || work.waitingSessionPIDs.contains(record.pid)
        || work.printRunStarts[record.pid] != nil
    }
    let live = Set(listed.map(\.pid))
    entries.withLock { entries in
      entries = entries.filter { live.contains($0.key) }
    }
    let summaries = listed.map(summary(for:)).sorted(by: Self.olderFirst)
    let busy = ClaudeCodeDetector.busySessionPIDs(in: records)
    let keys = summaries.map { SessionActivity.Session(pid: $0.pid, start: $0.startMono) }
    let since = activity.withLock { $0.update(sessions: keys, busyPIDs: busy, at: now) }
    let waitingSince = waiting.withLock {
      $0.update(
        sessions: keys, busyPIDs: work.waitingSessionPIDs, at: now, graceSeconds: Timing.sessionWaitingGraceSeconds)
    }
    return summaries.map { summary in
      var session = summary
      session.workingSince = since[summary.pid]
      session.waitingSince = waitingSince[summary.pid]
      session.printRun = work.printRunStarts[summary.pid] != nil
      return session
    }
  }

  static func olderFirst(_ lhs: SessionSummary, _ rhs: SessionSummary) -> Bool {
    switch (lhs.startMono, rhs.startMono) {
    case (let left?, let right?) where left != right:
      return left < right
    case (.some, nil):
      return true
    case (nil, .some):
      return false
    default:
      return lhs.pid < rhs.pid
    }
  }

  static func sameStart(_ cached: Instant?, _ fresh: Instant?) -> Bool {
    guard let cached, let fresh else { return cached == nil && fresh == nil }
    let delta = cached > fresh ? cached.seconds(since: fresh) : fresh.seconds(since: cached)
    return delta <= sameStartToleranceSeconds
  }

  public static func currentDirectory(_ pid: Int32) -> String? {
    var info = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
    let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { buffer in
      String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }
    return path.isEmpty ? nil : path
  }

  public static func terminalName(_ device: UInt32) -> String? {
    guard device != ProcessRecord.noDevice, let name = devname(dev_t(bitPattern: device), S_IFCHR) else {
      return nil
    }
    let text = String(cString: name)
    return text.isEmpty || text == "??" ? nil : text
  }
}
