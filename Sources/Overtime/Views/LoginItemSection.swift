import OvertimeAppSupport
import SwiftUI

struct LoginItemSection: View {
  let isOn: Bool
  let caption: LoginItemCaption?
  let canToggle: Bool
  let setLaunchAtLogin: (Bool) -> Void
  let openLoginItems: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Toggle(LoginItemCaption.toggleLabel, isOn: Binding(get: { isOn }, set: { setLaunchAtLogin($0) }))
        .toggleStyle(.switch)
        .controlSize(.mini)
        .disabled(!canToggle)
        .accessibilityHint(ifPresent: caption?.text)
      if let caption {
        HStack(alignment: .firstTextBaseline, spacing: StatusRowLayout.iconGap) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(caption.tone == .error ? Color.red : Color.orange)
            .frame(width: StatusRowLayout.iconWidth)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 4) {
            Text(caption.text)
              .font(.subheadline)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityHidden(true)
            Button(caption.actionLabel) { openLoginItems() }
              .buttonStyle(.link)
              .font(.subheadline)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

extension LoginItemSection {
  init(model: PanelModel) {
    self.init(
      isOn: model.launchAtLogin, caption: model.loginItemCaption, canToggle: true,
      setLaunchAtLogin: { model.setLaunchAtLogin($0) }, openLoginItems: { model.openLoginItems() })
  }

  init(model: SettingsModel) {
    self.init(
      isOn: model.launchAtLogin, caption: model.loginItemCaption, canToggle: model.canChangeLaunchAtLogin,
      setLaunchAtLogin: { model.setLaunchAtLogin($0) }, openLoginItems: { model.openLoginItems() })
  }
}
