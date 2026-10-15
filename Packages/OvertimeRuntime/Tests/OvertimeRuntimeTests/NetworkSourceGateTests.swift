import Foundation
import Testing

struct NetworkSourceGateTests {
  struct SourceFile: Sendable {
    let path: String
    let text: String
  }

  struct Rule: Sendable {
    let name: String
    let allowed: Set<String>
    let matches: @Sendable (String) -> Bool
  }

  static let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

  static let system = "Packages/OvertimeRuntime/Sources/OvertimeSystem/"
  static let networkMonitor = system + "NetworkMonitor.swift"
  static let knownNetworks = system + "KnownNetworks.swift"
  static let wifiRadio = system + "WiFiRadio.swift"
  static let connectivityProbe = system + "ConnectivityProbe.swift"
  static let wifiController = system + "WiFiController.swift"
  static let coreWLANInfo = "Sources/Overtime/Adapters/CoreWLANInfo.swift"
  static let locationReader = "Sources/Overtime/Adapters/LocationStatusReader.swift"
  static let declarationKinds: Set<String> = [
    "struct", "class", "enum", "protocol", "func", "var", "let", "typealias", "actor",
  ]
  static let accessModifiers: Set<String> = ["public", "internal", "package", "private", "fileprivate"]
  static let configurationModule = "SystemConfiguration"
  static let configurationImport = "import \(configurationModule)"

  static func importedModule(_ line: String) -> String? {
    var tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
    while let first = tokens.first, first.hasPrefix("@") || accessModifiers.contains(first) {
      tokens.removeFirst()
    }
    guard tokens.first == "import", tokens.count >= 2 else { return nil }
    tokens.removeFirst()
    if let kind = tokens.first, declarationKinds.contains(kind), tokens.count >= 2 {
      tokens.removeFirst()
    }
    return tokens.first.map { String($0.split(separator: ".").first ?? "") }
  }

  static func imports(_ module: String) -> @Sendable (String) -> Bool {
    { importedModule($0) == module }
  }

  static func mentions(_ text: String) -> @Sendable (String) -> Bool {
    { $0.contains(text) }
  }

  static let rules: [Rule] = [
    importRule(configurationModule, allowed: [networkMonitor]),
    importRule("CoreWLAN", allowed: [knownNetworks, wifiRadio]),
    Rule(name: "URLSession", allowed: [connectivityProbe], matches: mentions("URLSession")),
    Rule(name: "networksetup", allowed: [wifiController], matches: mentions("networksetup")),
    Rule(name: "scanForNetworks", allowed: [wifiRadio], matches: mentions("scanForNetworks")),
    Rule(name: "associate(", allowed: [wifiRadio], matches: mentions("associate(")),
    Rule(name: "setPower(", allowed: [wifiRadio, wifiController], matches: mentions("setPower(")),
    Rule(name: "disassociate", allowed: [], matches: mentions("disassociate")),
    importRule("Network", allowed: []),
    Rule(name: "NWPathMonitor", allowed: [], matches: mentions("NWPathMonitor")),
    importRule("CoreLocation", allowed: [locationReader]),
  ]

  static func importRule(_ module: String, allowed: Set<String>) -> Rule {
    Rule(name: "import \(module)", allowed: allowed, matches: imports(module))
  }

  static func sourceRoots() throws -> [URL] {
    let packages = repositoryRoot.appendingPathComponent("Packages")
    let names = try FileManager.default.contentsOfDirectory(atPath: packages.path).sorted()
    let packageSources = names.map { packages.appendingPathComponent($0).appendingPathComponent("Sources") }
      .filter { FileManager.default.fileExists(atPath: $0.path) }
    return [repositoryRoot.appendingPathComponent("Sources")] + packageSources
  }

  static func corpus() throws -> [SourceFile] {
    let rootPath = repositoryRoot.standardizedFileURL.path + "/"
    var files: [SourceFile] = []
    for root in try sourceRoots() {
      let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
      for case let url as URL in enumerator where url.pathExtension == "swift" {
        let full = url.standardizedFileURL.path
        let path = full.hasPrefix(rootPath) ? String(full.dropFirst(rootPath.count)) : full
        files.append(SourceFile(path: path, text: try String(contentsOf: url, encoding: .utf8)))
      }
    }
    return files.sorted { $0.path < $1.path }
  }

  static func findings(of rule: Rule, in files: [SourceFile]) -> [String] {
    files.flatMap { file in
      file.text.components(separatedBy: "\n").enumerated().compactMap { index, line in
        rule.matches(line) ? "\(file.path):\(index + 1)" : nil
      }
    }
  }

  static func violations(in files: [SourceFile]) -> [String] {
    rules.flatMap { rule in
      findings(of: rule, in: files.filter { !rule.allowed.contains($0.path) }).map { "\($0) \(rule.name)" }
    }
  }

  @Test func theCorpusHoldsBothSourceTreesAndTheAdapterFilesTheGateAllows() throws {
    let paths = Set(try Self.corpus().map(\.path))
    #expect(paths.count > 100)
    for expected in [Self.networkMonitor, Self.knownNetworks, Self.coreWLANInfo, Self.locationReader] {
      #expect(paths.contains(expected), "the corpus is missing \(expected)")
    }
    #expect(paths.contains { $0.hasPrefix("Packages/OvertimeCore/Sources/") })
    #expect(!paths.contains { $0.contains("/Tests/") || $0.contains("/.build/") })
  }

  static func filesMatching(_ ruleName: String, in files: [SourceFile]) throws -> [String] {
    let rule = try #require(rules.first { $0.name == ruleName })
    return findings(of: rule, in: files).map { $0.components(separatedBy: ":")[0] }
  }

  @Test func theScanFindsTheImportsThatAreAllowed() throws {
    let files = try Self.corpus()
    #expect(try Self.filesMatching(Self.configurationImport, in: files) == [Self.networkMonitor])
    #expect(try Self.filesMatching("import CoreWLAN", in: files) == [Self.knownNetworks, Self.wifiRadio])
    #expect(try Self.filesMatching("import CoreLocation", in: files) == [Self.locationReader])
    #expect(Set(try Self.filesMatching("URLSession", in: files)) == [Self.connectivityProbe])
  }

  @Test func theScanFindsTheWiFiWritesInTheirAdapterFiles() throws {
    let files = try Self.corpus()
    #expect(Set(try Self.filesMatching("networksetup", in: files)) == [Self.wifiController])
    for write in ["scanForNetworks", "associate("] {
      #expect(Set(try Self.filesMatching(write, in: files)) == [Self.wifiRadio], "\(write)")
    }
    #expect(Set(try Self.filesMatching("setPower(", in: files)) == [Self.wifiRadio, Self.wifiController])
  }

  @Test func theControllerTurnsWiFiPowerOnlyThroughTheRadioPort() throws {
    let file = try #require(try Self.corpus().first { $0.path == Self.wifiController })
    let writes = file.text.components(separatedBy: "\n").filter { $0.contains("setPower(") }
    #expect(!writes.isEmpty)
    for line in writes {
      #expect(line.contains("radio.setPower(interface: interface, on: "), "\(line)")
    }
    #expect(!file.text.contains("import CoreWLAN"))
  }

  static func stringLiterals(in text: String) -> [String] {
    var literals: [String] = []
    for line in text.components(separatedBy: "\n") {
      var current: String?
      var escaped = false
      for character in line {
        guard var literal = current else {
          if character == "\"" { current = "" }
          continue
        }
        if escaped {
          literal.append(character)
          escaped = false
        } else if character == "\\" {
          escaped = true
        } else if character == "\"" {
          literals.append(literal)
          current = nil
          continue
        } else {
          literal.append(character)
        }
        current = literal
      }
    }
    return literals
  }

  @Test func theLiteralExtractorReadsEachQuotedStringOnALine() {
    let line = #"run("/usr/sbin/tool", ["-a", "x \"y\"", "-b"]) "#
    #expect(Self.stringLiterals(in: line) == ["/usr/sbin/tool", "-a", #"x "y""#, "-b"])
  }

  @Test func bothJoinPathsInTheControllerSitBehindTheOneSavedProfileGate() throws {
    let file = try #require(try Self.corpus().first { $0.path == Self.wifiController })
    let lines = file.text.components(separatedBy: "\n")
    func lineIndices(_ text: String) -> [Int] {
      lines.indices.filter { lines[$0].contains(text) }
    }
    let gate = lineIndices("CoreWLANRadio.acceptsSaved(radio.savedSecurity(")
    let saved = lineIndices("radio.joinSaved(")
    let tool = lineIndices("run(Self.networksetup")
    #expect(gate.count == 1)
    #expect(saved.count == 1)
    #expect(tool.count == 1)
    #expect(lineIndices("refusedSecurity").isEmpty)
    if let gate = gate.first, let saved = saved.first, let tool = tool.first {
      #expect(gate < saved)
      #expect(gate < tool)
    }
  }

  @Test func theControllerSpellsOnlyTheToolPathAndItsTwoVerbs() throws {
    let file = try #require(try Self.corpus().first { $0.path == Self.wifiController })
    let literals = Self.stringLiterals(in: file.text)
    #expect(Set(literals.filter { $0.hasPrefix("-") }) == ["-setairportnetwork", "-setairportpower"])
    #expect(literals.filter { $0.contains("networksetup") } == ["/usr/sbin/networksetup"])
    #expect(!literals.contains { $0.lowercased().contains("password") })
  }

  @Test func theMatcherReportsPlantedLinesAndOnlyThose() {
    let planted = Self.system + "Planted.swift"
    let text = [
      "import Foundation",
      "@preconcurrency " + Self.configurationImport,
      "import NetworkExtension",
      "import struct Network.NWEndpoint",
      "let session = URLSession.shared",
      "let tool = \"/usr/sbin/networksetup\"",
      "try radio.setPower(false)",
      "interface.disassociate()",
      "import CoreLocation",
    ].joined(separator: "\n")
    let found = Self.violations(in: [SourceFile(path: planted, text: text)])
    #expect(
      Set(found) == [
        "\(planted):2 \(Self.configurationImport)",
        "\(planted):4 import Network",
        "\(planted):5 URLSession",
        "\(planted):6 networksetup",
        "\(planted):7 setPower(",
        "\(planted):8 associate(",
        "\(planted):8 disassociate",
        "\(planted):9 import CoreLocation",
      ])
    let allowed = Self.violations(in: [SourceFile(path: Self.networkMonitor, text: Self.configurationImport)])
    #expect(allowed.isEmpty)
  }

  @Test func everyNetworkingAPIStaysInsideItsAdapterFile() throws {
    #expect(Self.violations(in: try Self.corpus()) == [])
  }
}
