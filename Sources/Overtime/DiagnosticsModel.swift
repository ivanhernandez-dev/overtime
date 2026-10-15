import Foundation
import Observation
import OvertimeAppSupport
import OvertimeCore
import OvertimeSystem

@Observable
final class DiagnosticsModel {
  enum Phase: Equatable {
    case idle
    case exporting(DiagnosticsProgress)
    case saved(fileName: String, url: URL, partial: Bool)
    case failed(DiagnosticsFailure)
  }

  struct ResultRow: Equatable {
    enum Tone: Equatable {
      case success
      case error
    }

    let symbol: String
    let tone: Tone
    let title: String
    let caption: String?
    let showsReveal: Bool
  }

  static let sectionTitle = "Export"
  static let caption =
    "Creates a zip with Overtime's logs, settings, state, self-test result, helper status and power status. Your home folder appears as ~, network names are removed, and no transcript content or process arguments are included."
  static let exportTitle = DiagnosticsManifest.exportLabel
  static let showLogsTitle = "Show Logs in Finder"
  static let showInFinderTitle = "Show in Finder"
  static let collectingText = "Collecting logs and power status…"
  static let archivingText = "Creating the archive…"
  static let savedSymbol = "checkmark.circle.fill"
  static let failedSymbol = "xmark.circle.fill"
  static let failedTitle = "Couldn't export diagnostics."
  static let writeFailedReason = "The archive couldn't be written to that folder. Choose another folder."
  static let timedOutReason = "Creating the archive took too long. Try exporting again."
  static let partialCaption = "Some items couldn't be collected. The archive lists them in missing.txt."
  static let savedAnnouncement = "Diagnostics saved."

  static func savedTitle(_ fileName: String) -> String {
    "Saved \(fileName)."
  }

  static func reason(for failure: DiagnosticsFailure) -> String {
    switch failure {
    case .writeFailed: writeFailedReason
    case .timedOut: timedOutReason
    }
  }

  static func progressText(_ progress: DiagnosticsProgress) -> String {
    switch progress {
    case .collecting: collectingText
    case .archiving: archivingText
    }
  }

  private(set) var phase: Phase = .idle

  @ObservationIgnored var savePanel: (any SavePanelPort)?
  @ObservationIgnored var makeExporter: ((DiagnosticsInputs) -> any DiagnosticsExporting)?
  @ObservationIgnored var inputs: () -> DiagnosticsInputs = { DiagnosticsInputs(homeDirectory: NSHomeDirectory()) }
  @ObservationIgnored var wifi: () -> (any WiFiInfoPort)? = { nil }
  @ObservationIgnored var reveal: ([URL]) -> Void = { _ in }
  @ObservationIgnored var now: () -> Date = { Date() }
  @ObservationIgnored var timeZone: TimeZone = .current
  @ObservationIgnored var logsDirectory: URL?
  @ObservationIgnored var networksTimeoutSeconds = Timing.systemCallTimeoutSeconds
  @ObservationIgnored private let runner = DeadlineRunner()
  @ObservationIgnored private var choosing = false

  var isExporting: Bool {
    if case .exporting = phase { return true }
    return false
  }

  var canExport: Bool {
    !isExporting && savePanel != nil && makeExporter != nil
  }

  var progressText: String? {
    guard case .exporting(let progress) = phase else { return nil }
    return Self.progressText(progress)
  }

  var resultRow: ResultRow? {
    switch phase {
    case .idle, .exporting:
      nil
    case .saved(let fileName, _, let partial):
      ResultRow(
        symbol: Self.savedSymbol, tone: .success, title: Self.savedTitle(fileName),
        caption: partial ? Self.partialCaption : nil, showsReveal: true)
    case .failed(let failure):
      ResultRow(
        symbol: Self.failedSymbol, tone: .error, title: Self.failedTitle, caption: Self.reason(for: failure),
        showsReveal: false)
    }
  }

  var announcement: String? {
    switch phase {
    case .idle, .exporting: nil
    case .saved: Self.savedAnnouncement
    case .failed: Self.failedTitle
    }
  }

  var defaultFileName: String {
    DiagnosticsExporter.defaultFileName(wall: now(), timeZone: timeZone)
  }

  func export() async {
    guard canExport, !choosing, let savePanel, let makeExporter else { return }
    choosing = true
    let chosen = await savePanel.chooseDestination(defaultName: defaultFileName)
    choosing = false
    guard let destination = chosen else { return }
    phase = .exporting(.collecting)
    let networks = await knownNetworks()
    var gathered = inputs()
    gathered.knownNetworks = networks ?? []
    gathered.knownNetworksRead = networks != nil
    let exporter = makeExporter(gathered)
    let (steps, feed) = AsyncStream.makeStream(of: DiagnosticsProgress.self)
    let running = Task {
      let result = await exporter.export(to: destination) { feed.yield($0) }
      feed.finish()
      return result
    }
    for await step in steps where phase != .exporting(step) {
      phase = .exporting(step)
    }
    switch await running.value {
    case .saved(let fileName, let partial):
      phase = .saved(fileName: fileName, url: destination, partial: partial)
    case .failed(let failure):
      phase = .failed(failure)
    }
  }

  func showInFinder() {
    guard case .saved(_, let url, _) = phase else { return }
    reveal([url])
  }

  func showLogsInFinder() {
    guard let logsDirectory else { return }
    reveal([logsDirectory])
  }

  private func knownNetworks() async -> [String]? {
    guard let wifi = wifi() else { return nil }
    let outcome = await runner.perform(timeout: networksTimeoutSeconds) { wifi.knownNetworkNames() }
    guard case .value(let names) = outcome else { return nil }
    return names
  }
}
