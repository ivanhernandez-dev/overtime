import OvertimeAppSupport
import SwiftUI

struct HintsSection: View {
  let hints: [Hint]
  var perform: (HintAction) -> Void = { _ in }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(hints) { hint in
        HStack(alignment: .firstTextBaseline, spacing: StatusRowLayout.iconGap) {
          Image(systemName: hint.icon)
            .foregroundStyle(hint.tint == .warning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            .frame(width: StatusRowLayout.iconWidth)
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 4) {
            CommandSentence(text: hint.text)
              .font(.subheadline)
              .fixedSize(horizontal: false, vertical: true)
            if let action = hint.action {
              if action == .copyCommand {
                CopyCommandButton(label: action.label) { perform(action) }
              } else {
                Button(action.label) { perform(action) }
                  .buttonStyle(.link)
                  .font(.subheadline)
              }
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
