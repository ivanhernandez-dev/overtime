import Foundation
import Testing

struct TransportAndKeychainGateTests {
  typealias SourceFile = NetworkSourceGateTests.SourceFile

  static let projectSpec = "project.yml"
  static let infoPlist = "Resources/Info.plist"
  static let transportKeys = ["NSAppTransportSecurity", "NSAllowsArbitraryLoads", "NSExceptionDomains"]

  static func repositoryFile(_ path: String) throws -> String {
    try String(
      contentsOf: NetworkSourceGateTests.repositoryRoot.appendingPathComponent(path), encoding: .utf8)
  }

  static func transportFindings(spec: String, plist: String) throws -> [String] {
    var findings: [String] = []
    for key in transportKeys {
      if spec.contains(key) { findings.append("\(projectSpec) \(key)") }
      if plist.contains(key) { findings.append("\(infoPlist) \(key)") }
    }
    let data = Data(plist.utf8)
    let parsed = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    let dictionary = try #require(parsed as? [String: Any])
    if dictionary["NSAppTransportSecurity"] != nil {
      findings.append("\(infoPlist) parsed NSAppTransportSecurity")
    }
    return findings
  }

  @Test func neitherTheProjectSpecNorTheInfoPlistRelaxesAppTransportSecurity() throws {
    let spec = try Self.repositoryFile(Self.projectSpec)
    let plist = try Self.repositoryFile(Self.infoPlist)
    #expect(spec.contains("Resources/Info.plist"))
    #expect(plist.contains("NSLocationUsageDescription"))
    #expect(try Self.transportFindings(spec: spec, plist: plist).isEmpty)
  }

  @Test func theTransportCheckCatchesAPlantedExceptionInEitherFile() throws {
    let spec = try Self.repositoryFile(Self.projectSpec)
    let plist = try Self.repositoryFile(Self.infoPlist)
    let plantedEntry =
      "\t<key>NSAppTransportSecurity</key>\n\t<dict>\n\t\t<key>NSAllowsArbitraryLoads</key>\n\t\t<true/>\n\t</dict>\n"
    let anchor = try #require(plist.range(of: "\t<key>LSUIElement</key>"))
    let leakyPlist = plist.replacingCharacters(in: anchor, with: plantedEntry + "\t<key>LSUIElement</key>")
    let plistFindings = try Self.transportFindings(spec: spec, plist: leakyPlist)
    #expect(plistFindings.contains("\(Self.infoPlist) parsed NSAppTransportSecurity"))
    #expect(plistFindings.contains("\(Self.infoPlist) NSAllowsArbitraryLoads"))
    let leakySpec = spec + "\n        NSAppTransportSecurity:\n          NSAllowsArbitraryLoads: true\n"
    let specFindings = try Self.transportFindings(spec: leakySpec, plist: plist)
    #expect(specFindings.contains("\(Self.projectSpec) NSAppTransportSecurity"))
    #expect(specFindings.contains("\(Self.projectSpec) NSAllowsArbitraryLoads"))
  }

  static func locationPurposeFindings(plist: String) throws -> [String] {
    let parsed = try PropertyListSerialization.propertyList(from: Data(plist.utf8), options: [], format: nil)
    let dictionary = try #require(parsed as? [String: Any])
    var findings: [String] = []
    for key in ["NSLocationUsageDescription", "NSLocationWhenInUseUsageDescription"] {
      let text = dictionary[key] as? String ?? ""
      for phrase in ["find and join your iPhone hotspot", "never stores or sends your location"]
      where !text.contains(phrase) {
        findings.append("\(key) lacks \(phrase)")
      }
    }
    return findings
  }

  @Test func bothLocationPurposeStringsSayWhatLocationIsForAndThatItIsNeverStoredOrSent() throws {
    let plist = try Self.repositoryFile(Self.infoPlist)
    #expect(try Self.locationPurposeFindings(plist: plist) == [])
    let stale = plist.replacingOccurrences(of: "It never stores or sends your location.", with: "")
    #expect(try Self.locationPurposeFindings(plist: stale).count == 2)
  }

  static let keychainPatterns: [(name: String, pattern: String)] = [
    ("SecItem", #"\bSecItem[A-Za-z]*"#),
    ("SecKeychain", #"\bSecKeychain[A-Za-z]*"#),
    ("SecAccess", #"\bSecAccess[A-Za-z]*"#),
    ("kSec constant", #"\bkSec[A-Z][A-Za-z]*"#),
    ("security tool", #"bin/security\b"#),
  ]

  static func keychainFindings(in files: [SourceFile]) -> [String] {
    files.flatMap { file in
      file.text.components(separatedBy: "\n").enumerated().flatMap { index, line -> [String] in
        var hits: [String] = []
        if NetworkSourceGateTests.importedModule(line) == "Security" {
          hits.append("\(file.path):\(index + 1) import Security")
        }
        for pattern in keychainPatterns where line.range(of: pattern.pattern, options: .regularExpression) != nil {
          hits.append("\(file.path):\(index + 1) \(pattern.name)")
        }
        return hits
      }
    }
  }

  @Test func noSourceInTheAppOrAnyPackageReachesTheKeychainOrTheSecurityTool() throws {
    let files = try NetworkSourceGateTests.corpus()
    #expect(files.count > 100)
    #expect(files.contains { $0.path.hasPrefix("Sources/Overtime/") })
    #expect(files.contains { $0.path.hasPrefix("Packages/OvertimeRuntime/Sources/OvertimeSystem/") })
    #expect(files.contains { $0.path.hasPrefix("Packages/OvertimeCore/Sources/") })
    #expect(Self.keychainFindings(in: files) == [])
  }

  @Test(arguments: [
    ("import Security", "import Security"),
    ("@preconcurrency import Security", "import Security"),
    ("let status = SecItemCopyMatching(query as CFDictionary, &result)", "SecItem"),
    ("var keychain: SecKeychain?", "SecKeychain"),
    ("let access: SecAccess? = nil", "SecAccess"),
    ("let query = [kSecClass: kSecClassGenericPassword]", "kSec constant"),
    (#"run("/usr/bin/security", ["find-generic-password", "-wa", name])"#, "security tool"),
  ])
  func theKeychainScanCatchesAPlantedLeakInTheWiFiController(planted: String, finding: String) throws {
    let files = try NetworkSourceGateTests.corpus()
    let controller = try #require(files.first { $0.path == NetworkSourceGateTests.wifiController })
    let leaky = files.map { file in
      file.path == controller.path ? SourceFile(path: file.path, text: file.text + "\n" + planted + "\n") : file
    }
    let findings = Self.keychainFindings(in: leaky)
    #expect(findings.count == 1)
    #expect(findings.first?.hasPrefix(controller.path + ":") == true)
    #expect(findings.first?.hasSuffix(" " + finding) == true)
  }

  @Test(arguments: [
    "let tickSeconds = 2",
    "static let healthCheckSeconds: Double = 30",
    "let securityType = profile.security",
    "// keeps the Wi-Fi security of the saved profile",
  ])
  func theKeychainScanIgnoresWordsThatOnlyLookAlike(line: String) {
    #expect(Self.keychainFindings(in: [SourceFile(path: "x.swift", text: line)]) == [])
  }
}
