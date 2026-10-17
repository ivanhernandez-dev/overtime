import OvertimeAppSupport
import SwiftUI

struct UnplugProtectionPane: View {
  static let statusTitle = "Status"
  static let aboutTitle = "About unplug protection"
  static let noteSymbol = "info.circle"
  static let aboutNotes = HelperStatusPresentation.aboutNotes
  static let removeConfirmation = (
    title: HelperStatusPresentation.removeConfirmationTitle,
    message: HelperStatusPresentation.removeConfirmationMessage,
    confirm: HelperStatusPresentation.removeConfirmationConfirm,
    keep: HelperStatusPresentation.removeConfirmationKeep
  )

  static func settingNote(for model: SettingsModel) -> String? {
    LidClosedCopy.settingNote(model.settings.lidClosedKeepAwake)
  }

  static func role(for action: HelperStatusAction) -> ButtonRole? {
    action.isDestructive ? .destructive : nil
  }

  static func tint(for tone: HelperStatusTone) -> Color {
    switch tone {
    case .secondary: .secondary
    case .success: .green
    case .warning: .orange
    case .error: .red
    }
  }

  let model: SettingsModel

  var body: some View {
    let helper = model.helperPane
    Form {
      if let state = helper.uiState {
        Section {
          HelperStatusRowView(state: state, detail: helper.detail, helper: helper)
          if let note = Self.settingNote(for: model) {
            SettingsSectionCaption(text: note)
          }
          SleepDisabledRow(model: helper)
        } header: {
          SettingsSectionHeader(title: Self.statusTitle)
        }
      }
      Section {
        HelperAboutNotes()
      } header: {
        SettingsSectionHeader(title: Self.aboutTitle)
      }
    }
    .formStyle(.grouped)
    .transaction { $0.animation = nil }
    .background(PanelVisibility { host, visible in helper.setVisible(visible, host: host) })
    .modifier(HelperRemoveConfirmation(helper: helper))
  }
}

struct HelperAboutNotes: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(UnplugProtectionPane.aboutNotes, id: \.self) { note in
        HStack(alignment: .firstTextBaseline, spacing: StatusRowLayout.iconGap) {
          Image(systemName: UnplugProtectionPane.noteSymbol)
            .foregroundStyle(.secondary)
            .frame(width: StatusRowLayout.iconWidth)
            .accessibilityHidden(true)
          SettingsSectionCaption(text: note)
        }
      }
    }
  }
}

struct HelperRemoveConfirmation: ViewModifier {
  let helper: HelperPaneModel

  func body(content: Content) -> some View {
    content
      .confirmationDialog(
        UnplugProtectionPane.removeConfirmation.title, isPresented: confirmingRemove, titleVisibility: .visible
      ) {
        Button(UnplugProtectionPane.removeConfirmation.confirm, role: .destructive) {
          Task { await helper.confirmRemove() }
        }
        Button(UnplugProtectionPane.removeConfirmation.keep, role: .cancel) {
          helper.keepProtection()
        }
        .keyboardShortcut(.cancelAction)
      } message: {
        Text(UnplugProtectionPane.removeConfirmation.message)
      }
  }

  private var confirmingRemove: Binding<Bool> {
    Binding(
      get: { helper.confirmingRemove },
      set: { presented in
        if !presented { helper.keepProtection() }
      })
  }
}

struct HelperStatusRowView: View {
  let state: HelperUIState
  let detail: String?
  let helper: HelperPaneModel
  var actions: [HelperStatusAction]?

  var body: some View {
    let actions = actions ?? state.actions
    VStack(alignment: .leading, spacing: 4) {
      StatusRow(icon: Self.statusIcon(state.icon), title: state.title, caption: state.caption)
      if let detail {
        Text(detail)
          .font(.subheadline)
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.leading, StatusRowLayout.textInset)
      }
      if !actions.isEmpty {
        HStack(spacing: 8) {
          ForEach(actions, id: \.self) { action in
            HelperActionButton(action: action, helper: helper)
          }
        }
        .padding(.leading, StatusRowLayout.textInset)
      }
    }
  }

  static func statusIcon(_ icon: HelperStatusIcon) -> StatusRowIcon {
    switch icon {
    case .symbol(let name, let tone): .symbol(name, UnplugProtectionPane.tint(for: tone))
    case .progress: .progress
    }
  }
}

struct HelperActionButton: View {
  let action: HelperStatusAction
  let helper: HelperPaneModel

  var body: some View {
    let button = Button(action.label, role: UnplugProtectionPane.role(for: action)) {
      Task { await helper.perform(action) }
    }
    switch action.style {
    case .bordered:
      button
        .buttonStyle(.bordered)
        .controlSize(.regular)
    case .link:
      button
        .buttonStyle(.link)
        .font(.subheadline)
    }
  }
}
