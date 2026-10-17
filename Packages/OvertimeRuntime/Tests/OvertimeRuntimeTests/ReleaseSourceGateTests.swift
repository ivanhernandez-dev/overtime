import Foundation
import Testing

struct ReleaseSourceGateTests {
  typealias SourceFile = NetworkSourceGateTests.SourceFile

  struct Line: Sendable {
    let number: Int
    let text: String
  }

  static let releaseWorkflow = ".github/workflows/release.yml"
  static let ciWorkflow = ".github/workflows/ci.yml"
  static let caskTemplate = "packaging/homebrew/overtime.rb.template"
  static let uninstallScript = "scripts/uninstall.sh"
  static let pipelineScript = "scripts/release/lib/pipeline.sh"
  static let publishScript = "scripts/release/publish.sh"
  static let pinsFile = "scripts/release/pins.env"
  static let projectSpec = "project.yml"
  static let keysRecord = "docs/adr/0008-long-lived-t1-signing-identity-and-keys.md"
  static let loginItemAdapter = "Sources/Overtime/Adapters/SMAppServiceLoginItem.swift"
  static let uninstallAdapter = "Sources/Overtime/Adapters/LiveUninstallSystem.swift"
  static let releaseSecrets: Set<String> = [
    "T1_P12_BASE64", "T1_P12_PASSWORD", "SPARKLE_ED_PRIVATE_KEY", "HOMEBREW_TAP_TOKEN",
  ]
  static let mainAppService = ["SMAppService", "mainApp"].joined(separator: ".")
  static let caskUninstallLine = #"uninstall quit: "io.github.ivanhernandez-dev.overtime""#
  static let pinnedAction = #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}$"#
  static let cutReleaseWorkflow = ".github/workflows/cut-release.yml"
  static let cutReleaseScript = "scripts/release/cut-release.sh"
  static let actionlintScript = "scripts/ci/actionlint.sh"
  static let releaseTagGuard = "    if: startsWith(github.ref, 'refs/tags/v')"
  static let atomicPush = #"git push --atomic origin HEAD:refs/heads/main "refs/tags/v$VERSION""#
  static let cutDispatchTargets = ["release.yml", "ci.yml"]
  static let cutJobWrites = ["      actions: write", "      contents: write"]

  static func read(_ path: String) throws -> SourceFile {
    let url = NetworkSourceGateTests.repositoryRoot.appendingPathComponent(path)
    return SourceFile(path: path, text: try String(contentsOf: url, encoding: .utf8))
  }

  static func files(under directory: String) throws -> [SourceFile] {
    let rootPath = NetworkSourceGateTests.repositoryRoot.standardizedFileURL.path + "/"
    let base = NetworkSourceGateTests.repositoryRoot.appendingPathComponent(directory)
    let enumerator = try #require(
      FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey]))
    var result: [SourceFile] = []
    for case let url as URL in enumerator where url.lastPathComponent != ".DS_Store" {
      guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
      let full = url.standardizedFileURL.path
      let path = full.hasPrefix(rootPath) ? String(full.dropFirst(rootPath.count)) : full
      result.append(SourceFile(path: path, text: try String(contentsOf: url, encoding: .utf8)))
    }
    return result.sorted { $0.path < $1.path }
  }

  static func scripts() throws -> [SourceFile] {
    try files(under: "scripts")
  }

  static func workflows() throws -> [SourceFile] {
    try files(under: ".github/workflows").filter { $0.path.hasSuffix(".yml") }
  }

  static func releaseCorpus() throws -> [SourceFile] {
    try scripts() + workflows()
  }

  static func planted(_ files: [SourceFile], in path: String, _ addition: String) throws -> [SourceFile] {
    #expect(files.contains { $0.path == path })
    return files.map { $0.path == path ? SourceFile(path: path, text: $0.text + "\n" + addition + "\n") : $0 }
  }

  static func replacing(_ files: [SourceFile], in path: String, _ old: String, with new: String) throws
    -> [SourceFile]
  {
    let file = try #require(files.first { $0.path == path })
    #expect(file.text.contains(old))
    return files.map {
      $0.path == path ? SourceFile(path: path, text: $0.text.replacingOccurrences(of: old, with: new)) : $0
    }
  }

  static func expectOne(_ findings: [String], naming path: String) {
    #expect(findings.count == 1, "\(findings)")
    #expect(findings.first?.hasPrefix(path) == true, "\(findings)")
  }

  static func matches(_ text: String, _ pattern: String) -> Bool {
    text.range(of: pattern, options: .regularExpression) != nil
  }

  static func plainLines(_ text: String) -> [Line] {
    text.components(separatedBy: "\n").enumerated().map { Line(number: $0.offset + 1, text: $0.element) }
  }

  static func logicalLines(_ text: String) -> [Line] {
    var lines: [Line] = []
    var pending = ""
    var start = 1
    for line in plainLines(text) {
      if pending.isEmpty { start = line.number }
      if line.text.hasSuffix("\\") {
        pending += String(line.text.dropLast()) + " "
        continue
      }
      lines.append(Line(number: start, text: pending + line.text))
      pending = ""
    }
    if !pending.isEmpty { lines.append(Line(number: start, text: pending)) }
    return lines
  }

  static func lineFindings(_ files: [SourceFile], _ rule: String, _ hit: (String) -> Bool) -> [String] {
    files.flatMap { file in
      logicalLines(file.text).filter { hit($0.text) }.map { "\(file.path):\($0.number) \(rule)" }
    }
  }

  static func indentation(_ line: String) -> Int {
    line.prefix { $0 == " " }.count
  }

  static func yamlKey(_ line: String) -> String {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return trimmed.hasPrefix("- ") ? String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces) : trimmed
  }

  static func recursiveSigningFindings(_ files: [SourceFile]) -> [String] {
    lineFindings(files, "recursive codesign flag") { matches($0, #"(^|[\s("'=])--deep(["')\s=]|$)"#) }
  }

  static func keyGeneratorFindings(_ files: [SourceFile]) -> [String] {
    lineFindings(files, "Sparkle key generator") { $0.contains("generate_keys") }
  }

  static func keyOnCommandLineFindings(_ files: [SourceFile]) -> [String] {
    lineFindings(files, "key on a command line") { line in
      if matches(line, #"--ed-key-file(?!\s+-(\s|$))"#) { return true }
      return matches(line, #"\b(generate_appcast|sign_update)\b"#) && matches(line, #"(^|\s)-s(\s|$)"#)
    }
  }

  static func keysFolderFindings(_ files: [SourceFile]) -> [String] {
    lineFindings(files, "keys folder path") { $0.contains("Documents/Keys") }
  }

  static func commandFindings(_ files: [SourceFile], _ command: String) -> [String] {
    let prefix = #"(^|[;&|()`:{!]|\b(if|elif|while|until|then|do|else|sudo|exec|env|command|xargs|time))\s*"#
    let assignments = #"([A-Za-z_][A-Za-z0-9_]*=("[^"]*"|'[^']*'|[^\s"'])*\s+)*"#
    let pattern = prefix + assignments + "(/usr/bin/)?" + command + #"(\s|$|;|\))"#
    return lineFindings(files, "\(command) command") { matches($0, pattern) || $0.contains("/usr/bin/\(command)") }
  }

  static func securityCommandFindings(_ files: [SourceFile]) -> [String] {
    let scope = files.filter {
      $0.path.hasPrefix("scripts/release/") || $0.path.hasPrefix("scripts/ci/") || $0.path == uninstallScript
        || $0.path == ciWorkflow
    }
    return commandFindings(scope, "security")
  }

  static func mainAppUnregisterFindings(_ files: [SourceFile]) -> [String] {
    lineFindings(files.filter { $0.path != loginItemAdapter }, "\(mainAppService).unregister") {
      $0.contains("mainApp.unregister")
    }
  }

  static func caskUninstallFindings(_ cask: SourceFile) -> [String] {
    let lines = plainLines(cask.text).filter { $0.text.trimmingCharacters(in: .whitespaces).hasPrefix("uninstall") }
    guard lines.count == 1, let line = lines.first else {
      return ["\(cask.path) has \(lines.count) uninstall lines"]
    }
    return line.text.trimmingCharacters(in: .whitespaces) == caskUninstallLine
      ? [] : ["\(cask.path):\(line.number) uninstall beyond quit"]
  }

  static let servedCask = "Casks/overtime.rb"
  static let shortVersionLivecheck = "    strategy :sparkle, &:short_version"
  static let caskVersionPattern = #"^(0|[1-9][0-9]?)\.(0|[1-9][0-9]?)\.(0|[1-9][0-9]?)$"#
  static let caskShaPattern = #"^[0-9a-f]{64}$"#
  static let tapLoadedFolders: Set<String> = ["cmd", "completions", "formula", "homebrewformula", "manpages"]
  static let tapNameFiles: Set<String> = ["cask_renames.json", "formula_renames.json", "tap_migrations.json"]

  static func caskValue(_ key: String, in file: SourceFile) -> String? {
    let lines = plainLines(file.text).map { $0.text.trimmingCharacters(in: .whitespaces) }.filter {
      $0.hasPrefix(key + " ")
    }
    guard lines.count == 1, let line = lines.first else { return nil }
    let quoted = line.dropFirst(key.count + 1)
    guard quoted.count >= 2, quoted.hasPrefix("\""), quoted.hasSuffix("\"") else { return nil }
    let value = quoted.dropFirst().dropLast()
    return value.contains("\"") ? nil : String(value)
  }

  static func servedCaskFindings(cask: SourceFile, template: SourceFile) -> [String] {
    guard let version = caskValue("version", in: cask) else { return ["\(cask.path) has no single version line"] }
    guard matches(version, caskVersionPattern) else {
      return ["\(cask.path) version \(version) is not X.Y.Z with parts 0 to 99"]
    }
    guard let sha = caskValue("sha256", in: cask) else { return ["\(cask.path) has no single sha256 line"] }
    guard matches(sha, caskShaPattern) else { return ["\(cask.path) sha256 is not 64 lowercase hex characters"] }
    var findings: [String] = []
    let strategies = plainLines(template.text).filter {
      $0.text.trimmingCharacters(in: .whitespaces).hasPrefix("strategy ")
    }
    if strategies.count != 1 || strategies.first?.text != shortVersionLivecheck {
      findings.append("\(template.path) lacks the Sparkle short-version livecheck")
    }
    let rendered = template.text.replacingOccurrences(of: "{{VERSION}}", with: version)
      .replacingOccurrences(of: "{{ZIP_SHA256}}", with: sha)
    if rendered != cask.text {
      findings.append("\(cask.path) is not \(template.path) rendered for \(version)")
    }
    return findings
  }

  static func servedCaskMutant(_ name: String, cask: SourceFile, template: SourceFile) throws
    -> (cask: SourceFile, template: SourceFile)
  {
    let version = try #require(caskValue("version", in: cask))
    let sha = try #require(caskValue("sha256", in: cask))
    func edit(_ file: SourceFile, _ old: String, _ new: String) throws -> SourceFile {
      let changed = try #require(try replacing([file], in: file.path, old, with: new).first)
      #expect(changed.text != file.text, "\(name)")
      return changed
    }
    let bareLivecheck = "    strategy :sparkle\n"
    let versionLine = #"version "\#(version)""#
    let shaLine = #"sha256 "\#(sha)""#
    switch name {
    case "the bare Sparkle livecheck in the cask only":
      return (try edit(cask, shortVersionLivecheck + "\n", bareLivecheck), template)
    case "a two-part version":
      let twoParts = version.split(separator: ".").dropLast().joined(separator: ".")
      return (try edit(cask, versionLine, #"version "\#(twoParts)""#), template)
    case "a leading-zero version part":
      return (try edit(cask, versionLine, #"version "0\#(version)""#), template)
    case "an uppercase sha256":
      return (try edit(cask, shaLine, #"sha256 "\#(sha.uppercased())""#), template)
    case "a second version line":
      let line = "  version \"\(version)\"\n"
      return (try edit(cask, line, line + line), template)
    case "a placeholder left in the cask":
      return (try edit(cask, shaLine, #"sha256 "{{ZIP_SHA256}}""#), template)
    case "an extra trash path in the cask only":
      let anchor = "      trash:     [\n"
      return (try edit(cask, anchor, anchor + "        \"~/Library/Planted\",\n"), template)
    case "the bare Sparkle livecheck in the template and the cask":
      return (
        try edit(cask, shortVersionLivecheck + "\n", bareLivecheck),
        try edit(template, shortVersionLivecheck + "\n", bareLivecheck)
      )
    default:
      Issue.record("unknown mutant \(name)")
      return (cask, template)
    }
  }

  static func tapSurfaceFindings(root: [String], casks: [String]) -> [String] {
    var findings: [String] = []
    for entry in root.sorted() {
      let name = entry.lowercased()
      if name.hasSuffix(".rb") {
        findings.append("\(entry) is a formula Homebrew loads from a tap root")
      } else if tapLoadedFolders.contains(name) {
        findings.append("\(entry) is a folder Homebrew loads from a tap")
      } else if tapNameFiles.contains(name) {
        findings.append("\(entry) renames or moves names in a tap")
      }
    }
    let served = casks.filter { $0 != ".DS_Store" }
    findings += served.filter { $0 != "overtime.rb" }.sorted().map { "Casks/\($0) is a second cask" }
    if !served.contains("overtime.rb") {
      findings.append("\(servedCask) is missing")
    }
    return findings
  }

  static func liveTapSurface() throws -> (root: [String], casks: [String]) {
    let manager = FileManager.default
    let root = try manager.contentsOfDirectory(atPath: NetworkSourceGateTests.repositoryRoot.path)
    let casksPath = NetworkSourceGateTests.repositoryRoot.appendingPathComponent("Casks").path
    var casks: [String] = []
    if manager.fileExists(atPath: casksPath) {
      casks = try manager.contentsOfDirectory(atPath: casksPath)
    }
    return (root, casks)
  }

  static func forbiddenWorkflowFindings(_ files: [SourceFile]) -> [String] {
    lineFindings(files, "pull_request_target") { $0.contains("pull_request_target") }
      + lineFindings(files, "macos-14 runner") { $0.contains("macos-14") }
  }

  static func usesValue(_ line: String) -> String? {
    let key = yamlKey(line)
    guard key.hasPrefix("uses:") else { return nil }
    return key.dropFirst("uses:".count).split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
  }

  static func usesValues(_ files: [SourceFile]) -> [String] {
    files.flatMap { plainLines($0.text).compactMap { usesValue($0.text) } }
  }

  static func actionPinFindings(_ files: [SourceFile]) -> [String] {
    lineFindings(files, "action not pinned to a commit") { line in
      guard let value = usesValue(line) else { return false }
      return !matches(value, pinnedAction)
    }
  }

  static func releaseCacheFindings(_ files: [SourceFile]) -> [String] {
    lineFindings(files.filter { $0.path == releaseWorkflow }, "actions/cache in release") {
      $0.contains("actions/cache")
    }
  }

  static func secretNames(_ line: String) -> [String] {
    guard let expression = try? NSRegularExpression(pattern: #"secrets\.([A-Za-z0-9_]+)"#) else { return [] }
    let range = NSRange(line.startIndex..., in: line)
    return expression.matches(in: line, range: range).compactMap { match in
      Range(match.range(at: 1), in: line).map { String(line[$0]) }
    }
  }

  static func isStepEnvironmentEntry(_ lines: [Line], at index: Int) -> Bool {
    let line = lines[index].text
    guard matches(line, #"^\s+[A-Z0-9_]+: \$\{\{ (secrets\.[A-Z0-9_]+|github\.token) \}\}\s*$"#) else { return false }
    guard let envIndex = parentIndex(lines, of: index), yamlKey(lines[envIndex].text) == "env:" else { return false }
    guard let stepIndex = parentIndex(lines, of: envIndex) else { return false }
    return lines[stepIndex].text.trimmingCharacters(in: .whitespaces).hasPrefix("- ")
  }

  static func parentIndex(_ lines: [Line], of index: Int) -> Int? {
    let own = indentation(lines[index].text)
    var cursor = index - 1
    while cursor >= 0 {
      let text = lines[cursor].text
      if !text.trimmingCharacters(in: .whitespaces).isEmpty && indentation(text) < own { return cursor }
      cursor -= 1
    }
    return nil
  }

  static func expressions(_ line: String) -> [String] {
    guard let expression = try? NSRegularExpression(pattern: #"\$\{\{(.*?)\}\}"#) else { return [] }
    let range = NSRange(line.startIndex..., in: line)
    return expression.matches(in: line, range: range).compactMap { match in
      Range(match.range(at: 1), in: line).map { String(line[$0]) }
    }
  }

  static func mentionsCredential(_ line: String) -> Bool {
    if line.contains("secrets.") || line.contains("github.token") { return true }
    return expressions(line).contains {
      matches($0, #"\bsecrets\b"#) || matches($0, #"\bgithub\b(?!\s*\.\s*[A-Za-z_])"#)
    }
  }

  static func wholeOrIndexedContext(_ line: String) -> Bool {
    expressions(line).contains { matches($0, #"\b(secrets|github)\b(?!\s*\.\s*[A-Za-z_])"#) }
  }

  static func secretFindings(_ files: [SourceFile]) -> [String] {
    files.flatMap { file -> [String] in
      let lines = plainLines(file.text)
      return lines.indices.flatMap { index -> [String] in
        let line = lines[index]
        guard mentionsCredential(line.text) else { return [] }
        let place = "\(file.path):\(line.number)"
        if wholeOrIndexedContext(line.text) { return ["\(place) whole or indexed secrets or github context"] }
        if file.path == cutReleaseWorkflow {
          if line.text.contains("secrets.") { return ["\(place) secret outside release.yml"] }
          return isStepEnvironmentEntry(lines, at: index) ? [] : ["\(place) credential outside a step env"]
        }
        guard file.path == releaseWorkflow else { return ["\(place) credential outside release.yml"] }
        let unknown = secretNames(line.text).filter { !releaseSecrets.contains($0) }
        if !unknown.isEmpty { return ["\(place) unexpected secret \(unknown.joined(separator: ","))"] }
        return isStepEnvironmentEntry(lines, at: index) ? [] : ["\(place) credential outside a step env"]
      }
    }
  }

  static func runInterpolationFindings(_ files: [SourceFile]) -> [String] {
    files.flatMap { file -> [String] in
      var findings: [String] = []
      var blockIndent: Int?
      for line in plainLines(file.text) {
        let indent = indentation(line.text)
        let trimmed = line.text.trimmingCharacters(in: .whitespaces)
        if let block = blockIndent {
          if trimmed.isEmpty || indent > block {
            if line.text.contains("${{") { findings.append("\(file.path):\(line.number) expression in a run script") }
            continue
          }
          blockIndent = nil
        }
        let key = yamlKey(line.text)
        guard key.hasPrefix("run:") else { continue }
        let rest = key.dropFirst("run:".count).trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("|") || rest.hasPrefix(">") {
          blockIndent = indent + (trimmed.hasPrefix("- ") ? 2 : 0)
        } else if rest.contains("${{") {
          findings.append("\(file.path):\(line.number) expression in a run script")
        }
      }
      return findings
    }
  }

  static let sameRepositoryGuard = "github.event.pull_request.head.repo.full_name == github.repository"
  static let hostedRunnerPrefixes = ["macos-", "ubuntu-"]

  static func runsOnPullRequests(_ file: SourceFile) -> Bool {
    plainLines(file.text).contains { matches(yamlKey($0.text), #"^(on:.*)?\bpull_request\b(?!_)"#) }
  }

  static func runnerTrustFindings(_ files: [SourceFile]) -> [String] {
    files.filter(runsOnPullRequests).flatMap { file -> [String] in
      let section = jobSection(file)
      return section.unreadable
        + section.blocks.compactMap { block -> String? in
          let body = block.lines.map { yamlContent($0.text) }.filter { indentation($0) == 4 }.map(yamlKey)
          let guarded = body.contains { $0.hasPrefix("if:") && $0.contains(sameRepositoryGuard) }
          let runners = body.filter { $0.hasPrefix("runs-on:") }
          guard runners.count == 1, let runner = runners.first else {
            return guarded ? nil : "\(file.path):\(block.header.number) job without one readable runs-on"
          }
          let label = runner.dropFirst("runs-on:".count).trimmingCharacters(in: .whitespaces)
          let hosted = hostedRunnerPrefixes.contains { label.hasPrefix($0) }
          return hosted || guarded ? nil : "\(file.path):\(block.header.number) job on \(label) runs fork pull requests"
        }
    }
  }

  static func grantsWrite(_ line: String) -> Bool {
    matches(line, #"\bwrite-all\b"#) || matches(line, #"^\s*[A-Za-z-]+:\s*['"]?write['"]?\s*(#.*)?$"#)
      || matches(line, #"\{[^}]*:\s*['"]?write\b"#)
  }

  static func writePermissionFindings(_ files: [SourceFile]) -> [String] {
    let scope = files.filter { $0.path != releaseWorkflow && $0.path != cutReleaseWorkflow }
    return lineFindings(scope, "write permission outside release.yml") {
      grantsWrite($0)
    }
  }

  static let yamlReferencePatterns = [
    #"(^|[\s:\[{,-])&[A-Za-z0-9_-]+"#, #"(^|[\s:\[{,-])\*[A-Za-z0-9_-]+"#, "<<:",
  ]

  static func anchorFindings(_ files: [SourceFile]) -> [String] {
    files.flatMap { file in
      plainLines(file.text).filter { line in
        let content = yamlContent(line.text)
        return yamlReferencePatterns.contains { matches(content, $0) }
      }.map { "\(file.path):\($0.number) YAML anchor, alias or merge key" }
    }
  }

  static func yamlContent(_ line: String) -> String {
    var single = false
    var double = false
    var previous: Character = " "
    var end = line.endIndex
    for index in line.indices {
      let character = line[index]
      if character == "'" && !double {
        single.toggle()
      } else if character == "\"" && !single {
        double.toggle()
      } else if character == "#" && !single && !double && previous.isWhitespace {
        end = index
        break
      }
      previous = character
    }
    return String(String(line[..<end].reversed()).drop { $0.isWhitespace }.reversed())
  }

  static func isBlank(_ content: String) -> Bool {
    content.allSatisfy(\.isWhitespace)
  }

  static func jobSection(_ file: SourceFile) -> (blocks: [(header: Line, lines: [Line])], unreadable: [String]) {
    let lines = plainLines(file.text)
    let jobsLines = lines.indices.filter { yamlContent(lines[$0].text) == "jobs:" }
    guard jobsLines.count == 1, let jobsIndex = jobsLines.first else {
      return ([], ["\(file.path) has \(jobsLines.count) readable jobs: keys"])
    }
    var blocks: [(header: Line, lines: [Line])] = []
    var unreadable: [String] = []
    var index = jobsIndex + 1
    while index < lines.count {
      let line = lines[index]
      let content = yamlContent(line.text)
      if isBlank(content) {
        index += 1
        continue
      }
      if indentation(content) == 0 && !content.hasPrefix("\t") { break }
      var end = index + 1
      while end < lines.count {
        let next = yamlContent(lines[end].text)
        guard isBlank(next) || indentation(next) > 2 else { break }
        end += 1
      }
      if indentation(content) == 2, matches(content, #"^  ("[^"]+"|'[^']+'|[A-Za-z0-9_-]+):$"#) {
        blocks.append((header: line, lines: Array(lines[(index + 1)..<end])))
      } else {
        unreadable.append("\(file.path):\(line.number) job line the gate cannot read")
      }
      index = end
    }
    return (blocks, unreadable)
  }

  static func jobBlocks(_ file: SourceFile) -> [(header: Line, lines: [Line])] {
    jobSection(file).blocks
  }

  static func environmentIsRelease(_ block: [Line]) -> Bool {
    let contents = block.map { yamlContent($0.text) }
    let keys = contents.indices.filter {
      indentation(contents[$0]) == 4 && contents[$0].trimmingCharacters(in: .whitespaces).hasPrefix("environment:")
    }
    guard keys.count == 1, let keyIndex = keys.first else { return false }
    let value = contents[keyIndex].trimmingCharacters(in: .whitespaces).dropFirst("environment:".count)
      .trimmingCharacters(in: .whitespaces)
    let release = #"['"]?release['"]?"#
    if matches(value, "^" + release + "$") { return true }
    if value.hasPrefix("{") {
      return matches(value, #"^\{([^}]*,)?\s*name:\s*"# + release + #"\s*(,[^}]*)?\}$"#)
    }
    guard value.isEmpty else { return false }
    let mapping = contents[(keyIndex + 1)...].prefix { isBlank($0) || indentation($0) > 4 }
    let names = mapping.filter { indentation($0) == 6 && $0.trimmingCharacters(in: .whitespaces).hasPrefix("name:") }
    return names.count == 1 && names.allSatisfy { matches($0, #"^\s{6}name:\s*"# + release + "$") }
  }

  static func releaseEnvironmentFindings(_ release: SourceFile) -> [String] {
    let section = jobSection(release)
    let lines = plainLines(release.text)
    let jobsIndex = lines.firstIndex { yamlContent($0.text) == "jobs:" } ?? lines.count
    let workflowWrites = lines[..<jobsIndex].contains { grantsWrite(yamlContent($0.text)) }
    let publishing = section.blocks.filter { block in
      workflowWrites || block.lines.contains { mentionsCredential($0.text) || grantsWrite(yamlContent($0.text)) }
    }
    guard !publishing.isEmpty || !section.unreadable.isEmpty else {
      return ["\(release.path) has no job that holds the release secrets"]
    }
    return section.unreadable
      + publishing.compactMap { block in
        environmentIsRelease(block.lines)
          ? nil : "\(release.path):\(block.header.number) publishing job outside the release environment"
      }
  }

  static let bashFourPatterns: [(name: String, pattern: String)] = [
    ("mapfile", #"\bmapfile\b"#),
    ("readarray", #"\breadarray\b"#),
    ("associative array", #"\b(declare|local|typeset)\s+-[A-Za-z]*A"#),
    ("case-changing expansion", #"\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^\]]*\])?(\^|,)"#),
    ("|& pipe", #"\|&"#),
    ("&>> redirection", "&>>"),
  ]

  static func bashPortabilityFindings(_ files: [SourceFile]) -> [String] {
    files.filter { $0.path.hasSuffix(".sh") }.flatMap { file -> [String] in
      var findings: [String] = []
      if file.text.components(separatedBy: "\n").first != "#!/bin/bash" {
        findings.append("\(file.path):1 shebang is not #!/bin/bash")
      }
      for line in logicalLines(file.text) {
        for feature in bashFourPatterns where matches(line.text, feature.pattern) {
          findings.append("\(file.path):\(line.number) \(feature.name)")
        }
      }
      return findings
    }
  }

  static func traceFindings(_ files: [SourceFile]) -> [String] {
    let scope = files.filter { $0.path.hasPrefix("scripts/release/") || $0.path.hasPrefix(".github/workflows/") }
    return lineFindings(scope, "shell trace") {
      matches($0, #"\bset\s+-[A-Za-z]*x"#) || matches($0, #"\bset\s+-o\s+xtrace\b"#)
    }
  }

  static func value(of key: String, separator: String, in file: SourceFile) -> String? {
    for line in plainLines(file.text) {
      let trimmed = line.text.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix(key + separator) {
        return String(trimmed.dropFirst((key + separator).count)).trimmingCharacters(in: .whitespaces)
      }
    }
    return nil
  }

  static func recordedKey(in keys: SourceFile) -> String? {
    guard let line = plainLines(keys.text).first(where: { $0.text.contains("Sparkle EdDSA public key") }) else {
      return nil
    }
    let parts = line.text.components(separatedBy: "`")
    return parts.count >= 3 ? parts[1] : nil
  }

  static func pinFindings(pins: SourceFile, spec: SourceFile, keys: SourceFile) -> [String] {
    guard let recorded = recordedKey(in: keys) else { return ["\(keys.path) records no Sparkle public key"] }
    var findings: [String] = []
    let pinnedKey = value(of: "SPARKLE_PUBLIC_ED_KEY", separator: "=", in: pins)
    if pinnedKey != recorded { findings.append("\(pins.path) SPARKLE_PUBLIC_ED_KEY differs from \(keys.path)") }
    let specKey = value(of: "SPARKLE_PUBLIC_ED_KEY", separator: ":", in: spec)
    if specKey != recorded { findings.append("\(spec.path) SPARKLE_PUBLIC_ED_KEY differs from \(keys.path)") }
    let pinnedVersion = value(of: "SPARKLE_VERSION", separator: "=", in: pins)
    let specVersion = value(of: "exactVersion", separator: ":", in: spec)
    if pinnedVersion == nil || pinnedVersion != specVersion {
      findings.append("\(pins.path) SPARKLE_VERSION differs from \(spec.path) exactVersion")
    }
    return findings
  }

  static func uninstallRootFindings(_ script: SourceFile) -> [String] {
    let expanding = logicalLines(script.text).filter { matches($0.text, #"\$\{?OVERTIME_UNINSTALL_ROOT\b"#) }
    var findings = commandFindings([script], "defaults")
    if expanding.count != 1 {
      findings.append("\(script.path) expands OVERTIME_UNINSTALL_ROOT on \(expanding.count) lines")
    } else if let line = expanding.first, !line.text.contains("OVERTIME_SCRIPT_TESTS") {
      findings.append("\(script.path):\(line.number) OVERTIME_UNINSTALL_ROOT without the test marker")
    }
    return findings
  }

  static func helperSigningFindings(_ pipeline: SourceFile) -> [String] {
    let lines = plainLines(pipeline.text)
    guard let start = lines.firstIndex(where: { $0.text.hasPrefix("ot_sign_inside_out()") }) else {
      return ["\(pipeline.path) has no ot_sign_inside_out"]
    }
    let body = lines[(start + 1)...].prefix { $0.text != "}" }
    return body.filter { $0.text.contains("OvertimeHelper") }.map {
      "\(pipeline.path):\($0.number) the pipeline signs the helper"
    }
  }

  @Test func theRepositoryHasTheScriptsAndWorkflowsTheGatesRead() throws {
    let corpus = try Self.releaseCorpus()
    let paths = [
      Self.releaseWorkflow, Self.ciWorkflow, Self.cutReleaseWorkflow, Self.pipelineScript, Self.publishScript,
      Self.uninstallScript, Self.cutReleaseScript, Self.actionlintScript,
    ]
    for path in paths {
      #expect(corpus.contains { $0.path == path }, "\(path)")
    }
    #expect(try Self.workflows().count == 3)
  }

  @Test func noScriptOrWorkflowSignsRecursivelyGeneratesKeysOrPassesAKey() throws {
    let corpus = try Self.releaseCorpus()
    #expect(Self.recursiveSigningFindings(corpus) == [])
    #expect(Self.keyGeneratorFindings(corpus) == [])
    #expect(Self.keyOnCommandLineFindings(corpus) == [])
    #expect(Self.keysFolderFindings(corpus + [try Self.read(Self.caskTemplate)]) == [])
    #expect(try Self.read(Self.pipelineScript).text.contains("--ed-key-file -"))
  }

  @Test(arguments: [
    (pipelineScript, #"  codesign --force --deep -s "$identity" "$app""#),
    (releaseWorkflow, "          codesign --deep --verify Overtime.app"),
    (pipelineScript, "  flags=(--deep --force)"),
    (pipelineScript, #"  codesign "--deep" -s "$identity" "$app""#),
    (publishScript, #"  codesign --force '--deep' -s - "$app""#),
  ])
  func theRecursiveSigningGateCatchesAPlantedFlag(path: String, line: String) throws {
    let corpus = try Self.planted(try Self.releaseCorpus(), in: path, line)
    Self.expectOne(Self.recursiveSigningFindings(corpus), naming: path)
  }

  @Test func theKeyGeneratorGateCatchesAPlantedCall() throws {
    let line = #""$OT_SPARKLE_ARTIFACT/bin/generate_keys" --account overtime"#
    let findings = Self.keyGeneratorFindings(try Self.planted(try Self.releaseCorpus(), in: Self.pipelineScript, line))
    Self.expectOne(findings, naming: Self.pipelineScript)
  }

  @Test(arguments: [
    #"generate_appcast --ed-key-file "$KEY" "$stage""#,
    "generate_appcast --ed-key-file=/private/key \"$stage\"",
    #"sign_update -s "$SPARKLE_ED_PRIVATE_KEY" archive.zip"#,
    "\"$OT_SPARKLE_ARTIFACT/bin/generate_appcast\" \\\n  -s \"$key\" \"$stage\"",
  ])
  func theKeyOnCommandLineGateCatchesAPlantedKey(line: String) throws {
    let findings = Self.keyOnCommandLineFindings(
      try Self.planted(try Self.releaseCorpus(), in: Self.pipelineScript, line))
    Self.expectOne(findings, naming: Self.pipelineScript)
  }

  @Test func theKeysFolderGateCatchesAPlantedPath() throws {
    let line = #"cp "$HOME/Documents/Keys/overtime/sparkle-ed25519-private.key" "$out""#
    let findings = Self.keysFolderFindings(try Self.planted(try Self.releaseCorpus(), in: Self.publishScript, line))
    Self.expectOne(findings, naming: Self.publishScript)
  }

  @Test func theSecurityToolRunsOnlyInTheReleaseWorkflow() throws {
    let corpus = try Self.releaseCorpus()
    #expect(Self.securityCommandFindings(corpus) == [])
    #expect(try Self.read(Self.releaseWorkflow).text.contains("security create-keychain"))
  }

  @Test(arguments: [
    (publishScript, "security find-identity -v -p codesigning"),
    ("scripts/ci/actionlint.sh", #"password="$(security find-generic-password -wa overtime)""#),
    (uninstallScript, "  /usr/bin/security delete-keychain overtime.keychain-db"),
    (uninstallScript, "  sudo security delete-certificate -Z 9C54A8E3"),
    (ciWorkflow, "        run: security list-keychains"),
    (publishScript, "if security find-identity -v -p codesigning > /dev/null; then"),
    (pipelineScript, "  elif security list-keychains -d user; then"),
    ("scripts/ci/actionlint.sh", "while security find-identity -p codesigning; do"),
    ("scripts/release/pin-helper.sh", "until security unlock-keychain overtime.keychain-db; do"),
    (uninstallScript, "  ! security delete-keychain overtime.keychain-db"),
    (publishScript, "{ security delete-keychain overtime.keychain-db; } || true"),
    (uninstallScript, "    a) security list-keychains ;;"),
    (publishScript, "  --keys) security find-identity -v -p codesigning ;;"),
    (publishScript, "LC_ALL=C security find-identity -v"),
    (pipelineScript, #"  OT_LABEL="a b" LC_ALL=C security list-keychains"#),
    ("scripts/ci/actionlint.sh", "  if LC_ALL=C security find-identity; then"),
  ])
  func theSecurityGateCatchesAPlantedCommand(path: String, line: String) throws {
    let corpus = try Self.planted(try Self.releaseCorpus(), in: path, line)
    Self.expectOne(Self.securityCommandFindings(corpus), naming: path)
  }

  @Test(arguments: [
    "SECURITY_NOTE=1",
    "local securityType=1",
    #"printf '%s\n' "insecurity""#,
    "for tool in sudo launchctl pmset; do",
    #"[ ! -e "$security_file" ] || exit 1"#,
    #"printf '%s\n' "${security}""#,
    "if [ -n \"$securityLevel\" ]; then",
    #"case "$security" in"#,
    "x=security_level",
    "  security_*) echo skip ;;",
    "SECURITY=1 make",
    #"level="$(id -un)" securityctl"#,
  ])
  func theSecurityGateIgnoresWordsThatOnlyLookAlike(line: String) throws {
    let corpus = try Self.planted(try Self.releaseCorpus(), in: Self.publishScript, line)
    #expect(Self.securityCommandFindings(corpus) == [])
  }

  @Test func onlyTheLoginItemAdapterUnregistersTheMainApp() throws {
    let files = try NetworkSourceGateTests.corpus()
    #expect(Self.mainAppUnregisterFindings(files) == [])
    #expect(try Self.read(Self.loginItemAdapter).text.contains("\(Self.mainAppService).unregister()"))
    let leaky = try Self.planted(files, in: Self.uninstallAdapter, "    try \(Self.mainAppService).unregister()")
    Self.expectOne(Self.mainAppUnregisterFindings(leaky), naming: Self.uninstallAdapter)
  }

  @Test func theCaskUninstallStanzaOnlyQuits() throws {
    #expect(Self.caskUninstallFindings(try Self.read(Self.caskTemplate)) == [])
  }

  @Test(arguments: [
    (
      #"  uninstall quit: "io.github.ivanhernandez-dev.overtime""#,
      #"  uninstall quit: "io.github.ivanhernandez-dev.overtime", launchctl: "io.github.ivanhernandez-dev.overtime.x""#
    ),
    ("  app \"Overtime.app\"\n", "  app \"Overtime.app\"\n\n  uninstall_postflight do\n  end\n"),
    ("  app \"Overtime.app\"\n", "  app \"Overtime.app\"\n\n  uninstall delete: \"/Applications/Overtime.app\"\n"),
  ])
  func theCaskGateCatchesAnUninstallBeyondQuit(old: String, new: String) throws {
    let cask = try Self.read(Self.caskTemplate)
    let changed = try #require(try Self.replacing([cask], in: Self.caskTemplate, old, with: new).first)
    Self.expectOne(Self.caskUninstallFindings(changed), naming: Self.caskTemplate)
  }

  @Test func theServedCaskIsTheTemplateRenderedForOneRelease() throws {
    let cask = try Self.read(Self.servedCask)
    let template = try Self.read(Self.caskTemplate)
    #expect(Self.servedCaskFindings(cask: cask, template: template) == [])
    #expect(Self.caskUninstallFindings(cask) == [])
    #expect(Self.keysFolderFindings([cask]) == [])
    #expect(Self.machineSpecificFindings([cask]) == [])
  }

  @Test(arguments: [
    ("the bare Sparkle livecheck in the cask only", servedCask),
    ("a two-part version", servedCask),
    ("a leading-zero version part", servedCask),
    ("an uppercase sha256", servedCask),
    ("a second version line", servedCask),
    ("a placeholder left in the cask", servedCask),
    ("an extra trash path in the cask only", servedCask),
    ("the bare Sparkle livecheck in the template and the cask", caskTemplate),
  ])
  func theServedCaskGateCatchesAPlantedDrift(mutant: String, path: String) throws {
    let changed = try Self.servedCaskMutant(
      mutant, cask: try Self.read(Self.servedCask), template: try Self.read(Self.caskTemplate))
    Self.expectOne(Self.servedCaskFindings(cask: changed.cask, template: changed.template), naming: path)
  }

  @Test func theRepositoryServesOneCaskAndNothingElseHomebrewLoads() throws {
    let surface = try Self.liveTapSurface()
    #expect(Self.tapSurfaceFindings(root: surface.root, casks: surface.casks) == [])
    #expect(surface.root.contains("Casks"))
  }

  @Test(arguments: [
    "overtime.rb", "Formula", "HomebrewFormula", "cmd", "completions", "manpages", "tap_migrations.json",
  ])
  func theTapSurfaceGateCatchesAPlantedEntry(entry: String) {
    let root = ["Casks", "README.md", "packaging", entry]
    Self.expectOne(Self.tapSurfaceFindings(root: root, casks: ["overtime.rb"]), naming: entry)
  }

  @Test func theTapSurfaceGateCatchesASecondOrMissingCask() {
    let root = ["Casks", "README.md", "packaging"]
    Self.expectOne(
      Self.tapSurfaceFindings(root: root, casks: ["overtime.rb", "overtime-beta.rb"]), naming: "Casks/overtime-beta.rb")
    Self.expectOne(Self.tapSurfaceFindings(root: root, casks: []), naming: Self.servedCask)
    Self.expectOne(Self.tapSurfaceFindings(root: root, casks: [".DS_Store"]), naming: Self.servedCask)
  }

  @Test(arguments: ["overtime.rb.template", ".DS_Store", "Formulae.md", "commands"])
  func theTapSurfaceGateIgnoresEntriesHomebrewDoesNotLoad(entry: String) {
    let root = ["Casks", "README.md", "packaging", entry]
    #expect(Self.tapSurfaceFindings(root: root, casks: ["overtime.rb"]) == [])
  }

  @Test func theWorkflowsUsePinnedActionsNoPullRequestTargetNoMacOS14AndNoCacheInRelease() throws {
    let workflows = try Self.workflows()
    #expect(Self.forbiddenWorkflowFindings(workflows) == [])
    #expect(Self.actionPinFindings(workflows) == [])
    #expect(Self.releaseCacheFindings(workflows) == [])
    #expect(Self.usesValues(workflows).count == 4)
    #expect(Self.usesValues(workflows).allSatisfy { Self.matches($0, Self.pinnedAction) })
  }

  @Test(arguments: [
    (ciWorkflow, "  pull_request_target:"),
    (ciWorkflow, "    runs-on: macos-14"),
  ])
  func theTriggerAndRunnerGateCatchesAPlantedLine(path: String, line: String) throws {
    Self.expectOne(Self.forbiddenWorkflowFindings(try Self.planted(try Self.workflows(), in: path, line)), naming: path)
  }

  @Test(arguments: [
    "      - uses: actions/checkout@v7",
    "        uses: actions/upload-artifact@v7.0.2",
    "      - uses: actions/checkout@3d3c42e",
  ])
  func theActionPinGateCatchesAnUnpinnedAction(line: String) throws {
    let findings = Self.actionPinFindings(try Self.planted(try Self.workflows(), in: Self.ciWorkflow, line))
    Self.expectOne(findings, naming: Self.ciWorkflow)
  }

  @Test func theCacheGateCatchesAPlantedCacheInRelease() throws {
    let line = "      - uses: actions/cache@0123456789abcdef0123456789abcdef01234567"
    let findings = Self.releaseCacheFindings(try Self.planted(try Self.workflows(), in: Self.releaseWorkflow, line))
    Self.expectOne(findings, naming: Self.releaseWorkflow)
  }

  @Test func secretsAppearOnlyInReleaseStepEnvironmentsAndNoRunScriptInterpolates() throws {
    let workflows = try Self.workflows()
    #expect(Self.secretFindings(workflows) == [])
    #expect(Self.runInterpolationFindings(workflows) == [])
    #expect(Self.writePermissionFindings(workflows) == [])
    let release = try Self.read(Self.releaseWorkflow).text
    for name in Self.releaseSecrets {
      #expect(release.contains("${{ secrets.\(name) }}"), "\(name)")
    }
    #expect(release.contains("contents: write"))
    #expect(!(try Self.read(Self.ciWorkflow).text.contains("secrets.")))
  }

  @Test(arguments: [
    (ciWorkflow, "          TOKEN: ${{ secrets.HOMEBREW_TAP_TOKEN }}"),
    (ciWorkflow, "          GH_TOKEN: ${{ github.token }}"),
  ])
  func theSecretGateCatchesACredentialInCI(path: String, line: String) throws {
    Self.expectOne(Self.secretFindings(try Self.planted(try Self.workflows(), in: path, line)), naming: path)
  }

  @Test(arguments: [
    (
      ciWorkflow, "permissions:\n  contents: read\n",
      "env:\n  ALL: ${{ toJSON(secrets) }}\n\npermissions:\n  contents: read\n"
    ),
    (
      ciWorkflow, "      DEVELOPER_DIR: /Applications/Xcode_27.0.app/Contents/Developer\n",
      "      DEVELOPER_DIR: /Applications/Xcode_27.0.app/Contents/Developer\n"
        + "      PASSWORD: ${{ secrets['T1_P12_PASSWORD'] }}\n"
    ),
    (
      ciWorkflow, "      - name: Script tests\n",
      "      - name: Script tests\n        env:\n          GH_TOKEN: ${{ github['token'] }}\n"
    ),
    (
      ciWorkflow, "      - name: Script tests\n",
      "      - name: Script tests\n        env:\n          CONTEXT: ${{ toJSON(github) }}\n"
    ),
    (
      releaseWorkflow, "          T1_P12_PASSWORD: ${{ secrets.T1_P12_PASSWORD }}",
      "          T1_P12_PASSWORD: ${{ secrets['T1_P12_PASSWORD'] }}"
    ),
    (
      releaseWorkflow, "      DEVELOPER_DIR: /Applications/Xcode_27.0.app/Contents/Developer\n",
      "      DEVELOPER_DIR: /Applications/Xcode_27.0.app/Contents/Developer\n      ALL: ${{ toJSON(secrets) }}\n"
    ),
  ])
  func theSecretGateCatchesAWholeOrIndexedContext(path: String, old: String, new: String) throws {
    let leaky = try Self.replacing(try Self.workflows(), in: path, old, with: new)
    Self.expectOne(Self.secretFindings(leaky), naming: path)
  }

  @Test(arguments: [
    "    if: github.event_name != 'pull_request'",
    "  group: ci-${{ github.ref }}-${{ github.event.pull_request.number }}",
    "        run: echo \"no secrets here\"",
  ])
  func theSecretGateIgnoresOrdinaryGithubExpressionsAndPlainWords(line: String) throws {
    #expect(Self.secretFindings(try Self.planted(try Self.workflows(), in: Self.ciWorkflow, line)) == [])
  }

  @Test func theSecretGateCatchesAnUnknownSecretInRelease() throws {
    let anchor = "          SPARKLE_ED_PRIVATE_KEY: ${{ secrets.SPARKLE_ED_PRIVATE_KEY }}"
    let leaky = try Self.replacing(
      try Self.workflows(), in: Self.releaseWorkflow, anchor,
      with: anchor + "\n          OTHER: ${{ secrets.OTHER_TOKEN }}")
    Self.expectOne(Self.secretFindings(leaky), naming: Self.releaseWorkflow)
  }

  @Test func theSecretGateCatchesASecretInTheJobEnvironment() throws {
    let anchor = "      DEVELOPER_DIR: /Applications/Xcode_27.0.app/Contents/Developer"
    let leaky = try Self.replacing(
      try Self.workflows(), in: Self.releaseWorkflow, anchor,
      with: anchor + "\n      T1_P12_PASSWORD: ${{ secrets.T1_P12_PASSWORD }}")
    Self.expectOne(Self.secretFindings(leaky), naming: Self.releaseWorkflow)
  }

  @Test(arguments: [
    "      - name: Planted\n        run: echo \"${{ github.event.head_commit.message }}\"",
    "      - name: Planted\n        run: |\n          echo ready\n          echo \"${{ github.head_ref }}\"",
    "      - run: >\n          echo \"${{ github.event.pull_request.title }}\"",
  ])
  func theRunScriptGateCatchesAnInterpolatedExpression(step: String) throws {
    let findings = Self.runInterpolationFindings(try Self.planted(try Self.workflows(), in: Self.releaseWorkflow, step))
    Self.expectOne(findings, naming: Self.releaseWorkflow)
  }

  @Test(arguments: [
    "      contents: write",
    "      id-token: write",
    "      actions: 'write'",
    "    permissions: { contents: read, packages: write }",
    "    permissions: write-all",
  ])
  func theWritePermissionGateCatchesAPlantedWriteInCI(line: String) throws {
    let findings = Self.writePermissionFindings(try Self.planted(try Self.workflows(), in: Self.ciWorkflow, line))
    Self.expectOne(findings, naming: Self.ciWorkflow)
  }

  @Test func theWritePermissionGateCatchesAWorkflowLevelWriteAllInCI() throws {
    let leaky = try Self.replacing(
      try Self.workflows(), in: Self.ciWorkflow, "permissions:\n  contents: read\n", with: "permissions: write-all\n")
    Self.expectOne(Self.writePermissionFindings(leaky), naming: Self.ciWorkflow)
  }

  @Test(arguments: [
    "      contents: read",
    "    permissions: read-all",
    "      - name: Write the report",
    "        run: echo write",
  ])
  func theWritePermissionGateIgnoresReadsAndPlainWords(line: String) throws {
    #expect(Self.writePermissionFindings(try Self.planted(try Self.workflows(), in: Self.ciWorkflow, line)) == [])
  }

  @Test func noWorkflowUsesAYAMLAnchorAliasOrMergeKey() throws {
    let workflows = try Self.workflows()
    #expect(workflows.count == 3)
    #expect(Self.anchorFindings(workflows) == [])
  }

  static let permissionsBlock = "    permissions:\n      contents: write\n"
  static let mirrorJob = "  mirror:\n    runs-on: xcode-27\n    permissions: *w\n    steps:\n      - run: make"

  @Test func theAnchorGateCatchesAWriteGrantSharedThroughAnAlias() throws {
    let anchored = try Self.replacing(
      try Self.workflows(), in: Self.releaseWorkflow, Self.permissionsBlock,
      with: "    permissions: &w\n      contents: write\n")
    let leaky = try Self.planted(anchored, in: Self.releaseWorkflow, Self.mirrorJob)
    let findings = Self.anchorFindings(leaky)
    #expect(findings.count == 2, "\(findings)")
    #expect(findings.allSatisfy { $0.hasPrefix(Self.releaseWorkflow) }, "\(findings)")
  }

  @Test(arguments: [
    (ciWorkflow, "permissions:\n  contents: read\n", "permissions:\n  contents: &w write\n"),
    (ciWorkflow, "permissions:\n  contents: read\n", "permissions: &p\n  contents: read\n"),
    (ciWorkflow, "    runs-on: macos-26\n", "    runs-on: *runner\n"),
    (ciWorkflow, "    runs-on: macos-26\n", "    runs-on: macos-26\n    <<: { permissions: { contents: read } }\n"),
    (ciWorkflow, "    runs-on: macos-26\n", "    runs-on: [*runner]\n"),
    (ciWorkflow, "    runs-on: macos-26\n", "    runs-on: macos-26\n    env: {A: &a x, B: *a}\n"),
    (releaseWorkflow, permissionsBlock, "    permissions:\n      - &w contents: write\n"),
  ])
  func theAnchorGateCatchesAPlantedAnchorAliasOrMergeKey(path: String, old: String, new: String) throws {
    let leaky = try Self.replacing(try Self.workflows(), in: path, old, with: new)
    let findings = Self.anchorFindings(leaky)
    #expect(findings.count == 1, "\(findings)")
    #expect(findings.first?.hasPrefix(path) == true, "\(findings)")
  }

  @Test(arguments: [
    "        run: make && make test",
    "        run: make 2>&1 | tee log",
    "        run: ls build/*.zip",
    "        run: echo *.log",
    "        run: cat <<EOF",
    "        run: echo \"done\" # &note *note",
    "      - \"v*\"",
  ])
  func theAnchorGateIgnoresShellAndGlobLookAlikes(line: String) throws {
    #expect(Self.anchorFindings(try Self.planted(try Self.workflows(), in: Self.ciWorkflow, line)) == [])
  }

  @Test func theReleaseJobRunsInTheApprovalGatedEnvironment() throws {
    let release = try Self.read(Self.releaseWorkflow)
    #expect(Self.releaseEnvironmentFindings(release) == [])
    #expect(Self.jobBlocks(release).count == 1)
    #expect(release.text.contains("\n    environment: release\n"))
  }

  static let environmentLine = "    environment: release\n"
  static let secondJob = environmentLine + "    steps:\n      - run: make\n"

  static let environmentBypasses: [String] = [
    "",
    "    environment: release-open\n",
    "    # environment: release\n",
    secondJob + "  sneak:\n    runs-on: xcode-27\n    permissions:\n      contents: write\n",
    secondJob + "  tap-mirror: # mirrors the cask\n    runs-on: xcode-27\n    permissions:\n      contents: write\n",
    secondJob + "  sneak:\n    runs-on: xcode-27\n    permissions: write-all\n",
    secondJob + "  \"tap-mirror\":\n    runs-on: xcode-27\n    permissions: { contents: write }\n",
    secondJob + "  sneak: { runs-on: xcode-27, permissions: write-all }\n",
    environmentLine + "    environment: staging\n",
    "    environment:\n      name: staging\n",
    "    environment: staging # release\n",
  ]

  @Test(arguments: environmentBypasses)
  func theEnvironmentGateCatchesAPublishingJobOutsideTheReleaseEnvironment(new: String) throws {
    let release = try Self.read(Self.releaseWorkflow)
    let changed = try #require(
      try Self.replacing([release], in: Self.releaseWorkflow, Self.environmentLine, with: new).first)
    Self.expectOne(Self.releaseEnvironmentFindings(changed), naming: Self.releaseWorkflow)
  }

  @Test func theEnvironmentGateCatchesAJobThatInheritsAWorkflowLevelWrite() throws {
    let release = try Self.read(Self.releaseWorkflow)
    let writeAll = try Self.replacing(
      [release], in: Self.releaseWorkflow, "permissions:\n  contents: read\n", with: "permissions: write-all\n")
    let changed = try #require(
      try Self.replacing(
        writeAll, in: Self.releaseWorkflow, Self.environmentLine,
        with: Self.secondJob + "  lint:\n    runs-on: xcode-27\n"
      ).first)
    Self.expectOne(Self.releaseEnvironmentFindings(changed), naming: Self.releaseWorkflow)
  }

  static let environmentForms: [(old: String, new: String)] = [
    (environmentLine, "    environment: release # approval\n"),
    (environmentLine, "    environment: \"release\"\n"),
    (environmentLine, "    environment: { name: release }\n"),
    (environmentLine, "    environment:\n      name: release\n      url: https://github.com/releases\n"),
    ("  release:\n", "  release: # the one publishing job\n"),
    ("jobs:\n", "jobs: # one job\n"),
  ]

  @Test(arguments: environmentForms)
  func theEnvironmentGateAcceptsEquivalentYAMLForms(old: String, new: String) throws {
    let release = try Self.read(Self.releaseWorkflow)
    let changed = try #require(try Self.replacing([release], in: Self.releaseWorkflow, old, with: new).first)
    #expect(Self.releaseEnvironmentFindings(changed) == [])
    #expect(Self.jobBlocks(changed).count == 1)
  }

  @Test func onlyHostedRunnersOrSameRepositoryJobsRunPullRequests() throws {
    let workflows = try Self.workflows()
    #expect(Self.runnerTrustFindings(workflows) == [])
    #expect(try Self.runsOnPullRequests(Self.read(Self.ciWorkflow)))
    #expect(!(try Self.runsOnPullRequests(Self.read(Self.releaseWorkflow))))
    #expect(try Self.read(Self.ciWorkflow).text.contains(Self.sameRepositoryGuard))
  }

  @Test func theRunnerTrustGateCatchesTheXcodeJobWithoutItsGuard() throws {
    let leaky = try Self.replacing(try Self.workflows(), in: Self.ciWorkflow, Self.ciGuardLine, with: "")
    Self.expectOne(Self.runnerTrustFindings(leaky), naming: Self.ciWorkflow)
  }

  @Test func theRunnerTrustGateCatchesAPlantedSelfHostedJob() throws {
    let job = "  planted:\n    runs-on: [self-hosted, macOS]\n    steps:\n      - run: make"
    let leaky = try Self.planted(try Self.workflows(), in: Self.ciWorkflow, job)
    Self.expectOne(Self.runnerTrustFindings(leaky), naming: Self.ciWorkflow)
  }

  static let ciGuardLine =
    "    if: github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name"
    + " == github.repository\n"

  @Test(arguments: [
    "  build: # macOS\n    runs-on: self-hosted\n    steps:\n      - run: make",
    "  'build':   # macOS\n    runs-on: self-hosted\n    steps:\n      - run: make",
    "  planted:\n    runs-on:\n      group: big-runners\n    steps:\n      - run: make",
    "  planted:\n    runs-on: [macos-26, self-hosted]\n    steps:\n      - run: make",
    "  planted:\n    runs-on: self-hosted # macos-26\n    steps:\n      - run: make",
    "  planted: { runs-on: self-hosted, steps: [{ run: make }] }",
    "  planted:\n    steps:\n      - run: make",
  ])
  func theRunnerTrustGateCatchesAPlantedJobInAnyHeaderOrRunnerForm(job: String) throws {
    let leaky = try Self.planted(try Self.workflows(), in: Self.ciWorkflow, job)
    Self.expectOne(Self.runnerTrustFindings(leaky), naming: Self.ciWorkflow)
  }

  @Test(arguments: ["jobs: # every job\n", "jobs:   # every job\n"])
  func theRunnerTrustGateStillReadsTheJobsBehindACommentedJobsKey(jobsKey: String) throws {
    let unguarded = try Self.replacing(try Self.workflows(), in: Self.ciWorkflow, Self.ciGuardLine, with: "")
    let leaky = try Self.replacing(unguarded, in: Self.ciWorkflow, "jobs:\n", with: jobsKey)
    Self.expectOne(Self.runnerTrustFindings(leaky), naming: Self.ciWorkflow)
  }

  @Test func theRunnerTrustGateFailsClosedOnASecondOrMissingJobsKey() throws {
    let second = try Self.planted(try Self.workflows(), in: Self.ciWorkflow, "jobs:\n  more:\n    runs-on: macos-26")
    Self.expectOne(Self.runnerTrustFindings(second), naming: Self.ciWorkflow)
    let missing = try Self.replacing(try Self.workflows(), in: Self.ciWorkflow, "jobs:\n", with: "jobz:\n")
    Self.expectOne(Self.runnerTrustFindings(missing), naming: Self.ciWorkflow)
  }

  @Test(arguments: [
    ("jobs:\n", "jobs: # every job\n"),
    ("  xcode-27:\n", "  xcode-27: # the main job\n"),
    ("  macos-26:\n", "  \"macos-26\":\n"),
    ("    runs-on: macos-26\n", "    runs-on: macos-26 # hosted\n"),
  ])
  func theRunnerTrustGateAcceptsEquivalentYAMLForms(old: String, new: String) throws {
    let changed = try Self.replacing(try Self.workflows(), in: Self.ciWorkflow, old, with: new)
    #expect(Self.runnerTrustFindings(changed) == [])
  }

  @Test func theRunnerTrustGateCatchesTheReleaseJobOncePullRequestsTriggerIt() throws {
    let leaky = try Self.replacing(
      try Self.workflows(), in: Self.releaseWorkflow, "on:\n  push:\n", with: "on:\n  pull_request:\n  push:\n")
    Self.expectOne(Self.runnerTrustFindings(leaky), naming: Self.releaseWorkflow)
  }

  @Test func everyShellScriptIsBash32WithNoTraceInReleaseCode() throws {
    let corpus = try Self.releaseCorpus()
    #expect(Self.bashPortabilityFindings(corpus) == [])
    #expect(Self.traceFindings(corpus) == [])
  }

  @Test(arguments: [
    #"mapfile -t lines < "$file""#,
    #"readarray -t lines < "$file""#,
    "declare -A seen",
    "local -A seen",
    #"echo "${name,,}""#,
    #"echo "${name^^}""#,
    #"echo "${items[0]^}""#,
    "make 2>&1 |& tee build.log",
    "echo done &>> build.log",
  ])
  func theBashGateCatchesAPlantedBash4Feature(line: String) throws {
    let path = "scripts/tests/test_version.sh"
    let corpus = try Self.planted(try Self.releaseCorpus(), in: path, line)
    Self.expectOne(Self.bashPortabilityFindings(corpus), naming: path)
  }

  @Test(arguments: [
    #"echo "${name}""#,
    #"[ "${#items[@]}" -gt 0 ]"#,
    #"value="${other:-a,b}""#,
    #"[ -n "$x" ] || true"#,
    #"pattern='^(0|[1-9][0-9]?)$'"#,
  ])
  func theBashGateIgnoresPortableLines(line: String) throws {
    let path = "scripts/tests/test_version.sh"
    #expect(Self.bashPortabilityFindings(try Self.planted(try Self.releaseCorpus(), in: path, line)) == [])
  }

  @Test func theBashGateCatchesAScriptWithoutTheBinBashShebang() throws {
    let path = "scripts/release/lib/cask.sh"
    let changed = try Self.replacing(try Self.releaseCorpus(), in: path, "#!/bin/bash\n", with: "#!/usr/bin/env bash\n")
    Self.expectOne(Self.bashPortabilityFindings(changed), naming: path)
  }

  @Test(arguments: [
    (publishScript, "set -x"),
    (pipelineScript, "set -euxo pipefail"),
    (releaseWorkflow, "          set -o xtrace"),
  ])
  func theTraceGateCatchesAPlantedTrace(path: String, line: String) throws {
    Self.expectOne(Self.traceFindings(try Self.planted(try Self.releaseCorpus(), in: path, line)), naming: path)
  }

  @Test func thePinnedSparkleKeyAndVersionMatchTheProjectAndTheKeysRecord() throws {
    let pins = try Self.read(Self.pinsFile)
    let spec = try Self.read(Self.projectSpec)
    let keys = try Self.read(Self.keysRecord)
    #expect(Self.pinFindings(pins: pins, spec: spec, keys: keys) == [])
  }

  @Test(arguments: [
    (pinsFile, "SPARKLE_PUBLIC_ED_KEY=UD7lL+", "SPARKLE_PUBLIC_ED_KEY=XD7lL+"),
    (pinsFile, "SPARKLE_VERSION=2.10.0", "SPARKLE_VERSION=2.10.1"),
    (projectSpec, "SPARKLE_PUBLIC_ED_KEY: UD7lL+", "SPARKLE_PUBLIC_ED_KEY: XD7lL+"),
  ])
  func thePinGateCatchesAPlantedDrift(path: String, old: String, new: String) throws {
    let all = [try Self.read(Self.pinsFile), try Self.read(Self.projectSpec), try Self.read(Self.keysRecord)]
    let changed = try Self.replacing(all, in: path, old, with: new)
    Self.expectOne(Self.pinFindings(pins: changed[0], spec: changed[1], keys: changed[2]), naming: path)
  }

  @Test func theUninstallScriptHonoursTheTestRootOnlyBehindTheTestMarkerAndRunsNoDefaults() throws {
    let script = try Self.read(Self.uninstallScript)
    #expect(Self.uninstallRootFindings(script) == [])
    #expect(script.text.contains("OVERTIME_UNINSTALL_ROOT"))
  }

  @Test(arguments: [
    (#"ROOT_PREFIX="${OVERTIME_UNINSTALL_ROOT:-}""#, ""),
    ("", #"ROOT_PREFIX="$OVERTIME_UNINSTALL_ROOT""#),
    ("", "defaults delete io.github.ivanhernandez-dev.overtime"),
    ("", "if defaults read io.github.ivanhernandez-dev.overtime > /dev/null 2>&1; then"),
    ("", "  ! defaults delete io.github.ivanhernandez-dev.overtime"),
    ("", "{ defaults delete io.github.ivanhernandez-dev.overtime; } || true"),
    ("", "OVERTIME_X=1 defaults delete io.github.ivanhernandez-dev.overtime"),
    ("", "  --purge) defaults delete io.github.ivanhernandez-dev.overtime ;;"),
  ])
  func theUninstallGateCatchesAnUnguardedRootOrADefaultsCall(replacement: String, addition: String) throws {
    var files = [try Self.read(Self.uninstallScript)]
    if !replacement.isEmpty {
      let guarded = #"if [ "${OVERTIME_SCRIPT_TESTS:-}" = "1" ]; then ROOT_PREFIX="${OVERTIME_UNINSTALL_ROOT:-}"; fi"#
      files = try Self.replacing(files, in: Self.uninstallScript, guarded, with: replacement)
    }
    if !addition.isEmpty {
      files = try Self.planted(files, in: Self.uninstallScript, addition)
    }
    Self.expectOne(Self.uninstallRootFindings(files[0]), naming: Self.uninstallScript)
  }

  static func machineSpecificFindings(_ files: [SourceFile]) -> [String] {
    lineFindings(files, "author home path") { $0.contains("/Users/") }
      + lineFindings(files, "sudo chown") { matches($0, #"\bsudo\s+chown\b"#) }
  }

  static func repositoryAutomation() throws -> [SourceFile] {
    try files(under: ".github") + scripts()
  }

  @Test func noScriptOrWorkflowNamesAHomeFolderOrChownsWithSudo() throws {
    let corpus = try Self.repositoryAutomation()
    #expect(corpus.contains { $0.path == ".github/actionlint.yaml" })
    #expect(corpus.contains { $0.path == Self.ciWorkflow })
    #expect(Self.machineSpecificFindings(corpus) == [])
    let ci = try Self.read(Self.ciWorkflow).text
    #expect(ci.contains(#"-derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/Overtime-gate""#))
  }

  @Test(arguments: [
    (ciWorkflow, "          xcodebuild build -derivedDataPath /Users/devonshire/Library/Developer"),
    (ciWorkflow, #"          sudo chown -R "$(id -un)" "$HOME/Library""#),
    (".github/actionlint.yaml", "    - /Users/runner/xcode-27"),
    ("scripts/tests/test_version.sh", #"REPO="/Users/devonshire/src/overtime""#),
    (uninstallScript, #"  sudo  chown root:wheel "$target""#),
  ])
  func theMachineSpecificGateCatchesAPlantedLine(path: String, line: String) throws {
    let corpus = try Self.planted(try Self.repositoryAutomation(), in: path, line)
    Self.expectOne(Self.machineSpecificFindings(corpus), naming: path)
  }

  @Test func theReleasePipelineNeverSignsTheHelper() throws {
    let pipeline = try Self.read(Self.pipelineScript)
    #expect(Self.helperSigningFindings(pipeline) == [])
    let anchor = #"  "${sign[@]}" -i "$SENTINEL_IDENTIFIER" "$app/Contents/MacOS/overtime-sentinel" || return 1"#
    let changed = try #require(
      try Self.replacing(
        [pipeline], in: Self.pipelineScript, anchor,
        with: anchor + "\n" + #"  "${sign[@]}" "$app/Contents/MacOS/OvertimeHelper" || return 1"#
      ).first)
    Self.expectOne(Self.helperSigningFindings(changed), naming: Self.pipelineScript)
  }

  static let pushPattern = #"\bgit\s+(-C\s+\S+\s+)?push\b"#
  static let dispatchPattern = #"\bgh\s+workflow\s+run\s+\S+"#
  static let actionlintInvocation = #""$WORK/bin/actionlint" -shellcheck="#
  static let workflowGlob = ".github/workflows/*.yml"

  static func triggerBlock(_ file: SourceFile) -> (on: Line, lines: [Line])? {
    let lines = plainLines(file.text)
    let starts = lines.indices.filter { yamlContent(lines[$0].text) == "on:" }
    guard starts.count == 1, let start = starts.first else { return nil }
    let body = lines[(start + 1)...].prefix { line in
      let content = yamlContent(line.text)
      return isBlank(content) || indentation(content) > 0
    }
    return (lines[start], Array(body))
  }

  static func keyName(_ content: String) -> String {
    let trimmed = content.trimmingCharacters(in: .whitespaces)
    guard let colon = trimmed.firstIndex(of: ":") else { return trimmed }
    return String(trimmed[...colon])
  }

  static func triggerKeys(_ file: SourceFile) -> [String]? {
    triggerBlock(file).map { block in
      block.lines.map { yamlContent($0.text) }.filter { !isBlank($0) && indentation($0) == 2 }.map(keyName)
    }
  }

  static func grantsExactlyTheCutWrites(_ contents: [String]) -> Bool {
    let starts = contents.indices.filter {
      indentation(contents[$0]) == 4 && yamlKey(contents[$0]).hasPrefix("permissions:")
    }
    guard starts.count == 1, let start = starts.first, contents[start] == "    permissions:" else { return false }
    let mapping = contents[(start + 1)...].prefix { isBlank($0) || indentation($0) > 4 }
    return contents.filter(grantsWrite).sorted() == cutJobWrites && mapping.filter(grantsWrite).sorted() == cutJobWrites
  }

  static func cutReleaseFindings(_ file: SourceFile) -> [String] {
    var findings: [String] = []
    let lines = plainLines(file.text)
    if let block = triggerBlock(file) {
      if triggerKeys(file) != ["workflow_dispatch:"] {
        findings.append("\(file.path):\(block.on.number) triggers other than workflow_dispatch")
      }
    } else {
      findings.append("\(file.path) has no readable on: block")
    }
    let jobsIndex = lines.firstIndex { yamlContent($0.text) == "jobs:" } ?? lines.count
    findings += lines[..<jobsIndex].filter { grantsWrite(yamlContent($0.text)) }.map {
      "\(file.path):\($0.number) write permission outside the cut job"
    }
    let section = jobSection(file)
    guard section.blocks.count == 1, section.unreadable.isEmpty, let job = section.blocks.first else {
      return findings + ["\(file.path) has \(section.blocks.count) readable jobs, not one"]
    }
    let contents = job.lines.map { yamlContent($0.text) }
    if !grantsExactlyTheCutWrites(contents) {
      findings.append("\(file.path):\(job.header.number) job write grants are not exactly contents and actions")
    }
    let runners = contents.filter { indentation($0) == 4 && yamlKey($0).hasPrefix("runs-on:") }
    let label = runners.first.map { yamlKey($0).dropFirst("runs-on:".count).trimmingCharacters(in: .whitespaces) }
    if runners.count != 1 || !hostedRunnerPrefixes.contains(where: { label?.hasPrefix($0) == true }) {
      findings.append("\(file.path):\(job.header.number) job without one hosted runs-on")
    }
    findings += plainLines(file.text).filter { usesValue($0.text).map { !$0.hasPrefix("actions/checkout@") } ?? false }
      .map { "\(file.path):\($0.number) action other than the pinned checkout" }
    return findings
  }

  static func pushCorpus() throws -> [SourceFile] {
    try workflows() + scripts().filter { !$0.path.hasPrefix("scripts/tests/") }
  }

  static func pushFindings(_ files: [SourceFile]) -> [String] {
    files.flatMap { file in
      logicalLines(file.text).filter { matches($0.text, pushPattern) }.compactMap { line -> String? in
        let place = "\(file.path):\(line.number)"
        guard file.path == cutReleaseWorkflow else { return "\(place) git push outside cut-release.yml" }
        return line.text.contains(atomicPush) ? nil : "\(place) push is not the atomic push of main and the tag"
      }
    }
  }

  static func dispatchTarget(_ line: String) -> String? {
    guard let range = line.range(of: dispatchPattern, options: .regularExpression) else { return nil }
    let target = line[range].split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
    return target.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
  }

  static func dispatchTargets(_ file: SourceFile) -> [String] {
    logicalLines(file.text).compactMap { dispatchTarget($0.text) }
  }

  static func dispatchFindings(_ workflows: [SourceFile]) -> [String] {
    workflows.flatMap { file in
      logicalLines(file.text).compactMap { line -> String? in
        guard let target = dispatchTarget(line.text) else { return nil }
        let place = "\(file.path):\(line.number) dispatches \(target)"
        guard let workflow = workflows.first(where: { $0.path == ".github/workflows/\(target)" }) else {
          return "\(place), which does not exist"
        }
        return triggerKeys(workflow)?.contains("workflow_dispatch:") == true
          ? nil : "\(place), which has no workflow_dispatch trigger"
      }
    }
  }

  static func releaseTriggerFindings(_ release: SourceFile) -> [String] {
    guard let block = triggerBlock(release) else { return ["\(release.path) has no readable on: block"] }
    var findings: [String] = []
    let contents = block.lines.map { yamlContent($0.text) }.filter { !isBlank($0) }
    if contents.filter({ indentation($0) == 2 }).map(keyName) != ["push:", "workflow_dispatch:"] {
      findings.append("\(release.path):\(block.on.number) triggers other than a push and a dispatch")
    }
    let pushStart = contents.firstIndex { $0 == "  push:" }
    let pushBody =
      pushStart.map { start in
        contents[(start + 1)...].prefix { indentation($0) > 2 }.map { $0.trimmingCharacters(in: .whitespaces) }
      } ?? []
    if pushBody != ["tags:", #"- "v*""#] {
      findings.append("\(release.path):\(block.on.number) push runs on more than v tags")
    }
    let jobs = jobBlocks(release)
    if jobs.count != 1 || jobs.first?.lines.contains(where: { $0.text == releaseTagGuard }) != true {
      findings.append("\(release.path) job without the v tag guard")
    }
    return findings
  }

  static func actionlintCoverageFindings(script: SourceFile, workflows: [SourceFile]) -> [String] {
    let invocations = logicalLines(script.text).filter { $0.text.contains(actionlintInvocation) }
    guard invocations.count == 1, let invocation = invocations.first else {
      return ["\(script.path) has \(invocations.count) actionlint invocations"]
    }
    if invocation.text.contains(workflowGlob) { return [] }
    return workflows.filter { !invocation.text.contains($0.path) }.map { "\($0.path) is not linted by \(script.path)" }
  }

  @Test func theCutReleaseWorkflowIsDispatchOnlyWithContentsAndActionsWrite() throws {
    let cut = try Self.read(Self.cutReleaseWorkflow)
    #expect(Self.cutReleaseFindings(cut) == [])
    #expect(Self.jobBlocks(cut).count == 1)
    #expect(cut.text.contains(Self.atomicPush))
    #expect(cut.text.contains(#"gh workflow run release.yml --ref "v$VERSION""#))
    #expect(Self.dispatchTargets(cut) == Self.cutDispatchTargets)
  }

  static let cutPermissionsBlock = "    permissions:\n      contents: write\n      actions: write\n"
  static let cutCheckoutStep = "      - name: Check out main\n"
  static let foreignStep = "      - uses: someone/action@0123456789abcdef0123456789abcdef01234567\n"
  static let cutLastLine = "        run: gh workflow run ci.yml --ref main\n"
  static let extraJob = "  extra:\n    runs-on: macos-26\n    steps:\n      - run: make\n"

  @Test(arguments: [
    ("  workflow_dispatch:\n", "  push:\n    branches:\n      - main\n  workflow_dispatch:\n"),
    ("permissions:\n  contents: read\n", "permissions:\n  contents: write\n"),
    ("      actions: write\n", "      actions: write\n      packages: write\n"),
    (cutPermissionsBlock, "    permissions: write-all\n"),
    ("      actions: write\n", ""),
    ("    runs-on: macos-26\n", "    runs-on: self-hosted\n"),
    (cutCheckoutStep, foreignStep + cutCheckoutStep),
    (cutLastLine, cutLastLine + extraJob),
  ])
  func theCutReleaseGateCatchesAPlantedChange(old: String, new: String) throws {
    let cut = try Self.read(Self.cutReleaseWorkflow)
    let changed = try #require(try Self.replacing([cut], in: Self.cutReleaseWorkflow, old, with: new).first)
    Self.expectOne(Self.cutReleaseFindings(changed), naming: Self.cutReleaseWorkflow)
  }

  static let cutPushEnvironment = "          VERSION: ${{ inputs.version }}\n        run: git push"
  static let tapSecretLine = "          TAP: ${{ secrets.HOMEBREW_TAP_TOKEN }}\n"
  static let cutTimeout = "    timeout-minutes: 15\n"
  static let cutCredentials = "          persist-credentials: true\n"

  @Test(arguments: [
    (cutPushEnvironment, "          VERSION: ${{ inputs.version }}\n" + tapSecretLine + "        run: git push"),
    (cutTimeout, cutTimeout + "    env:\n      GH_TOKEN: ${{ github.token }}\n"),
    (cutTimeout, cutTimeout + "    env:\n      ALL: ${{ toJSON(secrets) }}\n"),
    (cutCredentials, cutCredentials + "          token: ${{ github.token }}\n"),
  ])
  func theSecretGateCatchesACredentialPlantedInTheCutWorkflow(old: String, new: String) throws {
    let leaky = try Self.replacing(try Self.workflows(), in: Self.cutReleaseWorkflow, old, with: new)
    Self.expectOne(Self.secretFindings(leaky), naming: Self.cutReleaseWorkflow)
  }

  @Test func everyDispatchedWorkflowAcceptsWorkflowDispatch() throws {
    #expect(Self.dispatchFindings(try Self.workflows()) == [])
  }

  @Test(arguments: [
    (ciWorkflow, "  workflow_dispatch:\n", ""),
    (releaseWorkflow, "  workflow_dispatch:\n", ""),
    (cutReleaseWorkflow, "gh workflow run ci.yml", "gh workflow run deploy.yml"),
  ])
  func theDispatchGateCatchesATargetWithoutTheTrigger(path: String, old: String, new: String) throws {
    let changed = try Self.replacing(try Self.workflows(), in: path, old, with: new)
    Self.expectOne(Self.dispatchFindings(changed), naming: Self.cutReleaseWorkflow)
  }

  @Test func onlyTheCutWorkflowPushesAndItsPushIsAtomic() throws {
    let corpus = try Self.pushCorpus()
    #expect(Self.pushFindings(corpus) == [])
    let pushing = corpus.flatMap { file in
      Self.logicalLines(file.text).filter { Self.matches($0.text, Self.pushPattern) }.map { _ in file.path }
    }
    #expect(pushing == [Self.cutReleaseWorkflow])
  }

  @Test(arguments: [
    (ciWorkflow, "        run: git push origin main"),
    (publishScript, "git push --force origin main"),
    (pipelineScript, #"  git push origin "v$version""#),
  ])
  func thePushGateCatchesAPushOutsideTheCutWorkflow(path: String, line: String) throws {
    Self.expectOne(Self.pushFindings(try Self.planted(try Self.pushCorpus(), in: path, line)), naming: path)
  }

  @Test func thePushGateCatchesANonAtomicPushInTheCutWorkflow() throws {
    let changed = try Self.replacing(
      try Self.pushCorpus(), in: Self.cutReleaseWorkflow, "git push --atomic origin", with: "git push origin")
    Self.expectOne(Self.pushFindings(changed), naming: Self.cutReleaseWorkflow)
  }

  @Test func theReleaseWorkflowRunsOnlyOnAVTagFromAPushOrADispatch() throws {
    let release = try Self.read(Self.releaseWorkflow)
    #expect(Self.releaseTriggerFindings(release) == [])
    #expect(Self.triggerKeys(release) == ["push:", "workflow_dispatch:"])
  }

  @Test(arguments: [
    (releaseTagGuard + "\n", ""),
    (releaseTagGuard + "\n", "    if: always()\n"),
    ("      - \"v*\"\n", "      - \"v*\"\n    branches:\n      - main\n"),
    ("      - \"v*\"\n", "      - \"*\"\n"),
    ("  workflow_dispatch:\n", "  workflow_dispatch:\n  schedule:\n    - cron: \"0 3 * * 1\"\n"),
  ])
  func theReleaseTriggerGateCatchesAPlantedChange(old: String, new: String) throws {
    let release = try Self.read(Self.releaseWorkflow)
    let changed = try #require(try Self.replacing([release], in: Self.releaseWorkflow, old, with: new).first)
    Self.expectOne(Self.releaseTriggerFindings(changed), naming: Self.releaseWorkflow)
  }

  @Test func actionlintLintsEveryWorkflow() throws {
    let script = try Self.read(Self.actionlintScript)
    #expect(Self.actionlintCoverageFindings(script: script, workflows: try Self.workflows()) == [])
    let invocation = Self.logicalLines(script.text).first { $0.text.contains(Self.actionlintInvocation) }
    #expect(invocation?.text.contains(Self.workflowGlob) == true)
  }

  @Test func theActionlintGateCatchesAWorkflowLeftOut() throws {
    let script = try Self.read(Self.actionlintScript)
    let named = ".github/workflows/ci.yml .github/workflows/release.yml"
    let changed = try #require(
      try Self.replacing([script], in: Self.actionlintScript, Self.workflowGlob, with: named).first)
    let findings = Self.actionlintCoverageFindings(script: changed, workflows: try Self.workflows())
    Self.expectOne(findings, naming: Self.cutReleaseWorkflow)
  }
}
