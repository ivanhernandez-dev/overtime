import OvertimeAppSupport
import SwiftUI

struct StepRow: View {
  static let captionGap: CGFloat = 4

  let title: String
  let status: StepStatus
  var caption: String?

  static func statusWord(_ status: StepStatus) -> String {
    switch status {
    case .pending: "not started"
    case .running: "in progress"
    case .done: "done"
    case .skipped: "skipped"
    case .failed: "failed"
    }
  }

  static func shownCaption(status: StepStatus, caption: String?) -> String? {
    if let caption { return caption }
    switch status {
    case .failed(let message), .skipped(let message): return message
    case .pending, .running, .done: return nil
    }
  }

  static func spokenText(title: String, status: StepStatus, caption: String?) -> String {
    let base = title + ", " + statusWord(status)
    guard let shown = shownCaption(status: status, caption: caption) else { return base }
    return base + ". " + shown
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: StatusRowLayout.iconGap) {
      StepIcon(status: status)
        .frame(width: StatusRowLayout.iconWidth)
      VStack(alignment: .leading, spacing: Self.captionGap) {
        Text(title)
          .fixedSize(horizontal: false, vertical: true)
        if let shown = Self.shownCaption(status: status, caption: caption) {
          Text(shown)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Self.spokenText(title: title, status: status, caption: caption))
  }
}

struct StepIcon: View {
  let status: StepStatus

  var body: some View {
    switch status {
    case .pending:
      Image(systemName: "circle").foregroundStyle(.secondary)
    case .running:
      ProgressView().controlSize(.small)
    case .done:
      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
    case .skipped:
      Image(systemName: "minus.circle.fill").foregroundStyle(.orange)
    case .failed:
      Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
    }
  }
}
