import Foundation
import Testing

struct TickSamplerToolGateTests {
  typealias SourceFile = NetworkSourceGateTests.SourceFile

  struct Needle: Sendable {
    let name: String
    let pattern: String
  }

  struct Pin: Sendable {
    let line: String
    let adr: String
  }

  struct ReachedSpawn: Sendable {
    let path: String
    let reason: String
    let pins: [Pin]
  }

  enum Plant: String, CaseIterable, Sendable {
    case toolRunnerInTheScanner
    case processInsideTheTickClosure
    case processOutsideTheTickClosure
    case spawnInTheEngine
    case existingToolRunnerConstantRead
    case processInTheNetworkMonitor
    case toolRunnerInTheNetworkFacts
    case secondToolPathInTheWiFiController
    case toolCallInTheMarkerCheck
    case powerToolCallInTheMarkerCheck
  }

  static let system = "Packages/OvertimeRuntime/Sources/OvertimeSystem/"
  static let engine = "Packages/OvertimeRuntime/Sources/OvertimeEngine/Engine.swift"
  static let composition = "Packages/OvertimeRuntime/Sources/OvertimeEngine/Composition.swift"
  static let adr = "docs/adr/0019-detection-loop-energy-design.md"
  static let scanner = system + "ProcessScanner.swift"
  static let networkMonitor = system + "NetworkMonitor.swift"
  static let livePort = system + "LiveNetworkPort.swift"
  static let wifi = system + "WiFiController.swift"

  static let samplerFiles = [
    scanner,
    system + "SessionReader.swift",
    system + "RegistryReader.swift",
    system + "CoexistenceProbe.swift",
    system + "TranscriptWatcher.swift",
    system + "TranscriptHeaderReader.swift",
    system + "TranscriptScanner.swift",
    system + "PowerSourceMonitor.swift",
    networkMonitor,
    system + "NetworkFactsParser.swift",
    system + "KnownNetworks.swift",
    system + "WiFiCycleMarker.swift",
    system + "DeadlineRunner.swift",
    engine,
    "Packages/OvertimeCore/Sources/OvertimeCore/Detectors/ClaudeCodeDetector.swift",
  ]

  static let recoveryRow = "| `LiveNetworkPort.recoveryRetrySeconds` | 30 s |"
  static let hotspotJoin = "joining the hotspot (`-setairportnetwork`"
  static let wifiCycle = "cycling Wi-Fi (`-setairportpower` through the same `runPowerTool`"
  static let defaultTools =
    "makeTools: @escaping @Sendable (Double) -> any ToolPort = { ToolRunner(timeoutSeconds: $0) },"

  static let reachedSpawns = [
    ReachedSpawn(
      path: livePort,
      reason: "facts(lidClosed:) starts a process only through recoverInBackground",
      pins: [
        Pin(
          line: "system call: public static func system(paths: Paths, location: LocationGrant) -> LiveNetworkPort {",
          adr: recoveryRow),
        Pin(line: "tool runner constructor: " + defaultTools, adr: recoveryRow),
        Pin(line: "tool port: " + defaultTools, adr: recoveryRow),
      ]),
    ReachedSpawn(
      path: wifi,
      reason: "networksetup -setairportpower from runPowerTool, on the Wi-Fi recovery retry and the failover effects",
      pins: [
        Pin(line: "tool path literal: public static let networksetup = \"/usr/sbin/networksetup\"", adr: recoveryRow),
        Pin(line: "tool port: private let makeTools: @Sendable (Double) -> any ToolPort", adr: recoveryRow),
        Pin(line: "tool runner constructor: " + defaultTools, adr: recoveryRow),
        Pin(line: "tool port: " + defaultTools, adr: recoveryRow),
        Pin(
          line: "tool factory call: let tools = makeTools(min(Self.fallbackMaxSeconds, "
            + "remaining - Self.fallbackReserveSeconds))",
          adr: hotspotJoin),
        Pin(
          line: "tool run call: return Self.joinOutcome(tools.run(Self.networksetup, "
            + "[Self.joinVerb, interface, ssid]))",
          adr: hotspotJoin),
        Pin(
          line: "tool factory call: return makeTools(Self.radioCallSeconds).run(tool, "
            + "[Self.powerVerb, interface, on ? \"on\" : \"off\"])",
          adr: recoveryRow),
        Pin(line: "power tool call: let outcome = runPowerTool(interface: interface, on: false)", adr: wifiCycle),
        Pin(line: "power tool call: _ = runPowerTool(interface: interface, on: true)", adr: recoveryRow),
        Pin(line: "power tool call: _ = runPowerTool(interface: interface, on: true)", adr: recoveryRow),
        Pin(
          line: "power tool call: private func runPowerTool(interface: String, on: Bool) -> ToolOutcome {",
          adr: recoveryRow),
      ]),
  ]

  static let toolRunner = "Tool" + "Runner"
  static let processType = "Pro" + "cess"
  static let tickOpening = "sample" + "Tick: {"
  static let toolFactory = "make" + "Tools("
  static let powerTool = "run" + "PowerTool("

  static let needles = [
    Needle(name: "tool runner constructor", pattern: "\\b" + toolRunner + "\\("),
    Needle(name: "tool port", pattern: "\\b" + "Tool" + "Port" + "\\b"),
    Needle(name: "process constructor", pattern: "\\b" + processType + "\\("),
    Needle(name: "posix spawn", pattern: "posix" + "_spawn"),
    Needle(name: "task class", pattern: "\\bNS" + "Task\\b"),
    Needle(name: "popen", pattern: "\\bpo" + "pen\\("),
    Needle(name: "system call", pattern: "\\bsys" + "tem\\("),
    Needle(name: "tool path literal", pattern: "\"/(" + "usr/bin|bin|usr/sbin" + ")/"),
    Needle(name: "tool factory call", pattern: "\\bmake" + "Tools\\("),
    Needle(name: "tool run call", pattern: "\\btools" + "\\.run\\("),
    Needle(name: "power tool call", pattern: "\\brun" + "PowerTool\\("),
  ]

  static func matches(_ line: String, _ pattern: String) -> Bool {
    line.range(of: pattern, options: .regularExpression) != nil
  }

  static func lineFindings(path: String, lines: [String], firstLine: Int) -> [String] {
    lines.enumerated().flatMap { offset, line in
      needles.filter { matches(line, $0.pattern) }.map { "\(path):\(firstLine + offset) \($0.name)" }
    }
  }

  static func samplerFindings(_ files: [SourceFile]) -> [String] {
    files.flatMap { file in
      lineFindings(path: file.path, lines: file.text.components(separatedBy: "\n"), firstLine: 1)
    }
  }

  static func tickBlocks(_ file: SourceFile) -> [(firstLine: Int, lines: [String])] {
    let lines = file.text.components(separatedBy: "\n")
    return lines.indices.filter { lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix(tickOpening) }.map {
      start in
      var depth = 0
      var end = lines.count - 1
      for index in start..<lines.count {
        depth += lines[index].filter { $0 == "{" }.count - lines[index].filter { $0 == "}" }.count
        if depth <= 0 {
          end = index
          break
        }
      }
      return (start + 1, Array(lines[start...end]))
    }
  }

  static func tickFindings(_ file: SourceFile) -> [String] {
    tickBlocks(file).flatMap { lineFindings(path: file.path, lines: $0.lines, firstLine: $0.firstLine) }
  }

  static func samplerInputs() throws -> [SourceFile] {
    try samplerFiles.map { try PublicFaceGateTests.read($0) }
  }

  static func reachedInputs() throws -> [SourceFile] {
    try reachedSpawns.map { try PublicFaceGateTests.read($0.path) }
  }

  static func pinnedLines(_ file: SourceFile) -> [(number: Int, text: String)] {
    file.text.components(separatedBy: "\n").enumerated().flatMap { offset, line in
      needles.filter { matches(line, $0.pattern) }.map {
        (number: offset + 1, text: "\($0.name): " + line.trimmingCharacters(in: .whitespaces))
      }
    }
  }

  static func reachedSpawnFindings(_ files: [SourceFile]) -> [String] {
    reachedSpawns.flatMap { reached -> [String] in
      guard let file = files.first(where: { $0.path == reached.path }) else {
        return ["\(reached.path) was not read"]
      }
      var remaining = reached.pins.map(\.line)
      var extra: [String] = []
      for line in pinnedLines(file) {
        if let index = remaining.firstIndex(of: line.text) {
          remaining.remove(at: index)
        } else {
          extra.append("\(reached.path):\(line.number) pinned line changed or new process start: \(line.text)")
        }
      }
      return extra + remaining.map { "\(reached.path) no longer holds the pinned line \($0)" }
    }
  }

  static func adrNote() throws -> String {
    let lines = try PublicFaceGateTests.read(adr).text.components(separatedBy: "\n")
    guard let note = lines.firstIndex(where: { $0.hasPrefix(PublicFaceGateTests.notePrefix) }) else { return "" }
    return lines[note...].joined(separator: "\n")
  }

  static func planting(_ line: String, after anchor: String, in file: SourceFile) -> SourceFile {
    PublicFaceGateTests.replacing(file, anchor, with: anchor + "\n" + line)
  }

  @Test func everyTickSamplerFileExists() throws {
    let files = try Self.samplerInputs()
    #expect(files.count == 15)
    #expect(Set(files.map(\.path)).count == 15)
    for file in files {
      #expect(file.text.components(separatedBy: "\n").count > 15, "\(file.path)")
    }
  }

  @Test func noTickSamplerFileCanStartAProcess() throws {
    #expect(Self.samplerFindings(try Self.samplerInputs()) == [])
  }

  @Test func theNetworkPathsTheTickReachesStartProcessesOnlyWhereADR0019Says() throws {
    let files = try Self.reachedInputs()
    #expect(files.count == 2)
    #expect(Set(Self.reachedSpawns.map(\.path)).isDisjoint(with: Self.samplerFiles))
    #expect(Self.reachedSpawnFindings(files) == [])
    let note = try Self.adrNote()
    #expect(!note.contains("launchctl"))
    #expect(note.contains("One path the tick reaches can start a process"))
    for reached in Self.reachedSpawns {
      #expect(!reached.reason.isEmpty)
      for pin in reached.pins {
        #expect(note.contains(pin.adr), "ADR 0019's note lacks \(pin.adr) for \(reached.path): \(pin.line)")
      }
    }
    let calls = Self.reachedSpawns.flatMap(\.pins).filter {
      $0.line.hasPrefix("tool factory call: ") || $0.line.hasPrefix("tool run call: ")
    }
    #expect(calls.count == 3)
    #expect(Self.reachedSpawns.flatMap(\.pins).filter { $0.line.hasPrefix("power tool call: ") }.count == 4)
  }

  @Test func theSampleTickClosureCanStartNoProcess() throws {
    let file = try PublicFaceGateTests.read(Self.composition)
    let blocks = Self.tickBlocks(file)
    #expect(blocks.count == 1)
    #expect((blocks.first?.lines.count ?? 0) > 5)
    #expect(blocks.first?.lines.last?.trimmingCharacters(in: .whitespaces) == "},")
    #expect(Self.tickFindings(file) == [])
  }

  @Test func aChangedPinnedLineIsReportedWithItsFileAndLine() throws {
    let call = "return " + Self.toolFactory + "Self.radioCallSeconds).run(tool, "
    let wrapped = "return " + Self.toolFactory + "Self.radioCallSeconds)\n      .run(tool, "
    let reached = try Self.reachedInputs().map {
      $0.path == Self.wifi ? PublicFaceGateTests.replacing($0, call, with: wrapped) : $0
    }
    let file = try #require(reached.first { $0.path == Self.wifi })
    let lines = file.text.components(separatedBy: "\n")
    let number = try #require(lines.firstIndex { $0.hasSuffix(Self.toolFactory + "Self.radioCallSeconds)") }) + 1
    let found = Self.reachedSpawnFindings(reached)
    #expect(found.count == 2, "\(found)")
    #expect(
      found.contains(
        "\(Self.wifi):\(number) pinned line changed or new process start: tool factory call: return "
          + Self.toolFactory + "Self.radioCallSeconds)"),
      "\(found)")
    let lost = "\(Self.wifi) no longer holds the pinned line tool factory call: "
    #expect(found.contains { $0.hasPrefix(lost) }, "\(found)")
  }

  @Test(arguments: Plant.allCases)
  func theToolGateReportsPlantedLinesAndOnlyThose(plant: Plant) throws {
    let files = try Self.samplerInputs()
    let composition = try PublicFaceGateTests.read(Self.composition)
    let found: [String]
    let expected: Int
    let path: String
    switch plant {
    case .toolRunnerInTheScanner:
      found = Self.samplerFindings(
        files.map {
          $0.path == Self.scanner
            ? PublicFaceGateTests.appending($0, "let runner = " + Self.toolRunner + "()") : $0
        })
      (expected, path) = (1, Self.scanner)
    case .processInsideTheTickClosure:
      let planted = Self.planting(
        "        let child = " + Self.processType + "()", after: Self.tickOpening, in: composition)
      found = Self.tickFindings(planted)
      (expected, path) = (1, Self.composition)
    case .processOutsideTheTickClosure:
      let planted = Self.planting(
        "    let child = " + Self.processType + "()", after: "let stateFile = paths.stateFile(mode)", in: composition)
      found = Self.tickFindings(planted)
      (expected, path) = (0, Self.composition)
    case .spawnInTheEngine:
      found = Self.samplerFindings(
        files.map {
          $0.path == Self.engine
            ? PublicFaceGateTests.appending($0, "    posix" + "_spawn(&pid, path, nil, nil, argv, nil)") : $0
        })
      (expected, path) = (1, Self.engine)
    case .existingToolRunnerConstantRead:
      let engine = try #require(files.first { $0.path == Self.engine })
      #expect(engine.text.contains(Self.toolRunner + ".terminateGraceSeconds"))
      found = Self.samplerFindings([engine])
      (expected, path) = (0, Self.engine)
    case .processInTheNetworkMonitor:
      found = Self.samplerFindings(
        files.map {
          $0.path == Self.networkMonitor
            ? PublicFaceGateTests.appending($0, "    let child = " + Self.processType + "()") : $0
        })
      (expected, path) = (1, Self.networkMonitor)
    case .toolRunnerInTheNetworkFacts:
      let reached = try Self.reachedInputs().map {
        $0.path == Self.livePort
          ? Self.planting(
            "    let runner = " + Self.toolRunner + "(timeoutSeconds: 1)",
            after: "public func facts(lidClosed: Bool?) -> NetworkFacts? {", in: $0) : $0
      }
      found = Self.reachedSpawnFindings(reached)
      (expected, path) = (1, Self.livePort)
    case .secondToolPathInTheWiFiController:
      let reached = try Self.reachedInputs().map {
        $0.path == Self.wifi ? PublicFaceGateTests.appending($0, "  static let other = \"/usr/" + "bin/pmset\"") : $0
      }
      found = Self.reachedSpawnFindings(reached)
      (expected, path) = (1, Self.wifi)
    case .toolCallInTheMarkerCheck:
      let reached = try Self.reachedInputs().map {
        $0.path == Self.wifi
          ? Self.planting(
            "    _ = " + Self.toolFactory + "1).run(Self.networksetup, [\"-getairportpower\", \"en0\"])",
            after: "public var markerKept: Bool {", in: $0) : $0
      }
      found = Self.reachedSpawnFindings(reached)
      (expected, path) = (1, Self.wifi)
    case .powerToolCallInTheMarkerCheck:
      let reached = try Self.reachedInputs().map {
        $0.path == Self.wifi
          ? Self.planting(
            "    _ = " + Self.powerTool + "interface: \"en0\", on: true)",
            after: "public var markerKept: Bool {", in: $0) : $0
      }
      found = Self.reachedSpawnFindings(reached)
      (expected, path) = (1, Self.wifi)
    }
    #expect(found.count == expected, "\(found)")
    #expect(found.allSatisfy { $0.hasPrefix(path) }, "\(found)")
  }
}
