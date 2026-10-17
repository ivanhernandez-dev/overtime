import Foundation
import OvertimeAppSupport
import Testing

struct KeepDisplayOnSourceGateTests {
  typealias SourceFile = AppViewSourceGuardTests.SourceFile

  static let controlsFile = "ControlsSection.swift"
  static let settingsModelFile = "SettingsModel.swift"
  static let appDelegateFile = "AppDelegate.swift"
  static let panelModelFile = "PanelModel.swift"
  static let rowPlacement = "KeepDisplayOnRow(model: model)"

  static let rowCounts: [(needle: String, expected: Int, what: String)] = [
    (rowPlacement, 1, "places the display switch row"),
    ("Toggle(", 1, "builds a switch"),
    (".toggleStyle(.switch)", 1, "styles a switch"),
    (".controlSize(.mini)", 1, "makes a mini switch"),
    (".labelsHidden()", 1, "hides the switch's own label"),
    ("Image(systemName: ControlMapping.keepDisplayOnSymbol)", 1, "draws the display symbol"),
    ("model.setKeepDisplayOn(", 1, "sends the switch to the panel model"),
    ("\"" + ControlMapping.keepDisplayOnLabel, 0, "spells the switch label"),
  ]

  static func rowFindings(in files: [SourceFile]) -> [String] {
    guard let file = files.first(where: { $0.name == controlsFile }) else {
      return [AppViewSourceGuardTests.missing(controlsFile)]
    }
    var findings: [String] = []
    for count in rowCounts {
      let found = AppViewSourceGuardTests.occurrences(of: count.needle, in: file.text)
      if found != count.expected {
        findings.append("\(file.name) \(count.what) \(found) times, expected \(count.expected)")
      }
    }
    let squeezed = file.text.filter { !$0.isWhitespace }
    let release = squeezed.range(of: "ControlMapping.releaseUntilIdleLabel")
    let row = squeezed.range(of: rowPlacement.filter { !$0.isWhitespace })
    let restore = squeezed.range(of: "ControlMapping.restoreLabel")
    let inOrder =
      if let release, let row, let restore {
        release.lowerBound < row.lowerBound && row.lowerBound < restore.lowerBound
      } else {
        false
      }
    if !inOrder {
      findings.append(
        "\(file.name) does not place the display switch row between Release Until Idle and Restore Normal Sleep Now")
    }
    return findings
  }

  static func writerFindings(in files: [SourceFile]) -> [String] {
    var findings: [String] = []
    for name in [settingsModelFile, appDelegateFile, panelModelFile] where !files.contains(where: { $0.name == name }) {
      findings.append(AppViewSourceGuardTests.missing(name))
    }
    let committers = files.filter { $0.text.contains("SettingsCommitter.commit(") }
    let commitCount = committers.reduce(0) {
      $0 + AppViewSourceGuardTests.occurrences(of: "SettingsCommitter.commit(", in: $1.text)
    }
    if committers.map(\.name) != [settingsModelFile] || commitCount != 1 {
      findings.append(
        "the app sources commit settings in \(committers.map(\.name).joined(separator: ", ")), "
          + "expected only \(settingsModelFile) once")
    }
    let assignments = files.flatMap { file in
      AppViewSourceGuardTests.lineNumbers(in: file.text) { $0.contains(#/\.keepDisplayOn\s*=(?!=)/#) }
        .map { (name: file.name, line: $0) }
    }
    if assignments.count != 1 || assignments.first?.name != settingsModelFile {
      let places = assignments.map { "\($0.name):\($0.line)" }.joined(separator: ", ")
      findings.append("the app sources assign keepDisplayOn in \(places), expected once in \(settingsModelFile)")
    }
    if let delegate = files.first(where: { $0.name == appDelegateFile }) {
      let delegateCounts: [(needle: String, what: String)] = [
        ("= SettingsModel(", "builds a settings model"),
        ("model.onSetKeepDisplayOn =", "wires the panel switch"),
        (".setKeepDisplayOn(", "commits the panel switch through the shared settings model"),
      ]
      for count in delegateCounts {
        let found = AppViewSourceGuardTests.occurrences(of: count.needle, in: delegate.text)
        if found != 1 {
          findings.append("\(appDelegateFile) \(count.what) \(found) times, expected 1")
        }
      }
    }
    if let panel = files.first(where: { $0.name == panelModelFile }), panel.text.contains("SettingsStore.") {
      findings.append("\(panelModelFile) touches the settings store")
    }
    return findings
  }

  static let plantedRelease = "icon: \"arrow.uturn.backward.circle\", title: ControlMapping.releaseUntilIdleLabel,"
  static let plantedRow = "KeepDisplayOnRow(model: model)"
  static let plantedRestore = "icon: \"arrow.counterclockwise.circle\", title: ControlMapping.restoreLabel,"
  static let plantedToggle =
    "Toggle(ControlMapping.keepDisplayOnLabel, isOn: Binding(get: { isOn }, set: { setKeepDisplayOn($0) }))"
  static let plantedCommit = "let result = await SettingsCommitter.commit(candidate, to: settingsFile, host: host)"
  static let plantedSettingsModel = "let settingsModel = SettingsModel("
  static let plantedPanelRead = "snapshot?.keepDisplayOn ?? false"

  static func plantedSources() -> [SourceFile] {
    [
      AppViewSourceGuardTests.planted(
        controlsFile,
        [
          plantedRelease,
          plantedRow,
          plantedRestore,
          "Image(systemName: ControlMapping.keepDisplayOnSymbol)",
          plantedToggle,
          "  .toggleStyle(.switch)",
          "  .controlSize(.mini)",
          "  .labelsHidden()",
          "setKeepDisplayOn: { enabled in Task { await model.setKeepDisplayOn(enabled) } })",
        ]),
      AppViewSourceGuardTests.planted(
        settingsModelFile, [plantedCommit, "candidate.keepDisplayOn = enabled"]),
      AppViewSourceGuardTests.planted(
        appDelegateFile,
        [
          plantedSettingsModel,
          "model.onSetKeepDisplayOn = { [weak self] enabled in await self?.commitKeepDisplayOn(enabled) }",
          "return await settings.setKeepDisplayOn(enabled)",
        ]),
      AppViewSourceGuardTests.planted(panelModelFile, [plantedPanelRead]),
    ]
  }

  enum Drift: CaseIterable, Sendable {
    case rowRemoved
    case rowAfterRestore
    case secondSwitch
    case literalLabel
    case panelModelCommits
    case secondSettingsModel
    case secondAssignment

    var file: String {
      switch self {
      case .rowRemoved, .rowAfterRestore, .secondSwitch, .literalLabel: KeepDisplayOnSourceGateTests.controlsFile
      case .panelModelCommits, .secondAssignment: KeepDisplayOnSourceGateTests.panelModelFile
      case .secondSettingsModel: KeepDisplayOnSourceGateTests.appDelegateFile
      }
    }

    var change: (old: String, new: String) {
      let row = KeepDisplayOnSourceGateTests.plantedRow
      let restore = KeepDisplayOnSourceGateTests.plantedRestore
      let toggle = KeepDisplayOnSourceGateTests.plantedToggle
      let read = KeepDisplayOnSourceGateTests.plantedPanelRead
      let model = KeepDisplayOnSourceGateTests.plantedSettingsModel
      return switch self {
      case .rowRemoved: (row + "\n", "\n")
      case .rowAfterRestore: (row + "\n" + restore, restore + "\n" + row)
      case .secondSwitch: (toggle, toggle + "\n" + toggle)
      case .literalLabel:
        ("Toggle(ControlMapping.keepDisplayOnLabel,", "Toggle(\"" + ControlMapping.keepDisplayOnLabel + "\",")
      case .panelModelCommits: (read, read + "\n" + KeepDisplayOnSourceGateTests.plantedCommit)
      case .secondSettingsModel: (model, model + "\n" + "let other = SettingsModel(")
      case .secondAssignment: (read, read + "\n" + "settings.keepDisplayOn = enabled")
      }
    }

    var phrase: String {
      switch self {
      case .rowRemoved: "places the display switch row 0 times, expected 1"
      case .rowAfterRestore: "does not place the display switch row between"
      case .secondSwitch: "builds a switch 2 times, expected 1"
      case .literalLabel: "spells the switch label 1 times, expected 0"
      case .panelModelCommits: "the app sources commit settings in"
      case .secondSettingsModel: "AppDelegate.swift builds a settings model 2 times, expected 1"
      case .secondAssignment: "the app sources assign keepDisplayOn in"
      }
    }
  }

  @Test func theAppSourcesPlaceTheSwitchRowAndKeepOneSettingsWriter() throws {
    let files = try AppViewSourceGuardTests.appSourceFiles()
    #expect(files.count > 40)
    #expect(Self.rowFindings(in: files) == [])
    #expect(Self.writerFindings(in: files) == [])
  }

  @Test func theUndriftedPlantedSourcesHaveNoFindings() {
    let files = Self.plantedSources()
    #expect(Self.rowFindings(in: files) == [])
    #expect(Self.writerFindings(in: files) == [])
    #expect(Self.rowFindings(in: []) == [AppViewSourceGuardTests.missing(Self.controlsFile)])
  }

  @Test(arguments: Drift.allCases)
  func aDriftedSourceIsReported(drift: Drift) throws {
    #expect(Drift.allCases.count == 7)
    let files = try Self.plantedSources().map { file -> SourceFile in
      guard file.name == drift.file else { return file }
      let change = drift.change
      let range = try #require(file.text.range(of: change.old), "the planted source does not hold \(change.old)")
      return SourceFile(
        name: file.name, path: file.path, text: file.text.replacingCharacters(in: range, with: change.new))
    }
    let findings = Self.rowFindings(in: files) + Self.writerFindings(in: files)
    #expect(findings.contains { $0.contains(drift.phrase) }, "\(findings)")
  }
}
