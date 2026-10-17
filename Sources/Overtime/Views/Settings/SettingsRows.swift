import OvertimeAppSupport
import SwiftUI

struct NumericSettingRow: View {
  let label: String
  let unit: String
  let caption: String?
  let field: SettingsField
  let model: SettingsModel
  var secondary = false
  @FocusState private var focused: Bool

  var body: some View {
    let message = model.message(for: field)
    VStack(alignment: .leading, spacing: 4) {
      LabeledContent {
        HStack(spacing: 4) {
          TextField(label, text: textBinding)
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(width: 64)
            .focused($focused)
            .onSubmit { commit() }
            .onExitCommand { model.revert(field) }
            .accessibilityHint(ifPresent: message)
          stepper
          Text(unit)
            .monospacedDigit()
            .foregroundStyle(labelStyle)
        }
      } label: {
        Text(label)
          .foregroundStyle(labelStyle)
      }
      if let message {
        ValidationLine(message: message)
      }
      if let caption {
        Text(caption)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .disabled(!model.canEdit)
    .onChange(of: focused) { _, isFocused in
      guard !isFocused else { return }
      Task { await model.commitIfEdited(field) }
    }
    .onChange(of: message) { _, message in
      guard let message else { return }
      AccessibilityNotification.Announcement(message).post()
    }
  }

  private var labelStyle: HierarchicalShapeStyle {
    secondary ? .secondary : .primary
  }

  private var textBinding: Binding<String> {
    Binding(get: { model.text(for: field) }, set: { model.setText($0, for: field) })
  }

  private var stepper: some View {
    let bounds = model.stepBounds(for: field)
    let value = SettingsModel.value(of: field, in: model.settings)
    return Stepper(
      label,
      onIncrement: value < bounds.upperBound ? { step(SettingsModel.stepSize(for: field)) } : nil,
      onDecrement: value > bounds.lowerBound ? { step(-SettingsModel.stepSize(for: field)) } : nil
    )
    .labelsHidden()
  }

  private func commit() {
    let text = model.text(for: field)
    Task { await model.commit(field, text: text) }
  }

  private func step(_ delta: Int) {
    Task { await model.step(field, by: delta) }
  }
}

struct ValidationLine: View {
  let message: String

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 4) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)
        .accessibilityHidden(true)
      Text(message)
        .font(.subheadline)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
  }
}

struct SaveErrorSection: View {
  let model: SettingsModel

  var body: some View {
    if let saveError = model.saveError {
      Section {
        ValidationLine(message: saveError)
      }
      .onAppear {
        AccessibilityNotification.Announcement(saveError).post()
      }
    }
  }
}

enum StatusRowIcon: Equatable {
  case symbol(String, Color)
  case progress
}

enum StatusRowLayout {
  static let iconWidth: CGFloat = 24
  static let iconGap: CGFloat = 4
  static let textInset: CGFloat = iconWidth + iconGap
}

struct StatusRowTitle: View {
  let text: String

  var body: some View {
    Text(text)
      .fixedSize(horizontal: false, vertical: true)
  }
}

struct StatusRow<Title: View>: View {
  let icon: StatusRowIcon
  let caption: String?
  let title: Title

  init(icon: StatusRowIcon, caption: String? = nil, @ViewBuilder title: () -> Title) {
    self.icon = icon
    self.caption = caption
    self.title = title()
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: StatusRowLayout.iconGap) {
      iconView
        .frame(width: StatusRowLayout.iconWidth)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        title
        if let caption {
          Text(caption)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder private var iconView: some View {
    switch icon {
    case .symbol(let name, let tint):
      Image(systemName: name)
        .foregroundStyle(tint)
    case .progress:
      ProgressView()
        .controlSize(.small)
    }
  }
}

extension StatusRow where Title == StatusRowTitle {
  init(icon: StatusRowIcon, title: String, caption: String? = nil) {
    self.init(icon: icon, caption: caption) { StatusRowTitle(text: title) }
  }

  init(symbol: String, tint: Color, title: String, caption: String? = nil) {
    self.init(icon: .symbol(symbol, tint), title: title, caption: caption)
  }
}
