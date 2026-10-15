import Foundation
import Testing

@Suite(.processCleanup)
struct RemovedToolGateTests {
  typealias SourceFile = TrackedFileCorpus.SourceFile

  static let folderName = "leg" + "acy"
  static let folderToken = folderName + "/"
  static let namePattern = "clau" + "de[-_]?aw" + "ake"
  static let tagPattern = "bash" + "-v0\\." + "1"
  static let gateFile = "Packages/OvertimeRuntime/Tests/OvertimeRuntimeTests/RemovedToolGateTests.swift"
  static let keptScenarioFile = "Packages/OvertimeCore/Tests/OvertimeCoreTests/Scenarios/BusyScenarios.swift"
  static let scenarioSpec = "docs/specs/SPEC-behavior-scenarios.md"

  static let requiredPaths = [
    "README.md",
    "LICENSE",
    "project.yml",
    ".github/workflows/ci.yml",
    "scripts/uninstall.sh",
    "docs/adr/0019-detection-loop-energy-design.md",
    "Packages/OvertimeCore/Sources/OvertimeCore/Model/Timing.swift",
    gateFile,
    keptScenarioFile,
    scenarioSpec,
  ]

  static func pathFindings(_ paths: [String]) -> [String] {
    TrackedFileCorpus.sorted(
      paths.filter { path in
        path.split(separator: "/", omittingEmptySubsequences: false).contains { $0.lowercased() == folderName }
      }
      .map { "\($0):0 path" })
  }

  static func isWordCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || character == "_"
  }

  static func mentionsFolder(_ line: String) -> Bool {
    var searchStart = line.startIndex
    while let range = line.range(of: folderToken, range: searchStart..<line.endIndex) {
      if range.lowerBound == line.startIndex || !isWordCharacter(line[line.index(before: range.lowerBound)]) {
        return true
      }
      searchStart = range.upperBound
    }
    return false
  }

  static func mentionFindings(_ files: [SourceFile]) -> [String] {
    TrackedFileCorpus.sorted(
      files.flatMap { file in
        TrackedFileCorpus.lines(of: file.text).enumerated().compactMap { index, line in
          mentionsFolder(line) ? "\(file.path):\(index + 1) mention" : nil
        }
      })
  }

  static func namesRemovedTool(_ line: String) -> Bool {
    [namePattern, tagPattern].contains { pattern in
      line.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
  }

  static func mayNameRemovedTool(_ text: String) -> Bool {
    let lowered = text.lowercased()
    return lowered.contains("aw" + "ake") || lowered.contains("bash")
  }

  static func nameFindings(_ files: [SourceFile]) -> [String] {
    TrackedFileCorpus.sorted(
      files.filter { mayNameRemovedTool($0.text) }
        .flatMap { file in
          TrackedFileCorpus.lines(of: file.text).enumerated().compactMap { index, line in
            namesRemovedTool(line) ? "\(file.path):\(index + 1) name" : nil
          }
        })
  }

  static let nameHead = "clau" + "de"
  static let nameTail = "aw" + "ake"
  static let tagName = "bash" + "-v0." + "1"

  @Test func theTrackedCorpusHoldsTheRepository() async throws {
    let corpus = try await TrackedFileCorpus.load()
    #expect(corpus.paths.count >= TrackedFileCorpus.minimumPaths)
    let findings = TrackedFileCorpus.populationFindings(corpus, requiring: Self.requiredPaths)
    #expect(findings.isEmpty, "\(findings)")
    #expect(corpus.files.contains { $0.path == Self.gateFile })
  }

  @Test func noTrackedPathOrFolderSitsUnderTheRemovedFolder() async throws {
    let corpus = try await TrackedFileCorpus.load()
    let findings = Self.pathFindings(corpus.paths)
    #expect(findings.isEmpty, "\(findings)")
    for name in [Self.folderName, Self.folderName.capitalized] {
      let folder = NetworkSourceGateTests.repositoryRoot.appendingPathComponent(name).path
      #expect(!FileManager.default.fileExists(atPath: folder), "a \(name) folder exists at the root")
    }
  }

  @Test func noTrackedFileMentionsTheRemovedFolder() async throws {
    let corpus = try await TrackedFileCorpus.load()
    let findings = Self.mentionFindings(corpus.files)
    #expect(findings.isEmpty, "\(findings)")
  }

  @Test func noTrackedFileNamesTheRemovedTool() async throws {
    let corpus = try await TrackedFileCorpus.load()
    let findings = Self.nameFindings(corpus.files)
    #expect(findings.isEmpty, "\(findings)")
  }

  struct Planted: Sendable, CustomTestStringConvertible {
    let name: String
    let paths: [String]
    let files: [SourceFile]
    let pathCount: Int
    let mentionCount: Int
    let nameCount: Int

    var testDescription: String { name }
  }

  static func planted(_ name: String, path: String, count: Int) -> Planted {
    Planted(name: name, paths: [path], files: [], pathCount: count, mentionCount: 0, nameCount: 0)
  }

  static func planted(_ name: String, text: String, mentions: Int = 0, names: Int = 0) -> Planted {
    Planted(
      name: name, paths: [], files: [SourceFile(path: "README.md", text: text)], pathCount: 0,
      mentionCount: mentions, nameCount: names)
  }

  static let plantedCases: [Planted] = [
    planted("a tracked path under the folder", path: folderToken + "bin/x", count: 1),
    planted("a nested path under the capitalised folder", path: "Tests/X/\(folderName.capitalized)/A.swift", count: 1),
    planted("the kept scenario file", path: keptScenarioFile, count: 0),
    planted(
      "a README line pointing into the folder", text: "See [\(folderToken)](\(folderToken)) for reference.",
      mentions: 1),
    planted("the capitalised token in prose", text: "See \(folderToken.capitalized) for the scenarios."),
    planted("the token after an identifier character", text: "let path = my_\(folderToken)x"),
    planted("the token after an opening parenthesis", text: "the old tool (\(folderToken)bin)", mentions: 1),
    planted("the name in lower case with a dash", text: "Run \(nameHead)-\(nameTail) first.", names: 1),
    planted("the name in upper case with an underscore", text: "\(nameHead)_\(nameTail)".uppercased(), names: 1),
    planted("the name in camel case run together", text: nameHead.capitalized + nameTail.capitalized, names: 1),
    planted("the tag", text: "It is kept at the \(tagName) tag.", names: 1),
    planted("the plain word in a sentence", text: "This is \(folderName) code, not a folder."),
    planted("a sentence about staying awake", text: "Claude stays awake while it works."),
  ]

  @Test(arguments: plantedCases)
  func theRulesReportPlantedPathsMentionsAndNamesAndOnlyThose(_ planted: Planted) async {
    #expect(Self.pathFindings(planted.paths).count == planted.pathCount)
    #expect(Self.mentionFindings(planted.files).count == planted.mentionCount)
    #expect(Self.nameFindings(planted.files).count == planted.nameCount)
  }

  @Test func theGateFileNeverSpellsWhatItGuards() async throws {
    let corpus = try await TrackedFileCorpus.load()
    let gate = try #require(corpus.files.first { $0.path == Self.gateFile })
    #expect(Self.mentionFindings([gate]).isEmpty)
    #expect(Self.nameFindings([gate]).isEmpty)
    #expect(Self.pathFindings([gate.path]).isEmpty)
  }

  @Test func anEmptyCorpusFailsThePopulationCheck() async {
    let empty = TrackedFileCorpus.Corpus(paths: [], files: [], unreadable: [])
    #expect(!TrackedFileCorpus.populationFindings(empty, requiring: Self.requiredPaths).isEmpty)
    #expect(Self.mentionFindings([SourceFile(path: "README.md", text: "")]).isEmpty)
    #expect(Self.nameFindings([SourceFile(path: "README.md", text: "")]).isEmpty)
  }

  @Test func findingsAreSortedByPathThenLine() async {
    let line = "see \(Self.folderToken)x, kept at \(Self.tagName)"
    var later = Array(repeating: "", count: 10)
    later[1] = line
    later[9] = line
    let files = [
      SourceFile(path: "docs/b.md", text: later.joined(separator: "\n")),
      SourceFile(path: "docs/a.md", text: line),
    ]
    let mentions = Self.mentionFindings(files)
    #expect(mentions == ["docs/a.md:1 mention", "docs/b.md:2 mention", "docs/b.md:10 mention"])
    #expect(TrackedFileCorpus.sorted(mentions) == mentions)
    #expect(TrackedFileCorpus.sorted(mentions.reversed()) == mentions)
    let names = Self.nameFindings(files)
    #expect(names == ["docs/a.md:1 name", "docs/b.md:2 name", "docs/b.md:10 name"])
    #expect(TrackedFileCorpus.sorted(names.reversed()) == names)
  }
}
