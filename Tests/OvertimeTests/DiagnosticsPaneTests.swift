import AppKit
import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import OvertimeHelperCore
import OvertimeSystem
import Testing
import os

import struct SwiftUI.Color

@testable import Overtime

@MainActor
struct DiagnosticsPaneTests {
  final class FakeSavePanel: SavePanelPort {
    private var picks: [URL?]
    private(set) var names: [String] = []
    private var held: CheckedContinuation<Void, Never>?
    var holds = false

    init(_ picks: [URL?]) {
      self.picks = picks
    }

    func chooseDestination(defaultName: String) async -> URL? {
      names.append(defaultName)
      if holds {
        await withCheckedContinuation { held = $0 }
      }
      return picks.isEmpty ? nil : picks.removeFirst()
    }

    func answer() {
      held?.resume()
      held = nil
    }
  }

  final class FakeExporter: DiagnosticsExporting {
    private struct State {
      var result: DiagnosticsResult
      var destinations: [URL] = []
      var waiting: [CheckedContinuation<Void, Never>] = []
      var tokens = 0
    }

    private let state: OSAllocatedUnfairLock<State>
    let holds: Bool

    init(_ result: DiagnosticsResult, holds: Bool = false) {
      state = OSAllocatedUnfairLock(initialState: State(result: result))
      self.holds = holds
    }

    var destinations: [URL] {
      state.withLock { $0.destinations }
    }

    func script(_ result: DiagnosticsResult) {
      state.withLock { $0.result = result }
    }

    func advance() {
      let next = state.withLock { state -> CheckedContinuation<Void, Never>? in
        guard !state.waiting.isEmpty else {
          state.tokens += 1
          return nil
        }
        return state.waiting.removeFirst()
      }
      next?.resume()
    }

    private func gate() async {
      guard holds else { return }
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let proceed = state.withLock { state -> Bool in
          guard state.tokens == 0 else {
            state.tokens -= 1
            return true
          }
          state.waiting.append(continuation)
          return false
        }
        if proceed { continuation.resume() }
      }
    }

    func export(
      to destination: URL, progress: @escaping @Sendable (DiagnosticsProgress) -> Void
    ) async -> DiagnosticsResult {
      state.withLock { $0.destinations.append(destination) }
      progress(.collecting)
      await gate()
      progress(.archiving)
      await gate()
      return state.withLock { $0.result }
    }
  }

  final class FakeWiFi: WiFiInfoPort {
    private let threads = OSAllocatedUnfairLock<[String]>(initialState: [])
    private let returned = OSAllocatedUnfairLock(initialState: 0)
    private let gate = DispatchSemaphore(value: 0)
    let networks: [String]?
    let holds: Bool

    init(networks: [String]?, holds: Bool = false) {
      self.networks = networks
      self.holds = holds
    }

    var reads: [String] {
      threads.withLock { $0 }
    }

    var readsReturned: Int {
      returned.withLock { $0 }
    }

    func release() {
      for _ in 0..<4 { gate.signal() }
    }

    func interfaceName() -> String? {
      nil
    }

    func knownNetworkNames() -> [String]? {
      threads.withLock { $0.append(Thread.isMainThread ? "main" : "background") }
      if holds { _ = gate.wait(timeout: .now() + FakeHelperInstaller.heldSeconds) }
      returned.withLock { $0 += 1 }
      return networks
    }
  }

  @MainActor final class Started {
    private(set) var finished = false

    init(_ work: @escaping @MainActor () async -> Void) {
      Task {
        await work()
        finished = true
      }
    }

    func settles(within seconds: Double = 5) async -> Bool {
      await waitUntil(timeout: seconds) { self.finished }
    }
  }

  final class Revealed {
    private(set) var urls: [[URL]] = []

    func append(_ batch: [URL]) {
      urls.append(batch)
    }
  }

  static let testHome = "/Users/someone"
  static let fileName = "Overtime-diagnostics-2026-09-27.zip"
  static let chosen = URL(fileURLWithPath: "/tmp/overtime-diagnostics-test/" + fileName)
  static let logs = URL(fileURLWithPath: "/tmp/overtime-diagnostics-test/logs", isDirectory: true)
  static let saved = DiagnosticsResult.saved(fileName: fileName, partial: false)

  static var today: Date {
    ISO8601DateFormatter().date(from: "2026-09-27T12:00:00Z") ?? Date(timeIntervalSince1970: 0)
  }

  @MainActor struct Fixture {
    let folder: TestFolder
    let host = FakeEngineHost()
    let panel = PanelModel()
    let settings: SettingsModel
    let savePanel: FakeSavePanel
    let exporter: FakeExporter
    let wifi: FakeWiFi
    let revealed = Revealed()
    let made = HelperPaneTests.EventLog()
    let gathered = OSAllocatedUnfairLock<[DiagnosticsInputs]>(initialState: [])

    init(
      picks: [URL?] = [DiagnosticsPaneTests.chosen], result: DiagnosticsResult = DiagnosticsPaneTests.saved,
      holds: Bool = false, stored: Settings? = nil, wifi: FakeWiFi = FakeWiFi(networks: ["Office", "Home"]),
      helper: HelperMonitorState? = nil
    ) throws {
      folder = try TestFolder()
      let file = folder.url.appendingPathComponent("settings.json")
      if let stored {
        try SettingsStore.save(stored, to: file)
      }
      panel.homeDirectory = DiagnosticsPaneTests.testHome
      panel.amphetamineLocator = .absent
      panel.bind(to: host)
      self.wifi = wifi
      let panel = panel
      var pane: HelperPaneModel?
      if let helper {
        pane = HelperPaneModel(panel: panel, source: HelperPaneTests.FakeHelperSource(helper))
        pane?.apply(helper)
      }
      settings = SettingsModel(
        settingsFile: file, host: host, wifi: wifi, panel: panel, helper: pane, environment: [:],
        homeDirectory: DiagnosticsPaneTests.testHome)
      savePanel = FakeSavePanel(picks)
      exporter = FakeExporter(result, holds: holds)
      let model = settings.diagnostics
      model.savePanel = savePanel
      model.logsDirectory = DiagnosticsPaneTests.logs
      model.now = { DiagnosticsPaneTests.today }
      model.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
      let revealed = revealed
      model.reveal = { revealed.append($0) }
      let exporter = exporter
      let gathered = gathered
      let made = made
      model.makeExporter = { inputs in
        gathered.withLock { $0.append(inputs) }
        made.append("exporter")
        return exporter
      }
    }

    var model: DiagnosticsModel {
      settings.diagnostics
    }

    var inputs: [DiagnosticsInputs] {
      gathered.withLock { $0 }
    }

    func export() async -> Bool {
      let model = model
      return await Started { await model.export() }.settles()
    }

    func reach(_ phase: DiagnosticsModel.Phase) async -> Bool {
      let model = model
      return await waitUntil { model.phase == phase }
    }
  }

  static let savedRow = DiagnosticsModel.ResultRow(
    symbol: "checkmark.circle.fill", tone: .success, title: "Saved Overtime-diagnostics-2026-09-27.zip.", caption: nil,
    showsReveal: true)

  @Test func aCancelledSavePanelChangesNothing() async throws {
    let fixture = try Fixture(picks: [nil])
    #expect(fixture.model.canExport)
    #expect(await fixture.export())
    #expect(fixture.savePanel.names == ["Overtime-diagnostics-2026-09-27.zip"])
    #expect(fixture.model.phase == .idle)
    #expect(fixture.model.resultRow == nil)
    #expect(fixture.model.progressText == nil)
    #expect(fixture.model.announcement == nil)
    #expect(fixture.model.canExport)
    #expect(fixture.made.all.isEmpty)
    #expect(fixture.wifi.reads.isEmpty)
  }

  @Test func aChosenFileDisablesTheButtonAndShowsCollectingThenArchivingThenTheSavedRow() async throws {
    let fixture = try Fixture(holds: true)
    let model = fixture.model
    let running = Started { await model.export() }
    #expect(await fixture.reach(.exporting(.collecting)))
    #expect(model.progressText == "Collecting logs and power status…")
    #expect(!model.canExport)
    #expect(model.isExporting)
    #expect(model.resultRow == nil)
    #expect(model.announcement == nil)
    #expect(await waitUntil { fixture.exporter.destinations == [Self.chosen] })
    #expect(model.phase == .exporting(.collecting))
    fixture.exporter.advance()
    #expect(await fixture.reach(.exporting(.archiving)))
    #expect(model.progressText == "Creating the archive…")
    #expect(!model.canExport)
    #expect(model.resultRow == nil)
    fixture.exporter.advance()
    #expect(await running.settles())
    #expect(model.phase == .saved(fileName: Self.fileName, url: Self.chosen, partial: false))
    #expect(model.resultRow == Self.savedRow)
    #expect(model.progressText == nil)
    #expect(model.canExport)
    #expect(!model.isExporting)
    #expect(model.announcement == "Diagnostics saved.")
  }

  @Test func theSavedRowNamesTheFileTheExporterReports() async throws {
    let fixture = try Fixture(result: .saved(fileName: "for support.zip", partial: false))
    #expect(await fixture.export())
    #expect(fixture.model.resultRow?.title == "Saved for support.zip.")
    #expect(DiagnosticsModel.savedTitle("a.zip") == "Saved a.zip.")
  }

  @Test func aPartialExportAddsTheMissingItemsCaption() async throws {
    let fixture = try Fixture(result: .saved(fileName: Self.fileName, partial: true))
    #expect(await fixture.export())
    #expect(
      fixture.model.resultRow
        == DiagnosticsModel.ResultRow(
          symbol: "checkmark.circle.fill", tone: .success, title: "Saved Overtime-diagnostics-2026-09-27.zip.",
          caption: "Some items couldn't be collected. The archive lists them in missing.txt.", showsReveal: true))
    #expect(fixture.model.announcement == "Diagnostics saved.")
  }

  struct FailureCase: Sendable, CustomTestStringConvertible {
    let failure: DiagnosticsFailure
    let reason: String

    var testDescription: String {
      reason
    }
  }

  @Test(arguments: [
    FailureCase(
      failure: .writeFailed, reason: "The archive couldn't be written to that folder. Choose another folder."),
    FailureCase(failure: .timedOut, reason: "Creating the archive took too long. Try exporting again."),
  ])
  func eachFailureShowsItsReasonVerbatimAndTheButtonIsOnAgain(_ item: FailureCase) async throws {
    let fixture = try Fixture(result: .failed(item.failure))
    #expect(await fixture.export())
    #expect(fixture.model.phase == .failed(item.failure))
    #expect(
      fixture.model.resultRow
        == DiagnosticsModel.ResultRow(
          symbol: "xmark.circle.fill", tone: .error, title: "Couldn't export diagnostics.", caption: item.reason,
          showsReveal: false))
    #expect(fixture.model.canExport)
    #expect(fixture.model.progressText == nil)
    #expect(fixture.model.announcement == "Couldn't export diagnostics.")
    fixture.model.showInFinder()
    #expect(fixture.revealed.urls.isEmpty)
  }

  @Test func theResultRowSurvivesClosingAndReopeningThePaneAndACancelledPanelAndGoesWithTheNextExport() async throws {
    let fixture = try Fixture(picks: [Self.chosen, nil, Self.chosen], holds: true)
    let model = fixture.model
    fixture.exporter.advance()
    fixture.exporter.advance()
    #expect(await fixture.export())
    #expect(model.resultRow == Self.savedRow)
    fixture.settings.close()
    fixture.settings.select(.general)
    fixture.settings.open(pane: .diagnostics)
    #expect(model.resultRow == Self.savedRow)
    #expect(await fixture.export())
    #expect(fixture.savePanel.names.count == 2)
    #expect(model.resultRow == Self.savedRow)
    #expect(fixture.exporter.destinations.count == 1)
    fixture.exporter.script(.failed(.timedOut))
    let running = Started { await model.export() }
    #expect(await fixture.reach(.exporting(.collecting)))
    #expect(model.resultRow == nil)
    fixture.exporter.advance()
    fixture.exporter.advance()
    #expect(await running.settles())
    #expect(model.resultRow?.title == "Couldn't export diagnostics.")
  }

  @Test func anExportThatFinishesWhileTheWindowIsClosedStillShowsItsResult() async throws {
    let fixture = try Fixture(holds: true)
    let model = fixture.model
    fixture.settings.open(pane: .diagnostics)
    let running = Started { await model.export() }
    #expect(await fixture.reach(.exporting(.collecting)))
    fixture.settings.close()
    fixture.exporter.advance()
    fixture.exporter.advance()
    #expect(await running.settles())
    fixture.settings.open(pane: .diagnostics)
    #expect(model.resultRow == Self.savedRow)
  }

  @Test func aSecondPressWhileThePanelIsOpenOrAnExportRunsDoesNothing() async throws {
    let fixture = try Fixture(picks: [Self.chosen, Self.chosen], holds: true)
    let model = fixture.model
    fixture.savePanel.holds = true
    let first = Started { await model.export() }
    #expect(await waitUntil { fixture.savePanel.names.count == 1 })
    #expect(await fixture.export())
    #expect(fixture.savePanel.names.count == 1)
    #expect(model.canExport)
    fixture.savePanel.answer()
    #expect(await fixture.reach(.exporting(.collecting)))
    fixture.savePanel.holds = false
    #expect(await fixture.export())
    #expect(fixture.savePanel.names.count == 1)
    fixture.exporter.advance()
    fixture.exporter.advance()
    #expect(await first.settles())
    #expect(fixture.made.all == ["exporter"])
    #expect(model.resultRow == Self.savedRow)
    #expect(fixture.exporter.destinations == [Self.chosen])
  }

  @Test func withoutASavePanelOrAnExporterTheButtonIsOffAndNothingRuns() async throws {
    let fixture = try Fixture()
    let model = fixture.model
    let make = model.makeExporter
    model.makeExporter = nil
    #expect(!model.canExport)
    #expect(await fixture.export())
    #expect(fixture.savePanel.names.isEmpty)
    model.makeExporter = make
    model.savePanel = nil
    #expect(!model.canExport)
    #expect(await fixture.export())
    #expect(fixture.made.all.isEmpty)
    #expect(model.phase == .idle)
    let fresh = SettingsModel(settingsFile: fixture.folder.url.appendingPathComponent("other.json"))
    #expect(!fresh.diagnostics.canExport)
    fresh.diagnostics.showLogsInFinder()
    fresh.diagnostics.showInFinder()
  }

  @Test func theExporterGetsTheHomeFolderTheHotspotAndTheKnownNetworksReadOffTheMainThread() async throws {
    let fixture = try Fixture(stored: Settings(hotspot: "Ivan’s iPhone"))
    #expect(await fixture.export())
    #expect(fixture.inputs.count == 1)
    #expect(fixture.inputs.first?.homeDirectory == "/Users/someone")
    #expect(fixture.inputs.first?.hotspot == "Ivan’s iPhone")
    #expect(fixture.inputs.first?.knownNetworks == ["Office", "Home"])
    #expect(fixture.inputs.first?.knownNetworksRead == true)
    #expect(fixture.wifi.reads == ["background"])
  }

  @Test func knownNetworksThatCannotBeReadStillExportWithTheHotspot() async throws {
    let fixture = try Fixture(stored: Settings(hotspot: "Ivan’s iPhone"), wifi: FakeWiFi(networks: nil))
    #expect(await fixture.export())
    #expect(fixture.inputs.first?.hotspot == "Ivan’s iPhone")
    #expect(fixture.inputs.first?.knownNetworks == [])
    #expect(fixture.inputs.first?.knownNetworksRead == false)
    #expect(fixture.model.resultRow == Self.savedRow)
  }

  @Test func aKnownNetworksReadThatOutlastsItsBoundDoesNotHoldTheExport() async throws {
    let wifi = FakeWiFi(networks: ["Late"], holds: true)
    defer { wifi.release() }
    let fixture = try Fixture(wifi: wifi)
    fixture.model.networksTimeoutSeconds = 0.05
    #expect(await fixture.export())
    #expect(wifi.readsReturned == 0)
    #expect(fixture.inputs.first?.knownNetworks == [])
    #expect(fixture.inputs.first?.knownNetworksRead == false)
    #expect(fixture.model.resultRow == Self.savedRow)
    #expect(DiagnosticsModel().networksTimeoutSeconds == 5)
  }

  @Test func theProgressRowShowsAndTheButtonIsOffWhileTheKnownNetworksAreStillBeingRead() async throws {
    let wifi = FakeWiFi(networks: ["Slow"], holds: true)
    defer { wifi.release() }
    let fixture = try Fixture(wifi: wifi)
    let model = fixture.model
    let running = Started { await model.export() }
    #expect(await fixture.reach(.exporting(.collecting)))
    #expect(fixture.made.all.isEmpty)
    #expect(!model.canExport)
    #expect(model.progressText == "Collecting logs and power status…")
    #expect(wifi.readsReturned == 0)
    wifi.release()
    #expect(await running.settles())
    #expect(fixture.inputs.first?.knownNetworks == ["Slow"])
    #expect(model.resultRow == Self.savedRow)
  }

  static let helperState = HelperMonitorState(
    installer: .enabled, reachability: .reachable, status: HelperStatus(helperVersion: 1, sleepDisabled: true),
    lastError: "status failed")

  @Test func theExporterGetsTheSnapshotTheLoginItemTheHelperStateTheStoredSelfTestAndTheSystemValuesOfThatMoment()
    async throws
  {
    let fixture = try Fixture(picks: [Self.chosen, Self.chosen], helper: Self.helperState)
    let record = SelfTestRecord(outcome: .passed, reason: nil, at: Self.today, osBuild: "26A428", osVersion: "27.0")
    try AppPreferencesStore.update(at: fixture.settings.preferencesFile) { $0.selfTest = record }
    fixture.settings.reloadPreferences()
    fixture.settings.setupInfo = SetupInfo(
      appVersion: "9.8.7", osVersion: "27.1", osBuild: "26B100", hardwareModel: "Mac99,1")
    fixture.panel.attachLoginItem(PanelModelTests.FakeLoginItem(status: .requiresApproval))
    let first = EngineSnapshot(wanted: true, reason: "busy", lidClosed: false, helperEngaged: true)
    fixture.host.publish(first)
    #expect(await waitUntil { fixture.panel.snapshot == first })
    #expect(await fixture.export())
    let expected = DiagnosticsInputs(
      homeDirectory: "/Users/someone", hotspot: "", knownNetworks: ["Office", "Home"], knownNetworksRead: true,
      snapshot: first, loginItem: .requiresApproval, helper: Self.helperState, selfTest: record, appVersion: "9.8.7",
      osVersion: "27.1", osBuild: "26B100", hardwareModel: "Mac99,1")
    #expect(fixture.inputs == [expected])
    let second = EngineSnapshot(wanted: false, reason: "idle", lidClosed: true)
    fixture.host.publish(second)
    #expect(await waitUntil { fixture.panel.snapshot == second })
    #expect(await fixture.export())
    #expect(fixture.inputs.last?.snapshot == second)
    #expect(fixture.inputs.count == 2)
  }

  @Test func withoutAnEngineAMonitorOrAStoredResultThoseInputsAreEmpty() async throws {
    let folder = try TestFolder()
    let settings = SettingsModel(
      settingsFile: folder.url.appendingPathComponent("settings.json"), environment: [:], homeDirectory: Self.testHome)
    settings.setupInfo = SetupInfo(appVersion: "1", osVersion: "2", osBuild: nil, hardwareModel: nil)
    let inputs = settings.diagnostics.inputs()
    #expect(
      inputs
        == DiagnosticsInputs(
          homeDirectory: "/Users/someone", hotspot: "", knownNetworks: [], knownNetworksRead: false, snapshot: nil,
          loginItem: nil, helper: nil, selfTest: nil, appVersion: "1", osVersion: "2", osBuild: nil,
          hardwareModel: nil))
  }

  @Test func theDetectionHealthTextOfTheArchiveUsesThePanesWordsForNoProblems() {
    #expect(DiagnosticsManifest.noDetectionProblems == DiagnosticsPane.noProblemsTitle)
  }

  @Test func showInFinderRevealsTheSavedFileAndShowLogsRevealsTheLogsFolder() async throws {
    let fixture = try Fixture()
    fixture.model.showInFinder()
    #expect(fixture.revealed.urls.isEmpty)
    fixture.model.showLogsInFinder()
    #expect(fixture.revealed.urls == [[Self.logs]])
    #expect(await fixture.export())
    fixture.model.showInFinder()
    #expect(fixture.revealed.urls == [[Self.logs], [Self.chosen]])
  }

  @Test func theDefaultNameCarriesTheLocalDate() throws {
    let model = DiagnosticsModel()
    model.now = { Self.today.addingTimeInterval(11.5 * 3_600) }
    model.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    #expect(model.defaultFileName == "Overtime-diagnostics-2026-09-27.zip")
    model.timeZone = try #require(TimeZone(secondsFromGMT: 3_600))
    #expect(model.defaultFileName == "Overtime-diagnostics-2026-09-28.zip")
  }

  @Test func theCopyIsTheUISpecCopy() {
    #expect(DiagnosticsModel.sectionTitle == "Export")
    #expect(
      DiagnosticsModel.caption
        == "Creates a zip with Overtime's logs, settings, state, self-test result, helper status and power status. Your home folder appears as ~, network names are removed, and no transcript content or process arguments are included."
    )
    #expect(DiagnosticsModel.exportTitle == "Export Diagnostics…")
    #expect(DiagnosticsModel.showLogsTitle == "Show Logs in Finder")
    #expect(DiagnosticsModel.showInFinderTitle == "Show in Finder")
    #expect(AppKitSavePanel.message == "Choose where to save the diagnostics archive.")
    #expect(AppKitSavePanel.prompt == "Export Archive")
    #expect(AppKitSavePanel.defaultFolder?.lastPathComponent == "Desktop")
    #expect(DiagnosticsModel.progressText(.collecting) == "Collecting logs and power status…")
    #expect(DiagnosticsModel.progressText(.archiving) == "Creating the archive…")
    #expect(ExportStatusView.tint(for: .success) == Color.green)
    #expect(ExportStatusView.tint(for: .error) == Color.red)
  }
}
