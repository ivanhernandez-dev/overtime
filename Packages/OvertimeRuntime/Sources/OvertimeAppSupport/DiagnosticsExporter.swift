import Darwin
import Foundation
import OvertimeCore
import OvertimeEngine
import OvertimeSystem

public enum DiagnosticsProgress: Sendable, Equatable {
  case collecting
  case archiving
}

public enum DiagnosticsFailure: Sendable, Equatable {
  case writeFailed
  case timedOut
}

public enum DiagnosticsResult: Sendable, Equatable {
  case saved(fileName: String, partial: Bool)
  case failed(DiagnosticsFailure)
}

public protocol DiagnosticsExporting: Sendable {
  func export(
    to destination: URL, progress: @escaping @Sendable (DiagnosticsProgress) -> Void
  ) async -> DiagnosticsResult
}

public struct DiagnosticsInputs: Sendable, Equatable {
  public var homeDirectory: String
  public var hotspot: String
  public var knownNetworks: [String]
  public var knownNetworksRead: Bool
  public var snapshot: EngineSnapshot?
  public var loginItem: LoginItemStatus?
  public var helper: HelperMonitorState?
  public var selfTest: SelfTestRecord?
  public var appVersion: String
  public var osVersion: String
  public var osBuild: String?
  public var hardwareModel: String?

  public init(
    homeDirectory: String, hotspot: String = "", knownNetworks: [String] = [], knownNetworksRead: Bool = false,
    snapshot: EngineSnapshot? = nil, loginItem: LoginItemStatus? = nil, helper: HelperMonitorState? = nil,
    selfTest: SelfTestRecord? = nil, appVersion: String = DiagnosticsManifest.unknown,
    osVersion: String = DiagnosticsManifest.unknown, osBuild: String? = nil, hardwareModel: String? = nil
  ) {
    self.homeDirectory = homeDirectory
    self.hotspot = hotspot
    self.knownNetworks = knownNetworks
    self.knownNetworksRead = knownNetworksRead
    self.snapshot = snapshot
    self.loginItem = loginItem
    self.helper = helper
    self.selfTest = selfTest
    self.appVersion = appVersion
    self.osVersion = osVersion
    self.osBuild = osBuild
    self.hardwareModel = hardwareModel
  }
}

public struct DiagnosticsExporter: DiagnosticsExporting {
  struct Item: Sendable, Equatable {
    var name: String
    var data: Data
  }

  struct Collection: Sendable, Equatable {
    var items: [Item] = []
    var networkNames: [String] = []
    var gaps: [DiagnosticsGap] = []

    var partial: Bool {
      gaps.contains { $0.kind == .failed }
    }

    mutating func add(_ name: String, _ data: Data) {
      items.append(Item(name: name, data: data))
    }

    mutating func miss(_ name: String, _ reason: String, _ kind: DiagnosticsGap.Kind) {
      gaps.append(DiagnosticsGap(name: name, reason: reason, kind: kind))
    }
  }

  public static let ditto = "/usr/bin/ditto"
  public static let pmset = "/usr/bin/pmset"
  public static let pmsetSettingsArguments = ["-g"]
  public static let pmsetAssertionsArguments = ["-g", "assertions"]
  public static let pmsetLogArguments = ["-g", "log"]
  public static let folderPrefix = "Overtime-diagnostics-"
  public static let archiveExtension = "zip"
  public static let rotatedSuffix = ".1"
  public static let maxFileBytes = 2_097_152
  public static let failedVerb = "diagnostics export failed"
  static let stagingTemplate = "overtime-diagnostics.XXXXXX"
  static let stagedArchiveName = "out.zip"

  public static func dittoArguments(folder: String, output: String) -> [String] {
    ["-c", "-k", "--norsrc", "--noextattr", "--noacl", "--keepParent", folder, output]
  }

  public static func folderName(wall: Date, timeZone: TimeZone) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let day = calendar.dateComponents([.year, .month, .day], from: wall)
    return folderPrefix + String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
  }

  public static func defaultFileName(wall: Date, timeZone: TimeZone) -> String {
    folderName(wall: wall, timeZone: timeZone) + "." + archiveExtension
  }

  public static func failure(stage: String) -> Decision {
    Decision(keyword: .error, verb: failedVerb, fields: [DecisionField(key: "stage", value: stage)])
  }

  let paths: Paths
  let tools: any ToolPort
  let inputs: DiagnosticsInputs
  let clock: any ClockPort
  let helperLogDirectory: String?
  let temporaryDirectory: URL
  let timeZone: TimeZone
  let log: @Sendable (Decision) -> Void

  public init(
    paths: Paths, tools: any ToolPort, inputs: DiagnosticsInputs, clock: any ClockPort,
    helperLogDirectory: String? = nil, temporaryDirectory: URL = FileManager.default.temporaryDirectory,
    timeZone: TimeZone = .current, log: @escaping @Sendable (Decision) -> Void = { _ in }
  ) {
    self.paths = paths
    self.tools = tools
    self.inputs = inputs
    self.clock = clock
    self.helperLogDirectory = helperLogDirectory
    self.temporaryDirectory = temporaryDirectory
    self.timeZone = timeZone
    self.log = log
  }

  public func export(
    to destination: URL, progress: @escaping @Sendable (DiagnosticsProgress) -> Void
  ) async -> DiagnosticsResult {
    await withCheckedContinuation { continuation in
      Thread.detachNewThread {
        continuation.resume(returning: run(to: destination, progress: progress))
      }
    }
  }

  func run(to destination: URL, progress: (DiagnosticsProgress) -> Void) -> DiagnosticsResult {
    progress(.collecting)
    guard let staging = Self.makeStagingDirectory(in: temporaryDirectory) else {
      return failed(.writeFailed, stage: "staging")
    }
    defer { try? FileManager.default.removeItem(atPath: staging) }
    let folder = staging + "/" + Self.folderName(wall: clock.wall(), timeZone: timeZone)
    guard mkdir(folder, 0o700) == 0 else { return failed(.writeFailed, stage: "staging") }
    let collection = collect()
    let redactor = DiagnosticsRedactor(
      homeDirectory: inputs.homeDirectory, realHomeDirectory: Self.realPath(of: inputs.homeDirectory),
      networkNames: collection.networkNames)
    for item in collection.items {
      guard Self.write(Self.redacted(item, by: redactor), to: folder + "/" + item.name) else {
        return failed(.writeFailed, stage: "staging")
      }
    }
    progress(.archiving)
    let output = staging + "/" + Self.stagedArchiveName
    switch tools.run(Self.ditto, Self.dittoArguments(folder: folder, output: output)) {
    case .finished(exitCode: 0, _, _):
      break
    case .timedOut:
      return failed(.timedOut, stage: "timeout")
    case .finished, .launchFailed:
      return failed(.writeFailed, stage: "archive")
    }
    guard chmod(output, 0o600) == 0, Self.place(output, at: destination.path(percentEncoded: false)) else {
      return failed(.writeFailed, stage: "destination")
    }
    return .saved(fileName: destination.lastPathComponent, partial: collection.partial)
  }

  private func failed(_ failure: DiagnosticsFailure, stage: String) -> DiagnosticsResult {
    log(Self.failure(stage: stage))
    return .failed(failure)
  }

  static func redacted(_ item: Item, by redactor: DiagnosticsRedactor) -> Data {
    let data = redactor.redact(item.data)
    guard DiagnosticsManifest.powerFiles.contains(item.name) else { return data }
    return Data(DiagnosticsPowerRedactor.redact(String(decoding: data, as: UTF8.self)).utf8)
  }

  func collect() -> Collection {
    var collection = Collection()
    collection.networkNames = [inputs.hotspot] + inputs.knownNetworks
    collection.add(DiagnosticsManifest.readmeFile, Data(DiagnosticsManifest.readmeText.utf8))
    for source in Self.fileSources(paths: paths) {
      collectFile(source.name, at: source.path, into: &collection)
    }
    if let helperLogDirectory {
      for name in DiagnosticsManifest.helperLogFiles {
        collectFile(name, at: helperLogDirectory + "/" + name, into: &collection)
      }
    }
    collectState(into: &collection)
    collectPowerStatus(into: &collection)
    if !collection.gaps.isEmpty {
      collection.add(DiagnosticsManifest.missingFile, Data(DiagnosticsManifest.missingText(collection.gaps).utf8))
    }
    return collection
  }

  private func collectFile(_ name: String, at path: String, into collection: inout Collection) {
    let read: PrivateFileRead
    if path == paths.sentinelLog.path(percentEncoded: false) {
      let tail = PrivateFile.readTail(at: path, maxBytes: Self.maxFileBytes)
      read = tail.read
      if tail.cut {
        collection.miss(name, DiagnosticsGap.onlyTail(Self.maxFileBytes), .cut)
      }
    } else {
      read = PrivateFile.read(at: path, maxBytes: Self.maxFileBytes)
    }
    switch read {
    case .data(let data):
      if path == paths.settingsFile.path(percentEncoded: false) {
        guard let hotspot = Self.storedHotspot(in: data) else {
          collection.miss(name, DiagnosticsGap.notSettings, .failed)
          return
        }
        collection.networkNames.append(hotspot)
      }
      collection.add(name, data)
    case .missing:
      collection.miss(name, DiagnosticsGap.notFound, .absent)
    case .notRegular:
      collection.miss(name, DiagnosticsGap.notRegular, .failed)
    case .tooLarge:
      collection.miss(name, DiagnosticsGap.tooLarge(Self.maxFileBytes), .failed)
    case .failed:
      collection.miss(name, DiagnosticsGap.unreadable, .failed)
    }
  }

  private func collectState(into collection: inout Collection) {
    if let snapshot = inputs.snapshot {
      collection.add(DiagnosticsManifest.snapshotFile, DiagnosticsManifest.snapshotJSON(snapshot))
    } else {
      collection.miss(DiagnosticsManifest.snapshotFile, DiagnosticsGap.noSnapshot, .failed)
    }
    if let record = inputs.selfTest {
      collection.add(DiagnosticsManifest.selfTestFile, DiagnosticsManifest.selfTestJSON(record))
    } else {
      collection.miss(DiagnosticsManifest.selfTestFile, DiagnosticsGap.noSelfTest, .absent)
    }
    collection.add(DiagnosticsManifest.statusFile, Data(DiagnosticsManifest.statusText(inputs).utf8))
    if let snapshot = inputs.snapshot {
      let text = DiagnosticsManifest.detectionHealthText(
        snapshot.detectionWarnings, homeDirectory: inputs.homeDirectory)
      collection.add(DiagnosticsManifest.detectionHealthFile, Data(text.utf8))
    } else {
      collection.miss(DiagnosticsManifest.detectionHealthFile, DiagnosticsGap.noSnapshot, .failed)
    }
  }

  private func collectPowerStatus(into collection: inout Collection) {
    for command in Self.powerCommands {
      switch tools.run(Self.pmset, command.arguments) {
      case .finished(exitCode: 0, let output, _):
        let text = command.lines.map { DiagnosticsManifest.pmsetLogTail(output, lines: $0) } ?? output
        collection.add(command.file, Data(text.utf8))
      case .finished(let status, _, _):
        collection.miss(command.file, DiagnosticsGap.exited(status), .failed)
      case .timedOut:
        collection.miss(command.file, DiagnosticsGap.timedOut, .failed)
      case .launchFailed:
        collection.miss(command.file, DiagnosticsGap.notStarted, .failed)
      }
    }
  }

  static let powerCommands: [(file: String, arguments: [String], lines: Int?)] = [
    (DiagnosticsManifest.pmsetSettingsFile, pmsetSettingsArguments, nil),
    (DiagnosticsManifest.pmsetAssertionsFile, pmsetAssertionsArguments, nil),
    (DiagnosticsManifest.pmsetLogFile, pmsetLogArguments, DiagnosticsManifest.pmsetLogLines),
  ]

  static func fileSources(paths: Paths) -> [(name: String, path: String)] {
    let logs = [paths.decisionLog(.live), paths.errorLog(.live)].flatMap { url in
      [url, url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + rotatedSuffix)]
    }
    let files =
      logs + [
        paths.sentinelLog, paths.settingsFile, paths.preferencesFile, paths.stateFile(.live),
      ]
    return files.map { (name: $0.lastPathComponent, path: $0.path(percentEncoded: false)) }
  }

  static func storedHotspot(in settings: Data) -> String? {
    (try? JSONDecoder().decode(Settings.self, from: settings))?.hotspot
  }

  static func realPath(of path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  static func makeStagingDirectory(in parent: URL) -> String? {
    var template = Array(parent.appendingPathComponent(stagingTemplate).path(percentEncoded: false).utf8CString)
    let created = template.withUnsafeMutableBufferPointer { mkdtemp($0.baseAddress) != nil }
    guard created else { return nil }
    return String(decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  static func write(_ data: Data, to path: String) -> Bool {
    let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    return writeAll(data, to: descriptor)
  }

  static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
    data.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let count = Darwin.write(descriptor, buffer.baseAddress?.advanced(by: offset), buffer.count - offset)
        if count < 0 {
          if errno == EINTR { continue }
          return false
        }
        offset += count
      }
      return true
    }
  }

  static func renameError(_ source: String, _ destination: String) -> Int32 {
    rename(source, destination) == 0 ? 0 : errno
  }

  static func place(
    _ source: String, at destination: String, rename: (String, String) -> Int32 = DiagnosticsExporter.renameError
  ) -> Bool {
    switch rename(source, destination) {
    case 0: true
    case EXDEV: copy(source, to: destination)
    default: false
    }
  }

  static func copy(_ source: String, to destination: String) -> Bool {
    guard case .data(let data) = PrivateFile.read(at: source, maxBytes: Int.max) else { return false }
    unlink(destination)
    guard write(data, to: destination) else {
      unlink(destination)
      return false
    }
    return true
  }
}
