import Foundation
import OvertimeAppSupport
import Testing

struct AssetCatalogGateTests {
  typealias SourceFile = NetworkSourceGateTests.SourceFile

  struct Slot: Hashable, Sendable {
    let points: Int
    let scale: Int

    var pixels: Int { points * scale }
    var size: String { "\(points)x\(points)" }
    var scaleName: String { "\(scale)x" }
    var label: String { "\(size)@\(scaleName)" }
  }

  struct ImageSet: Sendable {
    let name: String
    let contents: Data
    let files: [String: Data]
  }

  struct IconDocument: Decodable {
    struct Entry: Decodable {
      let filename: String?
      let idiom: String?
      let scale: String?
      let size: String?
    }

    let images: [Entry]
  }

  struct GlyphDocument: Decodable {
    struct Entry: Decodable {
      let filename: String?
    }

    struct Properties: Decodable {
      let intent: String?
      let preservesVector: Bool?

      enum CodingKeys: String, CodingKey {
        case intent = "template-rendering-intent"
        case preservesVector = "preserves-vector-representation"
      }
    }

    let images: [Entry]
    let properties: Properties?
  }

  struct GateFailure: Error, CustomStringConvertible {
    let description: String
  }

  static let catalog = "Resources/Assets.xcassets"
  static let iconSet = catalog + "/AppIcon.appiconset"
  static let master = "Resources/AppIcon.svg"
  static let projectSpec = "project.yml"
  static let documentName = "Contents.json"
  static let imageSetSuffix = ".imageset"
  static let macIdiom = "mac"
  static let catalogSourceLine = "- path: " + catalog
  static let iconNameKey = "ASSETCATALOG_COMPILER_APPICON_NAME"
  static let iconName = "AppIcon"
  static let templateIntent = "template"
  static let glyphCanvas = [" viewBox=\"0 0 18 18\"", " width=\"18\"", " height=\"18\""]
  static let masterCanvas = " viewBox=\"0 0 1024 1024\""
  static let pngSignature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
  static let headerChunk: [UInt8] = [73, 72, 68, 82]

  static let slots: [Slot] = [16, 32, 128, 256, 512].flatMap { points in
    [Slot(points: points, scale: 1), Slot(points: points, scale: 2)]
  }

  static let glyphSetNames = StatusGlyph.allCases.map(\.assetName)

  static func pngSize(_ data: Data) -> (width: Int, height: Int)? {
    let bytes = [UInt8](data.prefix(24))
    guard bytes.count == 24, Array(bytes[0..<8]) == pngSignature, Array(bytes[12..<16]) == headerChunk else {
      return nil
    }
    func bigEndian(at offset: Int) -> Int {
      bytes[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
    }
    return (bigEndian(at: 16), bigEndian(at: 20))
  }

  static func iconFindings(contents: Data, files: [String: Data]) -> [String] {
    guard let document = try? JSONDecoder().decode(IconDocument.self, from: contents) else {
      return ["\(iconSet)/\(documentName) is not a readable icon set document"]
    }
    var findings: [String] = []
    var named: Set<String> = []
    var fills: [Slot: Int] = [:]
    for (index, entry) in document.images.enumerated() {
      let place = "\(iconSet)/\(documentName) entry \(index + 1)"
      let slot = slots.first { $0.size == entry.size && $0.scaleName == entry.scale }
      if entry.idiom != macIdiom {
        findings.append("\(place) has the idiom \(entry.idiom ?? "none"), not \(macIdiom)")
      } else if let slot {
        fills[slot, default: 0] += 1
      } else {
        findings.append("\(place) is outside the ten macOS slots: \(entry.size ?? "none")@\(entry.scale ?? "none")")
      }
      guard let name = entry.filename else {
        findings.append("\(place) names no file")
        continue
      }
      named.insert(name)
      guard let data = files[name] else {
        findings.append("\(place) names \(name), which is not in the icon set")
        continue
      }
      guard let size = pngSize(data), let slot else { continue }
      if size.width != slot.pixels || size.height != slot.pixels {
        findings.append(
          "\(place): \(name) is \(size.width) x \(size.height) pixels, not \(slot.pixels) x \(slot.pixels)")
      }
    }
    for slot in slots {
      let count = fills[slot] ?? 0
      if count == 0 {
        findings.append("\(iconSet): the slot \(slot.label) is not filled")
      } else if count > 1 {
        findings.append("\(iconSet): the slot \(slot.label) is filled \(count) times")
      }
    }
    for (name, data) in files {
      if pngSize(data) == nil {
        findings.append("\(iconSet)/\(name) is not a PNG")
      }
      if !named.contains(name) {
        findings.append("\(iconSet)/\(name) is named by no entry")
      }
    }
    return findings.sorted()
  }

  static func glyphFindings(_ sets: [ImageSet], expected: [String]) -> [String] {
    var findings: [String] = []
    let present = Set(sets.map(\.name))
    for name in expected where !present.contains(name) {
      findings.append("\(catalog)/\(name)\(imageSetSuffix) is missing")
    }
    var artwork: [(set: String, data: Data)] = []
    for set in sets {
      let place = "\(catalog)/\(set.name)\(imageSetSuffix)"
      if !expected.contains(set.name) {
        findings.append("\(place) is no status glyph")
      }
      guard let document = try? JSONDecoder().decode(GlyphDocument.self, from: set.contents) else {
        findings.append("\(place)/\(documentName) is not a readable image set document")
        continue
      }
      if document.properties?.intent != templateIntent {
        findings.append("\(place) does not render as a template")
      }
      if document.properties?.preservesVector != true {
        findings.append("\(place) does not preserve its vector")
      }
      if document.images.count != 1 {
        findings.append("\(place) holds \(document.images.count) images, not one")
      }
      var named: Set<String> = []
      for entry in document.images {
        guard let name = entry.filename else {
          findings.append("\(place) has an image with no file name")
          continue
        }
        named.insert(name)
        guard name.hasSuffix(".svg") else {
          findings.append("\(place) names \(name), which is not an SVG")
          continue
        }
        guard let data = set.files[name] else {
          findings.append("\(place) names \(name), which is not in the image set")
          continue
        }
        artwork.append((set.name, data))
        let root = rootTag(of: data) ?? ""
        if !glyphCanvas.allSatisfy({ root.contains($0) }) {
          findings.append("\(place)/\(name) is not on the 18 x 18 canvas")
        }
      }
      for name in set.files.keys where !named.contains(name) {
        findings.append("\(place)/\(name) is named by no image")
      }
    }
    for (index, first) in artwork.enumerated() {
      for second in artwork[(index + 1)...] where second.data == first.data && second.set != first.set {
        findings.append("\(catalog): \(first.set) and \(second.set) hold the same artwork")
      }
    }
    return findings.sorted()
  }

  static func projectFindings(spec: String) -> [String] {
    let app = SparkleInfoPlistGateTests.targetBlock("Overtime", in: spec)
    var findings: [String] = []
    let listed = app.filter { $0.trimmingCharacters(in: .whitespaces) == catalogSourceLine }.count
    if listed != 1 {
      findings.append("\(projectSpec): the Overtime target lists \(catalog) \(listed) times as a source, not once")
    }
    if SparkleInfoPlistGateTests.setting(iconNameKey, in: app) != iconName {
      findings.append("\(projectSpec): the Overtime target does not set \(iconNameKey) to \(iconName)")
    }
    return findings
  }

  static func rootTag(of svg: Data) -> String? {
    let text = String(decoding: svg, as: UTF8.self)
    guard let start = text.range(of: "<svg"), let end = text[start.upperBound...].firstIndex(of: ">") else {
      return nil
    }
    return String(text[start.lowerBound...end])
  }

  static func visibleNames(in path: String) throws -> [String] {
    let url = NetworkSourceGateTests.repositoryRoot.appendingPathComponent(path)
    return try FileManager.default.contentsOfDirectory(atPath: url.path).filter { !$0.hasPrefix(".") }.sorted()
  }

  static func directoryFiles(_ path: String) throws -> [String: Data] {
    let url = NetworkSourceGateTests.repositoryRoot.appendingPathComponent(path)
    var files: [String: Data] = [:]
    for name in try visibleNames(in: path) {
      files[name] = try Data(contentsOf: url.appendingPathComponent(name))
    }
    return files
  }

  static func split(_ path: String) throws -> (contents: Data, files: [String: Data]) {
    var files = try directoryFiles(path)
    guard let contents = files.removeValue(forKey: documentName) else {
      throw GateFailure(description: "\(path)/\(documentName) is missing")
    }
    return (contents, files)
  }

  static func liveIconSet() throws -> (contents: Data, files: [String: Data]) {
    try split(iconSet)
  }

  static func liveImageSets() throws -> [ImageSet] {
    try visibleNames(in: catalog).filter { $0.hasSuffix(imageSetSuffix) }.map { folder in
      let parts = try split(catalog + "/" + folder)
      return ImageSet(name: String(folder.dropLast(imageSetSuffix.count)), contents: parts.contents, files: parts.files)
    }
  }

  static func pngHeader(width: Int, height: Int) -> Data {
    func bigEndian(_ value: Int) -> [UInt8] {
      [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
    return Data(pngSignature + [0, 0, 0, 13] + headerChunk + bigEndian(width) + bigEndian(height) + [8, 6, 0, 0, 0])
  }

  static func catalogInfo() -> [String: Any] {
    ["author": "xcode", "version": 1]
  }

  static func iconDocument(_ entries: [[String: String]]) throws -> Data {
    let document: [String: Any] = ["images": entries, "info": catalogInfo()]
    return try JSONSerialization.data(withJSONObject: document)
  }

  static func iconEntry(_ slot: Slot, idiom: String = macIdiom, filename: String? = nil) -> [String: String] {
    ["filename": filename ?? "icon_\(slot.pixels).png", "idiom": idiom, "scale": slot.scaleName, "size": slot.size]
  }

  static func plantedIconFiles() -> [String: Data] {
    var files: [String: Data] = [:]
    for slot in slots {
      files["icon_\(slot.pixels).png"] = pngHeader(width: slot.pixels, height: slot.pixels)
    }
    return files
  }

  enum IconDrift: CaseIterable, Sendable {
    case missingSlot
    case duplicatedSlot
    case wrongPixelSize
    case entryNamesAMissingFile
    case fileIsNotAPNG
    case fileNoEntryNames
    case otherIdiom

    var phrase: String {
      switch self {
      case .missingSlot: "512x512@2x is not filled"
      case .duplicatedSlot: "16x16@1x is filled 2 times"
      case .wrongPixelSize: "icon_32.png is 33 x 32 pixels"
      case .entryNamesAMissingFile: "names gone.png"
      case .fileIsNotAPNG: "icon_16.png is not a PNG"
      case .fileNoEntryNames: "extra.png is named by no entry"
      case .otherIdiom: "has the idiom universal"
      }
    }

    func apply(entries: inout [[String: String]], files: inout [String: Data]) {
      switch self {
      case .missingSlot:
        entries.removeLast()
      case .duplicatedSlot:
        entries.append(AssetCatalogGateTests.iconEntry(Slot(points: 16, scale: 1)))
      case .wrongPixelSize:
        files["icon_32.png"] = AssetCatalogGateTests.pngHeader(width: 33, height: 32)
      case .entryNamesAMissingFile:
        entries[0] = AssetCatalogGateTests.iconEntry(Slot(points: 16, scale: 1), filename: "gone.png")
      case .fileIsNotAPNG:
        files["icon_16.png"] = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8)
      case .fileNoEntryNames:
        files["extra.png"] = AssetCatalogGateTests.pngHeader(width: 16, height: 16)
      case .otherIdiom:
        entries[0] = AssetCatalogGateTests.iconEntry(Slot(points: 16, scale: 1), idiom: "universal")
      }
    }
  }

  static func glyphSource(canvas: Int = 18, mark: Int) -> Data {
    Data(
      ("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(canvas) \(canvas)\" width=\"\(canvas)\" "
        + "height=\"\(canvas)\"><rect x=\"\(mark)\" y=\"1\" width=\"2\" height=\"2\"/></svg>").utf8)
  }

  static func glyphDocument(files: [String], intent: String = templateIntent, vector: Bool = true) throws -> Data {
    let properties: [String: Any] = ["preserves-vector-representation": vector, "template-rendering-intent": intent]
    let document: [String: Any] = [
      "images": files.map { ["filename": $0, "idiom": "universal"] },
      "info": catalogInfo(),
      "properties": properties,
    ]
    return try JSONSerialization.data(withJSONObject: document)
  }

  static func plantedGlyphSet(_ name: String, mark: Int) throws -> ImageSet {
    ImageSet(
      name: name, contents: try glyphDocument(files: ["glyph.svg"]), files: ["glyph.svg": glyphSource(mark: mark)])
  }

  static func plantedGlyphSets() throws -> [ImageSet] {
    try glyphSetNames.enumerated().map { index, name in try plantedGlyphSet(name, mark: index) }
  }

  enum GlyphDrift: CaseIterable, Sendable {
    case expectedNameWithoutASet
    case setNoExpectedNameUses
    case originalRenderingIntent
    case vectorFlagOff
    case otherCanvas
    case twoImagesInOneSet
    case entryNamesAMissingFile
    case twoSetsWithTheSameArtwork

    var phrase: String {
      switch self {
      case .expectedNameWithoutASet: "StatusError.imageset is missing"
      case .setNoExpectedNameUses: "StatusExtra.imageset is no status glyph"
      case .originalRenderingIntent: "StatusIdle.imageset does not render as a template"
      case .vectorFlagOff: "StatusIdle.imageset does not preserve its vector"
      case .otherCanvas: "StatusIdle.imageset/glyph.svg is not on the 18 x 18 canvas"
      case .twoImagesInOneSet: "StatusIdle.imageset holds 2 images"
      case .entryNamesAMissingFile: "StatusIdle.imageset names gone.svg"
      case .twoSetsWithTheSameArtwork: "hold the same artwork"
      }
    }

    func apply(to sets: inout [ImageSet]) throws {
      let type = AssetCatalogGateTests.self
      let first = sets[0]
      switch self {
      case .expectedNameWithoutASet:
        sets.removeLast()
      case .setNoExpectedNameUses:
        sets.append(try type.plantedGlyphSet("StatusExtra", mark: 12))
      case .originalRenderingIntent:
        sets[0] = ImageSet(
          name: first.name, contents: try type.glyphDocument(files: ["glyph.svg"], intent: "original"),
          files: first.files)
      case .vectorFlagOff:
        sets[0] = ImageSet(
          name: first.name, contents: try type.glyphDocument(files: ["glyph.svg"], vector: false), files: first.files)
      case .otherCanvas:
        sets[0] = ImageSet(
          name: first.name, contents: first.contents, files: ["glyph.svg": type.glyphSource(canvas: 16, mark: 0)])
      case .twoImagesInOneSet:
        sets[0] = ImageSet(
          name: first.name, contents: try type.glyphDocument(files: ["glyph.svg", "second.svg"]),
          files: ["glyph.svg": type.glyphSource(mark: 0), "second.svg": type.glyphSource(mark: 13)])
      case .entryNamesAMissingFile:
        sets[0] = ImageSet(
          name: first.name, contents: try type.glyphDocument(files: ["gone.svg"]), files: first.files)
      case .twoSetsWithTheSameArtwork:
        sets[1] = ImageSet(name: sets[1].name, contents: sets[1].contents, files: first.files)
      }
    }
  }

  @Test func thePNGHeaderReaderReadsTheSignatureAndThePixelSize() throws {
    let header = Self.pngHeader(width: 1024, height: 512)
    let size = try #require(Self.pngSize(header))
    #expect(size.width == 1024)
    #expect(size.height == 512)
    var wrongSignature = header
    wrongSignature[0] = 0
    #expect(Self.pngSize(wrongSignature) == nil)
    #expect(Self.pngSize(header.prefix(23)) == nil)
    #expect(Self.pngSize(Data()) == nil)
    var otherChunk = header
    otherChunk[12] = 0x74
    #expect(Self.pngSize(otherChunk) == nil)
    let slice = (Data([0, 0, 0]) + header).dropFirst(3)
    let sliced = try #require(Self.pngSize(slice))
    #expect(sliced.width == 1024)
    #expect(sliced.height == 512)
  }

  @Test func theLiveAppIconSetFillsTheTenSlotsWithMatchingPNGs() throws {
    let live = try Self.liveIconSet()
    #expect(Self.iconFindings(contents: live.contents, files: live.files) == [])
    let document = try JSONDecoder().decode(IconDocument.self, from: live.contents)
    #expect(document.images.count == 10)
    #expect(document.images.allSatisfy { $0.idiom == Self.macIdiom })
    let filled = Set(document.images.map { "\($0.size ?? "")@\($0.scale ?? "")" })
    #expect(filled == Set(Self.slots.map(\.label)))
    #expect(live.files.count == 7)
    #expect(Set(document.images.compactMap(\.filename)) == Set(live.files.keys))
    for (name, data) in live.files {
      #expect(Self.pngSize(data) != nil, "\(name) is not a PNG")
    }
  }

  @Test func theUndriftedPlantedIconSetHasNoFindings() throws {
    let contents = try Self.iconDocument(Self.slots.map { Self.iconEntry($0) })
    #expect(Self.iconFindings(contents: contents, files: Self.plantedIconFiles()) == [])
    #expect(Self.iconFindings(contents: Data("not a document".utf8), files: Self.plantedIconFiles()).count == 1)
  }

  @Test(arguments: IconDrift.allCases)
  func aDriftedAppIconSetIsReported(drift: IconDrift) throws {
    var entries = Self.slots.map { Self.iconEntry($0) }
    var files = Self.plantedIconFiles()
    drift.apply(entries: &entries, files: &files)
    let findings = Self.iconFindings(contents: try Self.iconDocument(entries), files: files)
    #expect(findings.contains { $0.contains(drift.phrase) }, "\(findings)")
    #expect(findings.allSatisfy { $0.hasPrefix(Self.iconSet) }, "\(findings)")
    #expect(findings == findings.sorted())
  }

  @Test func everyGlyphImageSetIsOneTemplateVectorOnTheSharedCanvas() throws {
    let sets = try Self.liveImageSets()
    #expect(sets.count == 8)
    #expect(sets.map(\.name).sorted() == Self.glyphSetNames.sorted())
    #expect(Self.glyphFindings(sets, expected: Self.glyphSetNames) == [])
    let artwork = sets.flatMap { set in set.files.filter { $0.key.hasSuffix(".svg") }.map(\.value) }
    #expect(artwork.count == 8)
    #expect(Set(artwork).count == 8)
    for data in artwork {
      let root = try #require(Self.rootTag(of: data))
      #expect(Self.glyphCanvas.allSatisfy { root.contains($0) }, "\(root)")
    }
    let expected = [Self.documentName, "AppIcon.appiconset"] + Self.glyphSetNames.map { $0 + Self.imageSetSuffix }
    #expect(try Self.visibleNames(in: Self.catalog) == expected.sorted())
  }

  @Test func everyStatusGlyphHasItsImageSetAndEveryImageSetIsUsed() throws {
    let names = StatusGlyph.allCases.map(\.assetName)
    #expect(names.count == 8)
    #expect(Self.glyphSetNames == names)
    let sets = try Self.liveImageSets()
    #expect(Self.glyphFindings(sets, expected: names) == [])
    #expect(Set(sets.map(\.name)) == Set(names))

    let unused = Self.glyphFindings(sets, expected: Array(names.dropLast()))
    #expect(unused.count == 1, "\(unused)")
    #expect(unused.first?.hasSuffix("\(names[7])\(Self.imageSetSuffix) is no status glyph") == true, "\(unused)")
    let missing = Self.glyphFindings(Array(sets.dropLast()), expected: names)
    #expect(missing.count == 1, "\(missing)")
    #expect(missing.first?.hasSuffix("\(Self.imageSetSuffix) is missing") == true, "\(missing)")
  }

  @Test func theUndriftedPlantedGlyphSetsHaveNoFindings() throws {
    #expect(Self.glyphFindings(try Self.plantedGlyphSets(), expected: Self.glyphSetNames) == [])
    var unreadable = try Self.plantedGlyphSets()
    unreadable[0] = ImageSet(name: unreadable[0].name, contents: Data("{}".utf8), files: unreadable[0].files)
    #expect(Self.glyphFindings(unreadable, expected: Self.glyphSetNames).count == 1)
  }

  @Test(arguments: GlyphDrift.allCases)
  func aDriftedGlyphImageSetIsReported(drift: GlyphDrift) throws {
    var sets = try Self.plantedGlyphSets()
    try drift.apply(to: &sets)
    let findings = Self.glyphFindings(sets, expected: Self.glyphSetNames)
    #expect(findings.contains { $0.contains(drift.phrase) }, "\(findings)")
    #expect(findings.allSatisfy { $0.hasPrefix(Self.catalog) }, "\(findings)")
    #expect(findings == findings.sorted())
  }

  @Test func theProjectListsTheCatalogAndNamesTheAppIcon() throws {
    let spec = try SparkleInfoPlistGateTests.repositoryFile(Self.projectSpec)
    let app = SparkleInfoPlistGateTests.targetBlock("Overtime", in: spec)
    #expect(app.count > 20)
    #expect(app.filter { $0.trimmingCharacters(in: .whitespaces) == Self.catalogSourceLine }.count == 1)
    #expect(SparkleInfoPlistGateTests.setting(Self.iconNameKey, in: app) == Self.iconName)
    #expect(Self.projectFindings(spec: spec) == [])
  }

  @Test(arguments: [
    ("      - path: Resources/Assets.xcassets\n", ""),
    ("      - path: Resources/Assets.xcassets\n", "      - path: Resources/Other.xcassets\n"),
    (
      "      - path: Resources/Assets.xcassets\n",
      "      - path: Resources/Assets.xcassets\n      - path: Resources/Assets.xcassets\n"
    ),
    ("ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon\n", "ASSETCATALOG_COMPILER_APPICON_NAME: Other\n"),
    ("        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon\n", ""),
  ])
  func aProjectWithoutTheCatalogOrTheIconNameIsReported(original: String, planted: String) throws {
    let spec = try SparkleInfoPlistGateTests.repositoryFile(Self.projectSpec)
    #expect(spec.components(separatedBy: original).count == 2)
    let changed = spec.replacingOccurrences(of: original, with: planted)
    let findings = Self.projectFindings(spec: changed)
    #expect(findings.count == 1, "\(findings)")
    #expect(findings.first?.hasPrefix(Self.projectSpec) == true, "\(findings)")
  }

  @Test func aCatalogListedByAnotherTargetOnlyIsReported() throws {
    let spec = try SparkleInfoPlistGateTests.repositoryFile(Self.projectSpec)
    let line = "      - path: Resources/Assets.xcassets\n"
    let anchor = "      - path: Packages/OvertimeRuntime/Sources/overtime-sentinel\n"
    #expect(spec.components(separatedBy: anchor).count == 2)
    let moved = spec.replacingOccurrences(of: line, with: "").replacingOccurrences(of: anchor, with: anchor + line)
    #expect(Self.projectFindings(spec: moved).count == 1)
  }

  @Test func theIconMasterSitsBesideTheCatalog() throws {
    let url = NetworkSourceGateTests.repositoryRoot.appendingPathComponent(Self.master)
    let root = try #require(Self.rootTag(of: try Data(contentsOf: url)))
    #expect(root.contains(Self.masterCanvas), "\(root)")
    #expect(!Self.master.hasPrefix(Self.catalog + "/"))
    #expect(try !Self.visibleNames(in: Self.catalog).contains("AppIcon.svg"))
  }

  @Test func aDenylistedWordInAGlyphSourceIsReportedByTheEnglishGate() {
    let path = Self.catalog + "/StatusIdle.imageset/rays-idle.svg"
    #expect(!TrackedFileCorpus.isSkipped(path))
    let word = "pa" + "ra"
    let clean = String(decoding: Self.glyphSource(mark: 0), as: UTF8.self)
    #expect(EnglishTextGateTests.findings([SourceFile(path: path, text: clean)]) == [])
    let planted = clean.replacingOccurrences(of: "<rect", with: "<title>" + word + "</title><rect")
    PublicFaceGateTests.expectOne(EnglishTextGateTests.findings([SourceFile(path: path, text: planted)]), naming: path)
  }
}
