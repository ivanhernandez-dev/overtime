import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import SwiftUI

struct DetectionHealthRow: Equatable, Identifiable {
  let id: String
  let titlePrefix: String
  let displayPath: String?
  let caption: String
  let fullPath: String?

  var title: String {
    guard let displayPath else { return titlePrefix }
    return "\(titlePrefix) \(displayPath)"
  }

  var symbol: String {
    DiagnosticsPane.warningSymbol
  }

  var actionTitle: String {
    DiagnosticsPane.openDetectionSettingsTitle
  }
}

struct DiagnosticsPane: View {
  static let detectionHealthTitle = "Detection health"
  static let noProblemsTitle = "No detection problems found."
  static let noProblemsSymbol = "checkmark.circle.fill"
  static let reasonSpacing: CGFloat = 4
  static let warningSymbol = "exclamationmark.triangle.fill"
  static let openDetectionSettingsTitle = "Open Detection Settings"
  static let rootMissingCaption = "Overtime can't see Claude activity there."
  static let rootUnreadableCaption = "Check the folder's permissions, or remove it from the list."
  static let terminalSilenceTitle =
    "Claude has run in a terminal for \(Int(Timing.healthSilenceSeconds / 60)) minutes with no transcript activity."
  static let terminalSilenceCaption =
    "Claude Code may have moved its transcripts. Check the transcript folders, or export diagnostics and report it."

  static let setupTitle = "Setup"
  static let runOnboardingTitle = "Run Onboarding Again"

  static func setupCaption(_ info: SetupInfo) -> String {
    let build = info.osBuild.map { " (\($0))" } ?? ""
    let hardware = info.hardwareModel.map { ", \($0)" } ?? ""
    return "Overtime \(info.appVersion) on macOS \(info.osVersion)\(build)\(hardware)."
  }

  static let rootMissingPrefix = "Transcript folder not found:"
  static let rootUnreadablePrefix = "Can't read the transcript folder"

  static func rootMissingTitle(_ displayPath: String) -> String {
    "\(rootMissingPrefix) \(displayPath)"
  }

  static func rootUnreadableTitle(_ displayPath: String) -> String {
    "\(rootUnreadablePrefix) \(displayPath)"
  }

  static func rows(for warnings: [DetectionWarning], homeDirectory: String) -> [DetectionHealthRow] {
    warnings.map { warning in
      switch warning {
      case .rootMissing(let path):
        DetectionHealthRow(
          id: "missing:\(path)", titlePrefix: rootMissingPrefix,
          displayPath: PanelContent.abbreviatingHome(path, homeDirectory: homeDirectory),
          caption: rootMissingCaption, fullPath: path)
      case .rootUnreadable(let path):
        DetectionHealthRow(
          id: "unreadable:\(path)", titlePrefix: rootUnreadablePrefix,
          displayPath: PanelContent.abbreviatingHome(path, homeDirectory: homeDirectory),
          caption: rootUnreadableCaption, fullPath: path)
      case .terminalSilence:
        DetectionHealthRow(
          id: "terminalSilence", titlePrefix: terminalSilenceTitle, displayPath: nil,
          caption: terminalSilenceCaption, fullPath: nil)
      }
    }
  }

  let model: SettingsModel

  var body: some View {
    Form {
      Section {
        let rows = model.detectionHealthRows
        if rows.isEmpty {
          StatusRow(symbol: Self.noProblemsSymbol, tint: .green, title: Self.noProblemsTitle)
        } else {
          ForEach(rows) { row in
            DetectionHealthRowView(row: row, model: model)
          }
        }
      } header: {
        SettingsSectionHeader(title: Self.detectionHealthTitle)
      }
      Section {
        SelfTestRowView(row: model.selfTestRow)
        VStack(alignment: .leading, spacing: Self.reasonSpacing) {
          Button(SelfTestPresentation.runButtonTitle) {
            Task { await model.runSelfTest() }
          }
          .buttonStyle(.bordered)
          .controlSize(.regular)
          .disabled(!model.canRunSelfTest)
          .help(ifPresent: model.selfTestHelp)
          .accessibilityHint(ifPresent: model.selfTestHelp)
          if let reason = model.selfTestHelp {
            SettingsSectionCaption(text: reason)
              .accessibilityHidden(true)
          }
        }
      } header: {
        SettingsSectionHeader(title: SelfTestPresentation.sectionTitle)
      }
      Section {
        Text(DiagnosticsModel.caption)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 8) {
          Button(DiagnosticsModel.exportTitle) {
            Task { await model.diagnostics.export() }
          }
          .buttonStyle(.bordered)
          .controlSize(.regular)
          .disabled(!model.diagnostics.canExport)
          Button(DiagnosticsModel.showLogsTitle) {
            model.diagnostics.showLogsInFinder()
          }
          .buttonStyle(.link)
          .font(.subheadline)
        }
        ExportStatusView(model: model.diagnostics)
      } header: {
        SettingsSectionHeader(title: DiagnosticsModel.sectionTitle)
      }
      Section {
        Button(Self.runOnboardingTitle) {
          model.runOnboardingAgain()
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        Text(model.setupCaption)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .fixedSize(horizontal: false, vertical: true)
      } header: {
        SettingsSectionHeader(title: Self.setupTitle)
      }
    }
    .formStyle(.grouped)
    .transaction { $0.animation = nil }
    .onChange(of: model.selfTestStatus) {
      guard let announcement = model.selfTestAnnouncement else { return }
      AccessibilityNotification.Announcement(announcement).post()
    }
    .onChange(of: model.diagnostics.phase) {
      guard let announcement = model.diagnostics.announcement else { return }
      AccessibilityNotification.Announcement(announcement).post()
    }
  }
}

struct ExportStatusView: View {
  let model: DiagnosticsModel

  var body: some View {
    if let progress = model.progressText {
      StatusRow(icon: .progress, title: progress)
    } else if let row = model.resultRow {
      VStack(alignment: .leading, spacing: 4) {
        StatusRow(symbol: row.symbol, tint: Self.tint(for: row.tone), title: row.title, caption: row.caption)
        if row.showsReveal {
          Button(DiagnosticsModel.showInFinderTitle) {
            model.showInFinder()
          }
          .buttonStyle(.link)
          .font(.subheadline)
          .padding(.leading, StatusRowLayout.textInset)
        }
      }
    }
  }

  static func tint(for tone: DiagnosticsModel.ResultRow.Tone) -> Color {
    switch tone {
    case .success: .green
    case .error: .red
    }
  }
}

struct SelfTestRowView: View {
  let row: SelfTestRow

  var body: some View {
    StatusRow(icon: Self.statusIcon(for: row), title: row.title, caption: row.caption)
  }

  static func statusIcon(for row: SelfTestRow) -> StatusRowIcon {
    switch row.icon {
    case .symbol(let name): .symbol(name, tint(for: row.tone))
    case .progress: .progress
    }
  }

  static func tint(for tone: SelfTestRow.Tone) -> Color {
    switch tone {
    case .secondary: .secondary
    case .success: .green
    case .warning: .orange
    case .error: .red
    }
  }
}

struct DetectionHealthRowView: View {
  let row: DetectionHealthRow
  let model: SettingsModel

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      StatusRow(icon: .symbol(row.symbol, .orange), caption: row.caption) {
        title
      }
      Button(row.actionTitle) {
        model.openDetectionSettings()
      }
      .buttonStyle(.link)
      .font(.subheadline)
      .padding(.leading, StatusRowLayout.textInset)
    }
  }

  @ViewBuilder private var title: some View {
    if let displayPath = row.displayPath, let fullPath = row.fullPath {
      HStack(alignment: .firstTextBaseline, spacing: 4) {
        Text(row.titlePrefix)
          .fixedSize()
        Text(displayPath)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(fullPath)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(row.title)
    } else {
      StatusRowTitle(text: row.title)
    }
  }
}
