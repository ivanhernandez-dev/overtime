public enum SentinelLine: String, Sendable {
  case arm = "ARM"
  case heartbeat = "HB"
  case disarm = "DISARM"
  case bye = "BYE"
}

public struct SentinelLineBuffer: Sendable {
  public static let maximumLineLength = 4_096

  private var pending: [UInt8] = []
  private var discarding = false

  public init() {}

  public var pendingCount: Int { pending.count }

  public mutating func append(_ bytes: [UInt8]) -> [String] {
    var lines: [String] = []
    for byte in bytes {
      if byte == UInt8(ascii: "\n") {
        if !discarding {
          lines.append(String(decoding: pending, as: UTF8.self))
        }
        pending.removeAll(keepingCapacity: true)
        discarding = false
      } else if !discarding {
        pending.append(byte)
        if pending.count > Self.maximumLineLength {
          pending.removeAll()
          discarding = true
        }
      }
    }
    return lines
  }
}

public struct SentinelWatch: Sendable, Equatable {
  public enum Action: Sendable, Equatable {
    case none
    case exitWithoutClear
    case clearAndExit(reason: String)
    case clearThenTerminateParent(reason: String)
  }

  public static let defaultClearBudgetSeconds: UInt64 = 10

  public let timeoutNanoseconds: UInt64
  public private(set) var armed = false
  public private(set) var terminating = false
  public private(set) var lastHeartbeat: UInt64

  public init(timeoutNanoseconds: UInt64, nowUptime: UInt64) {
    self.timeoutNanoseconds = timeoutNanoseconds
    self.lastHeartbeat = nowUptime
  }

  public mutating func receive(_ line: String, nowUptime: UInt64) -> Action {
    switch SentinelLine(rawValue: line) {
    case .arm:
      armed = true
      lastHeartbeat = nowUptime
      return .none
    case .heartbeat:
      lastHeartbeat = nowUptime
      return .none
    case .disarm:
      armed = false
      return .none
    case .bye:
      armed = false
      return terminating ? .clearAndExit(reason: "bye") : .exitWithoutClear
    case nil:
      return .none
    }
  }

  public mutating func endOfInput() -> Action {
    guard armed || terminating else { return .exitWithoutClear }
    armed = false
    return .clearAndExit(reason: "eof")
  }

  public mutating func signalReceived() -> Action {
    guard armed || terminating else { return .exitWithoutClear }
    armed = false
    return .clearAndExit(reason: "signal")
  }

  public mutating func check(nowUptime: UInt64) -> Action {
    guard !terminating, armed, nowUptime > lastHeartbeat, nowUptime - lastHeartbeat > timeoutNanoseconds else {
      return .none
    }
    armed = false
    terminating = true
    return .clearThenTerminateParent(reason: "heartbeat-timeout")
  }

  public mutating func parentTerminated() -> Action {
    armed = false
    return .clearAndExit(reason: "post-terminate")
  }
}
