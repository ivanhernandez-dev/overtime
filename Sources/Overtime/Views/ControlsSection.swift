import OvertimeAppSupport
import SwiftUI

struct ControlsSection: View {
  let model: PanelModel

  var body: some View {
    let availability = model.controls
    let confirming = model.sleepConfirmation.isConfirming
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        ForEach(PanelActions.tiles(availability, confirmingSleep: confirming)) { tile in
          tileView(tile, availability: availability)
        }
      }
      .fixedSize(horizontal: false, vertical: true)
      if PanelActions.showsSleepConfirmation(availability, confirmingSleep: confirming) {
        SleepConfirmationRow(model: model)
      }
      VStack(alignment: .leading, spacing: 0) {
        Button {
          model.trigger(.releaseUntilIdle)
        } label: {
          PanelRowLabel(
            icon: "arrow.uturn.backward.circle", title: ControlMapping.releaseUntilIdleLabel,
            shortcut: .releaseUntilIdle)
        }
        .buttonStyle(PanelRowButtonStyle())
        .panelShortcut(.releaseUntilIdle)
        .disabled(!availability.releaseEnabled)
        .help(ifPresent: availability.releaseHelp)
        .accessibilityHint(ifPresent: availability.releaseHelp)
        KeepDisplayOnRow(model: model)
        Divider()
          .padding(.vertical, 8)
        Button(role: .destructive) {
          model.restore()
        } label: {
          PanelRowLabel(
            icon: "arrow.counterclockwise.circle", title: ControlMapping.restoreLabel, role: .destructive,
            shortcut: .restore)
        }
        .buttonStyle(PanelRowButtonStyle())
        .panelShortcut(.restore)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .transaction { $0.animation = nil }
  }

  @ViewBuilder
  private func tileView(_ tile: PanelActionTile, availability: ControlAvailability) -> some View {
    switch tile.kind {
    case .pauseMenu:
      Menu {
        ForEach(model.pauseChoices, id: \.self) { choice in
          Button(choice.label) { model.trigger(.pause(choice)) }
        }
      } label: {
        PanelActionTileLabel(tile: tile)
      }
      .panelTileMenu()
      .background {
        PanelShortcutButton(title: ControlMapping.pauseLabel, shortcut: .pause) {
          model.trigger(.pause(.untilResumed))
        }
      }
      .engineBound(availability)
    case .resume:
      Button {
        model.trigger(.resume)
      } label: {
        PanelActionTileLabel(tile: tile)
      }
      .buttonStyle(PanelTileButtonStyle())
      .panelShortcut(.pause)
      .engineBound(availability)
    case .keepAwakeMenu:
      Menu {
        ForEach(model.keepAwakeChoices, id: \.self) { choice in
          Button(choice.label) { model.trigger(.keepAwake(choice)) }
        }
      } label: {
        PanelActionTileLabel(tile: tile)
      }
      .panelTileMenu()
      .background {
        PanelShortcutButton(title: ControlMapping.keepAwakeLabel, shortcut: .keepAwake) {
          model.trigger(.keepAwake(.untilStopped))
        }
      }
      .engineBound(availability)
    case .stopKeepingAwake:
      Button {
        model.trigger(.stopKeepingAwake)
      } label: {
        PanelActionTileLabel(tile: tile)
      }
      .buttonStyle(PanelTileButtonStyle())
      .panelShortcut(.keepAwake)
      .engineBound(availability)
    case .sleepNow:
      if tile.shortcut == nil {
        Button {
          model.pressSleepNow()
        } label: {
          PanelActionTileLabel(tile: tile)
        }
        .buttonStyle(PanelTileButtonStyle())
        .disabled(!tile.isEnabled)
        .engineBound(availability)
      } else {
        Button {
          model.pressSleepNow()
        } label: {
          PanelActionTileLabel(tile: tile)
        }
        .buttonStyle(PanelTileButtonStyle())
        .panelShortcut(.sleepNow)
        .engineBound(availability)
      }
    }
  }
}

struct SleepConfirmationRow: View {
  let model: PanelModel

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(SleepConfirmation.prompt)
        .font(.subheadline)
        .foregroundStyle(.secondary)
      HStack(spacing: 8) {
        Button(SleepConfirmation.confirmLabel, role: .destructive) {
          model.confirmSleep()
        }
        Button(SleepConfirmation.cancelLabel) {
          model.keepWorking()
        }
        .keyboardShortcut(.cancelAction)
      }
      .controlSize(.small)
    }
    .padding(.horizontal, 4)
    .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
  }
}

struct KeepDisplayOnRow: View {
  let isOn: Bool
  let isEnabled: Bool
  let help: String
  let setKeepDisplayOn: (Bool) -> Void

  var body: some View {
    HStack(spacing: 0) {
      HStack(spacing: StatusRowLayout.iconGap) {
        Image(systemName: ControlMapping.keepDisplayOnSymbol)
          .frame(width: StatusRowLayout.iconWidth)
          .accessibilityHidden(true)
        Text(ControlMapping.keepDisplayOnLabel)
          .font(.body)
          .accessibilityHidden(true)
      }
      .opacity(isEnabled ? 1 : 0.5)
      Spacer(minLength: 8)
      Toggle(ControlMapping.keepDisplayOnLabel, isOn: Binding(get: { isOn }, set: { setKeepDisplayOn($0) }))
        .toggleStyle(.switch)
        .controlSize(.mini)
        .labelsHidden()
        .accessibilityHint(Text(help))
    }
    .padding(.horizontal, 4)
    .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
    .contentShape(Rectangle())
    .disabled(!isEnabled)
    .help(help)
  }
}

extension KeepDisplayOnRow {
  init(model: PanelModel) {
    let availability = model.controls
    self.init(
      isOn: model.keepDisplayOn, isEnabled: availability.engineControlsEnabled, help: availability.displaySwitchHelp,
      setKeepDisplayOn: { enabled in Task { await model.setKeepDisplayOn(enabled) } })
  }
}

struct PanelActionTileLabel: View {
  let tile: PanelActionTile

  var body: some View {
    VStack(spacing: 4) {
      Image(systemName: tile.symbol)
        .font(.title3)
        .accessibilityHidden(true)
      Text(tile.title)
        .font(.body)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 4) {
        if let shortcut = tile.shortcut {
          Text(shortcut.hint)
            .foregroundStyle(Color.secondary)
            .accessibilityLabel(shortcut.spoken)
        }
        if tile.opensMenu {
          Image(systemName: PanelActions.menuSymbol)
            .foregroundStyle(Color.secondary)
            .accessibilityHidden(true)
        }
      }
      .font(.subheadline)
    }
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .contentShape(Rectangle())
  }
}

struct PanelTileButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    PanelTileButtonBody(configuration: configuration)
  }
}

private struct PanelTileButtonBody: View {
  let configuration: ButtonStyleConfiguration
  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    configuration.label
      .modifier(PanelRowChrome(pressed: configuration.isPressed, corners: .tile))
      .panelTileFill()
      .opacity(isEnabled ? 1 : 0.5)
  }
}

struct PanelShortcutButton: View {
  let title: String
  let shortcut: PanelShortcut
  let action: () -> Void

  var body: some View {
    Button(title, action: action)
      .panelShortcut(shortcut)
      .frame(width: 0, height: 0)
      .opacity(0)
      .focusable(false)
      .accessibilityHidden(true)
  }
}

struct PanelRowLabel: View {
  let icon: String
  let title: String
  var role: ButtonRole?
  var shortcut: PanelShortcut?

  var body: some View {
    HStack(spacing: StatusRowLayout.iconGap) {
      Image(systemName: icon)
        .frame(width: StatusRowLayout.iconWidth)
        .accessibilityHidden(true)
      Text(title)
        .font(.body)
      Spacer(minLength: 0)
      if let shortcut {
        Text(shortcut.hint)
          .font(.subheadline)
          .foregroundStyle(Color.secondary)
          .accessibilityLabel(shortcut.spoken)
      }
    }
    .foregroundStyle(role == .destructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
    .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
    .contentShape(Rectangle())
  }
}

struct PanelRowButtonStyle: ButtonStyle {
  var corners: PanelRowCorners = .row

  func makeBody(configuration: Configuration) -> some View {
    PanelRowButtonBody(configuration: configuration, corners: corners)
  }
}

private struct PanelRowButtonBody: View {
  let configuration: ButtonStyleConfiguration
  let corners: PanelRowCorners
  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    configuration.label
      .modifier(PanelRowChrome(pressed: configuration.isPressed, corners: corners))
      .opacity(isEnabled ? 1 : 0.5)
  }
}

struct PanelRowChrome: ViewModifier {
  var pressed = false
  let corners: PanelRowCorners
  @State private var hovering = false
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.cornerContainerRadius) private var containerRadius

  private var showsPressed: Bool {
    isEnabled && pressed
  }

  private var showsHover: Bool {
    isEnabled && hovering && !pressed
  }

  func body(content: Content) -> some View {
    let shape = CornerShapes.rowHighlight(corners, container: containerRadius)
    content
      .padding(.horizontal, 4)
      .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
      .background {
        ZStack {
          shape
            .fill(.quinary)
            .opacity(showsHover ? 1 : 0)
            .animation(Motion.animation(.rowHighlight, reduceMotion: reduceMotion), value: showsHover)
          shape
            .fill(.quaternary)
            .opacity(showsPressed ? 1 : 0)
            .animation(Motion.animation(.rowHighlight, reduceMotion: reduceMotion), value: showsPressed)
        }
      }
      .contentShape(Rectangle())
      .onHover { hovering = $0 }
  }
}

extension View {
  func panelTileMenu() -> some View {
    self
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .frame(maxHeight: .infinity)
      .modifier(PanelRowChrome(corners: .tile))
      .panelTileFill()
  }

  func panelTileFill() -> some View {
    self.background(.quinary, in: CornerShapes.actionTile)
  }

  func engineBound(_ availability: ControlAvailability) -> some View {
    self
      .disabled(!availability.engineControlsEnabled)
      .help(ifPresent: availability.engineHelp)
      .accessibilityHint(ifPresent: availability.engineHelp)
  }
}
