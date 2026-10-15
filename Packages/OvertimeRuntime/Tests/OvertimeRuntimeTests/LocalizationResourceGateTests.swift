import Foundation
import Testing

@Suite(.processCleanup)
struct LocalizationResourceGateTests {
  static let resourceExtensions: Set<String> = ["strings", "stringsdict", "xcstrings"]

  static func findings(_ paths: [String]) -> [String] {
    TrackedFileCorpus.sorted(
      paths.compactMap { path in
        let components = path.split(separator: "/").map(String.init)
        if components.dropLast().contains(where: { $0.lowercased().hasSuffix(".lproj") }) {
          return "\(path):0 localization folder"
        }
        let pathExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
        return resourceExtensions.contains(pathExtension) ? "\(path):0 localization resource" : nil
      })
  }

  @Test func noTrackedFileIsALocalizationResource() async throws {
    let paths = try await TrackedFileCorpus.paths()
    #expect(paths.count >= TrackedFileCorpus.minimumPaths)
    let findings = Self.findings(paths)
    #expect(findings.isEmpty, "\(findings)")
  }

  @Test(arguments: [
    ("Resources/es.lproj/InfoPlist.strings", 1),
    ("Resources/Base.lproj/Main.storyboard", 1),
    ("Resources/Localizable.xcstrings", 1),
    ("Sources/Overtime/Localizable.strings", 1),
    ("Resources/en.lproj/Plurals.stringsdict", 1),
    ("Resources/Copy.XCSTRINGS", 1),
    ("docs/strings.md", 0),
    ("Sources/Overtime/StringsView.swift", 0),
    ("scripts/lproj-notes.sh", 0),
  ])
  func thePlantedResourcesAreReportedAndOnlyThose(_ path: String, _ count: Int) {
    #expect(Self.findings([path]).count == count)
  }
}
