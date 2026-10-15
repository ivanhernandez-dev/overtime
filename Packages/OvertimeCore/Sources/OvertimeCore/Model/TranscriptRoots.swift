import Foundation

public enum RootOrigin: String, Sendable, Equatable {
  case configured
  case inferred
}

public struct TranscriptRoot: Sendable, Equatable, Hashable {
  public var path: String
  public var origin: RootOrigin

  public init(path: String, origin: RootOrigin) {
    self.path = path
    self.origin = origin
  }
}

public enum TranscriptRoots {
  public static func normalizedPath(_ path: String) -> String? {
    guard path.hasPrefix("/") else { return nil }
    var components: [Substring] = []
    for component in path.split(separator: "/", omittingEmptySubsequences: true) {
      switch component {
      case ".":
        continue
      case "..":
        if !components.isEmpty {
          components.removeLast()
        }
      default:
        components.append(component)
      }
    }
    return "/" + components.joined(separator: "/")
  }

  public static func projectsRoot(forConfigDirectory directory: String) -> String? {
    guard let normalized = normalizedPath(directory) else { return nil }
    return normalized == "/" ? "/projects" : normalized + "/projects"
  }

  public static func defaults(environment: [String: String], homeDirectory: String) -> [TranscriptRoot] {
    let joinedHome = joined(homeDirectory, ".claude/projects")
    let home = normalizedPath(joinedHome) ?? joinedHome
    var roots = [TranscriptRoot(path: home, origin: .inferred)]
    if let configDirectory = environment["CLAUDE_CONFIG_DIR"], !configDirectory.isEmpty,
      let root = projectsRoot(forConfigDirectory: configDirectory), root != home
    {
      roots.append(TranscriptRoot(path: root, origin: .inferred))
    }
    return roots
  }

  public static func adding(learnedConfigDirectories: [String], to base: [TranscriptRoot]) -> [TranscriptRoot] {
    var result = base
    var present = Set(base.map { normalizedPath($0.path) ?? $0.path })
    for root in learnedConfigDirectories.compactMap(projectsRoot(forConfigDirectory:)).sorted() {
      guard present.insert(root).inserted else { continue }
      result.append(TranscriptRoot(path: root, origin: .inferred))
    }
    return result
  }

  private static func joined(_ directory: String, _ component: String) -> String {
    directory.hasSuffix("/") ? directory + component : directory + "/" + component
  }
}
