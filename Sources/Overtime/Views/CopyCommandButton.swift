import OvertimeAppSupport
import SwiftUI

@Observable
final class CopyFeedback {
  private(set) var isShowing = false
  private(set) var generation = 0
  let seconds: Double
  let announce: @MainActor (String) -> Void
  @ObservationIgnored private var expiry: Task<Void, Never>?

  init(
    seconds: Double = CopyConfirmation.seconds, announce: @escaping @MainActor (String) -> Void = CopyFeedback.post
  ) {
    self.seconds = seconds
    self.announce = announce
  }

  static func post(_ text: String) {
    AccessibilityNotification.Announcement(text).post()
  }

  func copied() {
    generation += 1
    isShowing = true
    announce(CopyConfirmation.announcement)
    let shown = generation
    let seconds = seconds
    expiry?.cancel()
    expiry = Task { [weak self] in
      try? await Task.sleep(for: .seconds(seconds))
      self?.expire(shown)
    }
  }

  func expire(_ generation: Int) {
    guard generation == self.generation else { return }
    isShowing = false
  }
}

struct CopyCommandButton: View {
  let label: String
  let copy: () -> Void
  @State private var feedback = CopyFeedback()

  var body: some View {
    Button {
      copy()
      feedback.copied()
    } label: {
      if feedback.isShowing {
        HStack(spacing: 2) {
          Image(systemName: CopyConfirmation.copiedSymbol)
            .accessibilityHidden(true)
          Text(CopyConfirmation.copiedLabel)
        }
      } else {
        Text(label)
      }
    }
    .buttonStyle(.link)
    .font(.subheadline)
    .accessibilityLabel(label)
  }
}

struct CommandSentence: View {
  let text: String

  var body: Text {
    let parts = CommandText.split(text)
    guard let command = parts.command else { return Text(text) }
    return Text("\(Text(verbatim: parts.sentence))\(Text(verbatim: command).monospaced())")
  }
}
