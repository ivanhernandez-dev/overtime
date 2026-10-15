import SwiftUI

struct AcknowledgementsSheet: View {
  static let size = CGSize(width: 560, height: 400)
  static let padding: CGFloat = 24
  static let titleGap: CGFloat = 16
  static let labelGap: CGFloat = 8
  static let fileGap: CGFloat = 24

  let about: AboutModel
  @AccessibilityFocusState private var titleFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(AboutModel.acknowledgementsTitle)
        .font(.title3)
        .fontWeight(.semibold)
        .accessibilityAddTraits(.isHeader)
        .accessibilityFocused($titleFocused)
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          AcknowledgementsFile(label: AboutModel.licenseLabel, text: about.licenseText, about: about)
          AcknowledgementsFile(label: AboutModel.noticeLabel, text: about.noticeText, about: about)
            .padding(.top, Self.fileGap)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.top, Self.titleGap)
      HStack {
        Spacer()
        Button(AboutModel.closeAcknowledgementsLabel) { about.closeAcknowledgements() }
          .keyboardShortcut(.defaultAction)
      }
      .padding(.top, Self.titleGap)
    }
    .padding(Self.padding)
    .frame(width: Self.size.width, height: Self.size.height)
    .transaction { $0.animation = nil }
    .background {
      Button(AboutModel.closeAcknowledgementsLabel) { about.closeAcknowledgements() }
        .keyboardShortcut(.cancelAction)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
    .onAppear { titleFocused = true }
  }
}

struct AcknowledgementsFile: View {
  let label: String
  let text: String?
  let about: AboutModel

  var body: some View {
    VStack(alignment: .leading, spacing: AcknowledgementsSheet.labelGap) {
      Text(label)
        .font(.subheadline)
        .fontWeight(.semibold)
        .foregroundStyle(.secondary)
        .accessibilityAddTraits(.isHeader)
      if let text {
        Text(text)
          .monospaced()
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        VStack(alignment: .leading, spacing: AboutModel.nameSpacing) {
          SettingsSectionCaption(text: AboutModel.unreadableFile)
          Button(AboutModel.repositoryLink) { about.openRepository() }
            .buttonStyle(.link)
            .font(.subheadline)
        }
      }
    }
  }
}
