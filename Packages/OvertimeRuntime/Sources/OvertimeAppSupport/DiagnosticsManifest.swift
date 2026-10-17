import Foundation
import OvertimeCore
import OvertimeEngine
import OvertimeHelperCore
import OvertimeSystem

public struct DiagnosticsGap: Sendable, Equatable {
  public enum Kind: Sendable, Equatable {
    case absent
    case cut
    case failed
  }

  public static let notFound = "not found"
  public static let notRegular = "not a regular file"
  public static let unreadable = "could not be read"
  public static let notSettings = "does not decode as settings and was left out"
  public static let noSnapshot = "the engine has published no snapshot"
  public static let noSelfTest = "no self-test result is stored"
  public static let timedOut = "the command timed out"
  public static let notStarted = "the command could not be started"

  public static func tooLarge(_ bytes: Int) -> String {
    "larger than \(bytes) bytes"
  }

  public static func onlyTail(_ bytes: Int) -> String {
    "only the last \(bytes) bytes"
  }

  public static func exited(_ status: Int32) -> String {
    "the command exited with status \(status)"
  }

  public var name: String
  public var reason: String
  public var kind: Kind

  public init(name: String, reason: String, kind: Kind) {
    self.name = name
    self.reason = reason
    self.kind = kind
  }
}

public enum DiagnosticsManifest {
  struct SnapshotExport: Encodable {
    struct Override: Encodable {
      var kind: String
      var untilMono: UInt64?
      var untilWall: Date?
    }

    struct Power: Encodable {
      var source: String
      var percent: Int?
    }

    struct Counters: Encodable {
      var holdErrorEpisodes: UInt64
      var holdErrorsWhileBusy: UInt64
      var batteryReleases: UInt64
      var busyStartsBelowFloor: UInt64
      var stuckReleases: UInt64
      var unexpectedSleeps: UInt64
      var forceSince: UInt64?
      var busyEndedAt: UInt64?
      var sleepRequested: Bool
      var hotspotSwitches: UInt64
      var wifiCycles: UInt64
      var temperatureReleases: UInt64
    }

    struct Network: Encodable {
      enum CodingKeys: String, CodingKey {
        case wired, wifiFound, onHotspot, switched, failover, reason, phase
      }

      var wired: Bool?
      var wifiFound: Bool
      var onHotspot: Bool?
      var switched: Bool
      var failover: String?
      var reason: String?
      var phase: String

      func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(wired, forKey: .wired)
        try container.encode(wifiFound, forKey: .wifiFound)
        try container.encode(onHotspot, forKey: .onHotspot)
        try container.encode(switched, forKey: .switched)
        try container.encode(failover, forKey: .failover)
        try container.encode(reason, forKey: .reason)
        try container.encode(phase, forKey: .phase)
      }
    }

    struct SelfTest: Encodable {
      var status: String
      var detail: String?
      var code: Int32?
      var errorActive: Bool
      var failures: UInt64
      var runs: UInt64
      var osBuild: String?
    }

    struct Helper: Encodable {
      var engaged: Bool
      var installed: Bool?
      var reachable: Bool?
      var current: Bool?
      var owns: Bool?
      var sleepDisabled: Bool?
    }

    struct Session: Encodable {
      var pid: Int32
      var cwd: String?
      var tty: String?
      var start: UInt64?
    }

    var mode: String
    var busy: Bool?
    var wanted: Bool?
    var reason: String?
    var releaseUntilIdle: Bool
    var pause: Override?
    var force: Override?
    var batteryBlocked: Bool
    var batteryLowPercent: Int
    var batteryResumePercent: Int
    var power: Power?
    var holdError: Bool
    var lidClosed: Bool?
    var externalDisplays: Int?
    var wantedSince: UInt64?
    var graceDeadline: UInt64?
    var coexistenceWarned: Bool
    var amphetamineRunning: Bool
    var otherTools: [String]
    var counters: Counters
    var detectionWarnings: [String]
    var selfTest: SelfTest
    var helper: Helper
    var network: Network?
    var sessions: [Session]
    var batteryProtectionEnabled: Bool
    var helperBatteryFloorPercent: Int
    var temperatureProtectionEnabled: Bool
    var temperatureReleaseCelsius: Int
    var temperatureBlocked: Bool
    var batteryTemperature: String?
    var lidClosedKeepAwake: String
    var lidClosedHoldAllowed: Bool
  }

  public static let snapshotFile = "snapshot.json"
  public static let selfTestFile = "self-test.json"
  public static let statusFile = "status.txt"
  public static let detectionHealthFile = "detection-health.txt"
  public static let pmsetSettingsFile = "pmset-g.txt"
  public static let pmsetAssertionsFile = "pmset-assertions.txt"
  public static let pmsetLogFile = "pmset-log.txt"
  public static let missingFile = "missing.txt"
  public static let readmeFile = "README.txt"
  public static let powerFiles = [pmsetSettingsFile, pmsetAssertionsFile, pmsetLogFile]
  public static let exportCommand = "Export Diagnostics"
  public static let exportLabel = exportCommand + "…"
  public static let readmeText = """
    Overtime diagnostics
    ====================

    Overtime made this archive from Settings > Diagnostics > \(exportCommand).
    It is meant to be attached to a bug report. Read this before you share it.

    What it contains

    - Overtime's logs, settings, preferences and saved state, and the log of
      unplug protection if it is installed.
    - snapshot.json: what Overtime knew when the archive was made. For each
      Claude Code session it lists the process ID, the working folder, the
      terminal and the start time. It holds no command lines and no transcript
      content.
    - self-test.json, status.txt and detection-health.txt: the last self-test
      result, the app and macOS versions, the Mac model, the login item, the
      state of unplug protection, and any problem Overtime had finding Claude
      Code's sessions.
    - pmset-g.txt, pmset-assertions.txt and pmset-log.txt: the Mac's power
      settings, its current power assertions and the last 500 lines of its
      power log, as printed by three read-only pmset commands.
    - missing.txt, only when something could not be collected, or when a log
      was too long and only its newest part is included.

    What was replaced

    - Your home folder is written as ~.
    - The names of your Wi-Fi networks, where Overtime could read them, are
      written as <network>.
    - In the three pmset files, hardware addresses are written as <address>,
      UUIDs as <uuid>, the names of connected devices as <device>, and the
      names of drivers that were slow to sleep or wake as <driver>.

    What it still shows

    - The pmset files name the apps and system processes that were
      holding power assertions when the archive was made, and those that
      held one in the last 500 lines of the power log. They can show, for
      example, that a meeting app or a browser was keeping the Mac or its
      display awake.
    - Overtime's own files can name another keep-awake tool it found, such
      as Amphetamine.
    - The names of folders inside your home folder, and the full path of
      folders outside it.
    - The Mac model, the macOS version, the battery level and the battery
      temperature.

    If any of this should stay private, open the files and check them before
    you share the archive.

    """
  public static let helperLogFiles = [HelperLog.fileName, HelperLog.rotatedFileName]
  public static let pmsetLogLines = 500
  public static let noDetectionProblems = "No detection problems found."
  public static let unknown = "unknown"
  public static let none = "none"

  public static func statusText(_ inputs: DiagnosticsInputs) -> String {
    let helper = inputs.helper
    let status = helper?.status
    let engaged = inputs.snapshot?.helperEngaged
    let row = helper.map { HelperStatusPresentation.derive($0, engaged: engaged ?? false) }
    let lines = [
      ("app version", inputs.appVersion),
      ("macOS version", inputs.osVersion),
      ("kern.osversion", inputs.osBuild ?? unknown),
      ("hw.model", inputs.hardwareModel ?? unknown),
      ("login item", word(inputs.loginItem)),
      ("helper state", word(row)),
      ("helper installer", word(helper?.installer)),
      ("helper reachability", word(helper?.reachability)),
      ("helper version", word(status?.helperVersion)),
      ("helper SleepDisabled", flag(status?.sleepDisabled, yes: "on", no: "off")),
      ("helper owns SleepDisabled", flag(status?.owns, yes: "yes", no: "no")),
      ("helper engaged", flag(engaged, yes: "yes", no: "no")),
      ("helper last release", oneLine(status?.lastReleaseReason)),
      ("helper last error", oneLine(helper?.lastError)),
      ("known networks", inputs.knownNetworksRead ? "read" : "not read"),
    ]
    return lines.map { $0.0 + ": " + $0.1 + "\n" }.joined()
  }

  public static func detectionHealthText(_ warnings: [DetectionWarning], homeDirectory: String) -> String {
    guard !warnings.isEmpty else { return noDetectionProblems + "\n" }
    return warnings.map { warningText($0, homeDirectory: homeDirectory) + "\n" }.joined()
  }

  public static func snapshotJSON(_ snapshot: EngineSnapshot) -> Data {
    encoded(export(snapshot))
  }

  public static func selfTestJSON(_ record: SelfTestRecord) -> Data {
    encoded(record)
  }

  public static func pmsetLogTail(_ text: String, lines: Int = DiagnosticsManifest.pmsetLogLines) -> String {
    guard lines > 0 else { return "" }
    let bytes = Array(text.utf8)
    var remaining = lines
    var index = bytes.count
    if bytes.last == UInt8(ascii: "\n") { index -= 1 }
    while index > 0 {
      if bytes[index - 1] == UInt8(ascii: "\n") {
        remaining -= 1
        if remaining == 0 { break }
      }
      index -= 1
    }
    return String(decoding: bytes[index...], as: UTF8.self)
  }

  public static func missingText(_ gaps: [DiagnosticsGap]) -> String {
    gaps.map { $0.name + ": " + $0.reason + "\n" }.joined()
  }

  static func warningText(_ warning: DetectionWarning, homeDirectory: String?) -> String {
    let path = warning.path.map { path in
      ": " + (homeDirectory.map { PanelContent.abbreviatingHome(path, homeDirectory: $0) } ?? path)
    }
    switch warning {
    case .rootMissing: return "rootMissing" + (path ?? "")
    case .rootUnreadable: return "rootUnreadable" + (path ?? "")
    case .terminalSilence: return "terminalSilence"
    }
  }

  static func word<Value>(_ value: Value?) -> String {
    value.map { String(describing: $0) } ?? unknown
  }

  static func flag(_ value: Bool?, yes: String, no: String) -> String {
    value.map { $0 ? yes : no } ?? unknown
  }

  static func oneLine(_ text: String?) -> String {
    guard let text, !text.isEmpty else { return none }
    return text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
  }

  static func encoded(_ value: some Encodable) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return ((try? encoder.encode(value)) ?? Data("{}".utf8)) + Data("\n".utf8)
  }

  static func export(_ snapshot: EngineSnapshot) -> SnapshotExport {
    let facts = snapshot.helperFacts
    return SnapshotExport(
      mode: snapshot.mode.rawValue, busy: snapshot.busy, wanted: snapshot.wanted, reason: snapshot.reason,
      releaseUntilIdle: snapshot.releaseUntilIdle, pause: snapshot.pause.map(export), force: snapshot.force.map(export),
      batteryBlocked: snapshot.batteryBlocked, batteryLowPercent: snapshot.batteryLowPercent,
      batteryResumePercent: snapshot.batteryResumePercent, power: snapshot.power.map(export),
      holdError: snapshot.holdError, lidClosed: snapshot.lidClosed, externalDisplays: snapshot.externalDisplays,
      wantedSince: snapshot.wantedSince?.nanoseconds, graceDeadline: snapshot.graceDeadline?.nanoseconds,
      coexistenceWarned: snapshot.coexistenceWarned, amphetamineRunning: snapshot.amphetamineRunning,
      otherTools: snapshot.otherTools,
      counters: SnapshotExport.Counters(
        holdErrorEpisodes: snapshot.events.holdErrorEpisodes, holdErrorsWhileBusy: snapshot.events.holdErrorsWhileBusy,
        batteryReleases: snapshot.events.batteryReleases, busyStartsBelowFloor: snapshot.events.busyStartsBelowFloor,
        stuckReleases: snapshot.events.stuckReleases, unexpectedSleeps: snapshot.events.unexpectedSleeps,
        forceSince: snapshot.events.forceSince?.nanoseconds, busyEndedAt: snapshot.events.busyEndedAt?.nanoseconds,
        sleepRequested: snapshot.events.sleepRequested, hotspotSwitches: snapshot.events.hotspotSwitches,
        wifiCycles: snapshot.events.wifiCycles, temperatureReleases: snapshot.events.temperatureReleases),
      detectionWarnings: snapshot.detectionWarnings.map { warningText($0, homeDirectory: nil) },
      selfTest: export(snapshot.selfTest, snapshot: snapshot),
      helper: SnapshotExport.Helper(
        engaged: snapshot.helperEngaged, installed: facts?.installed, reachable: facts?.reachable,
        current: facts?.current, owns: facts?.owns, sleepDisabled: facts?.sleepDisabled),
      network: snapshot.network.map(export),
      sessions: snapshot.sessions.map {
        SnapshotExport.Session(pid: $0.pid, cwd: $0.cwd, tty: $0.ttyName, start: $0.startMono?.nanoseconds)
      },
      batteryProtectionEnabled: snapshot.batteryProtectionEnabled,
      helperBatteryFloorPercent: snapshot.helperBatteryFloorPercent,
      temperatureProtectionEnabled: snapshot.temperatureProtectionEnabled,
      temperatureReleaseCelsius: snapshot.temperatureReleaseCelsius, temperatureBlocked: snapshot.temperatureBlocked,
      batteryTemperature: snapshot.batteryTemperature.map(export),
      lidClosedKeepAwake: snapshot.lidClosedKeepAwake.rawValue, lidClosedHoldAllowed: snapshot.lidClosedHoldAllowed)
  }

  static func export(_ reading: BatteryTemperatureReading) -> String {
    switch reading {
    case .celsius(let celsius): String(celsius)
    case .unavailable: "unavailable"
    case .unreadable: "unreadable"
    }
  }

  static func export(_ network: NetworkSummary) -> SnapshotExport.Network {
    let failover: String?
    let reason: String?
    switch network.readiness {
    case .armed(let source)?:
      failover = "armed"
      reason = source.rawValue
    case .off(let offReason)?:
      failover = "off"
      reason = offReason.rawValue
    case nil:
      failover = nil
      reason = nil
    }
    return SnapshotExport.Network(
      wired: network.wired, wifiFound: network.wifiFound, onHotspot: network.onHotspot, switched: network.switched,
      failover: failover, reason: reason, phase: network.phase.rawValue)
  }

  static func export(_ pause: PauseState) -> SnapshotExport.Override {
    switch pause {
    case .untilMono(let instant, let wall):
      SnapshotExport.Override(kind: "untilMono", untilMono: instant.nanoseconds, untilWall: wall)
    case .untilWall(let wall):
      SnapshotExport.Override(kind: "untilWall", untilMono: nil, untilWall: wall)
    case .indefinite:
      SnapshotExport.Override(kind: "indefinite", untilMono: nil, untilWall: nil)
    }
  }

  static func export(_ force: ForceState) -> SnapshotExport.Override {
    switch force {
    case .untilMono(let instant):
      SnapshotExport.Override(kind: "untilMono", untilMono: instant.nanoseconds, untilWall: nil)
    case .indefinite:
      SnapshotExport.Override(kind: "indefinite", untilMono: nil, untilWall: nil)
    }
  }

  static func export(_ power: PowerReading) -> SnapshotExport.Power {
    switch power {
    case .ac(let percent): SnapshotExport.Power(source: "ac", percent: percent)
    case .battery(let percent): SnapshotExport.Power(source: "battery", percent: percent)
    case .noBattery: SnapshotExport.Power(source: "noBattery", percent: nil)
    }
  }

  static func export(_ status: SelfTestStatus, snapshot: EngineSnapshot) -> SnapshotExport.SelfTest {
    var result = SnapshotExport.SelfTest(
      status: "notRun", detail: nil, code: nil, errorActive: snapshot.selfTestErrorActive,
      failures: snapshot.selfTestFailures, runs: snapshot.selfTestRuns, osBuild: snapshot.osBuild)
    switch status {
    case .notRun:
      break
    case .waiting:
      result.status = "waiting"
    case .running:
      result.status = "running"
    case .passed:
      result.status = "passed"
    case .failed(let failure):
      result.status = "failed"
      switch failure {
      case .clamshellRefused(let code):
        result.detail = "clamshellRefused"
        result.code = code
      case .assertionRefused(let code):
        result.detail = "assertionRefused"
        result.code = code
      case .timedOut:
        result.detail = "timedOut"
      case .watchdogNotRunning:
        result.detail = "watchdogNotRunning"
      case .stateNotSaved:
        result.detail = "stateNotSaved"
      }
    case .skipped(let skip):
      result.status = "skipped"
      switch skip {
      case .amphetamine: result.detail = "amphetamine"
      case .otherTool(let name): result.detail = "otherTool " + name
      case .sleepDisabled: result.detail = "sleepDisabled"
      }
    }
    return result
  }
}
