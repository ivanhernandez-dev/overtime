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

  public init(
    busyProcessCount: Int = 0, sessionCount: Int = 0, terminalAgentStarts: [Instant] = [],
    claudeConfigDirectories: [String] = []
  ) {
    self.busyProcessCount = busyProcessCount
    self.sessionCount = sessionCount
    self.terminalAgentStarts = terminalAgentStarts
    self.claudeConfigDirectories = claudeConfigDirectories
  }

  public static let none = AgentSignals()

  public static func merged(_ all: [AgentSignals]) -> AgentSignals {
    all.reduce(into: AgentSignals()) { result, signals in
      result.busyProcessCount += signals.busyProcessCount
      result.sessionCount += signals.sessionCount
      result.terminalAgentStarts += signals.terminalAgentStarts
      result.claudeConfigDirectories = Array(Set(result.claudeConfigDirectories + signals.claudeConfigDirectories))
        .sorted()
    }
  }
}
