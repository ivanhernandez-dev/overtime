import Foundation
import Testing

struct PublicFaceGateTests {
  typealias SourceFile = NetworkSourceGateTests.SourceFile

  static let readme = "README.md"
  static let notice = "NOTICE"
  static let license = "LICENSE"
  static let changelog = "CHANGELOG.md"

  static let readmePhrases = [
    "Keeps your Mac awake while Claude Code works, with the lid open or closed.",
    "Works with Claude Code. Not affiliated with Anthropic.",
    "Apple Silicon and macOS 14+ only",
    "brew install --cask ivanhernandez-dev/tap/overtime",
    "Open Anyway",
    "Control-click",
    "brew uninstall --zap --cask overtime",
    "scripts/uninstall.sh",
    "Overtime collects no telemetry.",
    "disable-library-validation",
    "docs/RELEASING.md",
    "about three minutes",
    "sudo pmset -a disablesleep 0",
    "Overtime.app/Contents/MacOS/Overtime --reset",
    "Restore Normal Sleep Now",
    "SHA256SUMS",
  ]

  static let readmeForbidden = [
    "xattr",
    "--no-quarantine",
    "Keeps your Mac awake with the lid closed while Claude Code is working",
    "one minute by default",
  ]

  static let readmeIcon = "Resources/Assets.xcassets/AppIcon.appiconset/icon_256.png"

  static func withoutComments(_ text: String) -> String {
    text.replacingOccurrences(of: "(?s)<!--.*?-->", with: "", options: .regularExpression)
  }

  static func captures(_ pattern: String, in text: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
      Range(match.range(at: 1), in: text).map { String(text[$0]) }
    }
  }

  static func readmeImageFindings(_ file: SourceFile, exists: (String) -> Bool) -> [String] {
    let text = withoutComments(file.text)
    let sources = captures(#"\bsrc="([^"]*)""#, in: text)
    let candidates = captures(#"\bsrcset="([^"]*)""#, in: text).flatMap { value in
      value.split(separator: ",").compactMap { candidate in
        candidate.split(whereSeparator: \.isWhitespace).first.map(String.init)
      }
    }
    let markdown = captures(#"!\[[^\]]*\]\(([^)\s]+)"#, in: text)
    return (sources + candidates + markdown)
      .filter { !$0.hasPrefix("http://") && !$0.hasPrefix("https://") && !exists($0) }
      .map { "\(file.path) shows \($0), which is not in the repository" }
  }

  struct PlantedImage: Sendable, CustomTestStringConvertible {
    let name: String
    let text: String
    let count: Int

    var testDescription: String { name }
  }

  static let missingImage = "<img src=\"docs/images/missing.png\" alt=\"x\">"
  static let pendingOpening =
    "<!-- SCREENSHOT PENDING: docs/images/missing.png. Save the PNG at that path, "
    + "then delete this line and the closing line below."

  static let plantedImages: [PlantedImage] = [
    PlantedImage(name: "I-1 a live image whose file is missing", text: missingImage, count: 1),
    PlantedImage(name: "I-2 the same image inside a comment", text: "<!-- \(missingImage) -->", count: 0),
    PlantedImage(
      name: "I-3 a comment over three lines", text: [pendingOpening, missingImage, "-->"].joined(separator: "\n"),
      count: 0),
    PlantedImage(
      name: "I-4 a live image after a closed comment", text: "<!-- note --><img src=\"docs/images/missing.png\">",
      count: 1),
    PlantedImage(
      name: "I-5 a live image between two comments",
      text: "<!-- a --><img src=\"docs/images/missing.png\"><!-- b -->", count: 1),
    PlantedImage(
      name: "I-6 a source set with two candidates",
      text: "<source srcset=\"docs/images/missing-dark.png 1x, docs/images/missing-dark-2x.png 2x\">", count: 2),
    PlantedImage(name: "I-7 a Markdown image", text: "![Panel](docs/images/missing.png)", count: 1),
    PlantedImage(
      name: "I-8 the app icon from the asset catalog", text: "<img src=\"\(readmeIcon)\" alt=\"x\">", count: 0),
    PlantedImage(
      name: "I-9 a badge from an absolute URL",
      text: "[![CI](https://github.com/o/r/actions/workflows/ci.yml/badge.svg)](https://github.com/o/r)", count: 0),
  ]

  static let lidlessCredit =
    "Overtime includes code adapted from Lidless (https://github.com/nghialuong/Lidless), MIT License"
  static let sparkleMarker = "Overtime includes Sparkle 2.10.0 (https://sparkle-project.org)"

  static let releasing = "docs/RELEASING.md"
  static let repositoryDescription =
    "Keeps your Mac awake while Claude Code works, with the lid open or closed. "
    + "Works with Claude Code. Not affiliated with Anthropic. Apple Silicon and macOS 14+ only."

  static let releasingPhrases =
    [
      repositoryDescription,
      "pin-helper.sh",
      "T1_P12_BASE64",
      "SPARKLE_ED_PRIVATE_KEY",
      "HOMEBREW_TAP_TOKEN",
      "macOS 14",
      "Never register a self-hosted runner with the `xcode-27` label",
      "commits `Casks/overtime.rb` directly to the tap's default branch",
      "protect it against force pushes and deletion only",
      beforeOneZero,
      "scripts/energy/sample.sh",
      "scripts/energy/report.sh",
      "Release build",
      "### Step 1: a clean starting point",
      "cut-release.yml",
      "scripts/release/cut-release.sh",
      "git push --atomic",
      "gh secret list --env release",
      "gh secret set T1_P12_PASSWORD --env release",
      "your offline backup folder",
    ] + [1, 2, 3, 4, 5, 6, 8, 9, 10, 11].map { "### A-\($0):" } + runbookSteps

  static let releasingForbidden = ["/Users/", "Documents/Keys", "--body"]

  static let humanVerification = "## Human verification list"
  static let beforeOneZero = "## Before 1.0.0"
  static let keyCustody = "## Key custody"
  static let runbookSteps = (1...6).map { "### Step \($0):" }

  static func beforeOneZeroFindings(_ file: SourceFile) -> [String] {
    let lines = file.text.components(separatedBy: "\n")
    guard let start = lines.firstIndex(of: beforeOneZero) else {
      return ["\(file.path) has no \(beforeOneZero) section"]
    }
    let placed =
      (lines.firstIndex(of: humanVerification).map { $0 < start } ?? false)
      && (lines.firstIndex(of: keyCustody).map { start < $0 } ?? false)
    var findings = placed ? [] : ["\(file.path) puts \(beforeOneZero) outside \(humanVerification) and \(keyCustody)"]
    let end = lines[(start + 1)...].firstIndex { $0.hasPrefix("## ") } ?? lines.endIndex
    let section = Array(lines[(start + 1)..<end])
    let positions = runbookSteps.map { step in section.firstIndex { $0.hasPrefix(step) } }
    let missing = zip(runbookSteps, positions).filter { $0.1 == nil }.map(\.0)
    if !missing.isEmpty {
      findings.append("\(file.path) lacks \(missing.joined(separator: ", ")) in \(beforeOneZero)")
    } else if positions.compactMap({ $0 }) != positions.compactMap({ $0 }).sorted() {
      findings.append("\(file.path) has the \(beforeOneZero) steps out of order")
    }
    return findings
  }

  static func movingBeforeOneZeroToTheEnd(_ file: SourceFile) -> SourceFile {
    let lines = file.text.components(separatedBy: "\n")
    guard let start = lines.firstIndex(of: beforeOneZero) else {
      Issue.record("\(file.path) lacks \(beforeOneZero)")
      return file
    }
    let end = lines[(start + 1)...].firstIndex { $0.hasPrefix("## ") } ?? lines.endIndex
    let kept = Array(lines[..<start]) + Array(lines[end...])
    return SourceFile(path: file.path, text: (kept + [""] + Array(lines[start..<end])).joined(separator: "\n"))
  }

  static func runbookMutant(_ name: String, of file: SourceFile) -> SourceFile {
    switch name {
    case "the Step 6 heading removed":
      return replacing(file, "### Step 6:", with: "")
    case "Steps 2 and 3 swapped":
      let held = replacing(file, "### Step 2:", with: "### Step X:")
      return replacing(replacing(held, "### Step 3:", with: "### Step 2:"), "### Step X:", with: "### Step 3:")
    default:
      return movingBeforeOneZeroToTheEnd(file)
    }
  }

  static let distributionRecord = "docs/adr/0006-t1-self-signed-distribution.md"
  static let keysRecord = "docs/adr/0008-long-lived-t1-signing-identity-and-keys.md"
  static let pinRecord = "docs/adr/0010-pinned-helper-binary.md"
  static let notePrefix = "## Implementation notes (2026-"

  static let adrNotePhrases: [String: [String]] = [
    distributionRecord: ["lipo -thin arm64", "Sign and notarize the DMG"],
    keysRecord: ["the EdDSA key is the sole update path", "SparkleInfoPlistGateTests"],
    pinRecord: ["MANIFEST.json", "--allow-missing"],
  ]

  static func releasingFindings(_ file: SourceFile) -> [String] {
    requiring(releasingPhrases, in: file) + forbidding(releasingForbidden, in: file)
  }

  static func adrFindings(_ file: SourceFile) -> [String] {
    let lines = file.text.components(separatedBy: "\n")
    guard lines.contains("## Decision") else { return ["\(file.path) lost its ## Decision heading"] }
    guard let note = lines.firstIndex(where: { $0.hasPrefix(notePrefix) }) else {
      return ["\(file.path) has no dated implementation note"]
    }
    guard let evidence = lines.firstIndex(of: "## Evidence"), evidence < note else {
      return ["\(file.path) puts its implementation note before ## Evidence"]
    }
    let noteText = SourceFile(path: file.path, text: lines[note...].joined(separator: "\n"))
    return requiring(adrNotePhrases[file.path] ?? [], in: noteText)
  }

  static func read(_ path: String) throws -> SourceFile {
    let url = NetworkSourceGateTests.repositoryRoot.appendingPathComponent(path)
    return SourceFile(path: path, text: try String(contentsOf: url, encoding: .utf8))
  }

  static func requiring(_ phrases: [String], in file: SourceFile) -> [String] {
    phrases.filter { !file.text.contains($0) }.map { "\(file.path) lacks \"\($0)\"" }
  }

  static func forbidding(_ phrases: [String], in file: SourceFile) -> [String] {
    phrases.filter { file.text.lowercased().contains($0.lowercased()) }.map { "\(file.path) has \"\($0)\"" }
  }

  static func readmeFindings(_ file: SourceFile) -> [String] {
    requiring(readmePhrases, in: file) + forbidding(readmeForbidden, in: file)
  }

  static func noticeFindings(_ file: SourceFile) -> [String] {
    requiring([lidlessCredit, "AuxiliaryWindowController", sparkleMarker], in: file)
  }

  static func licenseFindings(_ file: SourceFile) -> [String] {
    LicenseTerms.holds(file.text) ? [] : ["\(file.path) is not MIT with the Commons Clause"]
  }

  static func changelogFindings(_ file: SourceFile) -> [String] {
    let headed = file.text.components(separatedBy: "\n").contains { $0.hasPrefix("## [1.0.0]") }
    return headed ? [] : ["\(file.path) has no ## [1.0.0] section"]
  }

  static func replacing(_ file: SourceFile, _ old: String, with new: String) -> SourceFile {
    #expect(file.text.contains(old), "\(file.path) lacks \(old)")
    return SourceFile(path: file.path, text: file.text.replacingOccurrences(of: old, with: new))
  }

  static func appending(_ file: SourceFile, _ addition: String) -> SourceFile {
    SourceFile(path: file.path, text: file.text + "\n" + addition + "\n")
  }

  static func expectOne(_ findings: [String], naming path: String) {
    #expect(findings.count == 1, "\(findings)")
    #expect(findings.first?.hasPrefix(path) == true, "\(findings)")
  }

  @Test func theReadmeCarriesEveryPublicPhraseAndNoQuarantineRecipe() throws {
    #expect(Self.readmeFindings(try Self.read(Self.readme)) == [])
  }

  @Test func noticeLicenseAndChangelogMatchWhatTheAppShips() throws {
    #expect(Self.noticeFindings(try Self.read(Self.notice)) == [])
    #expect(Self.licenseFindings(try Self.read(Self.license)) == [])
    #expect(Self.changelogFindings(try Self.read(Self.changelog)) == [])
  }

  @Test(arguments: [
    "Works with Claude Code. Not affiliated with Anthropic.",
    "Apple Silicon and macOS 14+ only",
    "brew install --cask ivanhernandez-dev/tap/overtime",
    "Overtime collects no telemetry.",
    "about three minutes",
    "sudo pmset -a disablesleep 0",
  ])
  func theReadmeGateCatchesAMissingPhrase(phrase: String) throws {
    let changed = Self.replacing(try Self.read(Self.readme), phrase, with: "")
    Self.expectOne(Self.readmeFindings(changed), naming: Self.readme)
  }

  @Test(arguments: [
    "xattr -dr com.apple.quarantine /Applications/Overtime.app",
    "Run `XATTR -c Overtime.app` if macOS refuses to open it.",
    "brew install --cask --no-quarantine ivanhernandez-dev/tap/overtime",
    "Keeps your Mac awake with the lid closed while Claude Code is working, and lets it sleep.",
    "When the work stops, the Mac sleeps again after a short grace period, one minute by default.",
  ])
  func theReadmeGateCatchesAQuarantineRecipeOrTheOldLine(line: String) throws {
    let changed = Self.appending(try Self.read(Self.readme), line)
    Self.expectOne(Self.readmeFindings(changed), naming: Self.readme)
  }

  @Test func theNoticeGateCatchesAMissingLidlessCredit() throws {
    let changed = Self.replacing(try Self.read(Self.notice), Self.lidlessCredit, with: "Overtime includes code")
    Self.expectOne(Self.noticeFindings(changed), naming: Self.notice)
  }

  @Test func theNoticeGateCatchesAMissingSparkleMarker() throws {
    let changed = Self.replacing(try Self.read(Self.notice), Self.sparkleMarker, with: "Overtime includes Sparkle")
    Self.expectOne(Self.noticeFindings(changed), naming: Self.notice)
  }

  @Test func theReleaseChecklistCarriesEveryAuthorItemAndSecret() throws {
    #expect(Self.releasingFindings(try Self.read(Self.releasing)) == [])
  }

  @Test(arguments: [
    "### A-6:",
    "### A-1:",
    "HOMEBREW_TAP_TOKEN",
    "Never register a self-hosted runner with the `xcode-27` label",
    "Works with Claude Code. Not affiliated with Anthropic. Apple Silicon and macOS 14+ only.",
    "protect it against force pushes and deletion only",
    "### Step 6:",
    "scripts/energy/report.sh",
    "cut-release.yml",
    "gh secret list --env release",
    "your offline backup folder",
  ])
  func theReleaseChecklistGateCatchesAMissingItem(item: String) throws {
    let changed = Self.replacing(try Self.read(Self.releasing), item, with: "")
    Self.expectOne(Self.releasingFindings(changed), naming: Self.releasing)
  }

  @Test(arguments: [
    "cp /Users/someone/backup/overtime-t1.p12 .",
    "cat ~/Documents/Keys/overtime/sparkle-ed25519-private.key",
    "gh secret set HOMEBREW_TAP_TOKEN --env release --body github_pat_planted",
  ])
  func theReleaseChecklistGateCatchesAForbiddenLine(line: String) throws {
    let changed = Self.appending(try Self.read(Self.releasing), line)
    Self.expectOne(Self.releasingFindings(changed), naming: Self.releasing)
  }

  @Test func theBeforeOneZeroRunbookIsInPlaceAndInOrder() throws {
    #expect(Self.beforeOneZeroFindings(try Self.read(Self.releasing)) == [])
  }

  @Test(arguments: ["the Step 6 heading removed", "Steps 2 and 3 swapped", "the section moved after Key custody"])
  func theRunbookGateCatchesAMissingOrMisorderedStep(mutant: String) throws {
    let changed = Self.runbookMutant(mutant, of: try Self.read(Self.releasing))
    Self.expectOne(Self.beforeOneZeroFindings(changed), naming: Self.releasing)
  }

  @Test(arguments: [distributionRecord, keysRecord, pinRecord])
  func eachDistributionRecordKeepsItsDecisionAndGainsADatedNote(path: String) throws {
    #expect(Self.adrFindings(try Self.read(path)) == [])
  }

  @Test(arguments: [distributionRecord, keysRecord, pinRecord])
  func theRecordGateCatchesAMissingNoteOrDecision(path: String) throws {
    let file = try Self.read(path)
    Self.expectOne(Self.adrFindings(Self.replacing(file, Self.notePrefix, with: "## Notes (2026-")), naming: path)
    Self.expectOne(Self.adrFindings(Self.replacing(file, "\n## Decision\n", with: "\n## Choice\n")), naming: path)
  }

  @Test(arguments: [distributionRecord, keysRecord, pinRecord])
  func theRecordGateCatchesANoteAboveTheEvidence(path: String) throws {
    let file = try Self.read(path)
    let moved = Self.replacing(file, "\n## Evidence\n", with: "\n## Evidence (moved)\n")
    let planted = SourceFile(path: path, text: moved.text + "\n## Evidence\n\nPlanted.\n")
    Self.expectOne(Self.adrFindings(planted), naming: path)
  }

  @Test(arguments: [
    (distributionRecord, "lipo -thin arm64"),
    (distributionRecord, "Sign and notarize the DMG"),
    (keysRecord, "the EdDSA key is the sole update path"),
    (pinRecord, "--allow-missing"),
  ])
  func theRecordGateCatchesANoteWithoutItsPoint(path: String, phrase: String) throws {
    let changed = Self.replacing(try Self.read(path), phrase, with: "")
    Self.expectOne(Self.adrFindings(changed), naming: path)
  }

  @Test func theLicenseAndChangelogGatesCatchAPlantedChange() throws {
    let license = Self.replacing(try Self.read(Self.license), "\nMIT License\n", with: "\nApache License\n")
    Self.expectOne(Self.licenseFindings(license), naming: Self.license)
    let changelog = Self.replacing(try Self.read(Self.changelog), "## [1.0.0]", with: "## [0.0.9]")
    Self.expectOne(Self.changelogFindings(changelog), naming: Self.changelog)
  }

  @Test func theReadmeShowsTheAppIconAndOnlyImagesThatExist() throws {
    let file = try Self.read(Self.readme)
    #expect(Self.withoutComments(file.text).contains("src=\"\(Self.readmeIcon)\""))
    let findings = Self.readmeImageFindings(file) { path in
      FileManager.default.fileExists(atPath: NetworkSourceGateTests.repositoryRoot.appendingPathComponent(path).path)
    }
    #expect(findings == [])
  }

  @Test(arguments: plantedImages)
  func theReadmeImageGateReportsPlantedImagesAndOnlyThose(_ planted: PlantedImage) {
    let file = SourceFile(path: Self.readme, text: planted.text)
    let findings = Self.readmeImageFindings(file) { $0 == Self.readmeIcon }
    #expect(findings.count == planted.count, "\(findings)")
    #expect(findings.allSatisfy { $0.hasPrefix(file.path) }, "\(findings)")
  }
}
