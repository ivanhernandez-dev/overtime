import SwiftUI

struct AboutPane: View {
  let model: SettingsModel

  var body: some View {
    let about = model.about
    Form {
      Section {
        AboutIdentity(about: about)
      }
      Section {
        AboutUpdates(about: about)
      } header: {
        SettingsSectionHeader(title: AboutModel.updatesTitle)
      } footer: {
        if about.showsUpdateControls {
          SettingsSectionCaption(text: AboutModel.updatesFooter)
        }
      }
      Section {
        VStack(alignment: .leading, spacing: AboutModel.nameSpacing) {
          SettingsSectionCaption(text: AboutModel.acknowledgementsCaption)
          Button(AboutModel.showAcknowledgementsLink) { about.showAcknowledgements() }
            .buttonStyle(.link)
            .font(.subheadline)
        }
      } header: {
        SettingsSectionHeader(title: AboutModel.acknowledgementsTitle)
      }
      Section {
        AboutUninstall(about: about, helper: model.helperPane)
      } header: {
        SettingsSectionHeader(title: AboutModel.uninstallTitle)
      }
    }
    .formStyle(.grouped)
    .transaction { $0.animation = nil }
    .background(
      PanelVisibility { _, visible in
        if visible { about.refresh() }
      }
    )
    .sheet(isPresented: acknowledgementsShown(about)) {
      AcknowledgementsSheet(about: about)
    }
  }

  private func acknowledgementsShown(_ about: AboutModel) -> Binding<Bool> {
    Binding(
      get: { about.acknowledgementsShown },
      set: { presented in
        if !presented { about.closeAcknowledgements() }
      })
  }
}

struct AboutIdentity: View {
  let about: AboutModel

  static func applicationIcon() -> NSImage {
    NSApplication.shared.applicationIconImage
  }

  var body: some View {
    VStack(alignment: .leading, spacing: AboutModel.identitySpacing) {
      HStack(alignment: .center, spacing: AboutModel.iconSpacing) {
        Image(nsImage: Self.applicationIcon())
          .resizable()
          .frame(width: AboutModel.iconSide, height: AboutModel.iconSide)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: AboutModel.nameSpacing) {
          Text(AboutModel.name)
            .font(.title3)
            .fontWeight(.semibold)
          Text(about.versionLine)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
      }
      Text(AboutModel.tagline)
        .fixedSize(horizontal: false, vertical: true)
      SettingsSectionCaption(text: AboutModel.branding)
      SettingsSectionCaption(text: AboutModel.requirements)
      Button(AboutModel.repositoryLink) { about.openRepository() }
        .buttonStyle(.link)
        .font(.subheadline)
    }
  }
}

struct AboutUpdates: View {
  let about: AboutModel

  var body: some View {
    if let note = about.noteRow {
      StatusRow(symbol: AboutModel.noteSymbol, tint: .secondary, title: note.title, caption: note.caption)
    } else {
      if let version = about.waitingVersion {
        VStack(alignment: .leading, spacing: AboutModel.updateRowSpacing) {
          StatusRow(
            symbol: AboutModel.updateSymbol, tint: .secondary,
            title: AboutModel.updateAvailableTitle(version: version))
          Button(AboutModel.reviewUpdateLabel) { about.reviewUpdate() }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .padding(.leading, StatusRowLayout.textInset)
        }
      }
      AboutSwitchRow(
        label: AboutModel.automaticChecksLabel, caption: AboutModel.automaticChecksCaption,
        isOn: Binding(get: { about.automaticChecks }, set: { about.setAutomaticChecks($0) }))
      AboutSwitchRow(
        label: AboutModel.automaticDownloadsLabel, caption: AboutModel.automaticDownloadsCaption,
        isOn: Binding(get: { about.automaticDownloads }, set: { about.setAutomaticDownloads($0) })
      )
      .disabled(!about.downloadsEnabled)
      LabeledContent(AboutModel.lastCheckedLabel) {
        Text(about.lastCheckedText)
          .monospacedDigit()
      }
      Button(AboutModel.checkLabel) { about.checkForUpdates() }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(!about.canCheck)
        .help(ifPresent: about.checkHelp)
        .accessibilityHint(ifPresent: about.checkHelp)
    }
  }
}

struct AboutUninstall: View {
  let about: AboutModel
  let helper: HelperPaneModel

  var body: some View {
    let state = helper.uiState
    let help = about.uninstallHelp(helper: state)
    VStack(alignment: .leading, spacing: AboutModel.identitySpacing) {
      SettingsSectionCaption(text: AboutModel.uninstallCaption)
      Button(AboutModel.uninstallLabel, role: .destructive) {
        Task { await about.requestUninstall(helper: state) }
      }
      .buttonStyle(.bordered)
      .controlSize(.regular)
      .disabled(!about.canUninstall(helper: state))
      .help(ifPresent: help)
      .accessibilityHint(ifPresent: help)
    }
    .sheet(isPresented: presented) {
      if let uninstall = about.uninstall {
        UninstallSheet(model: uninstall)
      }
    }
  }

  private var presented: Binding<Bool> {
    Binding(
      get: { about.uninstall?.isPresented ?? false },
      set: { presented in
        if !presented { about.uninstall?.keep() }
      })
  }
}

struct AboutSwitchRow: View {
  let label: String
  let caption: String
  let isOn: Binding<Bool>

  var body: some View {
    VStack(alignment: .leading, spacing: AboutModel.nameSpacing) {
      Toggle(label, isOn: isOn)
        .toggleStyle(.switch)
        .controlSize(.mini)
        .accessibilityHint(Text(caption))
      SettingsSectionCaption(text: caption)
        .accessibilityHidden(true)
    }
  }
}
