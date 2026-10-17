import AppKit
import OvertimeAppSupport
import SwiftUI

struct OnboardingWindow: View {
  static let title = "Set Up Overtime"
  static let contentSize = CGSize(width: 560, height: 440)
  static let closeLabel = "Close Setup"

  let model: OnboardingModel
  @AccessibilityFocusState private var progressFocused: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let step = model.currentStep
    VStack(alignment: .leading, spacing: 0) {
      OnboardingProgressRow(model: model)
        .accessibilityFocused($progressFocused)
      ZStack(alignment: .topLeading) {
        VStack(alignment: .leading, spacing: 0) {
          OnboardingStepIcon(step: step)
            .padding(.top, 24)
          Text(step.title)
            .font(.title3)
            .fontWeight(.semibold)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 16)
          Text(model.stepBody)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
          ScrollView(.vertical) {
            OnboardingStepContent(model: model)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxHeight: .infinity)
          .padding(.top, 16)
        }
        .id(step)
        .transition(.opacity)
      }
      .animation(Motion.animation(.onboardingStep, reduceMotion: reduceMotion), value: step)
      OnboardingFooterRow(model: model)
        .padding(.top, 16)
    }
    .padding(24)
    .frame(width: Self.contentSize.width, height: Self.contentSize.height, alignment: .topLeading)
    .transaction { $0.animation = nil }
    .background {
      Button(Self.closeLabel) { model.close() }
        .keyboardShortcut("w")
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
    .background(PanelVisibility { _, visible in model.setWindowVisible(visible) })
    .onChange(of: model.canStartSelfTest) {
      model.startSelfTestIfDue()
    }
    .onChange(of: model.stepChanges) {
      if progressFocused {
        AccessibilityNotification.Announcement(model.progressAccessibilityLabel).post()
      } else {
        progressFocused = true
      }
    }
  }

  static func controller(model: OnboardingModel) -> AuxiliaryWindowController {
    let controller = AuxiliaryWindowController(
      title: title, contentSize: contentSize, didClose: { model.dismissed() },
      makeContent: { AnyView(OnboardingWindow(model: model)) })
    model.onClose = { [weak controller] in
      controller?.close()
    }
    return controller
  }
}

struct OnboardingStepIcon: View {
  static let side: CGFloat = 48

  let step: OnboardingStep

  var body: some View {
    if step == .welcome {
      Image(nsImage: AboutIdentity.applicationIcon())
        .resizable()
        .frame(width: Self.side, height: Self.side)
        .accessibilityHidden(true)
    } else {
      Image(systemName: step.symbol)
        .font(.largeTitle)
        .foregroundStyle(.secondary)
        .frame(width: Self.side, height: Self.side, alignment: .leading)
        .accessibilityHidden(true)
    }
  }
}

struct OnboardingProgressRow: View {
  let model: OnboardingModel

  var body: some View {
    HStack(spacing: 8) {
      ForEach(Array(model.dots.enumerated()), id: \.offset) { item in
        Circle()
          .fill(Self.style(for: item.element))
          .frame(width: 8, height: 8)
      }
      Spacer(minLength: 8)
      Text(model.progressLabel)
        .font(.subheadline)
        .fontWeight(.semibold)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(model.progressAccessibilityLabel)
  }

  static func style(for dot: OnboardingDot) -> HierarchicalShapeStyle {
    switch dot {
    case .current: .primary
    case .completed: .secondary
    case .upcoming: .quaternary
    }
  }
}

struct OnboardingFooterRow: View {
  let model: OnboardingModel

  var body: some View {
    let button = model.defaultButton
    HStack(spacing: 8) {
      if model.showsBack {
        Button(OnboardingFlow.backLabel) { model.back() }
          .disabled(!model.backEnabled)
      }
      Spacer()
      if model.showsSkip {
        Button(OnboardingFlow.skipLabel) { model.skipStep() }
          .disabled(!model.skipEnabled)
      }
      Button(button.title) { model.performDefault() }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(!button.enabled)
    }
  }
}

final class OnboardingPresenter {
  let model: OnboardingModel
  let controller: AuxiliaryWindowController
  private let present: (AuxiliaryWindowController) -> Void
  private(set) var armed = false

  init(model: OnboardingModel, present: @escaping (AuxiliaryWindowController) -> Void = { $0.show() }) {
    self.model = model
    controller = OnboardingWindow.controller(model: model)
    self.present = present
  }

  func arm(firstRun: Bool) {
    armed = firstRun
  }

  @discardableResult
  func openIfArmed() -> Bool {
    guard armed else { return false }
    show()
    return true
  }

  func show() {
    armed = false
    model.begin()
    present(controller)
  }
}
