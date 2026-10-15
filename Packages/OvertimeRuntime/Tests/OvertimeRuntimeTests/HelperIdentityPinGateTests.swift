import Foundation
import OvertimeHelperCore
import Testing

struct HelperIdentityPinGateTests {
  typealias SourceFile = NetworkSourceGateTests.SourceFile

  struct Expected: Sendable {
    let appIdentifier: String
    let helperIdentifier: String
    let appRequirement: String
    let helperRequirement: String
    let certificateRoot: String

    static let live = Expected(
      appIdentifier: HelperIdentity.release.appIdentifier,
      helperIdentifier: HelperIdentity.release.helperIdentifier,
      appRequirement: HelperIdentity.release.appRequirement,
      helperRequirement: HelperIdentity.release.helperRequirement,
      certificateRoot: HelperIdentity.certificateRoot)

    func drifted(root: String) -> Expected {
      Expected(
        appIdentifier: appIdentifier,
        helperIdentifier: helperIdentifier,
        appRequirement: appRequirement.replacingOccurrences(of: certificateRoot, with: root),
        helperRequirement: helperRequirement.replacingOccurrences(of: certificateRoot, with: root),
        certificateRoot: root)
    }
  }

  enum PinDefect: String, CaseIterable, Sendable {
    case repeated
    case missing
  }

  static let appBundleKey = "APP_BUNDLE_ID"
  static let helperIdentifierKey = "HELPER_IDENTIFIER"
  static let appRequirementKey = "APP_DESIGNATED_REQUIREMENT"
  static let helperRequirementKey = "HELPER_DESIGNATED_REQUIREMENT"
  static let certificateKey = "T1_IDENTITY_SHA1"
  static let keys = [appBundleKey, helperIdentifierKey, appRequirementKey, helperRequirementKey, certificateKey]
  static let driftedRoot = String(repeating: "0", count: 40)

  static func pins() throws -> SourceFile {
    try ReleaseSourceGateTests.read(ReleaseSourceGateTests.pinsFile)
  }

  static func pinnedValues(_ pins: SourceFile, key: String) -> [String] {
    ReleaseSourceGateTests.plainLines(pins.text).compactMap { line in
      let trimmed = line.text.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix(key + "=") else { return nil }
      let value = String(trimmed.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
      guard value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") else { return value }
      return String(value.dropFirst().dropLast())
    }
  }

  static func findings(pins: SourceFile, expected: Expected) -> [String] {
    var findings: [String] = []
    let pairs = [
      (appBundleKey, expected.appIdentifier),
      (helperIdentifierKey, expected.helperIdentifier),
      (appRequirementKey, expected.appRequirement),
      (helperRequirementKey, expected.helperRequirement),
    ]
    for (key, value) in pairs {
      let pinned = pinnedValues(pins, key: key)
      if pinned.count != 1 {
        findings.append("\(pins.path) has \(pinned.count) \(key) lines")
      } else if pinned[0] != value {
        findings.append("\(pins.path) \(key) differs from HelperIdentity")
      }
    }
    let certificate = pinnedValues(pins, key: certificateKey)
    if certificate.count != 1 {
      findings.append("\(pins.path) has \(certificate.count) \(certificateKey) lines")
    } else if !isCertificateHash(certificate[0]) || certificate[0].lowercased() != expected.certificateRoot {
      findings.append("\(pins.path) \(certificateKey) differs from HelperIdentity.certificateRoot")
    }
    return findings
  }

  static func isCertificateHash(_ value: String) -> Bool {
    value.count == 40 && value.allSatisfy(\.isHexDigit)
  }

  static func liveLine(_ pins: SourceFile, key: String) throws -> String {
    try #require(
      ReleaseSourceGateTests.plainLines(pins.text).first {
        $0.text.trimmingCharacters(in: .whitespaces).hasPrefix(key + "=")
      }?.text)
  }

  static func driftedLine(_ line: String, key: String) -> String {
    switch key {
    case appBundleKey, helperIdentifierKey:
      line + "x"
    case certificateKey:
      line.replacingOccurrences(of: HelperIdentity.certificateRoot.uppercased(), with: driftedRoot.uppercased())
    default:
      line.replacingOccurrences(of: HelperIdentity.certificateRoot, with: driftedRoot)
    }
  }

  @Test func theReleasePinsMatchTheHelperIdentityTheXPCCheckUses() throws {
    let pins = try Self.pins()
    #expect(Self.findings(pins: pins, expected: .live) == [])
    for key in Self.keys {
      #expect(Self.pinnedValues(pins, key: key).count == 1, "\(key)")
    }
    #expect(Expected.live.appRequirement.contains(HelperIdentity.certificateRoot))
    #expect(Expected.live.helperRequirement.contains(HelperIdentity.certificateRoot))
    #expect(Self.pinnedValues(pins, key: Self.appRequirementKey) == [HelperIdentity.release.appRequirement])
    #expect(Self.pinnedValues(pins, key: Self.helperRequirementKey) == [HelperIdentity.release.helperRequirement])
  }

  @Test(arguments: HelperIdentityPinGateTests.keys)
  func theGateCatchesAPinThatDrifted(_ key: String) throws {
    let pins = try Self.pins()
    let live = try Self.liveLine(pins, key: key)
    let drifted = Self.driftedLine(live, key: key)
    #expect(drifted != live)
    let files = try ReleaseSourceGateTests.replacing([pins], in: pins.path, live, with: drifted)
    let findings = Self.findings(pins: try #require(files.first), expected: .live)
    ReleaseSourceGateTests.expectOne(findings, naming: pins.path)
    #expect(findings.first?.contains(" \(key) ") == true, "\(findings)")
  }

  @Test(arguments: PinDefect.allCases)
  func theGateCatchesARepeatedOrMissingPin(_ defect: PinDefect) throws {
    let pins = try Self.pins()
    let key: String
    let files: [SourceFile]
    switch defect {
    case .repeated:
      key = Self.appRequirementKey
      files = try ReleaseSourceGateTests.planted([pins], in: pins.path, Self.liveLine(pins, key: key))
    case .missing:
      key = Self.certificateKey
      let live = try Self.liveLine(pins, key: key)
      files = try ReleaseSourceGateTests.replacing([pins], in: pins.path, live, with: "# " + live)
    }
    let findings = Self.findings(pins: try #require(files.first), expected: .live)
    ReleaseSourceGateTests.expectOne(findings, naming: pins.path)
    #expect(findings.first?.contains(" \(key) ") == true, "\(findings)")
  }

  @Test func theGateCatchesACertificateRootThatChangedOnlyInSwift() throws {
    let pins = try Self.pins()
    let findings = Self.findings(pins: pins, expected: Expected.live.drifted(root: Self.driftedRoot))
    #expect(
      findings == [
        "\(pins.path) \(Self.appRequirementKey) differs from HelperIdentity",
        "\(pins.path) \(Self.helperRequirementKey) differs from HelperIdentity",
        "\(pins.path) \(Self.certificateKey) differs from HelperIdentity.certificateRoot",
      ])
  }
}
