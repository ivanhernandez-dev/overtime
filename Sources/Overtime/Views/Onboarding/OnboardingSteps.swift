import AppKit
import OvertimeAppSupport
import SwiftUI

struct OnboardingStepContent: View {
  let model: OnboardingModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      switch model.currentStep {
      case .welcome:
        OnboardingWelcomeStep()
      case .launchAtLogin:
        LoginItemSection(model: model.panel)
      case .notifications:
        OnboardingNotificationsStep(model: model)
      case .location:
        OnboardingLocationStep(model: model)
      case .selfTest:
        OnboardingSelfTestStep(model: model)
      case .checks:
        OnboardingCheckRows(model: model)
      case .unplugProtection:
        OnboardingUnplugProtectionStep(model: model)
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      model.refreshStep()
    }
  }

  static func tint(for tone: NotificationStatusRow.Tone) -> Color {
    switch tone {
    case .success: .green
    case .info: .secondary
    case .warning: .orange
    }
  }

  static func tint(for tone: LocationRow.Tone) -> Color {
    switch tone {
    case .success: .green
    case .info: .secondary
    case .warning: .orange
    }
  }
}

struct OnboardingWelcomeStep: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(OnboardingFlow.welcomeRows) { row in
        HStack(alignment: .firstTextBaseline, spacing: StatusRowLayout.iconGap) {
          Image(systemName: row.symbol)
            .foregroundStyle(.secondary)
            .frame(width: StatusRowLayout.iconWidth)
            .accessibilityHidden(true)
          Text(row.text)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
      }
    }
  }
}

struct OnboardingNotificationsStep: View {
  let model: OnboardingModel

  var body: some View {
    if let row = model.notificationRow {
      VStack(alignment: .leading, spacing: 4) {
        StatusRow(symbol: row.symbol, tint: OnboardingStepContent.tint(for: row.tone), title: row.title)
        if row.action == .openNotificationSettings {
          Button(NotificationStatusRow.openLabel) { model.openNotificationSettings() }
            .buttonStyle(.link)
            .font(.subheadline)
        }
      }
    }
  }
}

struct OnboardingLocationStep: View {
  let model: OnboardingModel

  var body: some View {
    if let row = model.locationRow {
      VStack(alignment: .leading, spacing: 4) {
        StatusRow(symbol: row.symbol, tint: OnboardingStepContent.tint(for: row.tone), title: row.title)
        if row.action == .openLocationServices {
          Button(LocationRow.openLabel) { model.openLocationServices() }
            .buttonStyle(.link)
            .font(.subheadline)
        }
      }
    }
  }
}

struct OnboardingUnplugProtectionStep: View {
  static let notes = UnplugProtectionPane.aboutNotes

  let model: OnboardingModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if let helper = model.helper {
        OnboardingHelperStatus(helper: helper, actions: model.helperRowActions)
      }
      HelperAboutNotes()
    }
  }
}

struct OnboardingHelperStatus: View {
  let helper: HelperPaneModel
  let actions: [HelperStatusAction]

  var body: some View {
    if let state = helper.uiState {
      HelperStatusRowView(state: state, detail: helper.detail, helper: helper, actions: actions)
        .modifier(HelperRemoveConfirmation(helper: helper))
    }
  }
}

struct OnboardingSelfTestStep: View {
  let model: OnboardingModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      SelfTestRowView(row: model.selfTestRow)
      if let note = model.selfTestNote {
        Text(note)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.leading, StatusRowLayout.textInset)
      }
    }
    .onChange(of: model.shownSelfTest) {
      guard let announcement = SelfTestPresentation.announcement(for: model.shownSelfTest) else { return }
      AccessibilityNotification.Announcement(announcement).post()
    }
  }
}
