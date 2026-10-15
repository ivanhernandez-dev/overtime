import CoreFoundation
import Foundation
import Testing

struct SparkleInfoPlistGateTests {
  enum PlistValue: Equatable, CustomStringConvertible {
    case string(String)
    case bool(Bool)
    case integer(Int)

    var description: String {
      switch self {
      case .string(let text): text
      case .bool(let flag): flag ? "true" : "false"
      case .integer(let number): String(number)
      }
    }
  }

  static let projectSpec = "project.yml"
  static let infoPlist = "Resources/Info.plist"
  static let notice = "NOTICE"
  static let license = "LICENSE"
  static let feedURL = "https://github.com/ivanhernandez-dev/overtime/releases/latest/download/appcast.xml"
  static let publicKey = "UD7lL+zTuAv5psJB4a94BH94A95GEAlL3iGS26YFV3Q="
  static let sparkleMarker = "The Sparkle license, copied verbatim from the Sparkle 2.10.0 distribution, follows."
  static let sparkleLicenseStart = "Copyright (c) 2006-2013 Andy Matuschak."

  static let expectedKeys: [(key: String, value: PlistValue)] = [
    ("SUFeedURL", .string(feedURL)),
    ("SUPublicEDKey", .string("$(SPARKLE_PUBLIC_ED_KEY)")),
    ("SUEnableAutomaticChecks", .bool(true)),
    ("SUScheduledCheckInterval", .integer(86_400)),
    ("SUAutomaticallyUpdate", .bool(false)),
    ("SUEnableSystemProfiling", .bool(false)),
    ("SUVerifyUpdateBeforeExtraction", .bool(true)),
    ("SURequireSignedFeed", .bool(true)),
    ("LSMinimumSystemVersion", .string("14.0")),
    ("LSUIElement", .bool(true)),
    ("CFBundleDevelopmentRegion", .string("en")),
  ]

  static func repositoryFile(_ path: String) throws -> String {
    try String(
      contentsOf: NetworkSourceGateTests.repositoryRoot.appendingPathComponent(path), encoding: .utf8)
  }

  static func dictionary(_ plist: String) throws -> [String: Any] {
    let parsed = try PropertyListSerialization.propertyList(from: Data(plist.utf8), options: [], format: nil)
    return try #require(parsed as? [String: Any])
  }

  static func value(_ object: Any?) -> PlistValue? {
    if let text = object as? String { return .string(text) }
    guard let number = object as? NSNumber else { return nil }
    if CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
    return .integer(number.intValue)
  }

  static func keyFindings(_ dictionary: [String: Any]) -> [String] {
    expectedKeys.compactMap { entry in
      value(dictionary[entry.key]) == entry.value ? nil : entry.key
    }
  }

  static func signedFeedFindings(_ dictionary: [String: Any]) -> [String] {
    let signedFeed = value(dictionary["SURequireSignedFeed"]) == .bool(true)
    let verifiedFirst = value(dictionary["SUVerifyUpdateBeforeExtraction"]) == .bool(true)
    return signedFeed && !verifiedFirst ? ["SURequireSignedFeed without SUVerifyUpdateBeforeExtraction"] : []
  }

  static func topLevelBlock(_ name: String, in spec: String) -> [String] {
    var block: [String] = []
    var inside = false
    for line in spec.components(separatedBy: "\n") {
      let topLevel = !line.isEmpty && !line.hasPrefix(" ")
      if topLevel { inside = line == name + ":" }
      if inside { block.append(line) }
    }
    return block
  }

  static func targetBlock(_ name: String, in spec: String) -> [String] {
    var block: [String] = []
    var inside = false
    for line in topLevelBlock("targets", in: spec) {
      let targetHeader = line.hasPrefix("  ") && !line.hasPrefix("   ") && line.hasSuffix(":")
      if targetHeader { inside = line == "  " + name + ":" }
      if inside { block.append(line) }
    }
    return block
  }

  static func setting(_ key: String, in lines: [String]) -> String? {
    lines.lazy.map { $0.trimmingCharacters(in: .whitespaces) }
      .first { $0.hasPrefix(key + ": ") }
      .map { String($0.dropFirst(key.count + 2)) }
  }

  static func derivedBuildNumber(marketing: String) -> Int? {
    let parts = marketing.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
    guard parts.count == 3, let major = parts[0], let minor = parts[1], let patch = parts[2] else { return nil }
    guard (0..<100).contains(minor), (0..<100).contains(patch), major >= 0 else { return nil }
    return major * 10_000 + minor * 100 + patch
  }

  static func liveLine(_ key: String, in spec: String) throws -> String {
    let lines = spec.components(separatedBy: "\n").filter {
      $0.trimmingCharacters(in: .whitespaces).hasPrefix(key + ": ")
    }
    #expect(lines.count == 1)
    return try #require(lines.first)
  }

  static func replacingLine(_ line: String, value: String, in spec: String) -> String {
    let key = line.prefix { $0 != ":" }
    #expect(spec.components(separatedBy: line + "\n").count == 2)
    return spec.replacingOccurrences(of: line + "\n", with: key + ": " + value + "\n")
  }

  static func listsResource(_ path: String, in lines: [String]) -> Bool {
    let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }
    return trimmed.indices.dropLast().contains { index in
      trimmed[index] == "- path: " + path && trimmed[index + 1] == "buildPhase: resources"
    }
  }

  static func projectFindings(spec: String) -> [String] {
    var findings: [String] = []
    let packages = topLevelBlock("packages", in: spec).joined(separator: "\n")
    let sparklePackage =
      "  Sparkle:\n    url: https://github.com/sparkle-project/Sparkle\n    exactVersion: 2.10.0"
    if !packages.contains(sparklePackage) { findings.append("Sparkle package exactVersion 2.10.0") }
    let app = targetBlock("Overtime", in: spec)
    let sparkleLinks = spec.components(separatedBy: "\n").filter {
      $0.trimmingCharacters(in: .whitespaces) == "- package: Sparkle"
    }
    let appLinks = app.filter { $0.trimmingCharacters(in: .whitespaces) == "- package: Sparkle" }
    if sparkleLinks.count != 1 || appLinks.count != 1 { findings.append("Sparkle linked by the app target only") }
    if setting("SPARKLE_PUBLIC_ED_KEY", in: app) != publicKey { findings.append("SPARKLE_PUBLIC_ED_KEY") }
    if setting("CFBundleDevelopmentRegion", in: app) != "en" { findings.append("CFBundleDevelopmentRegion") }
    let base = topLevelBlock("settings", in: spec)
    if setting("ARCHS", in: base) != "arm64" { findings.append("ARCHS") }
    if setting("MACOSX_DEPLOYMENT_TARGET", in: base) != "\"14.0\"" { findings.append("MACOSX_DEPLOYMENT_TARGET") }
    let marketing = setting("MARKETING_VERSION", in: app).flatMap { derivedBuildNumber(marketing: $0) }
    let build = setting("CURRENT_PROJECT_VERSION", in: app).flatMap { Int($0) }
    if marketing == nil || marketing != build { findings.append("CURRENT_PROJECT_VERSION") }
    for resource in [notice, license] where !listsResource(resource, in: app) {
      findings.append("\(resource) resource")
    }
    return findings
  }

  static func noticeFindings(notice: String, license: String) -> [String] {
    var findings: [String] = []
    if !LicenseTerms.holds(license) { findings.append("LICENSE terms") }
    if !notice.hasPrefix("Overtime\nWorks with Claude Code. Not affiliated with Anthropic.\n") {
      findings.append("NOTICE branding")
    }
    if !notice.contains("AuxiliaryWindowController") || !notice.contains("Nghia Luong") {
      findings.append("NOTICE Lidless credit")
    }
    let marker = "\n" + sparkleMarker + "\n\n"
    guard let range = notice.range(of: marker) else {
      findings.append("NOTICE Sparkle license")
      return findings
    }
    let sparkleLicense = notice[range.upperBound...]
    let complete =
      sparkleLicense.hasPrefix(sparkleLicenseStart) && sparkleLicense.contains("Permission is hereby granted")
      && sparkleLicense.contains("EXTERNAL LICENSES")
    if !complete { findings.append("NOTICE Sparkle license") }
    return findings
  }

  @Test func theInfoPlistCarriesEverySparkleKeyWithItsSignedFeedValue() throws {
    let plist = try Self.dictionary(Self.repositoryFile(Self.infoPlist))
    #expect(Self.keyFindings(plist) == [])
    #expect(Self.signedFeedFindings(plist) == [])
  }

  @Test(arguments: SparkleInfoPlistGateTests.expectedKeys.map(\.key))
  func theKeyCheckCatchesAPlantedWrongOrMissingValue(key: String) throws {
    var plist = try Self.dictionary(Self.repositoryFile(Self.infoPlist))
    plist[key] = nil
    #expect(Self.keyFindings(plist) == [key])
    plist[key] = key == "SUScheduledCheckInterval" ? 3600 : "wrong"
    #expect(Self.keyFindings(plist) == [key])
  }

  @Test func theBooleanKeysMustBeRealBooleansAndNotNumbers() throws {
    var plist = try Self.dictionary(Self.repositoryFile(Self.infoPlist))
    plist["SURequireSignedFeed"] = NSNumber(value: 1)
    #expect(Self.keyFindings(plist) == ["SURequireSignedFeed"])
  }

  @Test func aSignedFeedWithoutVerificationBeforeExtractionIsReported() throws {
    var plist = try Self.dictionary(Self.repositoryFile(Self.infoPlist))
    plist["SUVerifyUpdateBeforeExtraction"] = false
    #expect(Self.signedFeedFindings(plist).count == 1)
    plist["SUVerifyUpdateBeforeExtraction"] = nil
    #expect(Self.signedFeedFindings(plist).count == 1)
    plist["SURequireSignedFeed"] = false
    #expect(Self.signedFeedFindings(plist) == [])
  }

  @Test func theProjectLinksSparkleExactlyAndKeepsTheFloorKeyBuildNumberAndNotices() throws {
    let spec = try Self.repositoryFile(Self.projectSpec)
    let app = Self.targetBlock("Overtime", in: spec)
    #expect(app.count > 20)
    let marketing = try #require(Self.setting("MARKETING_VERSION", in: app))
    let build = try #require(Self.derivedBuildNumber(marketing: marketing))
    #expect(Self.setting("CURRENT_PROJECT_VERSION", in: app) == String(build))
    #expect(Self.projectFindings(spec: spec) == [])
  }

  @Test func theBuildNumberCheckCatchesADriftFromTheLiveVersion() throws {
    let spec = try Self.repositoryFile(Self.projectSpec)
    let app = Self.targetBlock("Overtime", in: spec)
    let marketing = try #require(Self.setting("MARKETING_VERSION", in: app))
    let build = try #require(Self.setting("CURRENT_PROJECT_VERSION", in: app).flatMap { Int($0) })
    let buildLine = try Self.liveLine("CURRENT_PROJECT_VERSION", in: spec)
    let marketingLine = try Self.liveLine("MARKETING_VERSION", in: spec)
    let drifted = Self.replacingLine(buildLine, value: String(build + 1), in: spec)
    #expect(Self.projectFindings(spec: drifted) == ["CURRENT_PROJECT_VERSION"])
    let other = marketing == "99.99.99" ? "0.0.1" : "99.99.99"
    let remarketed = Self.replacingLine(marketingLine, value: other, in: spec)
    #expect(Self.projectFindings(spec: remarketed) == ["CURRENT_PROJECT_VERSION"])
  }

  @Test(arguments: ["0.1.1", "0.2.0", "1.0.0", "12.99.99"])
  func theProjectCheckHoldsAfterAReleaseBump(version: String) throws {
    let spec = try Self.repositoryFile(Self.projectSpec)
    let build = try #require(Self.derivedBuildNumber(marketing: version))
    let marketingLine = try Self.liveLine("MARKETING_VERSION", in: spec)
    let buildLine = try Self.liveLine("CURRENT_PROJECT_VERSION", in: spec)
    let remarketed = Self.replacingLine(marketingLine, value: version, in: spec)
    let bumped = Self.replacingLine(buildLine, value: String(build), in: remarketed)
    #expect(Self.projectFindings(spec: bumped) == [])
    let app = Self.targetBlock("Overtime", in: bumped)
    #expect(Self.setting("MARKETING_VERSION", in: app) == version)
    #expect(Self.setting("CURRENT_PROJECT_VERSION", in: app) == String(build))
  }

  @Test(arguments: [
    ("exactVersion: 2.10.0", "from: 2.6.0", "Sparkle package exactVersion 2.10.0"),
    ("github.com/sparkle-project/Sparkle\n", "github.com/someone/Sparkle\n", "Sparkle package exactVersion 2.10.0"),
    ("SPARKLE_PUBLIC_ED_KEY: UD7lL+", "SPARKLE_PUBLIC_ED_KEY: AAAA+", "SPARKLE_PUBLIC_ED_KEY"),
    ("    ARCHS: arm64\n", "    ARCHS: $(ARCHS_STANDARD)\n", "ARCHS"),
    ("MACOSX_DEPLOYMENT_TARGET: \"14.0\"", "MACOSX_DEPLOYMENT_TARGET: \"13.0\"", "MACOSX_DEPLOYMENT_TARGET"),
    ("- path: NOTICE\n        buildPhase: resources", "- path: NOTICE", "NOTICE resource"),
    ("LICENSE\n        buildPhase: resources", "LICENSE\n        buildPhase: sources", "LICENSE resource"),
    ("CFBundleDevelopmentRegion: en", "CFBundleDevelopmentRegion: es", "CFBundleDevelopmentRegion"),
  ])
  func theProjectCheckCatchesAPlantedChange(original: String, planted: String, finding: String) throws {
    let spec = try Self.repositoryFile(Self.projectSpec)
    #expect(spec.components(separatedBy: original).count == 2)
    let changed = spec.replacingOccurrences(of: original, with: planted)
    #expect(Self.projectFindings(spec: changed) == [finding])
  }

  @Test func sparkleLinkedByAnotherTargetIsReported() throws {
    let spec = try Self.repositoryFile(Self.projectSpec)
    let anchor = "    sources: [Tests/OvertimeTests]\n    dependencies:\n"
    #expect(spec.contains(anchor))
    let leaky = spec.replacingOccurrences(of: anchor, with: anchor + "      - package: Sparkle\n")
    #expect(Self.projectFindings(spec: leaky) == ["Sparkle linked by the app target only"])
    let unlinked = spec.replacingOccurrences(of: "      - package: Sparkle\n", with: "")
    #expect(Self.projectFindings(spec: unlinked) == ["Sparkle linked by the app target only"])
  }

  @Test(arguments: [
    ("0.1.0", 100),
    ("0.1.1", 101),
    ("1.0.0", 10_000),
    ("1.2.3", 10_203),
    ("12.99.99", 129_999),
  ])
  func theBuildNumberIsDerivedFromTheMarketingVersion(marketing: String, build: Int) {
    #expect(Self.derivedBuildNumber(marketing: marketing) == build)
  }

  @Test(arguments: ["0.1", "0.1.0.1", "0.100.0", "0.1.100", "a.b.c", "", "0.1.0-beta"])
  func aMarketingVersionOutsideTheSchemeHasNoBuildNumber(marketing: String) {
    #expect(Self.derivedBuildNumber(marketing: marketing) == nil)
  }

  @Test func theLicenseIsMITWithTheCommonsClauseAndTheNoticeCreditsLidlessAndCarriesSparklesLicense() throws {
    let notice = try Self.repositoryFile(Self.notice)
    let license = try Self.repositoryFile(Self.license)
    #expect(license.contains("Copyright (c) 2026 Iván Hernández"))
    #expect(Self.noticeFindings(notice: notice, license: license) == [])
  }

  @Test(arguments: [
    ("NOTICE", "AuxiliaryWindowController", "AuxWindow", "NOTICE Lidless credit"),
    ("NOTICE", "Copyright (c) 2026 Nghia Luong", "Copyright (c) 2026 Someone", "NOTICE Lidless credit"),
    ("NOTICE", "Works with Claude Code. Not affiliated with Anthropic.", "Works with Claude Code.", "NOTICE branding"),
    ("NOTICE", "copied verbatim from the Sparkle 2.10.0", "copied from Sparkle", "NOTICE Sparkle license"),
    ("NOTICE", "EXTERNAL LICENSES", "OTHER LICENSES", "NOTICE Sparkle license"),
    ("NOTICE", "Copyright (c) 2006-2013 Andy Matuschak.", "Copyright Sparkle.", "NOTICE Sparkle license"),
    ("LICENSE", "\nMIT License\n", "\nApache License\n", "LICENSE terms"),
    ("LICENSE", LicenseTerms.clauseHeader, "", "LICENSE terms"),
    ("LICENSE", "the right to Sell the Software", "the right to use the Software", "LICENSE terms"),
  ])
  func theNoticeCheckCatchesAPlantedChange(file: String, original: String, planted: String, finding: String) throws {
    var notice = try Self.repositoryFile(Self.notice)
    var license = try Self.repositoryFile(Self.license)
    if file == Self.notice {
      #expect(notice.contains(original))
      notice = notice.replacingOccurrences(of: original, with: planted)
    } else {
      #expect(license.contains(original))
      license = license.replacingOccurrences(of: original, with: planted)
    }
    #expect(Self.noticeFindings(notice: notice, license: license) == [finding])
  }
}

enum LicenseTerms {
  static let clauseHeader = "\"Commons Clause\" License Condition v1.0\n"
  static let required = [
    "the right to Sell the Software", "Software: Overtime\n", "License: MIT\n", "Licensor: Iván Hernández\n",
    "\n---\n\nMIT License\n", "Copyright (c) 2026 Iván Hernández",
  ]

  static func holds(_ license: String) -> Bool {
    license.hasPrefix(clauseHeader) && required.allSatisfy { license.contains($0) }
  }
}
