import Foundation
import OvertimeAppSupport
import OvertimeEngine
import Testing

struct UninstallExitCodeContractTests {
  static let script = "scripts/uninstall.sh"

  struct Arm: Equatable {
    let codes: [String]
    let removesBundle: Bool
  }

  static func scriptText() throws -> String {
    try String(
      contentsOf: NetworkSourceGateTests.repositoryRoot.appendingPathComponent(script), encoding: .utf8)
  }

  static func appResultArms(_ text: String) -> [Arm]? {
    let lines = text.components(separatedBy: "\n")
    guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "case \"$code\" in" })
    else { return nil }
    var arms: [Arm] = []
    var codes: [String]?
    var removes = false
    for line in lines[(start + 1)...] {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed == "esac" {
        return arms
      }
      if codes == nil, trimmed.hasSuffix(")"), !trimmed.hasPrefix("#") {
        codes = trimmed.dropLast().components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        removes = false
        continue
      }
      if trimmed.hasPrefix("remove_bundle") {
        removes = true
      }
      if trimmed == ";;", let current = codes {
        arms.append(Arm(codes: current, removesBundle: removes))
        codes = nil
      }
    }
    return nil
  }

  static func codesThatRemoveTheBundle(_ arms: [Arm]) -> Set<String> {
    Set(arms.filter(\.removesBundle).flatMap(\.codes))
  }

  @Test func aRefusedOrMalformedUninstallExitsWithTheUsageCode() {
    #expect(AppInvocation.usageExitCode == 64)
    #expect(ResetCommand.liveInstanceExitCode == 75)
    #expect(HeadlessUninstall.exitCode(.uninstalled) == 0)
    #expect(HeadlessUninstall.exitCode(.finishedWithProblems) == 1)
    #expect(HeadlessUninstall.exitCode(.stopped) == 1)
  }

  @Test func theScriptRemovesTheBundleOnlyAfterARunThatReachedItsSteps() throws {
    let arms = try #require(Self.appResultArms(try Self.scriptText()))
    #expect(Self.codesThatRemoveTheBundle(arms) == ["0", "1"])
    let removing = Self.codesThatRemoveTheBundle(arms)
    #expect(!removing.contains(String(AppInvocation.usageExitCode)))
    #expect(!removing.contains(String(ResetCommand.liveInstanceExitCode)))
    #expect(!removing.contains("*"))
    let wildcard = try #require(arms.last)
    #expect(wildcard.codes == ["*"])
    #expect(!wildcard.removesBundle)
  }

  @Test func theScriptPassesTheStillRunningCodeThroughWithoutRemovingTheBundle() throws {
    let arms = try #require(Self.appResultArms(try Self.scriptText()))
    let stillRunning = try #require(arms.first { $0.codes.contains(String(ResetCommand.liveInstanceExitCode)) })
    #expect(!stillRunning.removesBundle)
  }

  @Test(arguments: [
    ("    0)\n      remove_bundle || exit 1\n", "    0 | 64)\n      remove_bundle || exit 1\n", "0, 1, 64"),
    ("    *)\n      say", "    *)\n      remove_bundle || true\n      say", "*, 0, 1"),
    ("    75)\n      exit 75\n", "    75)\n      remove_bundle || true\n      exit 75\n", "0, 1, 75"),
  ])
  func theContractCatchesAnArmThatRemovesTheBundleTooOften(original: String, planted: String, expected: String) throws {
    let text = try Self.scriptText()
    #expect(text.contains(original))
    let mutated = text.replacingOccurrences(of: original, with: planted)
    let arms = try #require(Self.appResultArms(mutated))
    #expect(Self.codesThatRemoveTheBundle(arms).sorted().joined(separator: ", ") == expected)
  }
}
