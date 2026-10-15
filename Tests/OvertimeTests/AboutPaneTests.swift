import AppKit
import Foundation
import Observation
import OvertimeAppSupport
import Testing
import os

@testable import Overtime

@MainActor
struct AboutPaneTests {
  final class FakeUpdater: UpdaterPort {
    var automaticallyChecksForUpdates = true
    var automaticallyDownloadsUpdates = false
    var allowsAutomaticUpdates = true
    var canCheckForUpdates = true
    var lastUpdateCheckDate: Date?
    var reminder = UpdateReminder()
    var onChange: (() -> Void)?
    var events: [String] = []

    func checkForUpdates() {
      events.append("check")
    }
  }

  static let checkedAt = Date(timeIntervalSince1970: 1_791_542_520)

  static func model(_ fake: FakeUpdater, opened: @escaping (URL) -> Void = { _ in }) -> AboutModel {
    AboutModel(
      mode: .updates(fake), shortVersion: "0.1.0", build: "100",
      activate: { fake.events.append("activate") }, openURL: opened)
  }

  static func isDevelopment(_ mode: AboutUpdatesMode) -> Bool {
    if case .development = mode { return true }
    return false
  }

  static func isBlocked(_ mode: AboutUpdatesMode) -> Bool {
    if case .blocked = mode { return true }
    return false
  }

  static func updatesPort(_ mode: AboutUpdatesMode) -> (any UpdaterPort)? {
    if case .updates(let port) = mode { return port }
    return nil
  }

  @Test func theIdentityCopyMatchesTheUISpec() {
    #expect(AboutModel.name == "Overtime")
    #expect(AboutModel.tagline == "Keeps your Mac awake while Claude Code works, with the lid open or closed.")
    #expect(AboutModel.branding == "Works with Claude Code. Not affiliated with Anthropic.")
    #expect(AboutModel.requirements == "Requires a Mac with Apple silicon and macOS 14 or later.")
    #expect(AboutModel.repositoryLink == "Open Overtime on GitHub")
    #expect(AboutModel.repositoryURL.absoluteString == "https://github.com/ivanhernandez-dev/overtime")
  }

  @Test func theUpdatesCopyMatchesTheUISpec() {
    #expect(AboutModel.updatesTitle == "Updates")
    #expect(AboutModel.automaticChecksLabel == "Check for updates automatically")
    #expect(
      AboutModel.automaticChecksCaption
        == "Once a day, Overtime asks GitHub whether a newer version exists. No usage data is sent.")
    #expect(AboutModel.automaticDownloadsLabel == "Download and install updates automatically")
    #expect(
      AboutModel.automaticDownloadsCaption
        == "Updates download in the background and install the next time Overtime quits.")
    #expect(AboutModel.lastCheckedLabel == "Last checked")
    #expect(AboutModel.never == "Never")
    #expect(AboutModel.checkLabel == "Check for Updates…")
    #expect(AboutModel.checkUnavailableHelp == "Available when the current update check finishes.")
    #expect(
      AboutModel.updatesFooter
        == "Installing an update quits Overtime for a few seconds. The Mac sleeps normally until Overtime reopens.")
  }

  @Test func theNoUpdaterRowsMatchTheUISpec() {
    #expect(AboutModel.noteSymbol == "info.circle")
    #expect(AboutModel.developmentTitle == "Updates are off in development builds.")
    #expect(AboutModel.blockedTitle == "Updates are off until Overtime starts normally.")
    #expect(AboutModel.blockedCaption == "Fix the problem shown in the menu bar, then open Overtime again.")
    #expect(
      AboutModel(mode: .development).noteRow
        == AboutNoteRow(title: "Updates are off in development builds.", caption: nil))
    #expect(
      AboutModel(mode: .blocked).noteRow
        == AboutNoteRow(
          title: "Updates are off until Overtime starts normally.",
          caption: "Fix the problem shown in the menu bar, then open Overtime again."))
    #expect(Self.model(FakeUpdater()).noteRow == nil)
  }

  @Test func onlyTheLiveUpdaterShowsTheUpdateControls() {
    #expect(Self.model(FakeUpdater()).showsUpdateControls)
    #expect(!AboutModel(mode: .development).showsUpdateControls)
    #expect(!AboutModel(mode: .blocked).showsUpdateControls)
  }

  @Test func theIdentityBlockKeepsTheUISpecSpacing() {
    #expect(AboutModel.identitySpacing == 8)
    #expect(AboutModel.nameSpacing == 4)
  }

  @Test func theIdentityIconKeepsTheUISpecGeometry() {
    #expect(AboutModel.iconSide == 48)
    #expect(AboutModel.iconSpacing == 12)
  }

  @Test func theIdentityIconIsTheApplicationIconImage() {
    let icon = AboutIdentity.applicationIcon()
    #expect(icon.isValid)
    #expect(icon.size.width > 0)
    #expect(icon.size.height > 0)
    #expect(icon === NSApp.applicationIconImage)
  }

  @Test func theVersionLineIsBuiltFromTheShortVersionAndTheBuild() {
    #expect(AboutModel.versionLine(short: "0.1.0", build: "100") == "Version 0.1.0 (100)")
    #expect(Self.model(FakeUpdater()).versionLine == "Version 0.1.0 (100)")
  }

  @Test func theDefaultVersionComesFromTheBundle() {
    let model = AboutModel()
    let info = Bundle.main.infoDictionary ?? [:]
    #expect(model.shortVersion == info["CFBundleShortVersionString"] as? String)
    #expect(model.build == info["CFBundleVersion"] as? String)
    #expect(Self.isDevelopment(model.mode))
  }

  @Test func theLastCheckedTextIsNeverOrTheAbbreviatedDateAndShortTime() {
    #expect(AboutModel.lastChecked(nil) == "Never")
    #expect(AboutModel.lastChecked(Self.checkedAt) == UIDateText.string(Self.checkedAt))
  }

  @Test func theLastCheckedDateIsEnglishUnderASpanishLocale() throws {
    let spanish = Locale(identifier: "es_ES")
    let gmt = try #require(TimeZone(secondsFromGMT: 0))
    let date = Date(timeIntervalSince1970: 1_773_666_300)
    let text = AboutModel.lastChecked(date, locale: spanish, timeZone: gmt)
    #expect(text == UIDateText.string(date, locale: spanish, timeZone: gmt))
    #expect(text.contains("Mar"), "\(text)")
  }

  @Test(arguments: [UpdaterHost.testHost, .blocked, .live])
  func aDebugBuildIsADevelopmentBuildOnEveryHost(_ host: UpdaterHost) {
    #expect(Self.isDevelopment(AboutModel.mode(isDebugBuild: true, host: host, updater: FakeUpdater())))
    #expect(Self.isDevelopment(AboutModel.mode(isDebugBuild: true, host: host, updater: nil)))
  }

  @Test func theBlockedReleaseAppIsBlockedWithOrWithoutAPort() {
    #expect(Self.isBlocked(AboutModel.mode(isDebugBuild: false, host: .blocked, updater: nil)))
    #expect(Self.isBlocked(AboutModel.mode(isDebugBuild: false, host: .blocked, updater: FakeUpdater())))
  }

  @Test func theLiveReleaseAppWithAPortGetsTheUpdateControls() {
    let fake = FakeUpdater()
    let port = Self.updatesPort(AboutModel.mode(isDebugBuild: false, host: .live, updater: fake))
    #expect(port === fake)
    #expect(Self.isDevelopment(AboutModel.mode(isDebugBuild: false, host: .live, updater: nil)))
    #expect(Self.isDevelopment(AboutModel.mode(isDebugBuild: false, host: .testHost, updater: fake)))
  }

  @Test func theTestHostBuildsADevelopmentAboutModel() {
    #expect(Self.isDevelopment(AppDelegate.aboutModel(updater: nil).mode))
    #expect(Self.isDevelopment(AppDelegate.aboutModel(updater: FakeUpdater()).mode))
  }

  @Test func refreshCopiesThePortValuesAndTheLastCheck() {
    let fake = FakeUpdater()
    let model = Self.model(fake)
    #expect(model.automaticChecks)
    #expect(!model.automaticDownloads)
    #expect(model.downloadsEnabled)
    #expect(model.canCheck)
    #expect(model.lastCheckedText == "Never")
    fake.automaticallyChecksForUpdates = false
    fake.automaticallyDownloadsUpdates = true
    fake.allowsAutomaticUpdates = false
    fake.canCheckForUpdates = false
    fake.lastUpdateCheckDate = Self.checkedAt
    model.refresh()
    #expect(!model.automaticChecks)
    #expect(model.automaticDownloads)
    #expect(!model.downloadsEnabled)
    #expect(!model.canCheck)
    #expect(model.lastCheckedText == UIDateText.string(Self.checkedAt))
  }

  @Test func theSwitchesWriteThroughToThePort() {
    let fake = FakeUpdater()
    let model = Self.model(fake)
    model.setAutomaticChecks(false)
    #expect(!fake.automaticallyChecksForUpdates)
    #expect(!model.automaticChecks)
    model.setAutomaticDownloads(true)
    #expect(fake.automaticallyDownloadsUpdates)
    #expect(model.automaticDownloads)
  }

  @Test func theDownloadSwitchFollowsAllowsAutomaticUpdates() {
    let fake = FakeUpdater()
    fake.allowsAutomaticUpdates = false
    let model = Self.model(fake)
    #expect(!model.downloadsEnabled)
    model.setAutomaticDownloads(true)
    #expect(!fake.automaticallyDownloadsUpdates)
    #expect(!model.automaticDownloads)
    fake.allowsAutomaticUpdates = true
    model.refresh()
    #expect(model.downloadsEnabled)
  }

  @Test func checkingActivatesTheAppAndThenAsksTheUpdater() {
    let fake = FakeUpdater()
    let model = Self.model(fake)
    model.checkForUpdates()
    #expect(fake.events == ["activate", "check"])
  }

  @Test func checkingDoesNothingWhileACheckIsRunning() {
    let fake = FakeUpdater()
    fake.canCheckForUpdates = false
    let model = Self.model(fake)
    model.checkForUpdates()
    #expect(fake.events.isEmpty)
    fake.canCheckForUpdates = true
    model.checkForUpdates()
    #expect(fake.events == ["activate", "check"])
  }

  @Test func theCheckHelpIsOfferedOnlyWhileTheButtonIsDisabled() {
    let fake = FakeUpdater()
    let model = Self.model(fake)
    #expect(model.checkHelp == nil)
    fake.canCheckForUpdates = false
    model.refresh()
    #expect(model.checkHelp == "Available when the current update check finishes.")
  }

  @Test func aPortChangeRefreshesTheModelThroughTheAppDelegateRoute() {
    let fake = FakeUpdater()
    let model = Self.model(fake)
    fake.onChange = { AppDelegate.refreshAfterUpdaterChange(about: model) }
    fake.automaticallyChecksForUpdates = false
    fake.canCheckForUpdates = false
    #expect(model.automaticChecks)
    fake.onChange?()
    #expect(!model.automaticChecks)
    #expect(!model.canCheck)
  }

  @Test func theUpdateAvailableRowCopyMatchesTheUISpec() {
    #expect(AboutModel.updateSymbol == "arrow.down.circle")
    #expect(AboutModel.reviewUpdateLabel == "Review Update…")
    #expect(AboutModel.updateAvailableTitle(version: "0.1.1") == "Version 0.1.1 is available.")
    #expect(AboutModel.updateRowSpacing == 4)
    #expect(Set([AboutModel.updateSymbol]).isSubset(of: Set(SymbolAvailabilityTests.phaseFiveSymbols)))
  }

  @Test func aWaitingUpdateGivesTheModelItsVersion() {
    let fake = FakeUpdater()
    fake.reminder.willShowUpdate(handledBySparkle: false, version: "0.1.1")
    let model = Self.model(fake)
    #expect(model.waitingVersion == "0.1.1")
    #expect(AboutModel.updateAvailableTitle(version: model.waitingVersion ?? "") == "Version 0.1.1 is available.")
  }

  @Test func withNoWaitingUpdateThereIsNoUpdateRow() {
    let fake = FakeUpdater()
    let model = Self.model(fake)
    #expect(model.waitingVersion == nil)
    fake.reminder.willShowUpdate(handledBySparkle: true, version: "0.1.1")
    model.refresh()
    #expect(model.waitingVersion == nil)
  }

  @Test func theUpdateRowFollowsTheReminderThroughTheAppDelegateRoute() {
    let fake = FakeUpdater()
    let model = Self.model(fake)
    fake.onChange = { AppDelegate.refreshAfterUpdaterChange(about: model) }
    fake.reminder.willShowUpdate(handledBySparkle: false, version: "0.1.1")
    fake.onChange?()
    #expect(model.waitingVersion == "0.1.1")
    fake.reminder.userAttended()
    fake.onChange?()
    #expect(model.waitingVersion == nil)
    fake.reminder.willShowUpdate(handledBySparkle: false, version: "0.1.2")
    fake.onChange?()
    #expect(model.waitingVersion == "0.1.2")
    fake.reminder.sessionFinished()
    fake.onChange?()
    #expect(model.waitingVersion == nil)
  }

  @Test func reviewingTheUpdateActivatesTheAppAndThenAsksTheUpdater() {
    let fake = FakeUpdater()
    fake.reminder.willShowUpdate(handledBySparkle: false, version: "0.1.1")
    let model = Self.model(fake)
    model.reviewUpdate()
    #expect(fake.events == ["activate", "check"])
  }

  @Test func theNoUpdaterModesHaveNoWaitingVersionAndNeverReview() {
    var activated = 0
    for mode in [AboutUpdatesMode.development, .blocked] {
      let model = AboutModel(mode: mode, activate: { activated += 1 })
      model.refresh()
      model.reviewUpdate()
      #expect(model.waitingVersion == nil)
    }
    #expect(activated == 0)
  }

  @Test func openingTheRepositoryOpensTheGitHubPage() {
    var opened: [URL] = []
    let model = Self.model(FakeUpdater()) { opened.append($0) }
    model.openRepository()
    #expect(opened == [URL(string: "https://github.com/ivanhernandez-dev/overtime")!])
  }

  @MainActor
  final class Readers {
    var license: String?
    var notice: String?
    var licenseReads = 0
    var noticeReads = 0

    init(license: String?, notice: String?) {
      self.license = license
      self.notice = notice
    }

    func model() -> AboutModel {
      AboutModel(
        mode: .development, shortVersion: "0.1.0", build: "100",
        readLicense: {
          self.licenseReads += 1
          return self.license
        },
        readNotice: {
          self.noticeReads += 1
          return self.notice
        })
    }
  }

  @Test func theAcknowledgementsCopyMatchesTheUISpec() {
    #expect(AboutModel.acknowledgementsTitle == "Acknowledgements")
    #expect(
      AboutModel.acknowledgementsCaption
        == "Overtime's license, and the notices for the open-source code it includes.")
    #expect(AboutModel.showAcknowledgementsLink == "Show Acknowledgements…")
    #expect(AboutModel.licenseLabel == "Overtime license")
    #expect(AboutModel.noticeLabel == "Third-party notices")
    #expect(AboutModel.closeAcknowledgementsLabel == "Close Acknowledgements")
    #expect(
      AboutModel.unreadableFile
        == "Couldn't read this file from the app. It's also in the Overtime repository on GitHub.")
  }

  @Test func theAcknowledgementsSheetKeepsTheUISpecGeometry() {
    #expect(AcknowledgementsSheet.size == CGSize(width: 560, height: 400))
    #expect(AcknowledgementsSheet.padding == 24)
    #expect(AcknowledgementsSheet.titleGap == 16)
    #expect(AcknowledgementsSheet.labelGap == 8)
    #expect(AcknowledgementsSheet.fileGap == 24)
  }

  @Test func openingTheSheetReadsBothFilesOnceAndShowsThem() {
    let readers = Readers(license: "MIT License", notice: "Sparkle notice")
    let model = readers.model()
    #expect(readers.licenseReads == 0)
    #expect(readers.noticeReads == 0)
    #expect(!model.acknowledgementsShown)
    model.showAcknowledgements()
    #expect(model.acknowledgementsShown)
    #expect(model.licenseText == "MIT License")
    #expect(model.noticeText == "Sparkle notice")
    #expect(readers.licenseReads == 1)
    #expect(readers.noticeReads == 1)
  }

  @Test func anUnreadableLicenseLeavesTheNoticeShowing() {
    let model = Readers(license: nil, notice: "Sparkle notice").model()
    model.showAcknowledgements()
    #expect(model.licenseText == nil)
    #expect(model.noticeText == "Sparkle notice")
  }

  @Test func anUnreadableNoticeLeavesTheLicenseShowing() {
    let model = Readers(license: "MIT License", notice: nil).model()
    model.showAcknowledgements()
    #expect(model.licenseText == "MIT License")
    #expect(model.noticeText == nil)
  }

  @Test func closingTheSheetClearsItAndReopeningReadsAgain() {
    let readers = Readers(license: "MIT License", notice: nil)
    let model = readers.model()
    model.showAcknowledgements()
    model.closeAcknowledgements()
    #expect(!model.acknowledgementsShown)
    readers.notice = "Sparkle notice"
    model.showAcknowledgements()
    #expect(model.acknowledgementsShown)
    #expect(model.noticeText == "Sparkle notice")
    #expect(readers.licenseReads == 2)
    #expect(readers.noticeReads == 2)
  }

  @Test func theDefaultReadersShowTheErrorForBothFiles() {
    let model = AboutModel(mode: .development, shortVersion: "0.1.0", build: "100")
    model.showAcknowledgements()
    #expect(model.acknowledgementsShown)
    #expect(model.licenseText == nil)
    #expect(model.noticeText == nil)
  }

  @Test func theNoUpdaterModesNeverActivateOrOpenAnything() {
    var activated = 0
    for mode in [AboutUpdatesMode.development, .blocked] {
      let model = AboutModel(mode: mode, activate: { activated += 1 })
      model.checkForUpdates()
      model.setAutomaticChecks(true)
      model.setAutomaticDownloads(true)
      #expect(!model.automaticChecks)
      #expect(!model.canCheck)
      #expect(model.lastCheckedText == "Never")
    }
    #expect(activated == 0)
  }

  @Test func theUninstallSectionCopyMatchesTheUISpec() {
    #expect(AboutModel.uninstallTitle == "Uninstall")
    #expect(
      AboutModel.uninstallCaption
        == "Removes Overtime, its login item and unplug protection, and makes sure the Mac sleeps normally. "
        + "You choose whether to keep your settings.")
    #expect(AboutModel.uninstallLabel == "Uninstall Overtime…")
    #expect(AboutModel.uninstallUnavailableHelp == "Available when unplug protection finishes its current change.")
  }

  @Test(arguments: [HelperUIState?.none] + HelperUIState.allCases.map { Optional($0) })
  func uninstallIsOffWhileUnplugProtectionChangesOrAnUninstallIsOpen(_ helper: HelperUIState?) {
    let changing = helper == .installing || helper == .updating || helper == .removing
    #expect(AboutModel.uninstallEnabled(helper: helper, uninstallActive: false) == !changing)
    #expect(!AboutModel.uninstallEnabled(helper: helper, uninstallActive: true))
  }

  static func uninstallModel(panel: PanelModel? = nil) -> UninstallModel {
    let system = UninstallSheetTests.FakeSystem()
    return UninstallModel(
      coordinator: UninstallCoordinator(
        system: system, table: .dev, mode: .app, stepTimeoutSeconds: 10, stopTimeoutSeconds: 10,
        adminTimeoutSeconds: 10),
      table: .dev, helperStatus: { .notRegistered }, panel: panel, quit: {})
  }

  @Test func withNoUninstallModelTheButtonIsOffWithNoHelp() {
    let about = AboutModel()
    #expect(!about.canUninstall(helper: nil))
    #expect(about.uninstallHelp(helper: nil) == nil)
    #expect(!about.uninstallActive)
  }

  @Test func theButtonOpensTheSheetAndIsOffWithNoHelpWhileTheSheetIsOpen() async {
    let about = AboutModel()
    about.uninstall = Self.uninstallModel()
    #expect(about.canUninstall(helper: .onStandingBy))
    #expect(about.uninstallHelp(helper: .onStandingBy) == nil)
    #expect(about.uninstallHelp(helper: .installing) == AboutModel.uninstallUnavailableHelp)
    await about.requestUninstall(helper: .installing)
    #expect(about.uninstall?.isPresented == false)
    await about.requestUninstall(helper: .onStandingBy)
    #expect(about.uninstall?.isPresented == true)
    #expect(about.uninstallActive)
    #expect(!about.canUninstall(helper: .onStandingBy))
    #expect(about.uninstallHelp(helper: .onStandingBy) == nil)
    #expect(about.uninstallHelp(helper: .installing) == nil)
    about.uninstall?.keep()
    #expect(!about.uninstallActive)
  }

  final class StatusGate: Sendable {
    private let opened = OSAllocatedUnfairLock(initialState: false)

    func open() {
      opened.withLock { $0 = true }
    }

    func read() -> HelperInstallerStatus {
      let deadline = Date().addingTimeInterval(10)
      while !opened.withLock({ $0 }), Date() < deadline {
        Thread.sleep(forTimeInterval: 0.01)
      }
      return .notRegistered
    }
  }

  @Test func theUninstallButtonRedrawsOffWithNoHelpWhileTheHelperStatusIsRead() async {
    let gate = StatusGate()
    defer { gate.open() }
    let system = UninstallSheetTests.FakeSystem()
    let uninstall = UninstallModel(
      coordinator: UninstallCoordinator(
        system: system, table: .dev, mode: .app, stepTimeoutSeconds: 10, stopTimeoutSeconds: 10,
        adminTimeoutSeconds: 10),
      table: .dev, helperStatus: { gate.read() }, panel: nil, quit: {}, statusTimeoutSeconds: 10)
    let about = AboutModel()
    about.uninstall = uninstall
    let changed = OSAllocatedUnfairLock(initialState: false)
    withObservationTracking {
      _ = about.canUninstall(helper: .onStandingBy)
    } onChange: {
      changed.withLock { $0 = true }
    }
    let task = Task { await about.requestUninstall(helper: .onStandingBy) }
    #expect(await waitUntil(timeout: 2) { changed.withLock { $0 } })
    #expect(!about.canUninstall(helper: .onStandingBy))
    #expect(about.uninstallHelp(helper: .onStandingBy) == nil)
    #expect(about.uninstallHelp(helper: .installing) == nil)
    #expect(about.uninstall?.isPresented == false)
    gate.open()
    await task.value
    #expect(about.uninstall?.isPresented == true)
    #expect(about.uninstallHelp(helper: .onStandingBy) == nil)
  }

  @Test func updateChecksAndReviewsDoNothingWhileAnUninstallRuns() async {
    let fake = FakeUpdater()
    let about = Self.model(fake)
    let panel = PanelModel()
    let uninstall = Self.uninstallModel(panel: panel)
    about.uninstall = uninstall
    await uninstall.present()
    uninstall.confirm()
    #expect(about.uninstalling)
    about.checkForUpdates()
    about.reviewUpdate()
    #expect(fake.events.isEmpty)
    #expect(await uninstall.settled(seconds: 10))
  }
}
