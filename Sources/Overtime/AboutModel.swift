import Foundation
import Observation
import OvertimeAppSupport

enum AboutUpdatesMode {
  case updates(any UpdaterPort)
  case development
  case blocked
}

struct AboutNoteRow: Equatable {
  let title: String
  let caption: String?
}

@Observable
final class AboutModel {
  static let name = "Overtime"
  static let tagline = "Keeps your Mac awake while Claude Code works, with the lid open or closed."
  static let branding = "Works with Claude Code. Not affiliated with Anthropic."
  static let requirements = "Requires a Mac with Apple silicon and macOS 14 or later."
  static let repositoryLink = "Open Overtime on GitHub"
  static let repositoryURL = URL(string: "https://github.com/ivanhernandez-dev/overtime")!

  static let updatesTitle = "Updates"
  static let automaticChecksLabel = "Check for updates automatically"
  static let automaticChecksCaption =
    "Once a day, Overtime asks GitHub whether a newer version exists. No usage data is sent."
  static let automaticDownloadsLabel = "Download and install updates automatically"
  static let automaticDownloadsCaption =
    "Updates download in the background and install the next time Overtime quits."
  static let lastCheckedLabel = "Last checked"
  static let never = "Never"
  static let checkLabel = "Check for Updates…"
  static let checkUnavailableHelp = "Available when the current update check finishes."
  static let updatesFooter =
    "Installing an update quits Overtime for a few seconds. The Mac sleeps normally until Overtime reopens."
  static let updateSymbol = "arrow.down.circle"
  static let reviewUpdateLabel = "Review Update…"
  static let updateRowSpacing: CGFloat = 4
  static let noteSymbol = "info.circle"
  static let developmentTitle = "Updates are off in development builds."
  static let blockedTitle = "Updates are off until Overtime starts normally."
  static let blockedCaption = "Fix the problem shown in the menu bar, then open Overtime again."

  static let acknowledgementsTitle = "Acknowledgements"
  static let acknowledgementsCaption =
    "Overtime's license, and the notices for the open-source code it includes."
  static let showAcknowledgementsLink = "Show Acknowledgements…"
  static let licenseLabel = "Overtime license"
  static let noticeLabel = "Third-party notices"
  static let closeAcknowledgementsLabel = "Close Acknowledgements"
  static let unreadableFile =
    "Couldn't read this file from the app. It's also in the Overtime repository on GitHub."

  static let uninstallTitle = "Uninstall"
  static let uninstallCaption =
    "Removes Overtime, its login item and unplug protection, and makes sure the Mac sleeps normally. "
    + "You choose whether to keep your settings."
  static let uninstallLabel = "Uninstall Overtime…"
  static let uninstallUnavailableHelp = "Available when unplug protection finishes its current change."

  static let identitySpacing: CGFloat = 8
  static let iconSide: CGFloat = 48
  static let iconSpacing: CGFloat = 12
  static let nameSpacing: CGFloat = 4

  var uninstall: UninstallModel?

  let mode: AboutUpdatesMode
  let shortVersion: String
  let build: String
  private(set) var automaticChecks = false
  private(set) var automaticDownloads = false
  private(set) var downloadsEnabled = false
  private(set) var canCheck = false
  private(set) var lastCheckedText = AboutModel.never
  private(set) var waitingVersion: String?
  private(set) var acknowledgementsShown = false
  private(set) var licenseText: String?
  private(set) var noticeText: String?

  @ObservationIgnored private let readLicense: () -> String?
  @ObservationIgnored private let readNotice: () -> String?
  @ObservationIgnored private let activate: () -> Void
  @ObservationIgnored private let openURL: (URL) -> Void

  init(
    mode: AboutUpdatesMode = .development,
    shortVersion: String = AboutModel.bundleValue("CFBundleShortVersionString"),
    build: String = AboutModel.bundleValue("CFBundleVersion"),
    readLicense: @escaping () -> String? = { nil },
    readNotice: @escaping () -> String? = { nil },
    activate: @escaping () -> Void = {},
    openURL: @escaping (URL) -> Void = { _ in }
  ) {
    self.mode = mode
    self.shortVersion = shortVersion
    self.build = build
    self.readLicense = readLicense
    self.readNotice = readNotice
    self.activate = activate
    self.openURL = openURL
    refresh()
  }

  static func bundleValue(_ key: String) -> String {
    Bundle.main.infoDictionary?[key] as? String ?? "unknown"
  }

  static func mode(isDebugBuild: Bool, host: UpdaterHost, updater: (any UpdaterPort)?) -> AboutUpdatesMode {
    if isDebugBuild { return .development }
    if host == .blocked { return .blocked }
    if host == .live, let updater { return .updates(updater) }
    return .development
  }

  static func versionLine(short: String, build: String) -> String {
    "Version \(short) (\(build))"
  }

  static func updateAvailableTitle(version: String) -> String {
    "Version \(version) is available."
  }

  static func lastChecked(
    _ date: Date?, locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent
  ) -> String {
    guard let date else { return never }
    return UIDateText.string(date, locale: locale, timeZone: timeZone)
  }

  var versionLine: String {
    Self.versionLine(short: shortVersion, build: build)
  }

  var port: (any UpdaterPort)? {
    guard case .updates(let port) = mode else { return nil }
    return port
  }

  var showsUpdateControls: Bool {
    port != nil
  }

  var noteRow: AboutNoteRow? {
    switch mode {
    case .updates:
      nil
    case .development:
      AboutNoteRow(title: Self.developmentTitle, caption: nil)
    case .blocked:
      AboutNoteRow(title: Self.blockedTitle, caption: Self.blockedCaption)
    }
  }

  var checkHelp: String? {
    canCheck ? nil : Self.checkUnavailableHelp
  }

  func refresh() {
    guard let port else { return }
    automaticChecks = port.automaticallyChecksForUpdates
    automaticDownloads = port.automaticallyDownloadsUpdates
    downloadsEnabled = port.allowsAutomaticUpdates
    canCheck = port.canCheckForUpdates
    lastCheckedText = Self.lastChecked(port.lastUpdateCheckDate)
    waitingVersion = port.reminder.waitingVersion
  }

  func setAutomaticChecks(_ enabled: Bool) {
    guard let port else { return }
    port.automaticallyChecksForUpdates = enabled
    refresh()
  }

  func setAutomaticDownloads(_ enabled: Bool) {
    guard let port, port.allowsAutomaticUpdates else {
      refresh()
      return
    }
    port.automaticallyDownloadsUpdates = enabled
    refresh()
  }

  static func uninstallEnabled(helper: HelperUIState?, uninstallActive: Bool) -> Bool {
    guard !uninstallActive else { return false }
    switch helper {
    case .installing?, .updating?, .removing?: return false
    default: return true
    }
  }

  var uninstallActive: Bool {
    uninstall?.isOpenOrActive ?? false
  }

  var uninstalling: Bool {
    uninstall?.isActive ?? false
  }

  func canUninstall(helper: HelperUIState?) -> Bool {
    uninstall != nil && Self.uninstallEnabled(helper: helper, uninstallActive: uninstallActive)
  }

  func uninstallHelp(helper: HelperUIState?) -> String? {
    guard uninstall != nil, !uninstallActive, !canUninstall(helper: helper) else { return nil }
    return Self.uninstallUnavailableHelp
  }

  func requestUninstall(helper: HelperUIState?) async {
    guard let uninstall, canUninstall(helper: helper) else { return }
    await uninstall.present()
  }

  func checkForUpdates() {
    refresh()
    guard let port, canCheck, !uninstalling else { return }
    activate()
    port.checkForUpdates()
  }

  func reviewUpdate() {
    guard let port, !uninstalling else { return }
    activate()
    port.checkForUpdates()
  }

  func openRepository() {
    openURL(Self.repositoryURL)
  }

  func showAcknowledgements() {
    licenseText = readLicense()
    noticeText = readNotice()
    acknowledgementsShown = true
  }

  func closeAcknowledgements() {
    acknowledgementsShown = false
  }
}
