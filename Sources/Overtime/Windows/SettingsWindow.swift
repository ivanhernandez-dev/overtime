import AppKit
import OvertimeAppSupport
import SwiftUI

struct SidebarBadge: Equatable {
  struct Style: Equatable {
    let symbol: String
    let isUpdate: Bool
    let accessibilityValue: String
  }

  static let attentionStyle = Style(
    symbol: "exclamationmark.triangle.fill", isUpdate: false, accessibilityValue: "Needs attention")
  static let updateStyle = Style(symbol: "arrow.down.circle", isUpdate: true, accessibilityValue: "Update available")

  static func style(for pane: SettingsPane) -> Style {
    pane == .about ? updateStyle : attentionStyle
  }

  let texts: [String]

  var help: String {
    texts.joined(separator: "\n")
  }
}

struct SidebarRow: View {
  let pane: SettingsPane
  let badge: SidebarBadge?

  var body: some View {
    if let badge {
      let style = SidebarBadge.style(for: pane)
      HStack(spacing: StatusRowLayout.iconGap) {
        label
        Spacer(minLength: 4)
        Image(systemName: style.symbol)
          .foregroundStyle(style.isUpdate ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
          .frame(width: StatusRowLayout.iconWidth)
          .accessibilityHidden(true)
      }
      .help(badge.help)
      .accessibilityElement(children: .combine)
      .accessibilityValue(style.accessibilityValue)
    } else {
      label
    }
  }

  private var label: some View {
    Label {
      Text(pane.title)
    } icon: {
      SettingsTile(pane: pane, size: .sidebar)
    }
  }
}

struct SettingsWindow: View {
  static let contentSize = CGSize(width: 700, height: 520)
  static let sidebarWidth: CGFloat = 199
  static let dividerWidth: CGFloat = 1
  static let paneWidth: CGFloat = 500

  let model: SettingsModel

  var body: some View {
    HStack(spacing: 0) {
      List(selection: selection) {
        ForEach(SettingsPane.allCases) { pane in
          SidebarRow(pane: pane, badge: model.sidebarBadge(for: pane))
            .tag(pane)
        }
      }
      .listStyle(.sidebar)
      .frame(width: Self.sidebarWidth)
      Divider()
        .frame(width: Self.dividerWidth)
      VStack(spacing: 0) {
        SettingsPaneHeader(pane: model.selectedPane)
        paneContent
      }
      .frame(width: Self.paneWidth)
      .frame(maxHeight: .infinity)
      .transaction { $0.animation = nil }
    }
    .frame(width: Self.contentSize.width, height: Self.contentSize.height)
    .background {
      Button("Close Settings") { model.close() }
        .keyboardShortcut("w")
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
  }

  private var selection: Binding<SettingsPane?> {
    Binding(
      get: { model.selectedPane },
      set: { pane in
        guard let pane else { return }
        model.select(pane)
      })
  }

  @ViewBuilder private var paneContent: some View {
    switch model.selectedPane {
    case .general:
      GeneralPane(model: model)
    case .detection:
      DetectionPane(model: model)
    case .battery:
      BatteryPane(model: model)
    case .network:
      NetworkPane(model: model)
    case .diagnostics:
      DiagnosticsPane(model: model)
    case .unplugProtection:
      UnplugProtectionPane(model: model)
    case .about:
      AboutPane(model: model)
    }
  }

  static func controller(model: SettingsModel) -> AuxiliaryWindowController {
    let controller = AuxiliaryWindowController(title: model.windowTitle, contentSize: contentSize) {
      AnyView(SettingsWindow(model: model))
    }
    model.onSelectPane = { [weak controller] pane in
      controller?.setTitle(pane.title)
    }
    model.onClose = { [weak controller] in
      controller?.close()
    }
    return controller
  }
}

final class SettingsPresenter {
  let model: SettingsModel
  let controller: AuxiliaryWindowController
  private let present: (AuxiliaryWindowController) -> Void

  init(model: SettingsModel, present: @escaping (AuxiliaryWindowController) -> Void = { $0.show() }) {
    self.model = model
    controller = SettingsWindow.controller(model: model)
    self.present = present
  }

  func show(pane: SettingsPane?) {
    model.open(pane: pane)
    controller.setTitle(model.windowTitle)
    present(controller)
  }
}
