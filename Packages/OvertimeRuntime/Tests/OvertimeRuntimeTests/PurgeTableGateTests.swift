import Foundation
import OvertimeAppSupport
import OvertimeHelperCore
import Testing

struct PurgeTableGateTests {
  static let template = "packaging/homebrew/overtime.rb.template"
  static let script = "scripts/uninstall.sh"
  static let projectSpec = "project.yml"

  static func repositoryFile(_ path: String) throws -> String {
    try String(
      contentsOf: NetworkSourceGateTests.repositoryRoot.appendingPathComponent(path), encoding: .utf8)
  }

  static func quoted(_ line: String) -> [String] {
    let parts = line.components(separatedBy: "\"")
    return parts.indices.filter { $0 % 2 == 1 && $0 < parts.count - 1 }.map { parts[$0] }
  }

  static func zapList(_ key: String, in cask: String) -> [String] {
    let lines = cask.components(separatedBy: "\n")
    let start = lines.firstIndex { line in
      var trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("zap ") { trimmed.removeFirst(4) }
      return trimmed.hasPrefix(key + ":")
    }
    guard let start else { return [] }
    var items: [String] = []
    for line in lines[start...] {
      items += quoted(line)
      if line.contains("]") { break }
    }
    return items
  }

  static func scriptArray(_ name: String, in script: String) -> [String]? {
    let lines = script.components(separatedBy: "\n")
    guard let start = lines.firstIndex(of: name + "=(") else { return nil }
    var items: [String] = []
    for line in lines[(start + 1)...] {
      if line == ")" { return items }
      items += quoted(line)
    }
    return nil
  }

  static func scriptConstant(_ name: String, in script: String) -> String? {
    let prefix = name + "=\""
    guard let line = script.components(separatedBy: "\n").first(where: { $0.hasPrefix(prefix) }) else { return nil }
    return quoted(line).first
  }

  static func alphabetical(_ paths: [String]) -> [String] {
    paths.sorted { $0.lowercased() < $1.lowercased() }
  }

  static func findings(table: PurgeTable, identity: HelperIdentity, cask: String, script: String) -> [String] {
    var findings: [String] = []
    let trash = zapList("trash", in: cask)
    let delete = zapList("delete", in: cask)
    for item in table.userItems where !trash.contains(item.caskPath) {
      findings.append("cask trash lacks \(item.caskPath)")
    }
    for item in table.rootItems where !delete.contains(item.caskPath) {
      findings.append("cask delete lacks \(item.caskPath)")
    }
    if trash != alphabetical(table.userItems.map(\.caskPath)) {
      findings.append("cask trash is not the table's user items in alphabetical order")
    }
    if delete != alphabetical(table.rootItems.map(\.caskPath)) {
      findings.append("cask delete is not the table's root items in alphabetical order")
    }
    let userItems = scriptArray("USER_ITEMS", in: script)
    let rootItems = scriptArray("ROOT_ITEMS", in: script)
    for item in table.userItems where !(userItems ?? []).contains(item.relativePath) {
      findings.append("script lacks \(item.relativePath)")
    }
    for item in table.rootItems where !(rootItems ?? []).contains(item.relativePath) {
      findings.append("script root items lack \(item.relativePath)")
    }
    if userItems != table.userItems.map(\.relativePath) { findings.append("script USER_ITEMS is not the table") }
    if rootItems != table.rootItems.map(\.relativePath) { findings.append("script ROOT_ITEMS is not the table") }
    if scriptConstant("APP_IDENTIFIER", in: script) != table.appIdentifier { findings.append("script APP_IDENTIFIER") }
    if scriptConstant("HELPER_LABEL", in: script) != identity.label { findings.append("script HELPER_LABEL") }
    if !cask.contains("uninstall quit: \"\(table.appIdentifier)\"") { findings.append("cask uninstall quit") }
    if !cask.contains("zap launchctl: \"\(identity.label)\"") { findings.append("cask zap launchctl") }
    return findings
  }

  @Test func theCaskZapAndTheScriptPurgeExactlyTheReleaseTable() throws {
    let cask = try Self.repositoryFile(Self.template)
    let script = try Self.repositoryFile(Self.script)
    #expect(Self.zapList("trash", in: cask).count == 7)
    #expect(Self.zapList("delete", in: cask).count == 2)
    #expect(Self.scriptArray("USER_ITEMS", in: script)?.count == 7)
    #expect(Self.scriptArray("ROOT_ITEMS", in: script)?.count == 2)
    #expect(Self.findings(table: .release, identity: .release, cask: cask, script: script) == [])
  }

  @Test func theScriptPrintsTheSameSleepAndFinalLinesAsOvertimeUninstall() throws {
    let script = try Self.repositoryFile(Self.script)
    #expect(Self.scriptConstant("NOT_OWNED_LINE", in: script) == HeadlessUninstall.notOwnedLine)
    #expect(Self.scriptConstant("UNKNOWN_OWNER_LINE", in: script) == HeadlessUninstall.unknownOwnerLine)
    #expect(Self.scriptConstant("STOPPED_LINE", in: script) == UninstallCopy.headlessStopped)
    #expect(Self.scriptConstant("PROBLEMS_LINE", in: script) == UninstallCopy.headlessProblems)
  }

  @Test func theProjectBundlesUninstallScriptAsAnAppResource() throws {
    let spec = try Self.repositoryFile(Self.projectSpec)
    let app = SparkleInfoPlistGateTests.targetBlock("Overtime", in: spec)
    #expect(!app.isEmpty)
    #expect(SparkleInfoPlistGateTests.listsResource(Self.script, in: app))
  }

  @Test func aTemplateMissingOneTrashEntryIsFound() throws {
    let cask = try Self.repositoryFile(Self.template)
    let script = try Self.repositoryFile(Self.script)
    let dropped = try #require(PurgeTable.release.userItems.last?.caskPath)
    let planted = cask.components(separatedBy: "\n").filter { !$0.contains("\"" + dropped + "\"") }
      .joined(separator: "\n")
    #expect(planted != cask)
    let found = Self.findings(table: .release, identity: .release, cask: planted, script: script)
    #expect(found.contains("cask trash lacks \(dropped)"))
  }
}
