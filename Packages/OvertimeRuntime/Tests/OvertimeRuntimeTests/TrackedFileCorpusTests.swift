import Foundation
import Testing

@Suite(.processCleanup)
struct TrackedFileCorpusTests {
  @Test func aStagedFileMissingFromTheWorkingTreeIsReportedAsMissing() throws {
    let directory = try TempDirectory()
    try Data("text\n".utf8).write(to: directory.url.appendingPathComponent("present.md"))
    try Data([0xFF, 0xFE, 0x00]).write(to: directory.url.appendingPathComponent("binary.txt"))
    let corpus = TrackedFileCorpus.read(["binary.txt", "gone.md", "present.md"], under: directory.url)
    #expect(corpus.files.map(\.path) == ["present.md"])
    #expect(corpus.missing == ["gone.md"])
    #expect(corpus.unreadable == ["binary.txt"])
    let findings = TrackedFileCorpus.populationFindings(corpus, requiring: [])
    #expect(findings.contains("population: gone.md is missing from the working tree"))
    #expect(findings.contains("population: binary.txt is unreadable as UTF-8"))
    #expect(!findings.contains("population: gone.md is unreadable as UTF-8"))
  }

  @Test(arguments: [
    ("Pinned/helper/v1/OvertimeHelper", true),
    ("Pinned/helper/v12/OvertimeHelper", true),
    ("Pinned/helper/v1/MANIFEST.json", false),
    ("Pinned/notes.md", false),
    ("docs/Pinned/README.md", false),
    ("Resources/Assets.car", true),
    ("Resources/AppIcon.icns", true),
  ])
  func onlyThePinnedHelperBinaryAndBinaryExtensionsAreSkipped(path: String, skipped: Bool) {
    #expect(TrackedFileCorpus.isSkipped(path) == skipped)
  }

  @Test(arguments: [
    ("Resources/Assets.xcassets/AppIcon.appiconset/icon_16.png", true),
    ("Resources/Assets.xcassets/Group/Nested.imageset/mark.png", true),
    ("docs/screenshot.png", false),
    ("icon.png", false),
    ("Resources/icon_16.png", false),
    ("Sources/Overtime/Assets.xcassets/x.png", false),
    ("docs/Resources/Assets.xcassets/x.png", false),
    ("Resources/Assets.xcassets/StatusIdle.imageset/rays-idle.svg", false),
    ("Resources/Assets.xcassets/AppIcon.appiconset/Contents.json", false),
    ("Resources/AppIcon.svg", false),
    ("docs/images/panel-holding-light.png", true),
    ("docs/images/gatekeeper-open-anyway.png", true),
    ("docs/images/nested/shot.png", false),
    ("docs/images/shot.svg", false),
    ("docs/imagesx/shot.png", false),
    ("x/docs/images/shot.png", false),
  ])
  func aPNGIsSkippedOnlyInsideTheAssetCatalogOrTheReadmeImageFolder(path: String, skipped: Bool) {
    #expect(TrackedFileCorpus.isSkipped(path) == skipped)
  }

  @Test func theCatalogTextIsScannedAndOnlyItsPNGsAndTheReadmeImagesAreSkipped() async throws {
    let corpus = try await TrackedFileCorpus.load()
    let catalog = AssetCatalogGateTests.catalog + "/"
    let images = corpus.paths.filter { $0.lowercased().hasSuffix(".png") }
    #expect(images.count >= 7)
    for path in images {
      #expect(
        path.hasPrefix(catalog) || path.range(of: TrackedFileCorpus.readmeImage, options: .regularExpression) != nil,
        "\(path) is a PNG outside the asset catalog")
      #expect(TrackedFileCorpus.isSkipped(path), "\(path) is not skipped")
    }
    let read = Set(corpus.files.map(\.path))
    let text = corpus.paths.filter { $0.hasPrefix(catalog) && !$0.lowercased().hasSuffix(".png") }
    #expect(text.filter { $0.hasSuffix(".svg") }.count == 8)
    #expect(text.filter { $0.hasSuffix("/" + AssetCatalogGateTests.documentName) }.count == 10)
    #expect(text.count == 18)
    for path in text + [AssetCatalogGateTests.master] {
      #expect(read.contains(path), "\(path) is not read as text")
    }
    #expect(corpus.unreadable.isEmpty, "\(corpus.unreadable)")
    #expect(corpus.missing.isEmpty, "\(corpus.missing)")
  }

  @Test func aReadmeImageIsSkippedNotReportedUnreadable() throws {
    let directory = try TempDirectory()
    let images = directory.url.appendingPathComponent("docs/images")
    try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
    try AssetCatalogGateTests.pngHeader(width: 16, height: 16)
      .write(to: images.appendingPathComponent("panel-holding-light.png"))
    try Data("notes\n".utf8).write(to: directory.url.appendingPathComponent("docs/notes.md"))
    let corpus = TrackedFileCorpus.read(
      ["docs/images/panel-holding-light.png", "docs/notes.md"], under: directory.url)
    #expect(corpus.files.map(\.path) == ["docs/notes.md"])
    #expect(corpus.unreadable.isEmpty, "\(corpus.unreadable)")
    #expect(corpus.missing.isEmpty, "\(corpus.missing)")
  }

  @Test func aGitFailureCarriesGitsOwnMessage() async throws {
    let directory = try TempDirectory()
    do {
      let paths = try await TrackedFileCorpus.paths(in: directory.url)
      Issue.record("git ls-files listed \(paths.count) paths outside a repository")
    } catch let failure as TrackedFileCorpus.CorpusFailure {
      #expect(failure.description.contains("exited with status"), "\(failure)")
      #expect(failure.description.contains("not a git repository"), "\(failure)")
    }
  }
}
