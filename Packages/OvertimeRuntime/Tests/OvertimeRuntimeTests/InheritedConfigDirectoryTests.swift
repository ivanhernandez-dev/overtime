import Foundation
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing

struct InheritedConfigDirectoryTests {
  struct Fixture {
    let temp: TempDirectory
    let home: String
    let gone: String
    let paths: Paths

    init() throws {
      temp = try TempDirectory()
      let homeURL = temp.url.appendingPathComponent("home", isDirectory: true)
      let session = homeURL.appendingPathComponent(".claude/projects/-Users-dev-repo", isDirectory: true)
      try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
      try Data((#"{"type":"user","entrypoint":"cli"}"# + "\n").utf8)
        .write(to: session.appendingPathComponent("session.jsonl", isDirectory: false))
      home = homeURL.path(percentEncoded: false)
      gone = homeURL.appendingPathComponent("gone/sessions/4", isDirectory: false).path(percentEncoded: false)
      let state = temp.url.appendingPathComponent("state", isDirectory: true).path(percentEncoded: false)
      paths = Paths.resolve(environment: ["OVERTIME_HOME": state], homeDirectory: home)
    }

    func engine(settings: Settings) throws -> Engine {
      try Composition.makeShadowEngine(
        paths: paths, settings: settings, environment: ["CLAUDE_CONFIG_DIR": gone], homeDirectory: home, once: true,
        externalDisplays: { 0 }, tools: NoTools())
    }

    func lines() throws -> [String] {
      try String(contentsOf: paths.decisionLog(.shadow), encoding: .utf8).split(separator: "\n").map(String.init)
    }
  }

  @Test func aMissingInheritedConfigDirNeitherHidesTheHomeFolderNorWarns() async throws {
    let fixture = try Fixture()
    let engine = try fixture.engine(settings: Settings())
    await engine.runOnce()
    let goneRoot = try #require(TranscriptRoots.projectsRoot(forConfigDirectory: fixture.gone))
    let lines = try fixture.lines()
    #expect(!lines.contains { $0.contains(" WARN detectionHealth") })
    #expect(lines.filter { $0.contains(" CHECK transcriptRoot absent root=") }.count == 1)
    #expect(lines.contains { $0.hasSuffix(" CHECK transcriptRoot absent root=" + goneRoot) })
    #expect(await engine.state.busy.lastEligibleTranscript != nil)
    #expect(await engine.state.health.rootIssues.isEmpty)
    #expect(await engine.currentSnapshot().detectionWarnings.isEmpty)
  }

  @Test func aMissingConfiguredFolderStillWarnsThroughTheComposition() async throws {
    let fixture = try Fixture()
    let configured = URL(fileURLWithPath: fixture.home, isDirectory: true)
      .appendingPathComponent("configured-gone", isDirectory: false).path(percentEncoded: false)
    let engine = try fixture.engine(settings: Settings(transcriptRoots: [configured]))
    await engine.runOnce()
    let lines = try fixture.lines()
    #expect(lines.filter { $0.contains(" WARN detectionHealth reason=rootMissing root=") }.count == 1)
    #expect(lines.contains { $0.hasSuffix(" WARN detectionHealth reason=rootMissing root=" + configured) })
    #expect(await engine.currentSnapshot().detectionWarnings == [.rootMissing(configured)])
  }
}
