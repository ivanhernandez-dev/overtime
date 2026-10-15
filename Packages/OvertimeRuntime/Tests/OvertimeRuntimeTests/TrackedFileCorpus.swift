import Foundation
import Testing

enum TrackedFileCorpus {
  typealias SourceFile = NetworkSourceGateTests.SourceFile

  struct Corpus: Sendable {
    let paths: [String]
    let files: [SourceFile]
    let unreadable: [String]
    var missing: [String] = []
  }

  struct CorpusFailure: Error, CustomStringConvertible {
    let description: String
  }

  static let minimumPaths = 450
  static let binaryExtensions: Set<String> = ["icns", "zip", "dylib", "dmg", "car", "pdf", "p12"]
  static let outputPrefixes = [".build/", ".claude/", ".gsd/", ".planning/"]

  static let pinnedHelperBinary = #"^Pinned/helper/v[0-9]+/OvertimeHelper$"#
  static let catalogImage = #"^Resources/Assets\.xcassets/.+\.png$"#
  static let readmeImage = #"^docs/images/[^/]+\.png$"#

  static func isSkipped(_ path: String) -> Bool {
    let pathExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
    return binaryExtensions.contains(pathExtension)
      || path.range(of: pinnedHelperBinary, options: .regularExpression) != nil
      || path.range(of: catalogImage, options: .regularExpression) != nil
      || path.range(of: readmeImage, options: .regularExpression) != nil
  }

  static func paths() async throws -> [String] {
    try await paths(in: NetworkSourceGateTests.repositoryRoot)
  }

  static func paths(in root: URL) async throws -> [String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", root.path, "ls-files", "-z"]
    let pipe = Pipe()
    let errors = Pipe()
    process.standardOutput = pipe
    process.standardError = errors
    process.standardInput = FileHandle.nullDevice
    try process.run()
    ProcessCleanup.track(process)
    let reader = pipe.fileHandleForReading
    let errorReader = errors.fileHandleForReading
    async let output = OffPool.bounded(seconds: 30) { reader.readDataToEndOfFile() }
    async let errorOutput = OffPool.bounded(seconds: 30) { errorReader.readDataToEndOfFile() }
    let (read, errorRead) = await (output, errorOutput)
    guard let data = read, let errorData = errorRead else {
      throw CorpusFailure(description: "git ls-files did not close its output within 30 s")
    }
    guard await OffPool.eventually(seconds: 10, { !process.isRunning }) else {
      throw CorpusFailure(description: "git ls-files did not exit within 10 s")
    }
    guard process.terminationStatus == 0 else {
      let message = String(decoding: errorData, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? ""
      throw CorpusFailure(
        description: "git ls-files exited with status \(process.terminationStatus): \(message)")
    }
    let paths = String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init)
    guard !paths.isEmpty else {
      throw CorpusFailure(description: "git ls-files listed no path")
    }
    return paths.sorted()
  }

  static func load() async throws -> Corpus {
    let paths = try await paths()
    let root = NetworkSourceGateTests.repositoryRoot
    return await OffPool.run { read(paths, under: root) }
  }

  static func read(_ paths: [String], under root: URL) -> Corpus {
    var files: [SourceFile] = []
    var unreadable: [String] = []
    var missing: [String] = []
    for path in paths where !isSkipped(path) {
      let url = root.appendingPathComponent(path)
      if let text = try? String(contentsOf: url, encoding: .utf8) {
        files.append(SourceFile(path: path, text: text))
      } else if FileManager.default.fileExists(atPath: url.path) {
        unreadable.append(path)
      } else {
        missing.append(path)
      }
    }
    return Corpus(paths: paths, files: files, unreadable: unreadable, missing: missing)
  }

  static func populationFindings(_ corpus: Corpus, requiring required: [String]) -> [String] {
    var findings: [String] = []
    if corpus.paths.count < minimumPaths {
      findings.append("population: \(corpus.paths.count) tracked paths, fewer than \(minimumPaths)")
    }
    let present = Set(corpus.paths)
    for path in required where !present.contains(path) {
      findings.append("population: missing \(path)")
    }
    for path in corpus.paths
    where outputPrefixes.contains(where: { path.hasPrefix($0) }) || path.contains("/.build/") {
      findings.append("population: \(path) is build or planning output")
    }
    for path in corpus.unreadable {
      findings.append("population: \(path) is unreadable as UTF-8")
    }
    for path in corpus.missing {
      findings.append("population: \(path) is missing from the working tree")
    }
    return findings
  }

  static func lines(of text: String) -> [String] {
    text.components(separatedBy: "\n")
  }

  static func sortKey(_ finding: String) -> (path: String, line: Int, rest: String) {
    let characters = Array(finding)
    var index = 0
    while index < characters.count {
      if characters[index] == ":" {
        var end = index + 1
        while end < characters.count, characters[end].isASCII, characters[end].isNumber {
          end += 1
        }
        if end > index + 1, end < characters.count, characters[end] == " " {
          let line = Int(String(characters[(index + 1)..<end])) ?? 0
          return (String(characters[..<index]), line, String(characters[(end + 1)...]))
        }
      }
      index += 1
    }
    return (finding, 0, "")
  }

  static func sorted(_ findings: [String]) -> [String] {
    findings.map { ($0, sortKey($0)) }
      .sorted { left, right in
        if left.1.path != right.1.path { return left.1.path < right.1.path }
        if left.1.line != right.1.line { return left.1.line < right.1.line }
        return left.1.rest < right.1.rest
      }
      .map(\.0)
  }
}
