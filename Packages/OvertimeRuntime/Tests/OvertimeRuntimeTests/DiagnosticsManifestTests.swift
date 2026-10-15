import Foundation
import OvertimeCore
import OvertimeEngine
import OvertimeHelperCore
import OvertimeSystem
import Testing

@testable import OvertimeAppSupport

struct DiagnosticsManifestTests {
  static let home = "/Users/ivan"

  static var recordedAt: Date {
    ISO8601DateFormatter().date(from: "2026-09-27T08:42:00Z") ?? Date(timeIntervalSince1970: 0)
  }

  static var fullSnapshot: EngineSnapshot {
    EngineSnapshot(
      mode: .live, busy: true, wanted: true, reason: "busy", releaseUntilIdle: true,
      pause: .untilMono(Instant(nanoseconds: 9_000), wall: recordedAt), force: .untilMono(Instant(nanoseconds: 8_000)),
      batteryBlocked: true, holdError: true, lidClosed: true,
      sessions: [
        SessionSummary(
          pid: 4_242, cwd: "/Users/ivan/work/overtime", ttyName: "ttys003", startMono: Instant(nanoseconds: 7_000)),
        SessionSummary(pid: 4_243, cwd: nil, ttyName: nil, startMono: nil),
      ],
      wantedSince: Instant(nanoseconds: 6_000), graceDeadline: Instant(nanoseconds: 6_500), batteryLowPercent: 12,
      batteryResumePercent: 25, power: .battery(percent: 64), externalDisplays: 2, coexistenceWarned: true,
      amphetamineRunning: true, otherTools: ["KeepingYouAwake"],
      events: EventCounters(
        holdErrorEpisodes: 1, holdErrorsWhileBusy: 2, batteryReleases: 3, busyStartsBelowFloor: 4, stuckReleases: 5,
        unexpectedSleeps: 6, forceSince: Instant(nanoseconds: 5_000), busyEndedAt: Instant(nanoseconds: 5_500),
        sleepRequested: true, hotspotSwitches: 7, wifiCycles: 8),
      detectionWarnings: [
        .rootMissing("/Users/ivan/.claude/projects"), .rootUnreadable("/Volumes/Work/x"), .terminalSilence,
      ],
      selfTest: .failed(.clamshellRefused(-536_870_206)), selfTestErrorActive: true, selfTestFailures: 2,
      selfTestRuns: 3, osBuild: "26A428", helperEngaged: true,
      helperFacts: HelperFacts(installed: true, reachable: true, current: false, owns: true, sleepDisabled: false),
      network: NetworkSummary(
        wired: false, wifiFound: true, onHotspot: true, switched: true, readiness: .armed(.configured),
        phase: .waitingAfterCycle))
  }

  static var fullInputs: DiagnosticsInputs {
    DiagnosticsInputs(
      homeDirectory: home, hotspot: "Ivan’s iPhone", knownNetworks: ["Office/5G"], knownNetworksRead: true,
      snapshot: fullSnapshot, loginItem: .enabled,
      helper: HelperMonitorState(
        installer: .enabled, reachability: .reachable,
        status: HelperStatus(helperVersion: 1, sleepDisabled: true, owns: true, lastReleaseReason: "lidOpen"),
        staleAttempts: 0, lastError: nil, inFlight: nil),
      selfTest: SelfTestRecord(
        outcome: .skipped, reason: "KeepingYouAwake is managing sleep, so Overtime didn't touch it.", at: recordedAt,
        osBuild: "26A428", osVersion: "27.0"),
      appVersion: "0.1.0", osVersion: "27.0", osBuild: "26A428", hardwareModel: "Mac17,6")
  }

  static func object(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  static func keys(in value: Any) -> [String] {
    if let dictionary = value as? [String: Any] {
      return dictionary.keys + dictionary.values.flatMap(keys(in:))
    }
    if let array = value as? [Any] {
      return array.flatMap(keys(in:))
    }
    return []
  }

  @Test func theFileNamesAreTheDocumentedOnes() {
    #expect(DiagnosticsManifest.snapshotFile == "snapshot.json")
    #expect(DiagnosticsManifest.selfTestFile == "self-test.json")
    #expect(DiagnosticsManifest.statusFile == "status.txt")
    #expect(DiagnosticsManifest.detectionHealthFile == "detection-health.txt")
    #expect(DiagnosticsManifest.pmsetSettingsFile == "pmset-g.txt")
    #expect(DiagnosticsManifest.pmsetAssertionsFile == "pmset-assertions.txt")
    #expect(DiagnosticsManifest.pmsetLogFile == "pmset-log.txt")
    #expect(DiagnosticsManifest.missingFile == "missing.txt")
    #expect(DiagnosticsManifest.readmeFile == "README.txt")
    #expect(DiagnosticsManifest.powerFiles == ["pmset-g.txt", "pmset-assertions.txt", "pmset-log.txt"])
    #expect(DiagnosticsManifest.helperLogFiles == ["helper.log", "helper.log.1"])
    #expect(DiagnosticsManifest.pmsetLogLines == 500)
  }

  static let readmeLines = [
    "Overtime diagnostics",
    "====================",
    "",
    "Overtime made this archive from Settings > Diagnostics > Export Diagnostics.",
    "It is meant to be attached to a bug report. Read this before you share it.",
    "",
    "What it contains",
    "",
    "- Overtime's logs, settings, preferences and saved state, and the log of",
    "  unplug protection if it is installed.",
    "- snapshot.json: what Overtime knew when the archive was made. For each",
    "  Claude Code session it lists the process ID, the working folder, the",
    "  terminal and the start time. It holds no command lines and no transcript",
    "  content.",
    "- self-test.json, status.txt and detection-health.txt: the last self-test",
    "  result, the app and macOS versions, the Mac model, the login item, the",
    "  state of unplug protection, and any problem Overtime had finding Claude",
    "  Code's sessions.",
    "- pmset-g.txt, pmset-assertions.txt and pmset-log.txt: the Mac's power",
    "  settings, its current power assertions and the last 500 lines of its",
    "  power log, as printed by three read-only pmset commands.",
    "- missing.txt, only when something could not be collected, or when a log",
    "  was too long and only its newest part is included.",
    "",
    "What was replaced",
    "",
    "- Your home folder is written as ~.",
    "- The names of your Wi-Fi networks, where Overtime could read them, are",
    "  written as <network>.",
    "- In the three pmset files, hardware addresses are written as <address>,",
    "  UUIDs as <uuid>, the names of connected devices as <device>, and the",
    "  names of drivers that were slow to sleep or wake as <driver>.",
    "",
    "What it still shows",
    "",
    "- The pmset files name the apps and system processes that were",
    "  holding power assertions when the archive was made, and those that",
    "  held one in the last 500 lines of the power log. They can show, for",
    "  example, that a meeting app or a browser was keeping the Mac or its",
    "  display awake.",
    "- Overtime's own files can name another keep-awake tool it found, such",
    "  as Amphetamine.",
    "- The names of folders inside your home folder, and the full path of",
    "  folders outside it.",
    "- The Mac model, the macOS version and the battery level.",
    "",
    "If any of this should stay private, open the files and check them before",
    "you share the archive.",
  ]

  @Test func theReadmeSaysWhatTheArchiveHoldsWhatWasReplacedAndWhatItStillShows() {
    let text = DiagnosticsManifest.readmeText
    #expect(text == Self.readmeLines.joined(separator: "\n") + "\n")
    #expect(text.split(separator: "\n", omittingEmptySubsequences: false).count == Self.readmeLines.count + 1)
    #expect(text.utf8.allSatisfy { $0 == 10 || (32...126).contains($0) })
    #expect(Self.readmeLines.allSatisfy { $0.count <= 78 })
    let files =
      [
        DiagnosticsManifest.snapshotFile, DiagnosticsManifest.selfTestFile, DiagnosticsManifest.statusFile,
        DiagnosticsManifest.detectionHealthFile, DiagnosticsManifest.missingFile,
      ] + DiagnosticsManifest.powerFiles
    for name in files {
      #expect(text.contains(name), "the README does not name \(name)")
    }
    let tokens = [
      DiagnosticsRedactor.homePlaceholder, DiagnosticsRedactor.networkPlaceholder,
      DiagnosticsPowerRedactor.addressToken, DiagnosticsPowerRedactor.uuidToken, DiagnosticsPowerRedactor.deviceToken,
      DiagnosticsPowerRedactor.driverToken,
    ]
    for token in tokens {
      #expect(text.contains(" as " + token), "the README does not explain \(token)")
    }
    #expect(text.contains("last \(DiagnosticsManifest.pmsetLogLines) lines"))
  }

  @Test func statusTextListsOneKeyAndValuePerLine() {
    let expected = [
      "app version: 0.1.0",
      "macOS version: 27.0",
      "kern.osversion: 26A428",
      "hw.model: Mac17,6",
      "login item: enabled",
      "helper state: onHolding",
      "helper installer: enabled",
      "helper reachability: reachable",
      "helper version: 1",
      "helper SleepDisabled: on",
      "helper owns SleepDisabled: yes",
      "helper engaged: yes",
      "helper last release: lidOpen",
      "helper last error: none",
      "known networks: read",
    ]
    #expect(DiagnosticsManifest.statusText(Self.fullInputs) == expected.joined(separator: "\n") + "\n")
  }

  @Test func statusTextSaysUnknownForWhatWasNotRead() {
    let expected = [
      "app version: unknown",
      "macOS version: unknown",
      "kern.osversion: unknown",
      "hw.model: unknown",
      "login item: unknown",
      "helper state: unknown",
      "helper installer: unknown",
      "helper reachability: unknown",
      "helper version: unknown",
      "helper SleepDisabled: unknown",
      "helper owns SleepDisabled: unknown",
      "helper engaged: unknown",
      "helper last release: none",
      "helper last error: none",
      "known networks: not read",
    ]
    let text = DiagnosticsManifest.statusText(DiagnosticsInputs(homeDirectory: Self.home))
    #expect(text == expected.joined(separator: "\n") + "\n")
  }

  struct HelperCase: Sendable, CustomTestStringConvertible {
    let state: HelperMonitorState
    let engaged: Bool?
    let lines: [String]

    var testDescription: String {
      lines.first ?? ""
    }
  }

  static let helperCases = [
    HelperCase(
      state: HelperMonitorState(), engaged: false,
      lines: [
        "helper state: checking", "helper installer: unknown", "helper reachability: unknown",
        "helper version: unknown", "helper SleepDisabled: unknown", "helper owns SleepDisabled: unknown",
        "helper engaged: no",
      ]),
    HelperCase(
      state: HelperMonitorState(installer: .notRegistered), engaged: nil,
      lines: ["helper state: off", "helper installer: notRegistered", "helper engaged: unknown"]),
    HelperCase(
      state: HelperMonitorState(installer: .requiresApproval), engaged: false,
      lines: ["helper state: waitingForApproval", "helper installer: requiresApproval"]),
    HelperCase(
      state: HelperMonitorState(
        installer: .enabled, reachability: .reachable,
        status: HelperStatus(helperVersion: 7, sleepDisabled: false, owns: false)), engaged: false,
      lines: [
        "helper state: onStandingBy", "helper reachability: reachable", "helper version: 7",
        "helper SleepDisabled: off", "helper owns SleepDisabled: no", "helper engaged: no",
        "helper last release: none",
      ]),
    HelperCase(
      state: HelperMonitorState(
        installer: .enabled, reachability: .reachable, status: HelperStatus(helperVersion: 1, owns: true)),
      engaged: nil,
      lines: [
        "helper state: onStandingBy", "helper engaged: unknown", "helper owns SleepDisabled: yes",
        "helper SleepDisabled: unknown",
      ]),
    HelperCase(
      state: HelperMonitorState(installer: .enabled, reachability: .unreachable), engaged: false,
      lines: ["helper state: needsApprovalAgain", "helper reachability: unreachable"]),
    HelperCase(
      state: HelperMonitorState(
        installer: .enabled, reachability: .reachable, lastError: "NSCocoaErrorDomain 4097\nline two\r\nthree"),
      engaged: false,
      lines: ["helper state: error", "helper last error: NSCocoaErrorDomain 4097 line two  three"]),
    HelperCase(
      state: HelperMonitorState(installer: .notFound, inFlight: .installing), engaged: false,
      lines: ["helper state: installing", "helper installer: notFound"]),
  ]

  @Test(arguments: helperCases)
  func statusTextNamesTheRowThePaneShowsAndWhatTheHelperReported(_ item: HelperCase) {
    var inputs = DiagnosticsInputs(homeDirectory: Self.home, helper: item.state)
    if let engaged = item.engaged {
      inputs.snapshot = EngineSnapshot(helperEngaged: engaged)
    }
    let lines = DiagnosticsManifest.statusText(inputs).split(separator: "\n").map(String.init)
    #expect(lines.count == 15)
    for line in item.lines {
      #expect(lines.contains(line), "missing \(line)")
    }
  }

  @Test(arguments: [
    (LoginItemStatus.enabled, "enabled"), (.requiresApproval, "requiresApproval"), (.notRegistered, "notRegistered"),
    (.notFound, "notFound"),
  ])
  func statusTextNamesTheLoginItemStatus(_ status: LoginItemStatus, _ word: String) {
    let text = DiagnosticsManifest.statusText(DiagnosticsInputs(homeDirectory: Self.home, loginItem: status))
    #expect(text.contains("\nlogin item: " + word + "\n"))
  }

  @Test func textThatIsMissingOrEmptyReadsNoneAndLineBreaksBecomeSpaces() {
    #expect(DiagnosticsManifest.oneLine(nil) == "none")
    #expect(DiagnosticsManifest.oneLine("") == "none")
    #expect(DiagnosticsManifest.oneLine("a\nb\rc") == "a b c")
    #expect(DiagnosticsManifest.unknown == "unknown")
    #expect(DiagnosticsManifest.none == "none")
  }

  struct FlagCase: Sendable, CustomTestStringConvertible {
    let snapshot: EngineSnapshot
    let path: String

    var testDescription: String {
      path
    }
  }

  static func facts(installed: Bool = false, reachable: Bool = false, current: Bool = false) -> HelperFacts {
    HelperFacts(installed: installed, reachable: reachable, current: current, owns: false, sleepDisabled: false)
  }

  static let flagCases = [
    FlagCase(snapshot: EngineSnapshot(busy: true), path: "busy"),
    FlagCase(snapshot: EngineSnapshot(wanted: true), path: "wanted"),
    FlagCase(snapshot: EngineSnapshot(releaseUntilIdle: true), path: "releaseUntilIdle"),
    FlagCase(snapshot: EngineSnapshot(batteryBlocked: true), path: "batteryBlocked"),
    FlagCase(snapshot: EngineSnapshot(holdError: true), path: "holdError"),
    FlagCase(snapshot: EngineSnapshot(lidClosed: true), path: "lidClosed"),
    FlagCase(snapshot: EngineSnapshot(coexistenceWarned: true), path: "coexistenceWarned"),
    FlagCase(snapshot: EngineSnapshot(amphetamineRunning: true), path: "amphetamineRunning"),
    FlagCase(snapshot: EngineSnapshot(events: EventCounters(sleepRequested: true)), path: "counters.sleepRequested"),
    FlagCase(snapshot: EngineSnapshot(selfTestErrorActive: true), path: "selfTest.errorActive"),
    FlagCase(snapshot: EngineSnapshot(helperEngaged: true), path: "helper.engaged"),
    FlagCase(snapshot: EngineSnapshot(helperFacts: facts(installed: true)), path: "helper.installed"),
    FlagCase(snapshot: EngineSnapshot(helperFacts: facts(reachable: true)), path: "helper.reachable"),
    FlagCase(snapshot: EngineSnapshot(helperFacts: facts(current: true)), path: "helper.current"),
    FlagCase(
      snapshot: EngineSnapshot(
        helperFacts: HelperFacts(installed: false, reachable: false, current: false, owns: true)),
      path: "helper.owns"),
    FlagCase(
      snapshot: EngineSnapshot(
        helperFacts: HelperFacts(installed: false, reachable: false, current: false, sleepDisabled: true)),
      path: "helper.sleepDisabled"),
  ]

  static func truths(in value: Any, under prefix: String = "") -> [String] {
    guard let dictionary = value as? [String: Any] else { return [] }
    return dictionary.flatMap { key, value -> [String] in
      if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
        return number.boolValue ? [prefix + key] : []
      }
      return truths(in: value, under: prefix + key + ".")
    }
  }

  @Test(arguments: flagCases)
  func eachFlagOfTheSnapshotIsEncodedUnderItsOwnKey(_ item: FlagCase) throws {
    let object = try Self.object(DiagnosticsManifest.snapshotJSON(item.snapshot))
    #expect(Self.truths(in: object) == [item.path])
  }

  @Test func detectionHealthTextListsEachWarningWithAHomeAbbreviatedPath() {
    let text = DiagnosticsManifest.detectionHealthText(Self.fullSnapshot.detectionWarnings, homeDirectory: Self.home)
    #expect(
      text == "rootMissing: ~/.claude/projects\nrootUnreadable: /Volumes/Work/x\nterminalSilence\n")
    #expect(DiagnosticsManifest.detectionHealthText([], homeDirectory: Self.home) == "No detection problems found.\n")
    #expect(DiagnosticsManifest.noDetectionProblems == "No detection problems found.")
  }

  @Test func aForeignCaffeinateIsExportedWithTheNameOfItsStarterAndNothingElseAboutIt() throws {
    var state = AppState(mode: .live)
    state.coexistence.warned = true
    let snapshot = EngineSnapshot(
      state: state,
      coexistence: CoexistenceFacts(foreignAssertions: [
        ForeignAssertion(
          pid: 90696, type: "PreventUserIdleSystemSleep", processName: "caffeinate", parentName: "python3")
      ]))
    let data = DiagnosticsManifest.snapshotJSON(snapshot)
    let object = try Self.object(data)
    #expect(object["otherTools"] as? [String] == ["caffeinate (started by python3)"])
    #expect(!Self.keys(in: object).contains { $0.lowercased().contains("parent") })
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(!text.contains("90696"))
  }

  @Test func snapshotJSONEncodesTheDocumentedFieldsAndNothingAboutArgumentsOrExecutables() throws {
    let object = try Self.object(DiagnosticsManifest.snapshotJSON(Self.fullSnapshot))
    #expect(
      Set(object.keys) == [
        "mode", "busy", "wanted", "reason", "releaseUntilIdle", "pause", "force", "batteryBlocked",
        "batteryLowPercent", "batteryResumePercent", "power", "holdError", "lidClosed", "externalDisplays",
        "wantedSince", "graceDeadline", "coexistenceWarned", "amphetamineRunning", "otherTools", "counters",
        "detectionWarnings", "selfTest", "helper", "network", "sessions",
      ])
    for key in Self.keys(in: object).map({ $0.lowercased() }) {
      for word in ["arg", "exec", "command", "path", "transcript"] {
        #expect(!key.contains(word), "\(key) names \(word)")
      }
    }
    #expect(object["mode"] as? String == "live")
    #expect(object["busy"] as? Bool == true)
    #expect(object["wanted"] as? Bool == true)
    #expect(object["reason"] as? String == "busy")
    #expect(object["releaseUntilIdle"] as? Bool == true)
    #expect(object["batteryBlocked"] as? Bool == true)
    #expect(object["batteryLowPercent"] as? Int == 12)
    #expect(object["batteryResumePercent"] as? Int == 25)
    #expect(object["holdError"] as? Bool == true)
    #expect(object["lidClosed"] as? Bool == true)
    #expect(object["externalDisplays"] as? Int == 2)
    #expect(object["wantedSince"] as? Int == 6_000)
    #expect(object["graceDeadline"] as? Int == 6_500)
    #expect(object["coexistenceWarned"] as? Bool == true)
    #expect(object["amphetamineRunning"] as? Bool == true)
    #expect(object["otherTools"] as? [String] == ["KeepingYouAwake"])
    #expect(
      object["detectionWarnings"] as? [String]
        == ["rootMissing: /Users/ivan/.claude/projects", "rootUnreadable: /Volumes/Work/x", "terminalSilence"])
    let pause = try #require(object["pause"] as? [String: Any])
    #expect(pause["kind"] as? String == "untilMono")
    #expect(pause["untilMono"] as? Int == 9_000)
    #expect(pause["untilWall"] as? String == "2026-09-27T08:42:00Z")
    let force = try #require(object["force"] as? [String: Any])
    #expect(force["kind"] as? String == "untilMono")
    #expect(force["untilMono"] as? Int == 8_000)
    let power = try #require(object["power"] as? [String: Any])
    #expect(power["source"] as? String == "battery")
    #expect(power["percent"] as? Int == 64)
    let counters = try #require(object["counters"] as? [String: Any])
    #expect(
      Set(counters.keys) == [
        "holdErrorEpisodes", "holdErrorsWhileBusy", "batteryReleases", "busyStartsBelowFloor", "stuckReleases",
        "unexpectedSleeps", "forceSince", "busyEndedAt", "sleepRequested", "hotspotSwitches", "wifiCycles",
      ])
    #expect(counters["hotspotSwitches"] as? Int == 7)
    #expect(counters["wifiCycles"] as? Int == 8)
    #expect(counters["holdErrorEpisodes"] as? Int == 1)
    #expect(counters["holdErrorsWhileBusy"] as? Int == 2)
    #expect(counters["batteryReleases"] as? Int == 3)
    #expect(counters["busyStartsBelowFloor"] as? Int == 4)
    #expect(counters["stuckReleases"] as? Int == 5)
    #expect(counters["unexpectedSleeps"] as? Int == 6)
    #expect(counters["forceSince"] as? Int == 5_000)
    #expect(counters["busyEndedAt"] as? Int == 5_500)
    #expect(counters["sleepRequested"] as? Bool == true)
    let selfTest = try #require(object["selfTest"] as? [String: Any])
    #expect(selfTest["status"] as? String == "failed")
    #expect(selfTest["detail"] as? String == "clamshellRefused")
    #expect(selfTest["code"] as? Int == -536_870_206)
    #expect(selfTest["errorActive"] as? Bool == true)
    #expect(selfTest["failures"] as? Int == 2)
    #expect(selfTest["runs"] as? Int == 3)
    #expect(selfTest["osBuild"] as? String == "26A428")
    let helper = try #require(object["helper"] as? [String: Any])
    #expect(helper["engaged"] as? Bool == true)
    #expect(helper["installed"] as? Bool == true)
    #expect(helper["reachable"] as? Bool == true)
    #expect(helper["current"] as? Bool == false)
    #expect(helper["owns"] as? Bool == true)
    #expect(helper["sleepDisabled"] as? Bool == false)
    let network = try #require(object["network"] as? [String: Any])
    #expect(Set(network.keys) == Self.networkKeys)
    #expect(network["wired"] as? Bool == false)
    #expect(network["wifiFound"] as? Bool == true)
    #expect(network["onHotspot"] as? Bool == true)
    #expect(network["switched"] as? Bool == true)
    #expect(network["failover"] as? String == "armed")
    #expect(network["reason"] as? String == "configured")
    #expect(network["phase"] as? String == "waitingAfterCycle")
  }

  static let networkKeys: Set<String> = ["wired", "wifiFound", "onHotspot", "switched", "failover", "reason", "phase"]

  struct NetworkCase: Sendable, CustomTestStringConvertible {
    let readiness: NetReadiness?
    let failover: String?
    let reason: String?

    var testDescription: String {
      (failover ?? "null") + " " + (reason ?? "null")
    }
  }

  static let networkCases =
    [
      NetworkCase(readiness: .armed(.configured), failover: "armed", reason: "configured"),
      NetworkCase(readiness: .armed(.auto), failover: "armed", reason: "auto"),
      NetworkCase(readiness: nil, failover: nil, reason: nil),
    ] + NetOffReason.allCases.map { NetworkCase(readiness: .off($0), failover: "off", reason: $0.rawValue) }

  @Test(arguments: networkCases)
  func theNetworkObjectNamesTheFailoverAndItsReasonOrNull(_ item: NetworkCase) throws {
    let snapshot = EngineSnapshot(network: NetworkSummary(readiness: item.readiness, phase: .joining))
    let object = try Self.object(DiagnosticsManifest.snapshotJSON(snapshot))
    let network = try #require(object["network"] as? [String: Any])
    #expect(Set(network.keys) == Self.networkKeys)
    #expect(network["failover"] as? String == item.failover)
    #expect(network["reason"] as? String == item.reason)
    #expect((network["failover"] is NSNull) == (item.failover == nil))
    #expect((network["reason"] is NSNull) == (item.reason == nil))
    #expect(network["wired"] is NSNull)
    #expect(network["onHotspot"] is NSNull)
    #expect(network["wifiFound"] as? Bool == false)
    #expect(network["switched"] as? Bool == false)
    #expect(network["phase"] as? String == "joining")
  }

  @Test func aSnapshotBuiltFromAHotspotNameEncodesNoFormOfIt() throws {
    let name = ["Zo", "\u{EB}", "\u{2019}", "s iPhone"].joined()
    var state = AppState(mode: .live)
    state.network.facts = NetworkFacts(
      wifiInterface: "en0", onHotspot: true, wired: false, wifiPowered: true, autoHotspot: name)
    state.persisted.switchedToHotspot = true
    for settings in [Settings(hotspot: name), Settings(hotspotAutoDetect: true)] {
      let snapshot = EngineSnapshot(state: state, settings: settings)
      #expect(snapshot.network?.readiness != nil)
      let text = String(decoding: DiagnosticsManifest.snapshotJSON(snapshot), as: UTF8.self)
      #expect(text.contains("\"network\""))
      for form in [
        name, ["Zo", "\u{EB}"].joined(), "iPhone", ["\\", "u2019"].joined(), ["\\", "u00eb"].joined(),
        ["\\", "u00EB"].joined(), "Zo",
      ] {
        #expect(!text.contains(form), "snapshot.json carries \(form)")
      }
    }
  }

  @Test func aSessionCarriesOnlyItsPidFolderTerminalAndStart() throws {
    let object = try Self.object(DiagnosticsManifest.snapshotJSON(Self.fullSnapshot))
    let sessions = try #require(object["sessions"] as? [[String: Any]])
    #expect(sessions.count == 2)
    #expect(Set(sessions[0].keys) == ["pid", "cwd", "tty", "start"])
    #expect(sessions[0]["pid"] as? Int == 4_242)
    #expect(sessions[0]["cwd"] as? String == "/Users/ivan/work/overtime")
    #expect(sessions[0]["tty"] as? String == "ttys003")
    #expect(sessions[0]["start"] as? Int == 7_000)
    #expect(Set(sessions[1].keys) == ["pid"])
    #expect(sessions[1]["pid"] as? Int == 4_243)
  }

  struct SnapshotCase: Sendable, CustomTestStringConvertible {
    let snapshot: EngineSnapshot
    let key: String
    let expected: [String: String]

    var testDescription: String {
      key + " " + expected.values.sorted().joined(separator: " ")
    }
  }

  static let snapshotCases = [
    SnapshotCase(snapshot: EngineSnapshot(mode: .shadow), key: "mode", expected: ["mode": "shadow"]),
    SnapshotCase(snapshot: EngineSnapshot(pause: .indefinite), key: "pause", expected: ["kind": "indefinite"]),
    SnapshotCase(
      snapshot: EngineSnapshot(pause: .untilWall(recordedAt)), key: "pause",
      expected: ["kind": "untilWall", "untilWall": "2026-09-27T08:42:00Z"]),
    SnapshotCase(snapshot: EngineSnapshot(force: .indefinite), key: "force", expected: ["kind": "indefinite"]),
    SnapshotCase(snapshot: EngineSnapshot(power: .ac(percent: nil)), key: "power", expected: ["source": "ac"]),
    SnapshotCase(snapshot: EngineSnapshot(power: .noBattery), key: "power", expected: ["source": "noBattery"]),
    SnapshotCase(snapshot: EngineSnapshot(selfTest: .notRun), key: "selfTest", expected: ["status": "notRun"]),
    SnapshotCase(snapshot: EngineSnapshot(selfTest: .waiting), key: "selfTest", expected: ["status": "waiting"]),
    SnapshotCase(snapshot: EngineSnapshot(selfTest: .running), key: "selfTest", expected: ["status": "running"]),
    SnapshotCase(snapshot: EngineSnapshot(selfTest: .passed), key: "selfTest", expected: ["status": "passed"]),
    SnapshotCase(
      snapshot: EngineSnapshot(selfTest: .failed(.assertionRefused(5))), key: "selfTest",
      expected: ["status": "failed", "detail": "assertionRefused"]),
    SnapshotCase(
      snapshot: EngineSnapshot(selfTest: .failed(.timedOut)), key: "selfTest",
      expected: ["status": "failed", "detail": "timedOut"]),
    SnapshotCase(
      snapshot: EngineSnapshot(selfTest: .failed(.watchdogNotRunning)), key: "selfTest",
      expected: ["status": "failed", "detail": "watchdogNotRunning"]),
    SnapshotCase(
      snapshot: EngineSnapshot(selfTest: .failed(.stateNotSaved)), key: "selfTest",
      expected: ["status": "failed", "detail": "stateNotSaved"]),
    SnapshotCase(
      snapshot: EngineSnapshot(selfTest: .skipped(.amphetamine)), key: "selfTest",
      expected: ["status": "skipped", "detail": "amphetamine"]),
    SnapshotCase(
      snapshot: EngineSnapshot(selfTest: .skipped(.otherTool("Lungo"))), key: "selfTest",
      expected: ["status": "skipped", "detail": "otherTool Lungo"]),
    SnapshotCase(
      snapshot: EngineSnapshot(selfTest: .skipped(.sleepDisabled)), key: "selfTest",
      expected: ["status": "skipped", "detail": "sleepDisabled"]),
  ]

  @Test(arguments: snapshotCases)
  func snapshotJSONNamesEachModeOverridePowerSourceAndSelfTestResult(_ item: SnapshotCase) throws {
    let object = try Self.object(DiagnosticsManifest.snapshotJSON(item.snapshot))
    if let text = object[item.key] as? String {
      #expect([item.key: text] == item.expected)
    } else {
      let nested = try #require(object[item.key] as? [String: Any])
      let strings = nested.compactMapValues { $0 as? String }
      #expect(strings == item.expected)
    }
  }

  @Test func anEmptySnapshotLeavesOutWhatIsNotKnown() throws {
    let object = try Self.object(DiagnosticsManifest.snapshotJSON(EngineSnapshot()))
    #expect(
      Set(object.keys) == [
        "mode", "releaseUntilIdle", "batteryBlocked", "batteryLowPercent", "batteryResumePercent", "holdError",
        "coexistenceWarned", "amphetamineRunning", "otherTools", "counters", "detectionWarnings", "selfTest", "helper",
        "sessions",
      ])
    #expect((object["helper"] as? [String: Any])?.keys.sorted() == ["engaged"])
    #expect((object["selfTest"] as? [String: Any])?.keys.sorted() == ["errorActive", "failures", "runs", "status"])
    #expect(object["sessions"] as? [[String: Any]] != nil)
    #expect((object["sessions"] as? [Any])?.isEmpty == true)
    let code = try Self.object(
      DiagnosticsManifest.snapshotJSON(EngineSnapshot(selfTest: .failed(.assertionRefused(5)))))
    #expect((code["selfTest"] as? [String: Any])?["code"] as? Int == 5)
  }

  @Test func snapshotJSONIsSortedReadableAndKeepsSlashesPlain() {
    let text = String(decoding: DiagnosticsManifest.snapshotJSON(Self.fullSnapshot), as: UTF8.self)
    #expect(text.contains("\"cwd\" : \"/Users/ivan/work/overtime\""))
    #expect(text.hasPrefix("{\n  \"amphetamineRunning\" : true,\n"))
    #expect(text.hasSuffix("}\n"))
  }

  @Test func selfTestJSONIsTheStoredRecord() throws {
    let record = try #require(Self.fullInputs.selfTest)
    let data = DiagnosticsManifest.selfTestJSON(record)
    let object = try Self.object(data)
    #expect(Set(object.keys) == ["outcome", "reason", "at", "osBuild", "osVersion"])
    #expect(object["outcome"] as? String == "skipped")
    #expect(object["reason"] as? String == "KeepingYouAwake is managing sleep, so Overtime didn't touch it.")
    #expect(object["at"] as? String == "2026-09-27T08:42:00Z")
    #expect(object["osBuild"] as? String == "26A428")
    #expect(object["osVersion"] as? String == "27.0")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    #expect(try decoder.decode(SelfTestRecord.self, from: data) == record)
    #expect(String(decoding: data, as: UTF8.self).hasSuffix("}\n"))
  }

  @Test func pmsetLogTailKeepsTheLast500LinesOfA27830LineInput() {
    let lines = (1...27_830).map { "2026-09-27 10:00:00 +0200 Assertions line \($0)" }
    let tail = DiagnosticsManifest.pmsetLogTail(lines.joined(separator: "\n") + "\n")
    #expect(tail == lines.suffix(500).joined(separator: "\n") + "\n")
    #expect(tail.split(separator: "\n").count == 500)
    #expect(tail.hasPrefix("2026-09-27 10:00:00 +0200 Assertions line 27331\n"))
  }

  struct TailCase: Sendable, CustomTestStringConvertible {
    let input: String
    let lines: Int
    let output: String

    var testDescription: String {
      "\(lines) of " + input.replacingOccurrences(of: "\n", with: "|")
    }
  }

  @Test(arguments: [
    TailCase(input: "", lines: 2, output: ""),
    TailCase(input: "a", lines: 2, output: "a"),
    TailCase(input: "a\n", lines: 2, output: "a\n"),
    TailCase(input: "a\nb", lines: 2, output: "a\nb"),
    TailCase(input: "a\nb\n", lines: 2, output: "a\nb\n"),
    TailCase(input: "a\nb\nc", lines: 2, output: "b\nc"),
    TailCase(input: "a\nb\nc\n", lines: 2, output: "b\nc\n"),
    TailCase(input: "a\nb\nc\n", lines: 1, output: "c\n"),
    TailCase(input: "a\n\n\nb\n", lines: 2, output: "\nb\n"),
    TailCase(input: "a\nb\nc\n", lines: 0, output: ""),
    TailCase(input: "é\nü\nñ", lines: 2, output: "ü\nñ"),
  ])
  func pmsetLogTailKeepsWholeLinesFromTheEnd(_ item: TailCase) {
    #expect(DiagnosticsManifest.pmsetLogTail(item.input, lines: item.lines) == item.output)
  }

  @Test func missingTextListsEachGapOnItsOwnLine() {
    let gaps = [
      DiagnosticsGap(name: "state.json", reason: "not found", kind: .absent),
      DiagnosticsGap(name: "pmset-log.txt", reason: "the command timed out", kind: .failed),
    ]
    #expect(
      DiagnosticsManifest.missingText(gaps) == "state.json: not found\npmset-log.txt: the command timed out\n")
    #expect(DiagnosticsManifest.missingText([]) == "")
  }
}
