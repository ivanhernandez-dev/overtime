import Foundation

public struct CoexistenceKey: Sendable, Hashable {
  public var pid: Int32
  public var type: String

  public init(pid: Int32, type: String) {
    self.pid = pid
    self.type = type
  }
}

public struct CoexistenceState: Sendable, Equatable {
  public var previousForeign: Set<CoexistenceKey>
  public var warned: Bool

  public init(previousForeign: Set<CoexistenceKey> = [], warned: Bool = false) {
    self.previousForeign = previousForeign
    self.warned = warned
  }
}

public enum Coexistence {
  public static let maxLoggedNames = 8
  public static let maxLoggedNameLength = 32

  public static func step(_ state: inout AppState, facts: CoexistenceFacts?, now: Instant) -> [Effect] {
    guard state.want.wanted == true else {
      state.coexistence.previousForeign = []
      return []
    }
    guard let facts else { return [] }
    let current = Set(facts.foreignAssertions.map { CoexistenceKey(pid: $0.pid, type: $0.type) })
    let counted = facts.foreignAssertions.filter {
      state.coexistence.previousForeign.contains(CoexistenceKey(pid: $0.pid, type: $0.type))
    }
    state.coexistence.previousForeign = current
    let conflict = facts.amphetamineRunning || facts.sleepDisabled == true || !counted.isEmpty
    switch (conflict, state.coexistence.warned) {
    case (true, false):
      state.coexistence.warned = true
      return [.log(warning(facts, counted: counted))]
    case (false, true):
      state.coexistence.warned = false
      return [.log(Decision(keyword: .warn, verb: "coexistence cleared"))]
    default:
      return []
    }
  }

  static func warning(_ facts: CoexistenceFacts, counted: [ForeignAssertion]) -> Decision {
    let sleepDisabled = facts.sleepDisabled.map { $0 ? "true" : "false" } ?? "unknown"
    let names = Array(Set(counted.map { Reducer.loggable($0.processName ?? "?", limit: maxLoggedNameLength) }))
      .sorted()
      .prefix(maxLoggedNames)
    return Decision(
      keyword: .warn,
      verb: "coexistence",
      fields: [
        DecisionField(key: "amphetamine", value: facts.amphetamineRunning ? "true" : "false"),
        DecisionField(key: "sleepDisabled", value: sleepDisabled),
        DecisionField(key: "foreign", value: String(counted.count)),
        DecisionField(key: "names", value: names.isEmpty ? "none" : names.joined(separator: ",")),
      ]
    )
  }
}
