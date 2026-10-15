import Foundation
import Testing

@testable import OvertimeCore

struct TranscriptRootsTests {
  static let home = "/Users/dev"
  static let homeRoot = TranscriptRoot(path: "/Users/dev/.claude/projects", origin: .inferred)

  static func defaults(_ configDirectory: String?) -> [TranscriptRoot] {
    let environment = configDirectory.map { ["CLAUDE_CONFIG_DIR": $0] } ?? [:]
    return TranscriptRoots.defaults(environment: environment, homeDirectory: home)
  }

  static func inferred(_ path: String) -> TranscriptRoot {
    TranscriptRoot(path: path, origin: .inferred)
  }

  static func configured(_ path: String) -> TranscriptRoot {
    TranscriptRoot(path: path, origin: .configured)
  }

  @Test func normalizedPathResolvesDotsAndSlashesLexically() {
    #expect(TranscriptRoots.normalizedPath("/a//b/./c/../d") == "/a/b/d")
    #expect(TranscriptRoots.normalizedPath("/cfg/") == "/cfg")
    #expect(TranscriptRoots.normalizedPath("/") == "/")
    #expect(TranscriptRoots.normalizedPath("/..") == "/")
    #expect(TranscriptRoots.normalizedPath("relative/x") == nil)
    #expect(TranscriptRoots.normalizedPath("~/x") == nil)
    #expect(TranscriptRoots.normalizedPath("") == nil)
  }

  @Test func theHomeFolderIsWatchedWhateverTheEnvironmentSays() {
    #expect(Self.defaults(nil) == [Self.homeRoot])
    #expect(Self.defaults("") == [Self.homeRoot])
    #expect(Self.defaults("/cfg") == [Self.homeRoot, Self.inferred("/cfg/projects")])
  }

  @Test func theClaudeConfigDirFolderIsNormalizedAndDeduplicated() {
    #expect(Self.defaults("/cfg/") == [Self.homeRoot, Self.inferred("/cfg/projects")])
    #expect(Self.defaults("/cfg//.") == [Self.homeRoot, Self.inferred("/cfg/projects")])
    #expect(Self.defaults("/Users/dev/.claude") == [Self.homeRoot])
    #expect(Self.defaults("/Users/dev/.claude/") == [Self.homeRoot])
  }

  @Test func aClaudeConfigDirThatIsNotAnAbsolutePathIsIgnored() {
    #expect(Self.defaults("cfg") == [Self.homeRoot])
    #expect(Self.defaults("~/cfg") == [Self.homeRoot])
    #expect(Self.defaults("./cfg") == [Self.homeRoot])
  }

  @Test func theIncidentEnvironmentStillYieldsTheHomeFolder() {
    let environment = ["CLAUDE_CONFIG_DIR": "/Users/dev/.switcher/sessions/4"]
    let expected = [Self.homeRoot, Self.inferred("/Users/dev/.switcher/sessions/4/projects")]
    #expect(TranscriptRoots.defaults(environment: environment, homeDirectory: Self.home) == expected)
    #expect(Settings().transcriptRootSet(environment: environment, homeDirectory: Self.home) == expected)
    #expect(
      Settings.defaultTranscriptRoots(environment: environment, homeDirectory: Self.home) == expected.map(\.path))
  }

  @Test func configuredRootsAreKeptVerbatimAndReplaceTheDefaults() {
    let environment = ["CLAUDE_CONFIG_DIR": "/cfg"]
    #expect(
      Settings(transcriptRoots: ["/x/", "/y"]).transcriptRootSet(environment: environment, homeDirectory: Self.home)
        == [Self.configured("/x/"), Self.configured("/y")])
    #expect(
      Settings(transcriptRoots: []).transcriptRootSet(environment: environment, homeDirectory: Self.home)
        == TranscriptRoots.defaults(environment: environment, homeDirectory: Self.home))
  }

  @Test func learnedConfigDirectoriesAreAddedAsInferredRootsAfterTheBase() {
    #expect(
      TranscriptRoots.adding(learnedConfigDirectories: ["/cfg", "/b", "/cfg/", "rel", ""], to: [Self.homeRoot]) == [
        Self.homeRoot, Self.inferred("/b/projects"), Self.inferred("/cfg/projects"),
      ])
    #expect(
      TranscriptRoots.adding(learnedConfigDirectories: ["/cfg"], to: [Self.configured("/x/")]) == [
        Self.configured("/x/"), Self.inferred("/cfg/projects"),
      ])
  }

  @Test func aLearnedDirectoryAlreadyCoveredByTheBaseAddsNothing() {
    #expect(
      TranscriptRoots.adding(learnedConfigDirectories: ["/Users/dev/.claude"], to: [Self.homeRoot]) == [Self.homeRoot])
    #expect(
      TranscriptRoots.adding(learnedConfigDirectories: ["/x"], to: [Self.configured("/x/projects/")]) == [
        Self.configured("/x/projects/")
      ])
  }
}
