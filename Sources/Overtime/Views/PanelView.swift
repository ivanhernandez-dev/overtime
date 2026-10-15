import AppKit
import OvertimeAppSupport
import SwiftUI

struct PanelView: View {
  let model: PanelModel
  var banner: String? = nil

  var body: some View {
    Group {
      if model.isPanelVisible {
        TimelineView(.periodic(from: .now, by: 1)) { context in
          PanelBody(model: model, tick: context.date, banner: banner)
        }
      } else {
        PanelBody(model: model, tick: nil, banner: banner)
      }
    }
    .background(PanelVisibility { host, visible in model.setVisible(visible, host: host) })
    .onChange(of: model.isPanelVisible) { _, visible in
      if visible {
        model.refreshInstalledTools()
        model.refreshLoginItem()
        model.refreshSleepDisabled()
        model.refreshAttention()
      }
    }
  }
}

struct PanelBody: View {
  let model: PanelModel
  let tick: Date?
  let banner: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let banner {
        HStack(alignment: .firstTextBaseline, spacing: StatusRowLayout.iconGap) {
          Image(systemName: "info.circle")
            .frame(width: StatusRowLayout.iconWidth)
            .accessibilityHidden(true)
          Text(banner)
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
      }
      let status = model.statusChips
      StatusBlock(presentation: model.presentation, awakeTime: model.awakeTime, chips: status.chips)
      if model.offersTurnSleepBackOn {
        Button(SleepDisabledClearing.turnOnLabel) {
          Task { await model.turnSleepBackOn() }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(model.clearingSleepDisabled)
      }
      if let attention = model.attentionText {
        if model.showsUpdateRow {
          AttentionRow(text: attention, isUpdate: true) { model.reviewUpdate() }
        } else {
          AttentionRow(text: attention) { model.reviewAttention() }
        }
      }
      if !status.details.isEmpty {
        StatusDetailsSection(details: status.details)
      }
      Divider()
      SessionsSection(list: model.sessionList)
      let hints = model.hints
      if !hints.isEmpty {
        HintsSection(hints: hints) { model.performHint($0) }
      }
      Divider()
      ControlsSection(model: model)
      Divider()
      if model.showsLoginItemSection {
        LoginItemSection(model: model)
        Divider()
      }
      Footer { model.openSettings() }
    }
    .padding(CGFloat(CornerGeometry.panelPadding))
    .frame(width: 320, alignment: .leading)
    .transaction { $0.animation = nil }
  }
}

struct StatusBlock: View {
  let presentation: StatusPresentation
  let awakeTime: AwakeTime
  let chips: [StatusChip]
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.cornerContainerRadius) private var containerRadius

  var body: some View {
    let lit = HeroStatus.isLit(presentation.state)
    PrismCard(lit: lit, shape: CornerShapes.heroCard(container: containerRadius)) {
      VStack(alignment: .leading, spacing: 8) {
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 12) {
            PrismIndicator(lit: lit) {
              if presentation.showsProgress {
                ProgressView()
                  .controlSize(.small)
                  .accessibilityHidden(true)
              } else {
                ZStack {
                  StatusGlyphView(label: StatusItemLabel(presentation))
                    .equatable()
                    .id(presentation.glyph)
                    .transition(.opacity)
                }
                .animation(Motion.animation(.statusGlyph, reduceMotion: reduceMotion), value: presentation.glyph)
              }
            }
            VStack(alignment: .leading, spacing: 4) {
              Text(presentation.title)
                .font(.title3)
                .fontWeight(.semibold)
              Text(presentation.reason)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          AwakeTimeLine(time: awakeTime)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(awakeTime.spoken)
        StatusChipRow(chips: chips)
      }
    }
  }
}

struct AwakeTimeLine: View {
  let time: AwakeTime

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      if time.isPlaceholder {
        Text(time.figure)
          .font(.largeTitle)
          .fontWeight(.regular)
          .foregroundStyle(.tertiary)
      } else {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
          Text(time.figure)
            .font(.largeTitle)
            .fontWeight(.bold)
            .monospacedDigit()
          Text(AwakeTime.unit)
            .font(.body)
            .foregroundStyle(.secondary)
        }
      }
      if let note = time.note {
        Text(note)
          .font(.body)
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityHidden(true)
  }
}

struct Footer: View {
  let openSettings: () -> Void

  private var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(PanelContent.versionLine(version))
        .font(.subheadline)
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 0) {
        Button(action: openSettings) {
          PanelRowLabel(icon: "gearshape", title: PanelContent.settingsLabel, shortcut: .settings)
        }
        .buttonStyle(PanelRowButtonStyle())
        .panelShortcut(.settings)
        Button {
          NSApp.terminate(nil)
        } label: {
          PanelRowLabel(icon: "power", title: PanelContent.quitLabel, shortcut: .quit)
        }
        .buttonStyle(PanelRowButtonStyle(corners: .lastRow))
        .panelShortcut(.quit)
        .help(PanelContent.quitHelp)
      }
    }
  }
}
