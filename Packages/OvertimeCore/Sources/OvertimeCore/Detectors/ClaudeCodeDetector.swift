import Foundation

public struct LongRunningWork: Sendable, Equatable {
  public var waitingSessionPIDs: Set<Int32>
  public var printRunStarts: [Int32: Instant]

  public init(waitingSessionPIDs: Set<Int32> = [], printRunStarts: [Int32: Instant] = [:]) {
    self.waitingSessionPIDs = waitingSessionPIDs
    self.printRunStarts = printRunStarts
  }
}

public struct ClaudeCodeDetector: AgentDetector {
  public let name = "claude-code"
  public let userID: UInt32

  public static let toolShellNames: Set<String> = ["bash", "zsh"]

  public init(userID: UInt32) {
    self.userID = userID
  }

  public static func looksLikeClaude(comm: String) -> Bool {
    if comm == "claude" {
      return true
    }
    guard let first = comm.first, let last = comm.last, first.isASCIIDigit, last.isASCIIDigit else { return false }
    return isVersionName(comm)
  }

  public func longRunningWork(in records: [ProcessRecord], now: Instant) -> LongRunningWork {
    let own = records.filter { $0.uid == userID }
    var byPID: [Int32: ProcessRecord] = [:]
    for record in own {
      byPID[record.pid] = record
    }
    var work = LongRunningWork()
    for record in own where Self.isAgedToolCommand(record, now: now) {
      guard let parent = byPID[record.ppid], parent.uid == record.uid, !parent.zombie, Self.isClaude(parent)
      else { continue }
      work.waitingSessionPIDs.insert(parent.pid)
    }
    for record in own where record.printMode && !record.zombie && Self.isClaude(record) {
      guard let start = record.startMono else { continue }
      work.printRunStarts[record.pid] = start
    }
    return work
  }

  static func isAgedToolCommand(_ record: ProcessRecord, now: Instant) -> Bool {
    guard toolShellNames.contains(record.comm), !record.hasControllingTerminal, record.processGroup == record.pid,
      !record.zombie, record.claudeToolCommand, record.ppid > 1, let start = record.startMono, start <= now
    else { return false }
    return now.seconds(since: start) >= Timing.backgroundCommandMinimumAgeSeconds
  }

  public static func isClaude(_ record: ProcessRecord) -> Bool {
    if basename(record.argv0) == "claude" {
      return true
    }
    if basename(record.execPath) == "claude" {
      return true
    }
    if [record.argv0, record.execPath, record.pidPath].contains(where: isVersionedInstallPath) {
      return true
    }
    if let runtime = basename(record.argv0), runtime == "node" || runtime == "bun", let script = record.argv1 {
      return basename(script) == "claude" || script.hasSuffix("@anthropic-ai/claude-code/cli.js")
    }
    return false
  }

  public static func busySessionPIDs(in records: [ProcessRecord]) -> Set<Int32> {
    var byPID: [Int32: ProcessRecord] = [:]
    for record in records {
      byPID[record.pid] = record
    }
    var busy: Set<Int32> = []
    for record in records where record.comm == "caffeinate" && record.ppid != 1 {
      guard let parent = byPID[record.ppid], parent.uid == record.uid, parent.hasControllingTerminal,
        isClaude(parent)
      else { continue }
      busy.insert(parent.pid)
    }
    return busy
  }

  public func signals(from processes: [ProcessRecord]) -> AgentSignals {
    let own = processes.filter { $0.uid == userID }
    var byPID: [Int32: ProcessRecord] = [:]
    for record in own {
      byPID[record.pid] = record
    }
    var busyProcessCount = 0
    var sessionParents: Set<Int32> = []
    for record in own where record.comm == "caffeinate" && record.ppid != 1 {
      guard let parent = byPID[record.ppid], parent.hasControllingTerminal, ClaudeCodeDetector.isClaude(parent)
      else { continue }
      busyProcessCount += 1
      sessionParents.insert(parent.pid)
    }
    let terminalAgentStarts = own.compactMap { record in
      record.hasControllingTerminal && !record.printMode && ClaudeCodeDetector.isClaude(record)
        ? record.startMono : nil
    }
    let claudeConfigDirectories = Set(
      own.compactMap { record in
        ClaudeCodeDetector.isClaude(record) ? record.claudeConfigDirectory : nil
      })
    return AgentSignals(
      busyProcessCount: busyProcessCount,
      sessionCount: sessionParents.count,
      terminalAgentStarts: terminalAgentStarts,
      claudeConfigDirectories: claudeConfigDirectories.sorted()
    )
  }

  static func basename(_ path: String?) -> String? {
    guard let path else { return nil }
    guard let slash = path.lastIndex(of: "/") else { return path }
    return String(path[path.index(after: slash)...])
  }

  static func isVersionedInstallPath(_ path: String?) -> Bool {
    guard let path else { return false }
    let components = path.split(separator: "/", omittingEmptySubsequences: true)
    guard components.count >= 3 else { return false }
    let version = components[components.count - 1]
    guard components[components.count - 3] == "claude", components[components.count - 2] == "versions" else {
      return false
    }
    return isVersionName(version)
  }

  static func isVersionName<S: StringProtocol>(_ name: S) -> Bool {
    name.contains(".") && name.contains(where: \.isASCIIDigit) && name.allSatisfy { $0 == "." || $0.isASCIIDigit }
  }
}

extension Character {
  fileprivate var isASCIIDigit: Bool {
    isASCII && isNumber
  }
}
