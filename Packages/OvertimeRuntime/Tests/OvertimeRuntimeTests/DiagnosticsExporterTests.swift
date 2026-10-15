import Darwin
import Foundation
import OvertimeCore
import OvertimeEngine
import OvertimeHelperCore
import OvertimeSystem
import Testing
import os

@testable import OvertimeAppSupport

struct DiagnosticsExporterTests {
  final class Recorder<Value: Sendable>: Sendable {
    private let stored = OSAllocatedUnfairLock<[Value]>(initialState: [])

    var all: [Value] {
      stored.withLock { $0 }
    }

    func append(_ value: Value) {
      stored.withLock { $0.append(value) }
    }
  }

  struct StagedEntry: Sendable, Equatable {
    var name: String
    var mode: Int
  }

  enum Ditto: Sendable {
    case real
    case capture
    case scripted(ToolOutcome)
  }

  static let hotspot = "Ivan’s iPhone"
  static let hotspotEscaped = "Ivan" + "\\" + "u2019s iPhone"
  static let office = "Office/5G"
  static let officeEscaped = #"Office\/5G"#
  static let folderName = "Overtime-diagnostics-2026-09-27"
  static let fakeArchive = Data("PK-captured".utf8)
  static let dittoPrefix = ["-c", "-k", "--norsrc", "--noextattr", "--noacl", "--keepParent"]
  static let pmsetForms = [["-g"], ["-g", "assertions"], ["-g", "log"]]
  static let pmsetFiles = ["pmset-g.txt", "pmset-assertions.txt", "pmset-log.txt"]
  static let sourceFiles = [
    "overtimed.log", "overtimed.log.1", "overtimed-error.log", "overtimed-error.log.1", "sentinel.log",
    "settings.json", "preferences.json", "state.json",
  ]
  static let helperFiles = ["helper.log", "helper.log.1"]
  static let generatedFiles = ["README.txt", "snapshot.json", "self-test.json", "status.txt", "detection-health.txt"]
  static let everyFile = (sourceFiles + helperFiles + generatedFiles + pmsetFiles).sorted()
  static let deviceAddress = "A4-5E-60-1B-2C-3D"
  static let deviceUUID = "0FA1B2C3-D4E5-4F60-8A1B-2C3D4E5F6071"
  static let keyboard = "Lorem Keyboard K9"
  static let hub = "Ipsum Hub 7"
  static let meeting = "ExampleMeet"
  static let deviceNeedles = [deviceAddress, deviceUUID, keyboard, hub]
  static let keptLine =
    "boot 1FA1B2C3-D4E5-4F60-8A1B-2C3D4E5F6072 owner=Sit Amet Dock product:Sit Amet Pad eventType:3 B4-6E-70-2B-3C-4D"
  static let redactedSettings =
    " sleep 1 (sleep prevented by powerd, ExampleMeet, <network>)\n file ~/image\n note <address>\n"
  static let redactedAssertions =
    [
      "pid 1(powerd): named: \"<network>\" at ~/x",
      "pid 2(ExampleMeet): named: \"call <uuid>\"",
      "pid 3(WindowServer): named: \"tickle product:<device> eventType:3\"",
      " id=501 owner=<device>",
    ].joined(separator: "\n") + "\n"

  static func redactedLogLine(_ pid: Int) -> String {
    "2026-09-27 10:00:00 +0200 Assertions PID \(pid)(ExampleMeet) \"on <address>\" ~/x"
  }

  static var wall: Date {
    ISO8601DateFormatter().date(from: "2026-09-27T12:00:00Z") ?? Date(timeIntervalSince1970: 0)
  }

  static var utc: TimeZone {
    TimeZone(secondsFromGMT: 0) ?? .current
  }

  static func slashEscaped(_ text: String) -> String {
    text.replacingOccurrences(of: "/", with: #"\/"#)
  }

  static func mode(of path: String) -> Int? {
    var info = stat()
    guard lstat(path, &info) == 0 else { return nil }
    return Int(info.st_mode & 0o7777)
  }

  static func staged(under folder: String) -> [StagedEntry] {
    let parent = URL(fileURLWithPath: folder).deletingLastPathComponent().path(percentEncoded: false)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder))?.sorted() ?? []
    let files = names.map { StagedEntry(name: $0, mode: mode(of: folder + "/" + $0) ?? -1) }
    return [StagedEntry(name: "<staging>", mode: mode(of: parent) ?? -1)]
      + [StagedEntry(name: "<folder>", mode: mode(of: folder) ?? -1)] + files
  }

  static func contents(of folder: String) -> [String: Data] {
    let name = URL(fileURLWithPath: folder).lastPathComponent
    var files = [name: Data()]
    for file in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] {
      files[name + "/" + file] = FileManager.default.contents(atPath: folder + "/" + file) ?? Data()
    }
    return files
  }

  static func finished(_ text: String) -> ToolOutcome {
    .finished(exitCode: 0, stdout: text, stderr: "")
  }

  struct Fixture {
    let root: TempDirectory
    let home: String
    let realHome: String
    let paths: Paths
    let staging: URL
    let outFolder: URL
    let helperLogs: String
    let tools: FakeToolPort
    let pmset: OSAllocatedUnfairLock<[[String]: ToolOutcome]>
    let log = Recorder<Decision>()
    let staged = Recorder<[StagedEntry]>()
    let captured = Recorder<[String: Data]>()
    let insideATask = Recorder<Bool>()
    let progress = Recorder<DiagnosticsProgress>()
    let progressAtDitto = Recorder<[DiagnosticsProgress]>()

    init(ditto: Ditto = .capture) throws {
      root = try TempDirectory()
      for name in ["home", "support", "logs", "staging", "out", "helper-logs"] {
        try FileManager.default.createDirectory(
          at: root.url.appendingPathComponent(name), withIntermediateDirectories: false)
      }
      let base = DiagnosticsRedactor.trimmedDirectory(root.path)
      let home = base + "/home"
      let realHome = try #require(DiagnosticsExporter.realPath(of: home))
      self.home = home
      self.realHome = realHome
      helperLogs = base + "/helper-logs"
      paths = Paths(
        supportDirectory: root.url.appendingPathComponent("support", isDirectory: true),
        logsDirectory: root.url.appendingPathComponent("logs", isDirectory: true))
      staging = root.url.appendingPathComponent("staging", isDirectory: true)
      outFolder = root.url.appendingPathComponent("out", isDirectory: true)
      tools = FakeToolPort(outcome: .launchFailed("unscripted"))
      let tests = DiagnosticsExporterTests.self
      let logLines = (1...600).map {
        "2026-09-27 10:00:00 +0200 Assertions PID \($0)(\(tests.meeting)) \"on \(tests.deviceAddress)\" \(home)/x"
      }
      let settings =
        " sleep 1 (sleep prevented by powerd, \(tests.meeting), \(tests.hotspot))\n file \(home)/image\n"
        + " note \(tests.deviceAddress)\n"
      let assertions = [
        "pid 1(powerd): named: \"\(tests.office)\" at \(realHome)/x",
        "pid 2(\(tests.meeting)): named: \"call \(tests.deviceUUID)\"",
        "pid 3(WindowServer): named: \"tickle product:\(tests.keyboard) eventType:3\"",
        " id=501 owner=\(tests.hub)",
      ]
      let pmset = OSAllocatedUnfairLock<[[String]: ToolOutcome]>(initialState: [
        ["-g"]: tests.finished(settings),
        ["-g", "assertions"]: tests.finished(assertions.joined(separator: "\n") + "\n"),
        ["-g", "log"]: tests.finished(logLines.joined(separator: "\n") + "\n"),
      ])
      self.pmset = pmset
      let staged = staged
      let captured = captured
      let progress = progress
      let progressAtDitto = progressAtDitto
      let insideATask = insideATask
      tools.setResponder { executable, arguments in
        insideATask.append(withUnsafeCurrentTask { $0 != nil })
        if executable == DiagnosticsExporter.pmset {
          return pmset.withLock { $0[arguments] }
        }
        guard executable == DiagnosticsExporter.ditto, arguments.count == 8 else { return nil }
        progressAtDitto.append(progress.all)
        staged.append(DiagnosticsExporterTests.staged(under: arguments[6]))
        switch ditto {
        case .real:
          return ToolRunner().run(executable, arguments)
        case .scripted(let outcome):
          return outcome
        case .capture:
          captured.append(DiagnosticsExporterTests.contents(of: arguments[6]))
          let written = FileManager.default.createFile(
            atPath: arguments[7], contents: DiagnosticsExporterTests.fakeArchive,
            attributes: [.posixPermissions: 0o644])
          return written ? .finished(exitCode: 0, stdout: "", stderr: "") : .launchFailed("capture")
        }
      }
    }

    var destination: URL {
      outFolder.appendingPathComponent(DiagnosticsExporterTests.folderName + ".zip")
    }

    var logLines: String {
      [
        "2026-09-27T10:00:00.000+02:00 WARN detectionHealth root=\(home)/.claude/projects",
        "resolved \(realHome)/.claude/projects",
        "joined \(DiagnosticsExporterTests.hotspot) then \(DiagnosticsExporterTests.office)",
        DiagnosticsExporterTests.keptLine,
      ].joined(separator: "\n") + "\n"
    }

    var redactedLogLines: String {
      [
        "2026-09-27T10:00:00.000+02:00 WARN detectionHealth root=~/.claude/projects",
        "resolved ~/.claude/projects",
        "joined <network> then <network>",
        DiagnosticsExporterTests.keptLine,
      ].joined(separator: "\n") + "\n"
    }

    var powerOutputs: [String] {
      pmset.withLock { outcomes in
        DiagnosticsExporterTests.pmsetForms.map { form in
          guard case .finished(_, let text, _)? = outcomes[form] else { return "" }
          return text
        }
      }
    }

    var json: String {
      let tests = DiagnosticsExporterTests.self
      let note = [
        tests.slashEscaped(home) + #"\/x"#, tests.hotspotEscaped, tests.officeEscaped,
        tests.slashEscaped(realHome),
      ].joined(separator: " ")
      return #"{"note":""# + note + #""}"#
    }

    var forbidden: [String] {
      let tests = DiagnosticsExporterTests.self
      return [
        home, realHome, tests.slashEscaped(home), tests.slashEscaped(realHome), tests.hotspot, tests.hotspotEscaped,
        tests.office, tests.officeEscaped,
      ]
    }

    var logFiles: [URL] {
      let decision = paths.decisionLog(.live)
      let error = paths.errorLog(.live)
      return [
        decision, URL(fileURLWithPath: decision.path(percentEncoded: false) + ".1"), error,
        URL(fileURLWithPath: error.path(percentEncoded: false) + ".1"), paths.sentinelLog,
      ]
    }

    var helperLogFiles: [URL] {
      [URL(fileURLWithPath: helperLogs + "/helper.log"), URL(fileURLWithPath: helperLogs + "/helper.log.1")]
    }

    var jsonFiles: [URL] {
      [paths.preferencesFile, paths.stateFile(.live)]
    }

    func writeFiles() throws {
      for url in logFiles + helperLogFiles {
        try Data(logLines.utf8).write(to: url)
      }
      try SettingsStore.save(
        Settings(transcriptRoots: [home + "/.claude/projects"], hotspot: DiagnosticsExporterTests.hotspot),
        to: paths.settingsFile)
      for url in jsonFiles {
        try Data(json.utf8).write(to: url)
      }
    }

    func sourcesContain(_ needle: String) -> Bool {
      (logFiles + helperLogFiles + jsonFiles + [paths.settingsFile]).contains { url in
        (try? Data(contentsOf: url))?.range(of: Data(needle.utf8)) != nil
      }
    }

    var snapshot: EngineSnapshot {
      EngineSnapshot(
        busy: true, wanted: true, reason: "busy", lidClosed: false,
        sessions: [
          SessionSummary(pid: 4_242, cwd: home + "/work", ttyName: "ttys003", startMono: Instant(nanoseconds: 7))
        ],
        detectionWarnings: [.rootMissing(realHome + "/.claude/projects"), .terminalSilence], selfTest: .passed,
        helperEngaged: false)
    }

    var inputs: DiagnosticsInputs {
      let tests = DiagnosticsExporterTests.self
      return DiagnosticsInputs(
        homeDirectory: home, hotspot: "", knownNetworks: [tests.office], knownNetworksRead: true, snapshot: snapshot,
        loginItem: .requiresApproval,
        helper: HelperMonitorState(
          installer: .enabled, reachability: .reachable, status: HelperStatus(helperVersion: 1),
          lastError: "register failed at \(home)/Applications near \(tests.hotspot)"),
        selfTest: SelfTestRecord(
          outcome: .skipped, reason: "\(tests.office) is managing sleep", at: tests.wall, osBuild: "26A428",
          osVersion: "27.0"),
        appVersion: "0.1.0", osVersion: "27.0", osBuild: "26A428", hardwareModel: "Mac17,6")
    }

    var bareInputs: DiagnosticsInputs {
      DiagnosticsInputs(homeDirectory: home)
    }

    func exporter(
      inputs: DiagnosticsInputs? = nil, temporaryDirectory: URL? = nil, helperLogDirectory: String?? = nil
    ) -> DiagnosticsExporter {
      let log = log
      return DiagnosticsExporter(
        paths: paths, tools: tools, inputs: inputs ?? self.inputs,
        clock: FakeClock(wall: DiagnosticsExporterTests.wall), helperLogDirectory: helperLogDirectory ?? helperLogs,
        temporaryDirectory: temporaryDirectory ?? staging, timeZone: DiagnosticsExporterTests.utc,
        log: { log.append($0) })
    }

    func export(_ exporter: DiagnosticsExporter? = nil, to url: URL? = nil) async -> DiagnosticsResult {
      let progress = progress
      return await (exporter ?? self.exporter()).export(to: url ?? destination) { progress.append($0) }
    }

    var stagingLeftovers: [String] {
      (try? FileManager.default.contentsOfDirectory(atPath: staging.path(percentEncoded: false))) ?? ["<unreadable>"]
    }

    var outFiles: [String] {
      (try? FileManager.default.contentsOfDirectory(atPath: outFolder.path(percentEncoded: false))) ?? ["<unreadable>"]
    }

    var stages: [String] {
      log.all.map { decision in
        decision.keyword.rawValue + " " + decision.verb + " "
          + decision.fields.map { $0.key + "=" + $0.value }.joined(separator: " ")
      }
    }

    var archived: [String: Data] {
      captured.all.last ?? [:]
    }

    func unpack(_ archive: URL) async -> [String: Data] {
      let target = root.url.appendingPathComponent("unpacked-" + UUID().uuidString, isDirectory: true)
      let base = target.path(percentEncoded: false)
      let arguments = ["-x", "-k", archive.path(percentEncoded: false), base]
      let outcome = await OffPool.run { ToolRunner().run(DiagnosticsExporter.ditto, arguments) }
      guard case .finished(exitCode: 0, _, _) = outcome else { return [:] }
      var files: [String: Data] = [:]
      for relative in (try? FileManager.default.subpathsOfDirectory(atPath: base)) ?? [] {
        var isDirectory: ObjCBool = false
        let path = target.appendingPathComponent(relative).path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
        files[relative] = isDirectory.boolValue ? Data() : (FileManager.default.contents(atPath: path) ?? Data())
      }
      return files
    }

    func text(_ name: String, in files: [String: Data]) -> String? {
      files[DiagnosticsExporterTests.folderName + "/" + name].map { String(decoding: $0, as: UTF8.self) }
    }

    func names(in files: [String: Data]) -> [String] {
      files.keys.filter { $0 != DiagnosticsExporterTests.folderName }
        .map { String($0.dropFirst(DiagnosticsExporterTests.folderName.count + 1)) }.sorted()
    }

    var redactor: DiagnosticsRedactor {
      DiagnosticsRedactor(
        homeDirectory: home, realHomeDirectory: realHome,
        networkNames: [DiagnosticsExporterTests.hotspot, DiagnosticsExporterTests.office])
    }
  }

  @Test func theExportCollectsExactlyTheEightOwnFiles() throws {
    let root = try TempDirectory()
    let paths = Paths(
      supportDirectory: root.url.appendingPathComponent("support", isDirectory: true),
      logsDirectory: root.url.appendingPathComponent("logs", isDirectory: true))
    #expect(
      DiagnosticsExporter.fileSources(paths: paths).map(\.name) == [
        "overtimed.log", "overtimed.log.1", "overtimed-error.log", "overtimed-error.log.1", "sentinel.log",
        "settings.json", "preferences.json", "state.json",
      ])
  }

  @Test func theRealArchiveIsOneOwnerOnlyZipWithOneDatedFolderAndNoNetworkNameOrHomePathAnywhere() async throws {
    let fixture = try Fixture(ditto: .real)
    try fixture.writeFiles()
    for needle in fixture.forbidden {
      #expect(fixture.sourcesContain(needle), "the fixture files must contain \(needle)")
    }
    #expect(fixture.realHome != fixture.home)
    let result = await fixture.export()
    #expect(result == .saved(fileName: "Overtime-diagnostics-2026-09-27.zip", partial: false))
    #expect(Self.mode(of: fixture.destination.path(percentEncoded: false)) == 0o600)
    #expect(fixture.stagingLeftovers == [])
    #expect(fixture.stages == [])
    #expect(fixture.outFiles == ["Overtime-diagnostics-2026-09-27.zip"])
    let archive = try Data(contentsOf: fixture.destination)
    #expect(archive.prefix(2) == Data("PK".utf8))
    let files = await fixture.unpack(fixture.destination)
    #expect(files.keys.sorted() == [Self.folderName] + Self.everyFile.map { Self.folderName + "/" + $0 })
    #expect(!files.keys.contains { $0.contains("._") || $0.contains("__MACOSX") })
    for needle in fixture.forbidden {
      let bytes = Data(needle.utf8)
      #expect(archive.range(of: bytes) == nil, "the zip holds \(needle)")
      for (name, data) in files {
        #expect(Data(name.utf8).range(of: bytes) == nil, "\(name) is named after \(needle)")
        #expect(data.range(of: bytes) == nil, "\(name) holds \(needle)")
      }
    }
    for name in (fixture.logFiles + fixture.helperLogFiles).map(\.lastPathComponent) {
      #expect(fixture.text(name, in: files) == fixture.redactedLogLines)
    }
    for name in fixture.jsonFiles.map(\.lastPathComponent) {
      #expect(fixture.text(name, in: files) == #"{"note":"~\/x <network> <network> ~"}"#)
    }
    let settings = try #require(fixture.text("settings.json", in: files))
    #expect(settings.contains(#""hotspot" : "<network>""#))
    #expect(settings.contains(#""~\/.claude\/projects""#))
    #expect(
      fixture.text("status.txt", in: files)?.contains(
        "helper last error: register failed at ~/Applications near <network>\n") == true)
    #expect(fixture.text("snapshot.json", in: files)?.contains("\"cwd\" : \"~/work\"") == true)
    #expect(fixture.text("snapshot.json", in: files)?.contains("\"rootMissing: ~/.claude/projects\"") == true)
    #expect(fixture.text("detection-health.txt", in: files) == "rootMissing: ~/.claude/projects\nterminalSilence\n")
    #expect(fixture.text("self-test.json", in: files)?.contains("\"reason\" : \"<network> is managing sleep\"") == true)
    #expect(fixture.text("pmset-g.txt", in: files) == Self.redactedSettings)
    #expect(fixture.text("pmset-assertions.txt", in: files) == Self.redactedAssertions)
    #expect(fixture.text("pmset-log.txt", in: files)?.hasSuffix(Self.redactedLogLine(600) + "\n") == true)
    let power = fixture.powerOutputs
    #expect(power.count == 3)
    #expect(power[0].contains(Self.deviceAddress))
    #expect(power[1].contains(Self.deviceUUID) && power[1].contains(Self.keyboard) && power[1].contains(Self.hub))
    #expect(power[2].contains(Self.deviceAddress))
    for needle in Self.deviceNeedles {
      let bytes = Data(needle.utf8)
      for (name, data) in files {
        #expect(data.range(of: bytes) == nil, "\(name) holds \(needle)")
      }
    }
    for (index, file) in Self.pmsetFiles.enumerated() {
      #expect(power[index].contains(Self.meeting), "the fixture for \(file) must name the process")
      #expect(fixture.text(file, in: files)?.contains(Self.meeting) == true, "\(file) lost the process name")
    }
    #expect(fixture.sourcesContain(Self.keptLine))
    let readme = try #require(fixture.text("README.txt", in: files))
    #expect(readme == DiagnosticsManifest.readmeText)
    #expect(readme.hasPrefix("Overtime diagnostics\n"))
    #expect(readme.contains("holding power assertions when the archive was made"))
  }

  @Test func theOnlyProgramsRunAreTheThreeReadOnlyPmsetFormsAndDittoWithItsFixedArguments() async throws {
    let fixture = try Fixture()
    try fixture.writeFiles()
    #expect(await fixture.export() == .saved(fileName: "Overtime-diagnostics-2026-09-27.zip", partial: false))
    let calls = fixture.tools.calls
    #expect(calls.map(\.executable) == ["/usr/bin/pmset", "/usr/bin/pmset", "/usr/bin/pmset", "/usr/bin/ditto"])
    #expect(calls.prefix(3).map(\.arguments) == [["-g"], ["-g", "assertions"], ["-g", "log"]])
    #expect(calls.prefix(3).allSatisfy { $0.arguments.first == "-g" && $0.arguments.count <= 2 })
    let arguments = try #require(calls.last?.arguments)
    #expect(Array(arguments.prefix(6)) == Self.dittoPrefix)
    try #require(arguments.count == 8)
    #expect(URL(fileURLWithPath: arguments[6]).lastPathComponent == Self.folderName)
    #expect(arguments[6].hasPrefix(fixture.staging.path(percentEncoded: false) + "overtime-diagnostics."))
    #expect(fixture.staging.path(percentEncoded: false).hasSuffix("/staging/"))
    #expect(arguments[7] == String(arguments[6].dropLast(Self.folderName.count)) + "out.zip")
    #expect(DiagnosticsExporter.ditto == "/usr/bin/ditto")
    #expect(DiagnosticsExporter.pmset == "/usr/bin/pmset")
    #expect(DiagnosticsExporter.pmsetSettingsArguments == ["-g"])
    #expect(DiagnosticsExporter.pmsetAssertionsArguments == ["-g", "assertions"])
    #expect(DiagnosticsExporter.pmsetLogArguments == ["-g", "log"])
    #expect(
      DiagnosticsExporter.dittoArguments(folder: "/a/b", output: "/a/out.zip")
        == ["-c", "-k", "--norsrc", "--noextattr", "--noacl", "--keepParent", "/a/b", "/a/out.zip"])
  }

  @Test func theStagingFolderIsPrivateEveryStagedFileIsOwnerOnlyAndTheArchiveIsMadeOwnerOnly() async throws {
    let fixture = try Fixture()
    try fixture.writeFiles()
    _ = await fixture.export()
    let entries = try #require(fixture.staged.all.first)
    #expect(
      entries.prefix(2) == [StagedEntry(name: "<staging>", mode: 0o700), StagedEntry(name: "<folder>", mode: 0o700)])
    #expect(entries.dropFirst(2).map(\.name) == Self.everyFile)
    #expect(entries.dropFirst(2).allSatisfy { $0.mode == 0o600 })
    #expect(Self.mode(of: fixture.destination.path(percentEncoded: false)) == 0o600)
    #expect(FileManager.default.contents(atPath: fixture.destination.path(percentEncoded: false)) == Self.fakeArchive)
    #expect(fixture.stagingLeftovers == [])
    #expect(fixture.outFiles == ["Overtime-diagnostics-2026-09-27.zip"])
  }

  @Test func everyFileIsRedactedBeforeItIsStagedAndWithNothingMissingThereIsNoMissingFile() async throws {
    let fixture = try Fixture()
    try fixture.writeFiles()
    #expect(await fixture.export() == .saved(fileName: "Overtime-diagnostics-2026-09-27.zip", partial: false))
    let files = fixture.archived
    #expect(fixture.names(in: files) == Self.everyFile)
    for needle in fixture.forbidden {
      for (name, data) in files {
        #expect(data.range(of: Data(needle.utf8)) == nil, "\(name) holds \(needle)")
      }
    }
    #expect(fixture.text("sentinel.log", in: files) == fixture.redactedLogLines)
    #expect(fixture.text("overtimed.log.1", in: files) == fixture.redactedLogLines)
    #expect(fixture.text("helper.log.1", in: files) == fixture.redactedLogLines)
    #expect(fixture.text("state.json", in: files) == #"{"note":"~\/x <network> <network> ~"}"#)
  }

  @Test func theGeneratedFilesAreTheManifestTextsOfTheInputsRedacted() async throws {
    let fixture = try Fixture()
    try fixture.writeFiles()
    _ = await fixture.export()
    let files = fixture.archived
    let inputs = fixture.inputs
    let redactor = fixture.redactor
    #expect(fixture.text("status.txt", in: files) == redactor.redact(DiagnosticsManifest.statusText(inputs)))
    #expect(fixture.text("status.txt", in: files)?.contains("login item: requiresApproval\n") == true)
    #expect(
      files[Self.folderName + "/snapshot.json"]
        == redactor.redact(DiagnosticsManifest.snapshotJSON(fixture.snapshot)))
    #expect(fixture.text("snapshot.json", in: files)?.contains("\"cwd\" : \"~/work\"") == true)
    let record = try #require(inputs.selfTest)
    #expect(files[Self.folderName + "/self-test.json"] == redactor.redact(DiagnosticsManifest.selfTestJSON(record)))
    #expect(fixture.text("detection-health.txt", in: files) == "rootMissing: ~/.claude/projects\nterminalSilence\n")
  }

  @Test func thePowerOutputsAreArchivedRedactedAndTheLogIsCutToItsLast500Lines() async throws {
    let fixture = try Fixture()
    try fixture.writeFiles()
    _ = await fixture.export()
    let files = fixture.archived
    #expect(fixture.text("pmset-g.txt", in: files) == Self.redactedSettings)
    #expect(fixture.text("pmset-assertions.txt", in: files) == Self.redactedAssertions)
    let log = try #require(fixture.text("pmset-log.txt", in: files))
    let lines = log.split(separator: "\n")
    #expect(lines.count == 500)
    #expect(lines.first.map(String.init) == Self.redactedLogLine(101))
    #expect(lines.last.map(String.init) == Self.redactedLogLine(600))
    #expect(lines.allSatisfy { $0.hasSuffix("(ExampleMeet) \"on <address>\" ~/x") })
  }

  @Test func onlyThePowerOutputsLoseAddressesUUIDsAndDeviceNames() async throws {
    let fixture = try Fixture()
    try fixture.writeFiles()
    _ = await fixture.export()
    let files = fixture.archived
    let powerNames = Set(Self.pmsetFiles)
    for name in fixture.names(in: files) {
      let text = try #require(fixture.text(name, in: files))
      if powerNames.contains(name) {
        for needle in Self.deviceNeedles {
          #expect(!text.contains(needle), "\(name) holds \(needle)")
        }
        #expect(text.contains(Self.meeting), "\(name) lost the process name")
      }
    }
    for name in (fixture.logFiles + fixture.helperLogFiles).map(\.lastPathComponent) {
      #expect(fixture.text(name, in: files)?.contains(Self.keptLine + "\n") == true, "\(name) lost its own line")
    }
    #expect(fixture.home.contains("-"))
    #expect(DiagnosticsPowerRedactor.redact(fixture.home + "/x") != fixture.home + "/x")
    #expect(DiagnosticsManifest.powerFiles == Self.pmsetFiles)
  }

  @Test func theReadmeIsInEveryArchiveAlsoWhenNothingElseCouldBeCollected() async throws {
    let fixture = try Fixture()
    fixture.pmset.withLock { $0 = [:] }
    _ = await fixture.export(fixture.exporter(inputs: fixture.bareInputs))
    #expect(fixture.text("README.txt", in: fixture.archived) == DiagnosticsManifest.readmeText)
    #expect(DiagnosticsManifest.readmeText.utf8.count > 1_000)
  }

  struct PmsetCase: Sendable, CustomTestStringConvertible {
    let form: Int
    let outcome: ToolOutcome
    let reason: String

    var testDescription: String {
      DiagnosticsExporterTests.pmsetFiles[form] + " " + reason
    }
  }

  static let pmsetCases = [0, 1, 2].flatMap { form in
    [
      PmsetCase(form: form, outcome: .timedOut, reason: "the command timed out"),
      PmsetCase(
        form: form, outcome: .finished(exitCode: 2, stdout: "partial \(hotspot)", stderr: "usage"),
        reason: "the command exited with status 2"),
      PmsetCase(form: form, outcome: .launchFailed("no pmset"), reason: "the command could not be started"),
    ]
  }

  @Test(arguments: pmsetCases)
  func aPmsetFormThatDoesNotSucceedIsNamedInMissingAndTheResultIsPartial(_ item: PmsetCase) async throws {
    let fixture = try Fixture()
    try fixture.writeFiles()
    fixture.pmset.withLock { $0[Self.pmsetForms[item.form]] = item.outcome }
    #expect(await fixture.export() == .saved(fileName: "Overtime-diagnostics-2026-09-27.zip", partial: true))
    let files = fixture.archived
    let file = Self.pmsetFiles[item.form]
    #expect(fixture.text("missing.txt", in: files) == file + ": " + item.reason + "\n")
    #expect(fixture.names(in: files) == (Self.everyFile.filter { $0 != file } + ["missing.txt"]).sorted())
    #expect(fixture.tools.calls.count == 4)
  }

  @Test func aMissingOptionalFileIsListedInMissingAndDoesNotMakeTheExportPartial() async throws {
    let fixture = try Fixture()
    try fixture.writeFiles()
    try FileManager.default.removeItem(at: fixture.paths.stateFile(.live))
    try FileManager.default.removeItem(at: fixture.helperLogFiles[1])
    #expect(await fixture.export() == .saved(fileName: "Overtime-diagnostics-2026-09-27.zip", partial: false))
    let files = fixture.archived
    #expect(fixture.text("missing.txt", in: files) == "state.json: not found\nhelper.log.1: not found\n")
    #expect(!fixture.names(in: files).contains("state.json"))
    #expect(!fixture.names(in: files).contains("helper.log.1"))
  }

  @Test func anUnreadableHelperLogIsListedInMissingAndMakesTheExportPartial() async throws {
    let fixture = try Fixture()
    try fixture.writeFiles()
    let path = fixture.helperLogs + "/helper.log"
    #expect(chmod(path, 0) == 0)
    let result = await fixture.export()
    #expect(chmod(path, 0o600) == 0)
    #expect(result == .saved(fileName: "Overtime-diagnostics-2026-09-27.zip", partial: true))
    let files = fixture.archived
    #expect(fixture.text("missing.txt", in: files) == "helper.log: could not be read\n")
    #expect(!fixture.names(in: files).contains("helper.log"))
    #expect(fixture.text("helper.log.1", in: files) == fixture.redactedLogLines)
  }

  @Test func withNothingToCollectOnlyTheStatusAndTheMissingListAreArchived() async throws {
    let fixture = try Fixture()
    fixture.pmset.withLock { $0 = [:] }
    let result = await fixture.export(fixture.exporter(inputs: fixture.bareInputs))
    #expect(result == .saved(fileName: "Overtime-diagnostics-2026-09-27.zip", partial: true))
    let files = fixture.archived
    #expect(fixture.names(in: files) == ["README.txt", "missing.txt", "status.txt"])
    let expected = [
      "overtimed.log: not found", "overtimed.log.1: not found", "overtimed-error.log: not found",
      "overtimed-error.log.1: not found", "sentinel.log: not found", "settings.json: not found",
      "preferences.json: not found", "state.json: not found", "helper.log: not found",
      "helper.log.1: not found", "snapshot.json: the engine has published no snapshot",
      "self-test.json: no self-test result is stored",
      "detection-health.txt: the engine has published no snapshot",
      "pmset-g.txt: the command could not be started", "pmset-assertions.txt: the command could not be started",
      "pmset-log.txt: the command could not be started",
    ]
    #expect(fixture.text("missing.txt", in: files) == expected.joined(separator: "\n") + "\n")
    #expect(fixture.text("status.txt", in: files) == DiagnosticsManifest.statusText(fixture.bareInputs))
  }

  @Test func filesThatAreOnlyAbsentAndAStoredResultThatIsOnlyMissingDoNotMakeTheExportPartial() async throws {
    let fixture = try Fixture()
    var inputs = fixture.bareInputs
    inputs.snapshot = EngineSnapshot()
    let result = await fixture.export(fixture.exporter(inputs: inputs))
    #expect(result == .saved(fileName: "Overtime-diagnostics-2026-09-27.zip", partial: false))
    let files = fixture.archived
    #expect(
      fixture.names(in: files) == [
        "README.txt", "detection-health.txt", "missing.txt", "pmset-assertions.txt", "pmset-g.txt", "pmset-log.txt",
        "snapshot.json", "status.txt",
      ])
    #expect(fixture.text("detection-health.txt", in: files) == "No detection problems found.\n")
    #expect(
      fixture.text("missing.txt", in: files)?.hasSuffix("self-test.json: no self-test result is stored\n") == true)
    #expect(fixture.text("missing.txt", in: files)?.split(separator: "\n").count == 11)
  }

  @Test func withoutASnapshotTheSnapshotAndTheDetectionHealthAreMissingAndTheExportIsPartial() async throws {
    let fixture = try Fixture()
    try fixture.writeFiles()
    var inputs = fixture.inputs
    inputs.snapshot = nil
    let result = await fixture.export(fixture.exporter(inputs: inputs))
    #expect(result == .saved(fileName: "Overtime-diagnostics-2026-09-27.zip", partial: true))
    #expect(
      fixture.text("missing.txt", in: fixture.archived)
        == "snapshot.json: the engine has published no snapshot\n"
        + "detection-health.txt: the engine has published no snapshot\n")
  }

  @Test func withoutAHelperLogFolderNoHelperLogIsCollectedOrListed() async throws {
    let fixture = try Fixture()
    try fixture.writeFiles()
    let result = await fixture.export(fixture.exporter(helperLogDirectory: .some(nil)))
    #expect(result == .saved(fileName: "Overtime-diagnostics-2026-09-27.zip", partial: false))
    #expect(fixture.names(in: fixture.archived) == Self.everyFile.filter { !Self.helperFiles.contains($0) })
  }

  @Test func theConfiguredHotspotIsRemovedAlsoWhenNoSettingsFileIsCollected() async throws {
    let fixture = try Fixture()
    try Data(fixture.logLines.utf8).write(to: fixture.paths.decisionLog(.live))
    let inputs = DiagnosticsInputs(homeDirectory: fixture.home, hotspot: Self.hotspot, knownNetworks: [])
    _ = await fixture.export(fixture.exporter(inputs: inputs))
    let files = fixture.archived
    #expect(!fixture.names(in: files).contains("settings.json"))
    #expect(
      fixture.text("overtimed.log", in: files)
        == fixture.redactedLogLines.replacingOccurrences(of: "then <network>", with: "then " + Self.office))
  }

  @Test func theHotspotStoredInTheCollectedSettingsFileIsRemovedAlsoWhenTheAppDidNotLoadIt() async throws {
    let fixture = try Fixture()
    try SettingsStore.save(Settings(hotspot: "Café Net"), to: fixture.paths.settingsFile)
    try Data("joined Café Net\n".utf8).write(to: fixture.paths.sentinelLog)
    let inputs = DiagnosticsInputs(homeDirectory: fixture.home, hotspot: "", knownNetworks: [])
    _ = await fixture.export(fixture.exporter(inputs: inputs))
    let files = fixture.archived
    #expect(fixture.text("sentinel.log", in: files) == "joined <network>\n")
    #expect(fixture.text("settings.json", in: files)?.contains("Café") == false)
    #expect(fixture.text("settings.json", in: files)?.contains("\"hotspot\" : \"<network>\"") == true)
  }

  @Test func aSettingsFileThatDoesNotDecodeIsLeftOutAndListed() async throws {
    let fixture = try Fixture()
    try fixture.writeFiles()
    try Data(#"{"hotspot":["Café Net"]}"#.utf8).write(to: fixture.paths.settingsFile)
    #expect(await fixture.export() == .saved(fileName: "Overtime-diagnostics-2026-09-27.zip", partial: true))
    let files = fixture.archived
    #expect(!fixture.names(in: files).contains("settings.json"))
    #expect(
      fixture.text("missing.txt", in: files) == "settings.json: does not decode as settings and was left out\n")
    #expect(DiagnosticsExporter.storedHotspot(in: Data("not json".utf8)) == nil)
    #expect(DiagnosticsExporter.storedHotspot(in: Data("{}".utf8)) == "")
    #expect(DiagnosticsExporter.storedHotspot(in: Data(#"{"hotspot":"A"}"#.utf8)) == "A")
  }

  @Test func aSymlinkedFileIsNotFollowedAndIsListedAndMakesTheExportPartial() async throws {
    let fixture = try Fixture()
    try fixture.writeFiles()
    let outside = fixture.root.url.appendingPathComponent("outside.txt")
    try Data("OUTSIDE\n".utf8).write(to: outside)
    try FileManager.default.removeItem(at: fixture.paths.sentinelLog)
    try FileManager.default.createSymbolicLink(at: fixture.paths.sentinelLog, withDestinationURL: outside)
    #expect(await fixture.export() == .saved(fileName: "Overtime-diagnostics-2026-09-27.zip", partial: true))
    let files = fixture.archived
    #expect(fixture.text("missing.txt", in: files) == "sentinel.log: not a regular file\n")
    #expect(!fixture.names(in: files).contains("sentinel.log"))
    #expect(!files.values.contains { $0.range(of: Data("OUTSIDE".utf8)) != nil })
  }

  @Test func aFileOverTheCapIsLeftOutAndListedAndMakesTheExportPartialAndOneAtTheCapIsKept() async throws {
    let fixture = try Fixture()
    try fixture.writeFiles()
    let cap = DiagnosticsExporter.maxFileBytes
    try Data(repeating: 0x61, count: cap + 1).write(to: fixture.paths.decisionLog(.live))
    try Data(repeating: 0x62, count: cap).write(to: fixture.paths.errorLog(.live))
    #expect(await fixture.export() == .saved(fileName: "Overtime-diagnostics-2026-09-27.zip", partial: true))
    let files = fixture.archived
    #expect(fixture.text("missing.txt", in: files) == "overtimed.log: larger than 2097152 bytes\n")
    #expect(!fixture.names(in: files).contains("overtimed.log"))
    #expect(files[Self.folderName + "/overtimed-error.log"]?.count == cap)
    #expect(cap == 2_097_152)
  }

  static let sentinelTail: Comment =
    "S-WR-05: the unrotated sentinel.log over the cap is exported as its newest whole lines, never dropped, and does not make the export partial"

  static let sentinelLine = "2026-09-27T10:00:00+0200 HOLD sentinel heartbeat ok\n"
  static let newestLine = "NEWEST sentinel clear\n"

  static func sentinelHead() -> String {
    "OLDEST first line\n" + String(repeating: sentinelLine, count: 200)
  }

  static func sentinelTailExactlyAtTheCap() -> String {
    let cap = DiagnosticsExporter.maxFileBytes
    let room = cap - newestLine.utf8.count
    let lines = room / sentinelLine.utf8.count
    let pad = room - lines * sentinelLine.utf8.count
    let first = pad > 0 ? String(repeating: "p", count: pad - 1) + "\n" : ""
    return first + String(repeating: sentinelLine, count: lines) + newestLine
  }

  @Test func aSentinelLogOverTheCapIsExportedAsItsNewestWholeLinesAndTheExportIsNotPartial() async throws {
    let fixture = try Fixture()
    try fixture.writeFiles()
    let cap = DiagnosticsExporter.maxFileBytes
    let text = Self.sentinelHead() + String(repeating: Self.sentinelLine, count: cap / 40) + Self.newestLine
    try Data(text.utf8).write(to: fixture.paths.sentinelLog)
    #expect(
      await fixture.export() == .saved(fileName: "Overtime-diagnostics-2026-09-27.zip", partial: false),
      Self.sentinelTail)
    let files = fixture.archived
    let exported = try #require(fixture.text("sentinel.log", in: files), Self.sentinelTail)
    #expect(exported.hasSuffix(Self.newestLine), Self.sentinelTail)
    #expect(!exported.contains("OLDEST"))
    #expect(exported.utf8.count <= cap)
    #expect(exported.utf8.count > cap - Self.sentinelLine.utf8.count)
    #expect(exported.hasPrefix(Self.sentinelLine), "the first, cut line is dropped")
    #expect(fixture.text("missing.txt", in: files) == "sentinel.log: only the last 2097152 bytes\n")
  }

  @Test func aSentinelLogWhoseLastCapBytesStartAtALineKeepsThatWholeFirstLine() async throws {
    let fixture = try Fixture()
    try fixture.writeFiles()
    let tail = Self.sentinelTailExactlyAtTheCap()
    #expect(tail.utf8.count == DiagnosticsExporter.maxFileBytes)
    try Data((Self.sentinelHead() + tail).utf8).write(to: fixture.paths.sentinelLog)
    #expect(await fixture.export() == .saved(fileName: "Overtime-diagnostics-2026-09-27.zip", partial: false))
    #expect(fixture.text("sentinel.log", in: fixture.archived) == tail, Self.sentinelTail)
  }

  @Test func aSentinelLogAtTheCapIsExportedWholeAndListedNowhere() async throws {
    let fixture = try Fixture()
    try fixture.writeFiles()
    let line = "2026-09-27T10:00:00+0200 HOLD sentinel heartbeat ok\n"
    let text = String(repeating: line, count: DiagnosticsExporter.maxFileBytes / line.utf8.count)
    try Data(text.utf8).write(to: fixture.paths.sentinelLog)
    #expect(await fixture.export() == .saved(fileName: "Overtime-diagnostics-2026-09-27.zip", partial: false))
    let files = fixture.archived
    #expect(fixture.text("sentinel.log", in: files) == text)
    #expect(fixture.text("missing.txt", in: files) == nil)
  }

  @Test func theExportRunsOnAThreadOfItsOwnAndNotInsideTheCallersTask() async throws {
    let fixture = try Fixture()
    try fixture.writeFiles()
    #expect(withUnsafeCurrentTask { $0 != nil })
    _ = await fixture.export()
    #expect(fixture.insideATask.all == [false, false, false, false])
  }

  @Test func anExistingFileAtTheDestinationIsReplaced() async throws {
    let fixture = try Fixture()
    try fixture.writeFiles()
    let path = fixture.destination.path(percentEncoded: false)
    try Data("old".utf8).write(to: fixture.destination)
    #expect(chmod(path, 0o644) == 0)
    let result = await fixture.export()
    #expect(result == .saved(fileName: "Overtime-diagnostics-2026-09-27.zip", partial: false))
    #expect(FileManager.default.contents(atPath: path) == Self.fakeArchive)
    #expect(Self.mode(of: path) == 0o600)
  }

  @Test func theSavedNameIsTheNameTheUserChose() async throws {
    let fixture = try Fixture()
    try fixture.writeFiles()
    let chosen = fixture.outFolder.appendingPathComponent("for support.zip")
    #expect(await fixture.export(to: chosen) == .saved(fileName: "for support.zip", partial: false))
    #expect(Self.mode(of: chosen.path(percentEncoded: false)) == 0o600)
    #expect(fixture.outFiles == ["for support.zip"])
  }

  @Test func anUnwritableDestinationFolderIsAWriteFailure() async throws {
    let fixture = try Fixture()
    try fixture.writeFiles()
    let folder = fixture.outFolder.path(percentEncoded: false)
    #expect(chmod(folder, 0o500) == 0)
    let result = await fixture.export()
    #expect(chmod(folder, 0o700) == 0)
    #expect(result == .failed(.writeFailed))
    #expect(fixture.stages == ["ERROR diagnostics export failed stage=destination"])
    #expect(fixture.stagingLeftovers == [])
    #expect(fixture.outFiles == [])
  }

  @Test func aDittoThatTimesOutIsATimeoutAndTheStagingFolderIsRemoved() async throws {
    let fixture = try Fixture(ditto: .scripted(.timedOut))
    try fixture.writeFiles()
    #expect(await fixture.export() == .failed(.timedOut))
    #expect(fixture.stages == ["ERROR diagnostics export failed stage=timeout"])
    #expect(fixture.stagingLeftovers == [])
    #expect(fixture.outFiles == [])
  }

  @Test(arguments: [
    ToolOutcome.finished(exitCode: 1, stdout: "", stderr: "ditto: error"), .launchFailed("no ditto"),
  ])
  func aDittoThatFailsOrCannotStartIsAWriteFailure(_ outcome: ToolOutcome) async throws {
    let fixture = try Fixture(ditto: .scripted(outcome))
    try fixture.writeFiles()
    #expect(await fixture.export() == .failed(.writeFailed))
    #expect(fixture.stages == ["ERROR diagnostics export failed stage=archive"])
    #expect(fixture.stagingLeftovers == [])
    #expect(fixture.outFiles == [])
  }

  @Test func aDittoThatReportsSuccessAndWroteNoArchiveIsAWriteFailure() async throws {
    let fixture = try Fixture(ditto: .scripted(.finished(exitCode: 0, stdout: "", stderr: "")))
    try fixture.writeFiles()
    #expect(await fixture.export() == .failed(.writeFailed))
    #expect(fixture.stages == ["ERROR diagnostics export failed stage=destination"])
    #expect(fixture.stagingLeftovers == [])
    #expect(fixture.outFiles == [])
  }

  @Test func aStagingFolderThatCannotBeMadeIsAWriteFailureAndNothingIsRun() async throws {
    let fixture = try Fixture()
    try fixture.writeFiles()
    let nowhere = fixture.root.url.appendingPathComponent("nowhere", isDirectory: true)
    #expect(await fixture.export(fixture.exporter(temporaryDirectory: nowhere)) == .failed(.writeFailed))
    #expect(fixture.stages == ["ERROR diagnostics export failed stage=staging"])
    #expect(fixture.tools.calls.isEmpty)
    #expect(fixture.progress.all == [.collecting])
  }

  @Test func progressGoesFromCollectingToArchivingAfterThePowerCommandsAndBeforeDittoRuns() async throws {
    let fixture = try Fixture()
    try fixture.writeFiles()
    let progress = fixture.progress
    let seen = Recorder<[DiagnosticsProgress]>()
    let pmset = fixture.pmset
    let captured = fixture.captured
    fixture.tools.setResponder { executable, arguments in
      seen.append(progress.all)
      if executable == DiagnosticsExporter.pmset { return pmset.withLock { $0[arguments] } }
      guard arguments.count == 8 else { return .launchFailed("arguments") }
      captured.append(Self.contents(of: arguments[6]))
      return FileManager.default.createFile(atPath: arguments[7], contents: Self.fakeArchive)
        ? .finished(exitCode: 0, stdout: "", stderr: "") : .launchFailed("capture")
    }
    _ = await fixture.export()
    #expect(fixture.progress.all == [.collecting, .archiving])
    #expect(seen.all == [[.collecting], [.collecting], [.collecting], [.collecting, .archiving]])
  }

  @Test func theFolderAndTheDefaultFileNameCarryTheLocalDate() throws {
    let late = try #require(ISO8601DateFormatter().date(from: "2026-09-27T23:30:00Z"))
    let east = try #require(TimeZone(secondsFromGMT: 7_200))
    #expect(DiagnosticsExporter.folderName(wall: late, timeZone: Self.utc) == "Overtime-diagnostics-2026-09-27")
    #expect(DiagnosticsExporter.folderName(wall: late, timeZone: east) == "Overtime-diagnostics-2026-09-28")
    #expect(
      DiagnosticsExporter.defaultFileName(wall: late, timeZone: Self.utc) == "Overtime-diagnostics-2026-09-27.zip")
    let early = try #require(ISO8601DateFormatter().date(from: "2027-01-05T00:00:00Z"))
    #expect(DiagnosticsExporter.folderName(wall: early, timeZone: Self.utc) == "Overtime-diagnostics-2027-01-05")
  }

  @Test func aMoveAcrossVolumesCopiesTheArchiveAndAnyOtherRenameErrorIsAFailure() throws {
    let root = try TempDirectory()
    let base = DiagnosticsRedactor.trimmedDirectory(root.path)
    let source = base + "/out.zip"
    let destination = base + "/chosen.zip"
    try Data("PK-new".utf8).write(to: URL(fileURLWithPath: source))
    try Data("old".utf8).write(to: URL(fileURLWithPath: destination))
    #expect(chmod(destination, 0o644) == 0)
    #expect(!DiagnosticsExporter.place(source, at: destination) { _, _ in EACCES })
    #expect(FileManager.default.contents(atPath: destination) == Data("old".utf8))
    #expect(DiagnosticsExporter.place(source, at: destination) { _, _ in EXDEV })
    #expect(FileManager.default.contents(atPath: destination) == Data("PK-new".utf8))
    #expect(Self.mode(of: destination) == 0o600)
    #expect(!DiagnosticsExporter.place(base + "/absent.zip", at: destination) { _, _ in EXDEV })
    #expect(FileManager.default.contents(atPath: destination) == Data("PK-new".utf8))
    #expect(!DiagnosticsExporter.place(source, at: base + "/absent/chosen.zip") { _, _ in EXDEV })
    #expect(DiagnosticsExporter.place(source, at: base + "/moved.zip"))
    #expect(!FileManager.default.fileExists(atPath: source))
    #expect(FileManager.default.contents(atPath: base + "/moved.zip") == Data("PK-new".utf8))
    #expect(DiagnosticsExporter.renameError(base + "/absent.zip", base + "/other.zip") == ENOENT)
  }

  @Test func aStagedFileIsNeverWrittenOverAnExistingOne() throws {
    let root = try TempDirectory()
    let base = DiagnosticsRedactor.trimmedDirectory(root.path)
    let path = base + "/file.txt"
    #expect(DiagnosticsExporter.write(Data("one".utf8), to: path))
    #expect(Self.mode(of: path) == 0o600)
    #expect(!DiagnosticsExporter.write(Data("two".utf8), to: path))
    #expect(FileManager.default.contents(atPath: path) == Data("one".utf8))
    #expect(!DiagnosticsExporter.write(Data("three".utf8), to: base + "/absent/file.txt"))
    #expect(DiagnosticsExporter.write(Data(), to: base + "/empty.txt"))
    #expect(FileManager.default.contents(atPath: base + "/empty.txt") == Data())
  }

  @Test func theFailureLineNamesTheStage() {
    let expected = Decision(
      keyword: .error, verb: "diagnostics export failed", fields: [DecisionField(key: "stage", value: "archive")])
    #expect(DiagnosticsExporter.failure(stage: "archive") == expected)
  }
}
