import Foundation
import Testing

@Suite(.processCleanup)
struct EnglishTextGateTests {
  typealias SourceFile = TrackedFileCorpus.SourceFile

  static let runtimeTests = "Packages/OvertimeRuntime/Tests/OvertimeRuntimeTests/"
  static let gateFile = runtimeTests + "EnglishTextGateTests.swift"

  static let allowedNames: [String: Set<String>] = [
    "LICENSE": ["Iván", "Hernández"],
    "NOTICE": ["Lesiński"],
    "docs/RELEASING.md": ["Iván", "Hernández"],
    runtimeTests + "SparkleInfoPlistGateTests.swift": ["Iván", "Hernández"],
  ]

  static let allowlist: Set<String> = [
    "Packages/OvertimeCore/Tests/OvertimeCoreTests/TranscriptHeaderTests.swift",
    runtimeTests + "DiagnosticsExporterTests.swift",
    runtimeTests + "DiagnosticsManifestTests.swift",
    runtimeTests + "DiagnosticsRedactionTests.swift",
    runtimeTests + "HotspotPickerCopyTests.swift",
    runtimeTests + "SettingsEditorTests.swift",
    runtimeTests + "WiFiControllerJoinTests.swift",
    gateFile,
  ]

  static let letterCategories: Set<Unicode.GeneralCategory> = [
    .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .otherLetter,
  ]

  static let denylist: Set<String> = [
    "que", "para", "pero", "porque", "cuando", "también", "tambien", "esto", "está", "ahora",
    "siempre", "nunca", "aquí", "hacer", "usuario", "archivo", "prueba", "ejemplo", "después", "mientras",
    "pantalla", "batería", "dormir", "gracias", "hola", "cerrar", "cómo", "dónde",
  ]

  static let variationSelectors: [ClosedRange<UInt32>] = [0xFE00...0xFE0F, 0xE0100...0xE01EF]

  static func isCombiningMark(_ scalar: Unicode.Scalar) -> Bool {
    scalar.properties.generalCategory == .nonspacingMark
      && !variationSelectors.contains { $0.contains(scalar.value) }
  }

  static func isNonEnglishLetter(_ scalar: Unicode.Scalar) -> Bool {
    (!scalar.isASCII && letterCategories.contains(scalar.properties.generalCategory)) || isCombiningMark(scalar)
  }

  static func hex(_ scalar: Unicode.Scalar) -> String {
    let digits = String(scalar.value, radix: 16, uppercase: true)
    return "U+" + String(repeating: "0", count: max(0, 4 - digits.count)) + digits
  }

  static func tokens(of line: String) -> [String] {
    line.split(whereSeparator: { !$0.isLetter }).map(String.init)
  }

  static func scanned(_ line: String, allowing names: Set<String>) -> String {
    guard !names.isEmpty else { return line }
    var kept = ""
    var token = ""
    for character in line {
      if character.isLetter {
        token.append(character)
        continue
      }
      if !names.contains(token) {
        kept += token
      }
      token = ""
      kept.append(character)
    }
    return names.contains(token) ? kept : kept + token
  }

  static func letterFindings(_ file: SourceFile) -> [String] {
    let names = allowedNames[file.path] ?? []
    return TrackedFileCorpus.lines(of: file.text).enumerated().flatMap { index, line in
      scanned(line, allowing: names).unicodeScalars.filter(isNonEnglishLetter).map {
        "\(file.path):\(index + 1) \(isCombiningMark($0) ? "mark" : "letter") \(hex($0))"
      }
    }
  }

  static func wordFindings(_ file: SourceFile) -> [String] {
    TrackedFileCorpus.lines(of: file.text).enumerated().flatMap { index, line in
      line.split(whereSeparator: { !$0.isLetter }).map { $0.lowercased() }.filter { denylist.contains($0) }
        .map { "\(file.path):\(index + 1) word \($0)" }
    }
  }

  static func findings(_ files: [SourceFile]) -> [String] {
    TrackedFileCorpus.sorted(
      files.flatMap { file in
        (allowlist.contains(file.path) ? [] : letterFindings(file))
          + (file.path == gateFile ? [] : wordFindings(file))
      })
  }

  @Test func theCorpusHoldsEveryFileTheAllowlistNames() async throws {
    let corpus = try await TrackedFileCorpus.load()
    let required = Self.allowlist.union(Self.allowedNames.keys).sorted()
    let findings = TrackedFileCorpus.populationFindings(corpus, requiring: required)
    #expect(findings.isEmpty, "\(findings)")
  }

  @Test func everyTrackedTextFileIsEnglish() async throws {
    let corpus = try await TrackedFileCorpus.load()
    #expect(corpus.files.count >= TrackedFileCorpus.minimumPaths)
    let findings = Self.findings(corpus.files)
    #expect(findings.isEmpty, "\(findings)")
  }

  @Test func theAllowlistNamesOnlyFilesThatStillHoldNonEnglishLetters() async throws {
    let corpus = try await TrackedFileCorpus.load()
    let byPath = Dictionary(uniqueKeysWithValues: corpus.files.map { ($0.path, $0) })
    for path in Self.allowlist.sorted() where path != Self.gateFile {
      let file = try #require(byPath[path], "\(path) is not in the corpus")
      #expect(!Self.letterFindings(file).isEmpty, "\(path) no longer holds a non-English letter")
    }
  }

  @Test func theNameAllowlistNamesOnlyTokensThatStillOccurAndNeedIt() async throws {
    let corpus = try await TrackedFileCorpus.load()
    let byPath = Dictionary(uniqueKeysWithValues: corpus.files.map { ($0.path, $0) })
    #expect(Self.allowlist.isDisjoint(with: Self.allowedNames.keys))
    for (path, names) in Self.allowedNames.sorted(by: { $0.key < $1.key }) {
      let file = try #require(byPath[path], "\(path) is not in the corpus")
      let tokens = Set(TrackedFileCorpus.lines(of: file.text).flatMap(Self.tokens(of:)))
      for name in names.sorted() {
        #expect(tokens.contains(name), "\(path) no longer holds the token \(name)")
        #expect(name.unicodeScalars.contains(where: Self.isNonEnglishLetter), "\(name) needs no allowance")
      }
    }
  }

  struct Planted: Sendable, CustomTestStringConvertible {
    let name: String
    let path: String
    let text: String
    let letters: Int
    let words: Int

    var testDescription: String { name }

    func counts() -> (letters: Int, words: Int) {
      let found = EnglishTextGateTests.findings([SourceFile(path: path, text: text)])
      return (
        found.filter { $0.contains(" letter ") || $0.contains(" mark ") }.count,
        found.filter { $0.contains(" word ") }.count
      )
    }
  }

  static let plantedLetters: [Planted] = [
    Planted(
      name: "the Spanish word for battery", path: "Sources/Overtime/Planted.swift",
      text: "let label = \"batería\"", letters: 1, words: 1),
    Planted(
      name: "an accented cafe name in an allowlisted test", path: runtimeTests + "DiagnosticsRedactionTests.swift",
      text: "let name = \"Café Net\"", letters: 0, words: 0),
    Planted(name: "a modifier letter", path: "docs/Planted.md", text: "20 s × 2ⁿ", letters: 0, words: 0),
    Planted(
      name: "typographic punctuation and an emoji", path: "docs/Planted.md", text: "It’s on… → ✋", letters: 0,
      words: 0),
    Planted(name: "an Arabic-Indic digit", path: "docs/Planted.md", text: "level ٣", letters: 0, words: 0),
    Planted(name: "a decomposed accent", path: "docs/Planted.md", text: "bateri\u{0301}a", letters: 1, words: 1),
    Planted(
      name: "a decomposed word off the denylist", path: "docs/Planted.md", text: "Revisio\u{0301}n del ajuste",
      letters: 1, words: 0),
    Planted(
      name: "an emoji variation selector", path: "docs/Planted.md", text: "\u{26A0}\u{FE0F} warning", letters: 0,
      words: 0),
  ]

  @Test(arguments: plantedLetters)
  func theLetterRuleReportsPlantedLettersAndSkipsTypography(_ planted: Planted) async {
    let counts = planted.counts()
    #expect(counts.letters == planted.letters)
    #expect(counts.words == planted.words)
  }

  static let plantedNames: [Planted] = [
    Planted(
      name: "the copyright holder in the runbook", path: "docs/RELEASING.md",
      text: "Copyright (c) 2026 Iván Hernández", letters: 0, words: 0),
    Planted(
      name: "an accented word beside the name in the runbook", path: "docs/RELEASING.md",
      text: "Iván Hernández: Revisión del ajuste", letters: 1, words: 0),
    Planted(
      name: "a longer token that starts with the name", path: "docs/RELEASING.md", text: "Ivánez", letters: 1,
      words: 0),
    Planted(
      name: "an accented word in a gate test that names the holder",
      path: runtimeTests + "SparkleInfoPlistGateTests.swift", text: "let label = \"Configuración\"", letters: 1,
      words: 0),
    Planted(
      name: "another name in the license", path: "LICENSE", text: "Copyright (c) 2026 Ramón", letters: 1, words: 0),
    Planted(name: "the Sparkle author in the notice", path: "NOTICE", text: "Lesiński.", letters: 0, words: 0),
    Planted(
      name: "the name in a file that does not list it", path: "docs/Planted.md", text: "Iván", letters: 1, words: 0),
  ]

  @Test(arguments: plantedNames)
  func theNameAllowlistExemptsOnlyTheExactTokensInTheirFiles(_ planted: Planted) async {
    let counts = planted.counts()
    #expect(counts.letters == planted.letters)
    #expect(counts.words == planted.words)
  }

  @Test func anAccentedWordAddedToTheRealRunbookFails() throws {
    let runbook = try PublicFaceGateTests.read("docs/RELEASING.md")
    #expect(Self.findings([runbook]) == [])
    let planted = PublicFaceGateTests.appending(runbook, "Revisión del ajuste")
    PublicFaceGateTests.expectOne(Self.findings([planted]), naming: "docs/RELEASING.md")
  }

  static let plantedWords: [Planted] = [
    Planted(
      name: "letters join a longer token", path: "README.md", text: "queue paragraph comoTodo", letters: 0, words: 0),
    Planted(name: "punctuation separates", path: "README.md", text: "que, then", letters: 0, words: 1),
    Planted(name: "an underscore separates", path: "README.md", text: "para_x", letters: 0, words: 1),
    Planted(name: "a digit separates", path: "README.md", text: "2para", letters: 0, words: 1),
    Planted(name: "the match ignores case", path: "README.md", text: "QUE", letters: 0, words: 1),
    Planted(name: "kept off the list", path: "scripts/x.sh", text: "jq 'del(.sources)' # TODO", letters: 0, words: 0),
    Planted(name: "the gate itself is exempt", path: gateFile, text: "que para pero", letters: 0, words: 0),
  ]

  @Test(arguments: plantedWords)
  func theWordRuleMatchesWholeWordsOnly(_ planted: Planted) async {
    let counts = planted.counts()
    #expect(counts.letters == planted.letters)
    #expect(counts.words == planted.words)
  }

  @Test func theEnglishFindingsAreSortedByPathThenLine() async {
    let files = [
      SourceFile(path: "docs/b.md", text: "first\nque batería"),
      SourceFile(path: "docs/a.md", text: "para"),
    ]
    let findings = Self.findings(files)
    #expect(
      findings == [
        "docs/a.md:1 word para", "docs/b.md:2 letter U+00ED", "docs/b.md:2 word batería", "docs/b.md:2 word que",
      ])
    #expect(TrackedFileCorpus.sorted(findings.reversed()) == findings)
  }
}
