import OvertimeAppSupport
import OvertimeEngine
import SwiftUI

struct DetectionPane: View {
  static let foldersTitle = "Transcript folders"
  static let addFolderLabel = "Add Folder…"
  static let useDefaultFolderLabel = "Use Default Folder"
  static let restoreDefaultLabel = "Restore Default"
  static let addEntrypointLabel = "Add Entrypoint"
  static let defaultFolderCaption = "Default folder."
  static let foldersCaption =
    "Overtime watches these folders for Claude transcripts. The default is ~/.claude/projects, plus the projects folder of CLAUDE_CONFIG_DIR when it is set. A running Claude Code session that sets its own CLAUDE_CONFIG_DIR is always watched too."

  static let timingTitle = "Timing"
  static let transcriptWindowCaption = "Claude counts as working if a transcript changed within this time."
  static let releaseGraceCaption = "How long Overtime waits after Claude goes quiet before letting the Mac sleep."
  static let stuckLimitCaption = "A terminal session with no transcript activity for this long is ignored."
  static let entrypointsTitle = "Ignored entrypoints"
  static let entrypointsCaption =
    "Transcripts whose entrypoint matches are not counted as Claude working. The default, sdk-*, ignores claude -p and Agent SDK automations."
  static let entrypointPlaceholder = "sdk-*"
  static let noEntrypointsTitle = "No ignored entrypoints."
  static let noEntrypointsBody = "Every Claude transcript counts, including claude -p and Agent SDK automations."
  static let noEntrypoints = EmptyStateRow(heading: noEntrypointsTitle, detail: noEntrypointsBody)
  static let folderWarningSymbol = "exclamationmark.triangle.fill"
  static let folderMissingHelp = "This folder wasn't found. Overtime can't see Claude activity there."
  static let folderUnreadableHelp =
    "Overtime can't read this folder. Check the folder's permissions, or remove it from the list."

  static func folderWarning(for path: String, in warnings: [DetectionWarning]) -> String? {
    for warning in warnings {
      switch warning {
      case .rootMissing(let flagged) where flagged == path:
        return folderMissingHelp
      case .rootUnreadable(let flagged) where flagged == path:
        return folderUnreadableHelp
      case .rootMissing, .rootUnreadable, .terminalSilence:
        continue
      }
    }
    return nil
  }

  let model: SettingsModel

  var body: some View {
    Form {
      SaveErrorSection(model: model)
      Section {
        NumericSettingRow(
          label: "Transcript window", unit: "seconds", caption: Self.transcriptWindowCaption,
          field: .transcriptWindowSeconds, model: model)
        NumericSettingRow(
          label: "Release grace", unit: "seconds", caption: Self.releaseGraceCaption, field: .releaseGraceSeconds,
          model: model)
        NumericSettingRow(
          label: "Stuck-session limit", unit: "minutes", caption: Self.stuckLimitCaption, field: .stuckWindowMinutes,
          model: model)
      } header: {
        SettingsSectionHeader(title: Self.timingTitle)
      }
      Section {
        ForEach(model.folderRows) { row in
          TranscriptFolderRowView(row: row, model: model)
        }
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            Button(Self.addFolderLabel) {
              Task { await model.addFolder() }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            if model.showsUseDefaultFolder {
              Button(Self.useDefaultFolderLabel) {
                Task { await model.useDefaultFolder() }
              }
              .buttonStyle(.link)
              .font(.subheadline)
            }
          }
          if let message = model.folderMessage {
            ValidationLine(message: message)
          }
        }
      } header: {
        SettingsSectionHeader(title: Self.foldersTitle)
      } footer: {
        SettingsSectionCaption(text: Self.foldersCaption)
      }
      Section {
        if model.showsNoIgnoredEntrypoints {
          Self.noEntrypoints
        }
        ForEach(model.settings.ignoredEntrypoints, id: \.self) { pattern in
          IgnoredEntrypointRowView(pattern: pattern, model: model)
        }
        EntrypointAddRow(model: model)
        if model.showsRestoreDefaultEntrypoints {
          Button(Self.restoreDefaultLabel) {
            Task { await model.restoreDefaultEntrypoints() }
          }
          .buttonStyle(.link)
          .font(.subheadline)
        }
      } header: {
        SettingsSectionHeader(title: Self.entrypointsTitle)
      } footer: {
        SettingsSectionCaption(text: Self.entrypointsCaption)
      }
    }
    .formStyle(.grouped)
    .disabled(!model.canEdit)
    .transaction { $0.animation = nil }
    .onChange(of: model.folderMessage) { _, message in
      guard let message else { return }
      AccessibilityNotification.Announcement(message).post()
    }
  }
}

struct IgnoredEntrypointRowView: View {
  let pattern: String
  let model: SettingsModel

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 4) {
      Text(pattern)
        .monospaced()
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 8)
      Button {
        Task { await model.removeEntrypoint(pattern) }
      } label: {
        Image(systemName: "minus.circle")
      }
      .buttonStyle(.borderless)
      .help("Remove \(pattern)")
      .accessibilityLabel("Remove \(pattern)")
    }
  }
}

struct EntrypointAddRow: View {
  let model: SettingsModel

  var body: some View {
    let message = model.entrypointMessage
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        TextField("Ignored entrypoint", text: draft, prompt: Text(DetectionPane.entrypointPlaceholder))
          .labelsHidden()
          .monospaced()
          .frame(maxWidth: .infinity)
          .onSubmit { add() }
          .accessibilityHint(ifPresent: message)
        Button(DetectionPane.addEntrypointLabel) { add() }
          .buttonStyle(.bordered)
          .controlSize(.regular)
      }
      if let message {
        ValidationLine(message: message)
      }
    }
    .onChange(of: message) { _, message in
      guard let message else { return }
      AccessibilityNotification.Announcement(message).post()
    }
  }

  private var draft: Binding<String> {
    Binding(get: { model.entrypointDraft }, set: { model.setEntrypointDraft($0) })
  }

  private func add() {
    Task { await model.addEntrypoint() }
  }
}

struct TranscriptFolderRowView: View {
  let row: TranscriptFolderRow
  let model: SettingsModel

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: StatusRowLayout.iconGap) {
      Image(systemName: "folder")
        .foregroundStyle(.secondary)
        .frame(width: StatusRowLayout.iconWidth)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text(row.displayPath)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(row.path)
          .accessibilityLabel(row.path)
        if row.isDefault {
          Text(DetectionPane.defaultFolderCaption)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 8)
      if let warning = row.warning {
        Image(systemName: DetectionPane.folderWarningSymbol)
          .foregroundStyle(.orange)
          .frame(width: StatusRowLayout.iconWidth)
          .help(warning)
          .accessibilityLabel(warning)
      }
      if !row.isDefault {
        Button {
          Task { await model.removeFolder(row.path) }
        } label: {
          Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .help(row.removeLabel)
        .accessibilityLabel(row.removeLabel)
      }
    }
  }
}

struct EmptyStateRow: View {
  let heading: String
  let detail: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(heading)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
      SettingsSectionCaption(text: detail)
    }
    .accessibilityElement(children: .combine)
  }
}

struct SettingsSectionHeader: View {
  let title: String

  var body: some View {
    Text(title)
      .font(.subheadline)
      .fontWeight(.semibold)
      .foregroundStyle(.secondary)
  }
}

struct SettingsSectionCaption: View {
  let text: String

  var body: some View {
    CommandSentence(text: text)
      .font(.subheadline)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }
}
