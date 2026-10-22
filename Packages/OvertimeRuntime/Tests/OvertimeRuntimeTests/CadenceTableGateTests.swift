import Foundation
import OvertimeCore
import OvertimeHelperCore
import OvertimeSystem
import Testing

@Suite(.processCleanup)
struct CadenceTableGateTests {
  typealias SourceFile = NetworkSourceGateTests.SourceFile

  struct Inputs: Sendable {
    var adr: SourceFile
    var timing: SourceFile
    var panel: SourceFile
    var pane: SourceFile
    var sentinel: SourceFile
    var view: SourceFile
  }

  enum Mechanism: String, CaseIterable, Sendable {
    case dispatchTimer
    case scheduledTimer
    case publishedTimer
    case periodicTimeline
    case animatedTimeline
    case sleepInALoop
    case clockSleepInALoop

    var needles: [String] {
      switch self {
      case .dispatchTimer: ["DispatchSource." + "makeTimer" + "Source("]
      case .scheduledTimer: ["Timer." + "scheduledTimer("]
      case .publishedTimer: ["Timer." + "publish("]
      case .periodicTimeline: ["TimelineView(" + ".periodic"]
      case .animatedTimeline: ["TimelineView(" + ".animation"]
      case .sleepInALoop: ["Task." + "sleep("]
      case .clockSleepInALoop: ["clock" + ".sleep(", "Clock()" + ".sleep("]
      }
    }

    var needle: String {
      needles.first ?? ""
    }

    var insideLoopsOnly: Bool {
      self == .sleepInALoop || self == .clockSleepInALoop
    }
  }

  struct PeriodicSite: Sendable {
    let path: String
    let mechanism: Mechanism
    let count: Int
    let adr: String
  }

  struct SourceValue: Sendable {
    let row: String
    let path: String
    let pattern: String
  }

  struct Row: Sendable {
    let line: Int
    let name: String
    let seconds: Double
  }

  enum Drift: String, CaseIterable, Sendable {
    case tickRowChanged
    case batteryRowRemoved
    case unknownRowAdded
    case timingConstantAdded
    case panelValueChanged
    case sentinelTimerAdded
    case timelineValueChanged
  }

  static let adr = "docs/adr/0019-detection-loop-energy-design.md"
  static let timing = "Packages/OvertimeCore/Sources/OvertimeCore/Model/Timing.swift"
  static let panel = "Sources/Overtime/PanelModel.swift"
  static let pane = "Sources/Overtime/HelperPaneModel.swift"
  static let sentinel = "Packages/OvertimeRuntime/Sources/overtime-sentinel/main.swift"
  static let system = "Packages/OvertimeRuntime/Sources/OvertimeSystem/"
  static let helper = "Packages/OvertimeRuntime/Sources/overtime-helper/main.swift"
  static let view = "Sources/Overtime/Views/PanelView.swift"
  static let engine = "Packages/OvertimeRuntime/Sources/OvertimeEngine/Engine.swift"

  static let periodic: [String: Double] = [
    "tickSeconds": Timing.tickSeconds,
    "displayRecheckSeconds": Timing.displayRecheckSeconds,
    "resleepEverySeconds": Timing.resleepEverySeconds,
    "netEverySeconds": Timing.netEverySeconds,
    "batteryPollSeconds": Timing.batteryPollSeconds,
    "reassertEverySeconds": Timing.reassertEverySeconds,
    "healthCheckSeconds": Timing.healthCheckSeconds,
    "coexistenceCheckSeconds": Timing.coexistenceCheckSeconds,
  ]

  static let notPeriodic: Set<String> = [
    "lidStableSeconds", "hidIdleResleepSeconds", "netFailsNeeded", "netWaitMinSeconds", "netWaitMaxSeconds",
    "freshCaffeinateSeconds", "assertionTimeoutSeconds", "backoffBaseSeconds", "backoffCapSeconds",
    "releaseVerificationSeconds", "healthSilenceSeconds", "hotspotJoinWaitSeconds", "hotspotJoinLandSeconds",
    "sentinelTimeoutSeconds", "sentinelRespawnRetryBaseSeconds", "sentinelRespawnRetryCapSeconds",
    "systemCallTimeoutSeconds", "releaseRetrySeconds", "releaseFailuresBeforeEscalation",
    "lateWriteQuarantineSeconds", "lateWriteClearSeconds", "logRotateBytes", "learnedRootLingerSeconds",
    "sessionWorkingGraceSeconds", "sessionWaitingGraceSeconds", "backgroundCommandMinimumAgeSeconds",
  ]

  static let compiledRows: [String: Double] = [
    "Hold.acquireOrRenew": Timing.tickSeconds,
    "HelperMachine.watchPeriodSeconds": HelperMachine.watchPeriodSeconds,
    "HelperWatchdog.checkSeconds": HelperWatchdog.checkSeconds,
    "LiveNetworkPort.recoveryRetrySeconds": LiveNetworkPort.recoveryRetrySeconds,
  ]

  static let number = #"([0-9]+(?:\.[0-9]+)?)"#

  static let sourceValues = [
    SourceValue(
      row: "PanelModel.livenessIntervalSeconds", path: panel,
      pattern: #"var livenessIntervalSeconds: Double = "# + number),
    SourceValue(
      row: "HelperPaneModel.pollIntervalSeconds", path: pane,
      pattern: #"static let pollIntervalSeconds: Double = "# + number),
    SourceValue(row: "overtime-sentinel", path: sentinel, pattern: #"repeating: \.seconds\(([0-9]+)\)"#),
    SourceValue(
      row: "PanelView.TimelineView", path: view, pattern: #"TimelineView\(\.periodic\(from: \.now, by: ([0-9]+)\)\)"#),
  ]

  static func row(_ name: String) -> String {
    "| `" + name + "` |"
  }

  static let periodicSites = [
    PeriodicSite(
      path: system + "PowerSourceMonitor.swift", mechanism: .dispatchTimer, count: 1,
      adr: row("Timing.batteryPollSeconds")),
    PeriodicSite(
      path: system + "TranscriptWatcher.swift", mechanism: .dispatchTimer, count: 1,
      adr: row("Timing.healthCheckSeconds")),
    PeriodicSite(path: helper, mechanism: .dispatchTimer, count: 2, adr: row("HelperWatchdog.checkSeconds")),
    PeriodicSite(path: sentinel, mechanism: .dispatchTimer, count: 1, adr: row("overtime-sentinel")),
    PeriodicSite(path: view, mechanism: .periodicTimeline, count: 1, adr: row("PanelView.TimelineView")),
    PeriodicSite(path: engine, mechanism: .sleepInALoop, count: 1, adr: row("Timing.tickSeconds")),
    PeriodicSite(path: panel, mechanism: .sleepInALoop, count: 1, adr: row("PanelModel.livenessIntervalSeconds")),
    PeriodicSite(
      path: system + "SentinelLink.swift", mechanism: .sleepInALoop, count: 1, adr: "`SentinelLink.waitForExit`"),
    PeriodicSite(
      path: "Sources/Overtime/UninstallModel.swift", mechanism: .sleepInALoop, count: 2, adr: "`UninstallModel`"),
  ]

  static let loopOpening = #"^\s*(?:\w+:\s*)?(?:while\s|for\s|repeat\s*\{)"#

  static func captures(_ text: String, _ pattern: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    return regex.matches(in: text, range: range).compactMap { match in
      Range(match.range(at: 1), in: text).map { String(text[$0]) }
    }
  }

  static func timingNames(_ file: SourceFile) -> [String] {
    captures(file.text, #"public static let (\w+)"#)
  }

  static func classificationFindings(_ file: SourceFile) -> [String] {
    let names = Set(timingNames(file))
    let known = Set(periodic.keys).union(notPeriodic)
    let unclassified = names.subtracting(known).map { "\(file.path) unclassified \($0)" }
    let lost = known.subtracting(names).map { "\(file.path) no longer declares \($0)" }
    return unclassified + lost
  }

  static func sourceValue(_ value: SourceValue, in file: SourceFile) -> (seconds: Double?, findings: [String]) {
    let found = captures(file.text, value.pattern)
    guard found.count == 1, let seconds = Double(found[0]) else {
      return (nil, ["\(file.path) has \(found.count) matches for the \(value.row) cadence, expected 1"])
    }
    return (seconds, [])
  }

  static func expectedRows(_ inputs: Inputs) -> (rows: [String: Double?], findings: [String]) {
    var rows: [String: Double?] = [:]
    for (name, seconds) in periodic {
      rows["Timing." + name] = seconds
    }
    for (name, seconds) in compiledRows {
      rows[name] = seconds
    }
    var findings: [String] = []
    let files = [
      inputs.panel.path: inputs.panel, inputs.pane.path: inputs.pane, inputs.sentinel.path: inputs.sentinel,
      inputs.view.path: inputs.view,
    ]
    for value in sourceValues {
      guard let file = files[value.path] else {
        findings.append("\(value.path) was not read for the \(value.row) cadence")
        rows[value.row] = .some(nil)
        continue
      }
      let read = sourceValue(value, in: file)
      rows[value.row] = .some(read.seconds)
      findings += read.findings
    }
    return (rows, findings)
  }

  static let rowPattern = #"^\| `([^`|]+)` \| "# + number + #" s \|"#

  static func groups(_ text: String, _ pattern: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    else { return [] }
    return (1..<match.numberOfRanges).compactMap { index in
      Range(match.range(at: index), in: text).map { String(text[$0]) }
    }
  }

  static func tableRows(_ file: SourceFile) -> [Row] {
    let lines = file.text.components(separatedBy: "\n")
    guard let note = lines.firstIndex(where: { $0.hasPrefix(PublicFaceGateTests.notePrefix) }) else { return [] }
    return lines.enumerated().compactMap { index, line in
      let cells = groups(line, rowPattern)
      guard index > note, cells.count == 2, let seconds = Double(cells[1]) else { return nil }
      return Row(line: index + 1, name: cells[0], seconds: seconds)
    }
  }

  static func tableFindings(_ file: SourceFile, expected: [String: Double?]) -> [String] {
    var findings: [String] = []
    var seen: Set<String> = []
    for row in tableRows(file) {
      guard let codeValue = expected[row.name] else {
        findings.append("\(file.path):\(row.line) has an unknown cadence row \(row.name)")
        continue
      }
      guard seen.insert(row.name).inserted else {
        findings.append("\(file.path):\(row.line) repeats the row \(row.name)")
        continue
      }
      if let codeValue, codeValue != row.seconds {
        findings.append(
          "\(file.path):\(row.line) says \(row.name) runs every \(row.seconds) s, the code says \(codeValue) s")
      }
    }
    for name in expected.keys where !seen.contains(name) {
      findings.append("\(file.path) lacks a cadence row for \(name)")
    }
    return findings
  }

  static func findings(_ inputs: Inputs) -> [String] {
    let expected = expectedRows(inputs)
    let table = tableFindings(inputs.adr, expected: expected.rows)
    return (classificationFindings(inputs.timing) + expected.findings + table).sorted()
  }

  static func isProductSource(_ path: String) -> Bool {
    guard path.hasSuffix(".swift") else { return false }
    if path.hasPrefix("Sources/") { return true }
    let parts = path.split(separator: "/")
    return parts.count > 3 && parts[0] == "Packages" && parts[2] == "Sources"
  }

  static func loopLines(_ lines: [String]) -> Set<Int> {
    var inside: Set<Int> = []
    for start in lines.indices where lines[start].range(of: loopOpening, options: .regularExpression) != nil {
      var depth = 0
      var opened = false
      for index in start..<lines.count {
        let line = lines[index]
        depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
        opened = opened || line.contains("{")
        inside.insert(index)
        if opened && depth <= 0 {
          break
        }
      }
    }
    return inside
  }

  static func occurrences(of mechanism: Mechanism, in text: String) -> Int {
    mechanism.needles.map { text.components(separatedBy: $0).count - 1 }.reduce(0, +)
  }

  static func count(_ mechanism: Mechanism, in file: SourceFile) -> Int {
    guard mechanism.insideLoopsOnly else {
      return occurrences(of: mechanism, in: file.text)
    }
    let lines = file.text.components(separatedBy: "\n")
    let loops = loopLines(lines)
    let counts = lines.indices.filter { loops.contains($0) }.map { occurrences(of: mechanism, in: lines[$0]) }
    return counts.reduce(0, +)
  }

  static func timerSiteFindings(_ files: [SourceFile]) -> [String] {
    var findings: [String] = []
    for mechanism in Mechanism.allCases {
      let pinned = Dictionary(
        periodicSites.filter { $0.mechanism == mechanism }.map { ($0.path, $0.count) }, uniquingKeysWith: +)
      var counts: [String: Int] = [:]
      for file in files where isProductSource(file.path) {
        let found = count(mechanism, in: file)
        if found > 0 {
          counts[file.path] = found
        }
      }
      for (path, found) in counts where pinned[path] != found {
        findings.append("\(path) has \(found) \(mechanism.rawValue), ADR 0019 justifies \(pinned[path] ?? 0)")
      }
      for (path, expected) in pinned where counts[path] == nil {
        findings.append("\(path) has no \(mechanism.rawValue), ADR 0019 justifies \(expected)")
      }
    }
    return findings.sorted()
  }

  static func noteText(_ file: SourceFile) -> String {
    let lines = file.text.components(separatedBy: "\n")
    guard let note = lines.firstIndex(where: { $0.hasPrefix(PublicFaceGateTests.notePrefix) }) else { return "" }
    return lines[note...].joined(separator: "\n")
  }

  static func liveInputs() throws -> Inputs {
    Inputs(
      adr: try PublicFaceGateTests.read(adr),
      timing: try PublicFaceGateTests.read(timing),
      panel: try PublicFaceGateTests.read(panel),
      pane: try PublicFaceGateTests.read(pane),
      sentinel: try PublicFaceGateTests.read(sentinel),
      view: try PublicFaceGateTests.read(view))
  }

  static func removingLine(containing marker: String, from file: SourceFile) -> SourceFile {
    let lines = file.text.components(separatedBy: "\n")
    #expect(lines.filter { $0.contains(marker) }.count == 1, "\(file.path) lacks one line with \(marker)")
    return SourceFile(path: file.path, text: lines.filter { !$0.contains(marker) }.joined(separator: "\n"))
  }

  @Test func everyTimingConstantIsClassified() throws {
    let names = Self.timingNames(try PublicFaceGateTests.read(Self.timing))
    #expect(names.count == 34)
    #expect(Set(names).count == names.count)
    #expect(Self.periodic.count == 8)
    #expect(Self.notPeriodic.count == 26)
    #expect(Set(Self.periodic.keys).isDisjoint(with: Self.notPeriodic))
    #expect(Set(names) == Set(Self.periodic.keys).union(Self.notPeriodic))
  }

  @Test func theCadenceTableMatchesTheCode() throws {
    let inputs = try Self.liveInputs()
    #expect(Self.tableRows(inputs.adr).count == 16)
    #expect(Self.expectedRows(inputs).rows.count == 16)
    #expect(Self.findings(inputs) == [])
  }

  @Test func theTimerSitesAreTheOnesTheTableJustifies() async throws {
    let corpus = try await TrackedFileCorpus.load()
    let required = Set(Self.periodicSites.map(\.path)).sorted()
    #expect(TrackedFileCorpus.populationFindings(corpus, requiring: required) == [])
    #expect(corpus.files.filter { Self.isProductSource($0.path) }.count > 100)
    #expect(Self.timerSiteFindings(corpus.files) == [])
  }

  @Test func everyPeriodicSiteIsNamedInTheNote() throws {
    let note = Self.noteText(try PublicFaceGateTests.read(Self.adr))
    #expect(!note.isEmpty)
    for site in Self.periodicSites {
      #expect(note.contains(site.adr), "ADR 0019's note lacks \(site.adr) for \(site.path)")
    }
  }

  static let plantedMechanisms: [Mechanism: String] = [
    .dispatchTimer: "let timer = " + Mechanism.dispatchTimer.needle + "queue: .main)",
    .scheduledTimer: "let timer = " + Mechanism.scheduledTimer.needle + "withTimeInterval: 1, repeats: true) { _ in }",
    .publishedTimer: "let ticks = " + Mechanism.publishedTimer.needle + "every: 1, on: .main, in: .common)",
    .periodicTimeline: Mechanism.periodicTimeline.needle + "(from: .now, by: 1)) { _ in EmptyView() }",
    .animatedTimeline: "TimelineView(" + ".animation) { _ in EmptyView() }",
    .sleepInALoop: "func poll() async {\n  while !Task.isCancelled {\n    try? await " + Mechanism.sleepInALoop.needle
      + "for: .seconds(1))\n  }\n}",
    .clockSleepInALoop: "func poll() async {\n  let clock = ContinuousClock()\n  while !Task.isCancelled {\n"
      + "    try? await clock" + ".sleep(for: .seconds(1))\n  }\n}",
  ]

  @Test(arguments: Mechanism.allCases)
  func theTimerSiteCheckReportsAPlantedMechanism(mechanism: Mechanism) throws {
    let scanner = Self.system + "ProcessScanner.swift"
    var files = try Set(Self.periodicSites.map(\.path)).sorted().map { try PublicFaceGateTests.read($0) }
    #expect(Self.timerSiteFindings(files) == [])
    let planted = try #require(Self.plantedMechanisms[mechanism])
    files.append(PublicFaceGateTests.appending(try PublicFaceGateTests.read(scanner), planted))
    PublicFaceGateTests.expectOne(Self.timerSiteFindings(files), naming: scanner)
  }

  @Test func aSleepOutsideALoopOrAForLabelIsNotACadence() throws {
    let scanner = try PublicFaceGateTests.read(Self.system + "ProcessScanner.swift")
    let sleep = Mechanism.sleepInALoop.needle
    let once = "func later() async {\n  try? await " + sleep + "for: .seconds(1))\n}"
    let label = "func later() async {\n  try? await " + sleep + "\n    for: .seconds(1))\n}"
    let loop = "func poll() async {\n  repeat {\n    try? await " + sleep + "for: .seconds(1))\n  } while true\n}"
    #expect(Self.count(.sleepInALoop, in: PublicFaceGateTests.appending(scanner, once)) == 0)
    #expect(Self.count(.sleepInALoop, in: PublicFaceGateTests.appending(scanner, label)) == 0)
    #expect(Self.count(.sleepInALoop, in: PublicFaceGateTests.appending(scanner, loop)) == 1)
    let clockSleep = "ContinuousClock()" + ".sleep(for: .seconds(1))"
    let clockOnce = "func later() async {\n  try? await " + clockSleep + "\n}"
    let clockLoop = "func poll() async {\n  for _ in 0..<10 {\n    try? await " + clockSleep + "\n  }\n}"
    #expect(Self.count(.clockSleepInALoop, in: PublicFaceGateTests.appending(scanner, clockOnce)) == 0)
    #expect(Self.count(.clockSleepInALoop, in: PublicFaceGateTests.appending(scanner, clockLoop)) == 1)
    #expect(Self.count(.sleepInALoop, in: PublicFaceGateTests.appending(scanner, clockLoop)) == 0)
  }

  @Test func theNoteSitsAfterTheEvidenceAndKeepsTheDecision() throws {
    #expect(PublicFaceGateTests.adrFindings(try PublicFaceGateTests.read(Self.adr)) == [])
  }

  @Test(arguments: Drift.allCases)
  func theCadenceGateReportsPlantedDriftAndOnlyThat(drift: Drift) throws {
    var inputs = try Self.liveInputs()
    let item: String
    switch drift {
    case .tickRowChanged:
      inputs.adr = PublicFaceGateTests.replacing(
        inputs.adr, "| `Timing.tickSeconds` | 2 s |", with: "| `Timing.tickSeconds` | 3 s |")
      item = "Timing.tickSeconds"
    case .batteryRowRemoved:
      inputs.adr = Self.removingLine(containing: "| `Timing.batteryPollSeconds` |", from: inputs.adr)
      item = "Timing.batteryPollSeconds"
    case .unknownRowAdded:
      inputs.adr = PublicFaceGateTests.appending(
        inputs.adr, "| `Timing.pollSeconds` | 5 s | **APP-13** | always | a planted row |")
      item = "Timing.pollSeconds"
    case .timingConstantAdded:
      let opening = "public enum Timing {"
      inputs.timing = PublicFaceGateTests.replacing(
        inputs.timing, opening, with: opening + "\n  public static let pollSeconds: Double = 5")
      item = "pollSeconds"
    case .panelValueChanged:
      inputs.panel = PublicFaceGateTests.replacing(
        inputs.panel, "var livenessIntervalSeconds: Double = 5", with: "var livenessIntervalSeconds: Double = 7")
      item = "PanelModel.livenessIntervalSeconds"
    case .sentinelTimerAdded:
      let schedule = "repeating: .seconds(1), leeway: .milliseconds(100))"
      inputs.sentinel = PublicFaceGateTests.replacing(
        inputs.sentinel, schedule, with: schedule + "\n    other.schedule(deadline: .now(), repeating: .seconds(5))")
      item = "overtime-sentinel"
    case .timelineValueChanged:
      inputs.view = PublicFaceGateTests.replacing(
        inputs.view, "TimelineView(.periodic(from: .now, by: 1))", with: "TimelineView(.periodic(from: .now, by: 2))")
      item = "PanelView.TimelineView"
    }
    let found = Self.findings(inputs)
    #expect(found.count == 1, "\(found)")
    #expect(found.first?.contains(item) == true, "\(found)")
  }
}
