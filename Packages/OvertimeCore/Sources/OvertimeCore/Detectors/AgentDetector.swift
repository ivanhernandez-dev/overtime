import Foundation

public protocol AgentDetector: Sendable {
  var name: String { get }
  func signals(from processes: [ProcessRecord]) -> AgentSignals
}

public struct AgentSignals: Sendable, Equatable {
  public var busyProcessCount: Int
  public var sessionCount: Int
  public var terminalAgentStarts: [Instant]
  public var claudeConfigDirectories: [String]
  public var backgroundCommandSessions: Int
  public var printRunStarts: [Instant]

  public init(
    busyProcessCount: Int = 0, sessionCount: Int = 0, terminalAgentStarts: [Instant] = [],
    claudeConfigDirectories: [String] = [], backgroundCommandSessions: Int = 0, printRunStarts: [Instant] = []
  ) {
    self.busyProcessCount = busyProcessCount
    self.sessionCount = sessionCount
    self.terminalAgentStarts = terminalAgentStarts
    self.claudeConfigDirectories = claudeConfigDirectories
    self.backgroundCommandSessions = backgroundCommandSessions
    self.printRunStarts = printRunStarts
  }

  public static let none = AgentSignals()

  public func including(_ work: LongRunningWork) -> AgentSignals {
    var signals = self
    signals.backgroundCommandSessions = work.waitingSessionPIDs.count
    signals.printRunStarts = work.printRunStarts.values.sorted()
    return signals
  }

  public static func merged(_ all: [AgentSignals]) -> AgentSignals {
    all.reduce(into: AgentSignals()) { result, signals in
      result.busyProcessCount += signals.busyProcessCount
      result.sessionCount += signals.sessionCount
      result.terminalAgentStarts += signals.terminalAgentStarts
      result.claudeConfigDirectories = Array(Set(result.claudeConfigDirectories + signals.claudeConfigDirectories))
        .sorted()
      result.backgroundCommandSessions += signals.backgroundCommandSessions
      result.printRunStarts += signals.printRunStarts
    }
  }
}
