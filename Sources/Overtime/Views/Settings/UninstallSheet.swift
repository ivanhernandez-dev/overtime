import OvertimeAppSupport
import SwiftUI

struct UninstallSheetButton: Equatable, Identifiable {
  enum Action: Equatable {
    case keep
    case uninstall
    case openLoginItems
    case quit
    case retry
  }

  let action: Action
  let label: String
  var isDefault = false
  var isCancel = false
  var isDestructive = false
  var isLink = false

  var id: Action {
    action
  }
}

struct UninstallSheet: View {
  static let width: CGFloat = 480
  static let maxHeight: CGFloat = 480
  static let padding: CGFloat = 24
  static let sectionGap: CGFloat = 16
  static let rowGap: CGFloat = 8
  static let buttonGap: CGFloat = 8
  static let captionGap: CGFloat = 4
  static let checkboxTextInset: CGFloat = 20

  static func buttons(for phase: UninstallSession.Phase) -> [UninstallSheetButton] {
    switch phase {
    case .confirm:
      [
        UninstallSheetButton(action: .keep, label: UninstallCopy.keepLabel, isCancel: true),
        UninstallSheetButton(action: .uninstall, label: UninstallCopy.uninstallLabel, isDestructive: true),
      ]
    case .running:
      []
    case .stopped:
      [
        UninstallSheetButton(action: .openLoginItems, label: UninstallCopy.openLoginItemsLabel, isLink: true),
        UninstallSheetButton(action: .quit, label: UninstallCopy.quitLabel),
        UninstallSheetButton(action: .retry, label: UninstallCopy.retryLabel, isDestructive: true),
      ]
    case .result:
      [UninstallSheetButton(action: .quit, label: UninstallCopy.quitLabel, isDefault: true)]
    }
  }

  static func scrollHeight(body: CGFloat, title: CGFloat, footer: CGFloat) -> CGFloat {
    max(0, min(body, maxHeight - 2 * padding - title - sectionGap - footer))
  }

  static func linkLabel(for step: UninstallManualStep) -> String? {
    switch step {
    case .loginItem: UninstallCopy.openLoginItemsLabel
    case .trash: UninstallCopy.showInFinderLabel
    case .rootFolders, .userFiles, .restart: nil
    }
  }

  let model: UninstallModel
  @AccessibilityFocusState private var titleFocused: Bool
  @State private var titleHeight: CGFloat = 0
  @State private var bodyHeight: CGFloat = 0
  @State private var footerHeight: CGFloat = 0

  var body: some View {
    if let session = model.session {
      VStack(alignment: .leading, spacing: 0) {
        Text(session.title)
          .font(.title3)
          .fontWeight(.semibold)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityAddTraits(.isHeader)
          .accessibilityFocused($titleFocused)
          .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { titleHeight = $0 }
        ScrollView(.vertical) {
          UninstallSheetBody(model: model, session: session)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { bodyHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: Self.scrollHeight(body: bodyHeight, title: titleHeight, footer: footerHeight))
        .padding(.top, Self.sectionGap)
        UninstallSheetFooter(model: model, phase: session.phase)
          .padding(.top, Self.sectionGap)
          .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { footerHeight = $0 }
      }
      .padding(Self.padding)
      .frame(width: Self.width, alignment: .leading)
      .frame(maxHeight: Self.maxHeight)
      .transaction { $0.animation = nil }
      .interactiveDismissDisabled(session.phase != .confirm)
      .onAppear { titleFocused = true }
      .onChange(of: session.announcement) { _, announcement in
        guard let announcement else { return }
        AccessibilityNotification.Announcement(announcement).post()
      }
    }
  }
}

struct UninstallSheetBody: View {
  let model: UninstallModel
  let session: UninstallSession

  var body: some View {
    VStack(alignment: .leading, spacing: UninstallSheet.rowGap) {
      if session.phase == .confirm {
        UninstallLabel(text: UninstallCopy.checklistLabel)
      }
      if session.phase == .stopped {
        Text(UninstallCopy.stoppedBody)
          .fixedSize(horizontal: false, vertical: true)
      }
      ForEach(session.steps, id: \.self) { step in
        StepRow(title: step.title, status: session.statuses[step] ?? .pending, caption: session.caption(for: step))
      }
      switch session.phase {
      case .confirm:
        UninstallConfirmOptions(model: model, session: session)
      case .stopped:
        SettingsSectionCaption(text: UninstallCopy.stoppedAdvice)
      case .result:
        UninstallResultExtras(model: model, session: session)
      case .running:
        EmptyView()
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct UninstallLabel: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.subheadline)
      .fontWeight(.semibold)
      .foregroundStyle(.secondary)
      .accessibilityAddTraits(.isHeader)
  }
}

struct UninstallResultExtras: View {
  let model: UninstallModel
  let session: UninstallSession

  var body: some View {
    if model.showsSleepDisabledRow, let caption = session.sleepDisabledCaption {
      SleepDisabledRowContent(
        caption: caption, clearing: model.clearing, clearCaption: model.clearCaption,
        turnOn: { Task { await model.turnSleepBackOn() } }, copy: { model.copyCommand() })
    }
    let lines = session.manualStepLines
    if !lines.isEmpty {
      UninstallLabel(text: UninstallCopy.stillToDoLabel)
      ForEach(lines) { line in
        UninstallManualLineView(line: line) { model.followLink(for: line.step) }
      }
    }
  }
}

struct UninstallManualLineView: View {
  let line: UninstallManualLine
  let follow: () -> Void

  var body: some View {
    if let link = UninstallSheet.linkLabel(for: line.step) {
      HStack(alignment: .firstTextBaseline, spacing: UninstallSheet.buttonGap) {
        SettingsSectionCaption(text: line.text)
        Button(link, action: follow)
          .buttonStyle(.link)
          .font(.subheadline)
      }
    } else {
      SettingsSectionCaption(text: line.text)
    }
  }
}

struct UninstallConfirmOptions: View {
  let model: UninstallModel
  let session: UninstallSession

  var body: some View {
    VStack(alignment: .leading, spacing: UninstallSheet.captionGap) {
      Toggle(
        UninstallCopy.purgeLabel,
        isOn: Binding(get: { session.purge }, set: { model.setPurge($0) })
      )
      .toggleStyle(.checkbox)
      .accessibilityHint(Text(session.purgeCaption))
      SettingsSectionCaption(text: session.purgeCaption)
        .padding(.leading, UninstallSheet.checkboxTextInset)
        .accessibilityHidden(true)
    }
    SettingsSectionCaption(text: UninstallCopy.untouchedCaption)
    if session.helperInstalled {
      SettingsSectionCaption(text: UninstallCopy.administratorOnceCaption)
    }
  }
}

struct UninstallSheetFooter: View {
  let model: UninstallModel
  let phase: UninstallSession.Phase

  var body: some View {
    let buttons = UninstallSheet.buttons(for: phase)
    if !buttons.isEmpty {
      HStack(spacing: UninstallSheet.buttonGap) {
        ForEach(buttons.filter(\.isLink)) { button in
          UninstallButtonView(button: button) { model.press(button.action) }
        }
        Spacer()
        ForEach(buttons.filter { !$0.isLink }) { button in
          UninstallButtonView(button: button) { model.press(button.action) }
        }
      }
    }
  }
}

struct UninstallButtonView: View {
  let button: UninstallSheetButton
  let action: () -> Void

  var body: some View {
    let role: ButtonRole? = button.isDestructive ? .destructive : nil
    if button.isLink {
      Button(button.label, role: role, action: action)
        .buttonStyle(.link)
    } else if button.isDefault {
      Button(button.label, role: role, action: action)
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
    } else if button.isCancel {
      Button(button.label, role: role, action: action)
        .keyboardShortcut(.cancelAction)
        .buttonStyle(.bordered)
    } else {
      Button(button.label, role: role, action: action)
        .buttonStyle(.bordered)
    }
  }
}
