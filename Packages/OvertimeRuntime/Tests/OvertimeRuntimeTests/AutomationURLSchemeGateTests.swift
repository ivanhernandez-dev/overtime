import Foundation
import OvertimeAppSupport
import Testing

struct AutomationURLSchemeGateTests {
  typealias Gate = SparkleInfoPlistGateTests

  static let schemeSetting = "OVERTIME_URL_SCHEME"

  struct URLType: Equatable {
    let name: String?
    let schemes: [String]?
  }

  static let expectedURLTypes = [URLType(name: "$(PRODUCT_BUNDLE_IDENTIFIER)", schemes: ["$(" + schemeSetting + ")"])]

  static func urlTypeFindings(_ plist: [String: Any]) -> [String] {
    let types = (plist["CFBundleURLTypes"] as? [[String: Any]])?.map { entry in
      URLType(name: entry["CFBundleURLName"] as? String, schemes: entry["CFBundleURLSchemes"] as? [String])
    }
    return types == expectedURLTypes ? [] : ["CFBundleURLTypes"]
  }

  static func configBlock(_ name: String, in target: [String]) -> [String] {
    var block: [String] = []
    var inside = false
    for line in target {
      let indent = line.prefix { $0 == " " }.count
      if indent <= 8 && !line.trimmingCharacters(in: .whitespaces).isEmpty {
        inside = line == "        " + name + ":"
        continue
      }
      if inside { block.append(line) }
    }
    return block
  }

  static func projectFindings(spec: String) -> [String] {
    var findings: [String] = []
    let app = Gate.targetBlock("Overtime", in: spec)
    let declared = [
      "        CFBundleURLTypes:",
      "          - CFBundleURLName: $(PRODUCT_BUNDLE_IDENTIFIER)",
      "            CFBundleURLSchemes:",
      "              - $(" + schemeSetting + ")",
    ]
    if !app.joined(separator: "\n").contains(declared.joined(separator: "\n")) {
      findings.append("CFBundleURLTypes property")
    }
    if Gate.setting(schemeSetting, in: configBlock("Debug", in: app)) != AutomationURL.debugScheme {
      findings.append("Debug \(schemeSetting)")
    }
    if Gate.setting(schemeSetting, in: configBlock("Release", in: app)) != AutomationURL.releaseScheme {
      findings.append("Release \(schemeSetting)")
    }
    return findings
  }

  @Test func theInfoPlistRegistersTheSchemeOfTheBuild() throws {
    let plist = try Gate.dictionary(Gate.repositoryFile(Gate.infoPlist))
    #expect(Self.urlTypeFindings(plist) == [])
  }

  @Test func aMissingOrChangedURLTypeIsReported() throws {
    var plist = try Gate.dictionary(Gate.repositoryFile(Gate.infoPlist))
    plist["CFBundleURLTypes"] = [["CFBundleURLSchemes": ["overtime"]]]
    #expect(Self.urlTypeFindings(plist) == ["CFBundleURLTypes"])
    plist["CFBundleURLTypes"] = nil
    #expect(Self.urlTypeFindings(plist) == ["CFBundleURLTypes"])
  }

  @Test func theProjectGivesTheReleaseAndDevelopmentBuildsTheirOwnScheme() throws {
    let spec = try Gate.repositoryFile(Gate.projectSpec)
    #expect(Self.projectFindings(spec: spec) == [])
  }

  @Test(arguments: [
    ("OVERTIME_URL_SCHEME: overtime-dev\n", "OVERTIME_URL_SCHEME: overtime\n", "Debug OVERTIME_URL_SCHEME"),
    ("OVERTIME_URL_SCHEME: overtime\n", "OVERTIME_URL_SCHEME: overtime-dev\n", "Release OVERTIME_URL_SCHEME"),
    ("              - $(OVERTIME_URL_SCHEME)\n", "              - overtime\n", "CFBundleURLTypes property"),
  ])
  func theProjectCheckCatchesAPlantedChange(original: String, planted: String, finding: String) throws {
    let spec = try Gate.repositoryFile(Gate.projectSpec)
    #expect(spec.components(separatedBy: original).count == 2)
    let changed = spec.replacingOccurrences(of: original, with: planted)
    #expect(Self.projectFindings(spec: changed) == [finding])
  }
}
