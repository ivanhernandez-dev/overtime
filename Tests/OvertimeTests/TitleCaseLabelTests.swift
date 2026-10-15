import Foundation
import OvertimeAppSupport
import Testing

@testable import Overtime

struct TitleCaseLabelTests {
  @MainActor @Test func everyAppLabelHasItsTitleCaseText() {
    let renamed: [(text: String, expected: String)] = [
      (SleepDisabledRow.turnOnLabel, "Turn Sleep Back On…"),
      (AttentionRow.reviewUpdateLabel, "Review Update…"),
      (AboutModel.reviewUpdateLabel, "Review Update…"),
      (AboutModel.checkLabel, "Check for Updates…"),
      (AboutModel.showAcknowledgementsLink, "Show Acknowledgements…"),
      (AboutModel.closeAcknowledgementsLabel, "Close Acknowledgements"),
      (DiagnosticsModel.exportTitle, "Export Diagnostics…"),
      (DiagnosticsModel.showLogsTitle, "Show Logs in Finder"),
      (DiagnosticsPane.runOnboardingTitle, "Run Onboarding Again"),
      (DiagnosticsPane.openDetectionSettingsTitle, "Open Detection Settings"),
      (DetectionPane.addFolderLabel, "Add Folder…"),
      (DetectionPane.useDefaultFolderLabel, "Use Default Folder"),
      (DetectionPane.restoreDefaultLabel, "Restore Default"),
      (DetectionPane.addEntrypointLabel, "Add Entrypoint"),
      (NotificationStatusRow.allowLabel, "Allow Notifications"),
      (OnboardingWindow.closeLabel, "Close Setup"),
      (AppKitFolderPicker.prompt, "Add Folder"),
      (AppKitSavePanel.prompt, "Export Archive"),
      (OnboardingWindow.title, "Set Up Overtime"),
    ]
    #expect(renamed.count == 19)
    for label in renamed {
      #expect(label.text == label.expected)
    }
    #expect(DiagnosticsModel.exportTitle == DiagnosticsManifest.exportLabel)
    #expect(SleepDisabledRow.turnOnLabel == SleepDisabledClearing.turnOnLabel)
    #expect(NotificationStatusRow.allowLabel == OnboardingFlow.allowNotificationsLabel)

    let unchanged: [(text: String, expected: String)] = [
      (AboutModel.repositoryLink, "Open Overtime on GitHub"),
      (AboutModel.uninstallLabel, "Uninstall Overtime…"),
      (DiagnosticsModel.showInFinderTitle, "Show in Finder"),
      (NotificationStatusRow.openLabel, "Open Notification Settings"),
      (AttentionRow.reviewLabel, "Review in Settings…"),
      (ReopenWindow.closeLabel, "Close Window"),
    ]
    for label in unchanged {
      #expect(label.text == label.expected)
    }
  }

  @MainActor @Test func theSentencesInTheAppThatNameAControlUseItsLabel() {
    let label = GeneralPane.notificationLabel(.forceReminder)
    #expect(label == "Keep Awake reminder")
    #expect(label.contains(ControlMapping.keepAwakeLabel))
    let caption = GeneralPane.notificationCaption(.forceReminder, floorPercent: 10)
    #expect(caption == "When Keep Awake has been on with no Claude activity.")
    #expect(caption.contains(ControlMapping.keepAwakeLabel))
  }
}
