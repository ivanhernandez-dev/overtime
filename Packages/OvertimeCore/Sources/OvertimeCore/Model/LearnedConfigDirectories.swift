import Foundation

public struct LearnedConfigDirectories: Sendable, Equatable {
  public static let maxActive = 8
  static let projectsSuffix = "/projects"

  public private(set) var lastSeen: [String: Instant]

  public init() {
    lastSeen = [:]
  }

  public func active() -> [String] {
    lastSeen.keys.map(Self.configDirectory(ofProjectsRoot:)).sorted()
  }

  public mutating func observe(
    _ seen: [String], at now: Instant, lingerSeconds: Double = Timing.learnedRootLingerSeconds
  ) -> [Decision] {
    let sighted = Set(seen.compactMap(TranscriptRoots.projectsRoot(forConfigDirectory:)))
    for root in sighted where lastSeen[root] != nil {
      lastSeen[root] = now
    }
    let linger = Instant.nanoseconds(forSeconds: lingerSeconds)
    let expired = lastSeen.filter { now.nanoseconds(since: $0.value) >= linger }.keys.sorted()
    for root in expired {
      lastSeen[root] = nil
    }
    var learned: [String] = []
    for root in sighted.subtracting(lastSeen.keys).sorted() where lastSeen.count < Self.maxActive {
      lastSeen[root] = now
      learned.append(root)
    }
    return expired.map { Self.decision("transcriptRoot forgotten", $0) }
      + learned.map { Self.decision("transcriptRoot learned", $0) }
  }

  static func configDirectory(ofProjectsRoot root: String) -> String {
    let directory = String(root.dropLast(projectsSuffix.count))
    return directory.isEmpty ? "/" : directory
  }

  static func decision(_ verb: String, _ root: String) -> Decision {
    Decision(
      keyword: .check, verb: verb,
      fields: [DecisionField(key: "root", value: Reducer.loggable(root, limit: Health.maxLoggedRootLength))])
  }
}
