import Foundation
import OvertimeAppSupport
import OvertimeEngine
import Testing

struct LabelCaseTests {
  static let smallWords: Set<String> = [
    "a", "an", "the", "and", "or", "nor", "but", "for", "at", "by", "from", "in", "of", "to", "with", "as",
  ]
  static let productNames: Set<String> = ["iPhone", "GitHub"]
  static let ellipsis = "…"

  static func titleCaseFindings(_ label: String) -> [String] {
    let text = label.hasSuffix(ellipsis) ? String(label.dropLast(ellipsis.count)) : label
    let words = text.split(separator: " ").map(String.init)
    guard !words.isEmpty else { return ["\"\(label)\" holds no word"] }
    var findings: [String] = []
    for (index, word) in words.enumerated() where !productNames.contains(word) {
      let inside = index != 0 && index != words.count - 1
      if inside, smallWords.contains(word) { continue }
      for part in word.split(separator: "-") {
        guard let first = part.first, first.isLetter, first.isLowercase else { continue }
        findings.append("\"\(label)\": \"\(part)\" starts in lower case")
      }
    }
    return findings
  }

  static let hintActions: [HintAction] = [
    .copyCommand, .setUpUnplugProtection, .reviewUnplugProtection,
  ]
  static let helperActions: [HelperStatusAction] = [.install, .openLoginItems, .remove, .reconnect]

  static func sharedLabels() -> [String] {
    var labels = [
      DiagnosticsManifest.exportLabel,
      ControlMapping.pauseLabel, ControlMapping.keepAwakeLabel, ControlMapping.resumeLabel,
      ControlMapping.stopKeepingAwakeLabel, ControlMapping.releaseUntilIdleLabel, ControlMapping.restoreLabel,
    ]
    labels += PauseChoice.allCases.map(\.label)
    labels += KeepAwakeChoice.allCases.map(\.label)
    labels += [SleepConfirmation.sleepNowLabel, SleepConfirmation.confirmLabel, SleepConfirmation.cancelLabel]
    labels += hintActions.map(\.label)
    labels += [SleepDisabledClearing.turnOnLabel, SleepDisabledClearing.copyLabel, CopyConfirmation.copiedLabel]
    labels += [LoginItemCaption.openLabel, LocationRow.allowLabel, LocationRow.openLabel]
    labels += helperActions.map(\.label)
    labels += [HelperStatusPresentation.removeConfirmationConfirm, HelperStatusPresentation.removeConfirmationKeep]
    labels += [
      OnboardingFlow.continueLabel, OnboardingFlow.backLabel, OnboardingFlow.skipLabel, OnboardingFlow.finishLabel,
      OnboardingFlow.allowNotificationsLabel, OnboardingFlow.allowLocationLabel, OnboardingFlow.installHelperLabel,
    ]
    labels += CheckRow.Link.allCases.map(\.label)
    labels += [
      UninstallCopy.keepLabel, UninstallCopy.uninstallLabel, UninstallCopy.quitLabel, UninstallCopy.retryLabel,
      UninstallCopy.showInFinderLabel, UninstallCopy.openLoginItemsLabel,
    ]
    labels += [NotificationContent.turnOffActionTitle, SelfTestPresentation.runButtonTitle]
    labels += [PanelContent.settingsLabel, PanelContent.quitLabel]
    labels += SettingsPane.allCases.map(\.title)
    return labels
  }

  @Test func everySharedButtonMenuAndPaneLabelReadsInTitleCase() {
    let labels = Self.sharedLabels()
    #expect(labels.count == 58)
    #expect(Set(labels).count == 52)
    for label in labels {
      #expect(Self.titleCaseFindings(label) == [], "\(label)")
    }
  }

  @Test func theTitleCaseRuleSeesASentenceCaseLabel() {
    #expect(Self.titleCaseFindings("Keep awake").count == 1)
    #expect(Self.titleCaseFindings("Release until idle").count == 2)
    #expect(Self.titleCaseFindings("Turn Sleep Back on…").count == 1)
    #expect(Self.titleCaseFindings("Sleep Now in").count == 1)
    #expect(Self.titleCaseFindings("Run Self-test").count == 1)
    #expect(Self.titleCaseFindings("open Settings").count == 1)
    #expect(Self.titleCaseFindings("for Now").count == 1)
    #expect(Self.titleCaseFindings("").count == 1)

    #expect(Self.titleCaseFindings("Show Logs in Finder") == [])
    #expect(Self.titleCaseFindings("Check for Updates…") == [])
    #expect(Self.titleCaseFindings("Review in GitHub") == [])
    #expect(Self.titleCaseFindings("Join iPhone Hotspot") == [])
    #expect(Self.titleCaseFindings("15 Minutes") == [])
    #expect(Self.titleCaseFindings("Open Wi-Fi Settings") == [])
    #expect(Self.titleCaseFindings("Set Up Unplug Protection…") == [])
    #expect(Self.titleCaseFindings("Turn Off") == [])
    #expect(Self.titleCaseFindings("Settings…") == [])
  }

  static let keepAwakeFailure = "Couldn't turn on Keep Awake. Try again."
  static let overrideReason = "You turned on Keep Awake. It still stops at 10% battery."
  static let restoreReason =
    "Choose Restore Normal Sleep Now to make sure the Mac can sleep, then quit and reopen Overtime."
  static let reminderTitle = "Keep Awake is still on"
  static let reminderBody = "Keep Awake has been on for 3 hours with no Claude activity."
  static let notificationsBody =
    "Overtime notifies you only when you need to act: when keep-awake fails, when the battery is too low to keep going, once when you open the lid if something happened, and when Keep Awake is left on. You can turn off each kind in Settings."
  static let archiveSentence = "Overtime made this archive from Settings > Diagnostics > Export Diagnostics."

  @Test func theSentencesThatNameAControlUseItsLabel() {
    let keepAwake = ControlMapping.keepAwakeLabel
    for choice in KeepAwakeChoice.allCases {
      #expect(ControlFeedback.failureCopy(for: .keepAwake(choice)) == Self.keepAwakeFailure)
    }
    #expect(Self.keepAwakeFailure.contains(keepAwake))

    #expect(StatusPresentation.overrideReason(lowPercent: 10) == Self.overrideReason)
    #expect(Self.overrideReason.contains(keepAwake))

    let unresponsive = StatusPresentation.derive(
      snapshot: EngineSnapshot(busy: false, wanted: false, reason: "idle"), hostFailure: nil,
      engineUnresponsive: true)
    #expect(unresponsive.reason == Self.restoreReason)
    #expect(Self.restoreReason.contains(ControlMapping.restoreLabel))

    #expect(NotificationContent.forceReminderTitle == Self.reminderTitle)
    #expect(Self.reminderTitle.contains(keepAwake))
    #expect(NotificationContent.forceReminderBody(hours: 3) == Self.reminderBody)
    #expect(Self.reminderBody.contains(keepAwake))

    #expect(OnboardingStep.notifications.body == Self.notificationsBody)
    #expect(Self.notificationsBody.contains(keepAwake))

    let readme = DiagnosticsManifest.readmeText
    #expect(readme.components(separatedBy: Self.archiveSentence).count - 1 == 1)
    #expect(Self.archiveSentence.contains(DiagnosticsManifest.exportCommand))
    #expect(DiagnosticsManifest.exportCommand == "Export Diagnostics")
    #expect(DiagnosticsManifest.exportLabel == DiagnosticsManifest.exportCommand + Self.ellipsis)
    #expect(DiagnosticsManifest.exportLabel == "Export Diagnostics…")
  }

  @Test func theRestoreLabelIsSharedCopy() {
    #expect(ControlMapping.restoreLabel == "Restore Normal Sleep Now")
  }

  @Test func theSwitchLabelsKeepSentenceCase() {
    let labels = [LoginItemCaption.toggleLabel, ControlMapping.keepDisplayOnLabel]
    #expect(labels == ["Launch at login", "Keep display on"])
    for label in labels {
      #expect(label.first?.isUppercase == true, "\(label)")
      #expect(!Self.titleCaseFindings(label).isEmpty, "\(label)")
    }
  }
}
