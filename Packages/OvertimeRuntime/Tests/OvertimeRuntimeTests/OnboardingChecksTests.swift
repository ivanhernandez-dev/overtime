import Foundation
import OvertimeAppSupport
import OvertimeCore
import Testing

struct OnboardingChecksTests {
  struct ScreenLockCase: Sendable, CustomTestStringConvertible {
    let status: ScreenLockStatus
    let row: CheckRow

    var testDescription: String {
      row.title
    }
  }

  static let lockLabel = "Open Lock Screen Settings"
  static let wifiLabel = "Open Wi-Fi Settings"

  static let screenLockCases = [
    ScreenLockCase(
      status: .immediate,
      row: CheckRow(check: .screenLock, icon: .pass, title: "Screen lock asks for your password immediately.")),
    ScreenLockCase(
      status: .delayed(seconds: 5),
      row: CheckRow(
        check: .screenLock, icon: .warning, title: "Screen lock waits before asking for your password.",
        caption: "With the lid closed and the display off, the Mac stays unlocked until then.", link: .lockScreen)),
    ScreenLockCase(
      status: .delayed(seconds: 3_600),
      row: CheckRow(
        check: .screenLock, icon: .warning, title: "Screen lock waits before asking for your password.",
        caption: "With the lid closed and the display off, the Mac stays unlocked until then.", link: .lockScreen)),
    ScreenLockCase(
      status: .off,
      row: CheckRow(
        check: .screenLock, icon: .warning,
        title: "The Mac doesn't ask for a password after the display turns off.",
        caption: "Anyone who opens the lid can use it.", link: .lockScreen)),
    ScreenLockCase(
      status: .unknown,
      row: CheckRow(
        check: .screenLock, icon: .info, title: "Overtime couldn't read the screen lock setting.",
        caption:
          "In System Settings > Lock Screen, set Require password after screen saver begins or display is turned off to Immediately.",
        link: .lockScreen)),
  ]

  @Test(arguments: screenLockCases)
  func theScreenLockRowIsTheUISpecRowForWhatWasRead(_ item: ScreenLockCase) {
    #expect(OnboardingChecks.screenLock(item.status) == item.row)
  }

  @Test func onlyAnImmediateScreenLockReadsAsAPassAndEveryOtherStateOffersTheLockScreenSettings() {
    let statuses: [ScreenLockStatus] = [.immediate, .delayed(seconds: 1), .off, .unknown]
    let rows = statuses.map { OnboardingChecks.screenLock($0) }
    #expect(rows.map(\.icon) == [.pass, .warning, .warning, .info])
    #expect(rows.map(\.link) == [nil, .lockScreen, .lockScreen, .lockScreen])
    #expect(rows.map { $0.caption == nil } == [true, false, false, false])
    #expect(rows.allSatisfy { $0.check == .screenLock })
  }

  @Test func aScreenLockThatCouldNotBeReadIsNeverShownAsAPassOrAWarning() {
    let row = OnboardingChecks.screenLock(.unknown)
    #expect(row.icon == .info)
    #expect(row.link?.label == Self.lockLabel)
    #expect(row.title.contains("couldn't read"))
    let parsed = ScreenLockStatus.parse(output: "", exitCode: nil, timedOut: true)
    #expect(OnboardingChecks.screenLock(parsed) == row)
    let garbled = ScreenLockStatus.parse(output: "screenLock delay is soon", exitCode: 0, timedOut: false)
    #expect(OnboardingChecks.screenLock(garbled) == row)
  }

  struct HotspotCase: Sendable, CustomTestStringConvertible {
    let name: String
    let networks: [String]?
    let row: CheckRow

    var testDescription: String {
      name
    }
  }

  static let found = CheckRow(
    check: .hotspot, icon: .pass, title: "A known iPhone hotspot was found.",
    caption: "You can choose it in Settings > Network.")
  static let noneKnown = CheckRow(
    check: .hotspot, icon: .info, title: "No iPhone hotspot among your known networks.",
    caption: "Join your iPhone's hotspot once so failover can use it later.")
  static let unreadable = CheckRow(
    check: .hotspot, icon: .info, title: "Overtime couldn't read your known networks.",
    caption: "You can check your known networks in System Settings > Wi-Fi.", link: .wifi)

  static let hotspotCases = [
    HotspotCase(name: "one iPhone name", networks: ["Home", "Ivan's iPhone"], row: found),
    HotspotCase(name: "the marker inside a longer name", networks: ["iPhone de Ana 15"], row: found),
    HotspotCase(name: "several networks, one iPhone", networks: ["Office", "Cafe", "iPhone"], row: found),
    HotspotCase(name: "no iPhone name", networks: ["Home", "Office"], row: noneKnown),
    HotspotCase(name: "another capitalisation is not the marker", networks: ["iphone", "IPHONE"], row: noneKnown),
    HotspotCase(name: "no known network", networks: [], row: noneKnown),
    HotspotCase(name: "the list could not be read", networks: nil, row: unreadable),
  ]

  @Test(arguments: hotspotCases)
  func theHotspotRowFollowsTheKnownNetworks(_ item: HotspotCase) {
    #expect(OnboardingChecks.hotspot(knownNetworks: item.networks) == item.row)
  }

  @Test func theHotspotMarkerIsTheStartupChecksMarker() {
    #expect(StartupChecks.autodetectMarker == "iPhone")
    #expect(OnboardingChecks.hotspot(knownNetworks: [StartupChecks.autodetectMarker]) == Self.found)
  }

  @Test func noHotspotRowNamesANetwork() {
    let names = ["Ivan's iPhone", "Home-5G"]
    let row = OnboardingChecks.hotspot(knownNetworks: names)
    for name in names {
      #expect(!row.title.contains(name))
      #expect(row.caption?.contains(name) != true)
    }
  }

  @Test func askToJoinHotspotsIsAlwaysTheExplanationWithTheWiFiLink() {
    let row = CheckRow(
      check: .askToJoin, icon: .info, title: "Check Ask to join hotspots.",
      caption:
        "Failover works best when System Settings > Wi-Fi > Ask to join hotspots is set to Automatic. Overtime can't read this setting.",
      link: .wifi)
    #expect(OnboardingChecks.askToJoin == row)
    #expect(OnboardingChecks.askToJoin == OnboardingChecks.askToJoin(reading: .unreadable))
    #expect(OnboardingChecks.askToJoin.link?.label == Self.wifiLabel)
  }

  @Test func theReadableAskToJoinRowsAreTheUISpecOnes() {
    #expect(
      OnboardingChecks.askToJoin(reading: .automatic)
        == CheckRow(check: .askToJoin, icon: .pass, title: "Ask to join hotspots is set to Automatic."))
    #expect(
      OnboardingChecks.askToJoin(reading: .notAutomatic)
        == CheckRow(
          check: .askToJoin, icon: .info, title: "Ask to join hotspots isn't set to Automatic.",
          caption: "Failover works best when macOS can join your iPhone's hotspot on its own.", link: .wifi))
    #expect(Set(AskToJoinHotspots.allCases.map { OnboardingChecks.askToJoin(reading: $0).title }).count == 3)
  }

  struct SleepCase: Sendable, CustomTestStringConvertible {
    let sleepDisabled: Bool?
    let helperOwns: Bool?
    let check: SystemSleepCheck

    var testDescription: String {
      let value = sleepDisabled.map { $0 ? "1" : "0" } ?? "unknown"
      let owner = helperOwns.map { $0 ? "yes" : "no" } ?? "unknown"
      return "SleepDisabled \(value), helper owns \(owner)"
    }
  }

  static let sleepOn = SystemSleepCheck.row(CheckRow(check: .systemSleep, icon: .pass, title: "System sleep is on."))

  static let sleepCases = [
    SleepCase(sleepDisabled: false, helperOwns: false, check: sleepOn),
    SleepCase(sleepDisabled: false, helperOwns: true, check: sleepOn),
    SleepCase(sleepDisabled: false, helperOwns: nil, check: sleepOn),
    SleepCase(sleepDisabled: true, helperOwns: false, check: .sleepDisabledRow),
    SleepCase(sleepDisabled: true, helperOwns: true, check: .nothing),
    SleepCase(sleepDisabled: true, helperOwns: nil, check: .nothing),
    SleepCase(sleepDisabled: nil, helperOwns: false, check: .nothing),
    SleepCase(sleepDisabled: nil, helperOwns: true, check: .nothing),
    SleepCase(sleepDisabled: nil, helperOwns: nil, check: .nothing),
  ]

  @Test(arguments: sleepCases)
  func theSystemSleepCheckClaimsOnlyWhatWasRead(_ item: SleepCase) {
    #expect(
      OnboardingChecks.systemSleep(sleepDisabled: item.sleepDisabled, helperOwns: item.helperOwns) == item.check)
  }

  @Test func theLinksOpenTheLockScreenAndWiFiPanesWithTheUISpecLabels() {
    #expect(CheckRow.Link.lockScreen.label == Self.lockLabel)
    #expect(CheckRow.Link.wifi.label == Self.wifiLabel)
    #expect(CheckRow.Link.lockScreen.url == SystemSettingsLinks.lockScreen)
    #expect(CheckRow.Link.wifi.url == SystemSettingsLinks.wifi)
    #expect(CheckRow.Link.lockScreen.url.absoluteString.hasPrefix(SystemSettingsLinks.scheme))
    #expect(CheckRow.Link.wifi.url.absoluteString.hasPrefix(SystemSettingsLinks.scheme))
    #expect(CheckRow.Link.lockScreen.url != CheckRow.Link.wifi.url)
  }

  @Test func theIconRolesUseTheUISpecSymbols() {
    #expect(CheckRow.Icon.pass.symbol == "checkmark.circle.fill")
    #expect(CheckRow.Icon.warning.symbol == "exclamationmark.triangle.fill")
    #expect(CheckRow.Icon.info.symbol == "info.circle")
  }

  @Test func eachRowIsIdentifiedByItsCheck() {
    #expect(OnboardingChecks.screenLock(.off).id == .screenLock)
    #expect(OnboardingChecks.hotspot(knownNetworks: nil).id == .hotspot)
    #expect(OnboardingChecks.askToJoin.id == .askToJoin)
    #expect(Self.sleepOn == .row(CheckRow(check: .systemSleep, icon: .pass, title: "System sleep is on.")))
  }
}
