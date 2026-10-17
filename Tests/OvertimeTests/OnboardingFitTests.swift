import AppKit
import Foundation
import OvertimeAppSupport
import OvertimeCore
import SwiftUI
import Testing

@testable import Overtime

@MainActor
struct OnboardingFitTests {
  nonisolated static let renderDirectory = ProcessInfo.processInfo.environment["OVERTIME_FIT_RENDER_DIR"]
  nonisolated static let tolerance: CGFloat = 0.5
  static let offscreenOrigin = CGPoint(x: -20_000, y: -20_000)
  static let refusal = Int32(bitPattern: 0xE000_02C2)

  enum Shown: String, CaseIterable, Sendable {
    case welcome
    case loginNotRegistered
    case loginOn
    case loginNeedsApproval
    case loginError
    case notificationsNoPort
    case notificationsNotDetermined
    case notificationsAuthorized
    case notificationsProvisional
    case notificationsDenied
    case hotspotNotChosen
    case hotspotNotChosenUnreadable
    case hotspotChosenNoLocationPort
    case hotspotNotDetermined
    case hotspotDenied
    case hotspotRestricted
    case hotspotAuthorized
    case hotspotNotDeterminedUnreadable
    case hotspotDeniedUnreadable
    case checksPassing
    case checksWarnings
    case checksUnread
    case checksCancelledPrompt
    case checksFailedPrompt
    case selfTestWaiting
    case selfTestRunning
    case selfTestPassed
    case selfTestFailed
    case selfTestSkippedSleepDisabled
    case selfTestSkippedAmphetamine
  }

  struct Prepared {
    let model: OnboardingModel
    let keep: Any
  }

  struct Fit {
    let content: CGFloat
    let viewport: CGFloat

    var fits: Bool {
      content <= viewport + OnboardingFitTests.tolerance
    }

    var verdict: String {
      "content \(content) pt, viewport \(viewport) pt, slack \(viewport - content) pt"
    }
  }

  @Test func theMeasureSeesAScrollViewThatOverflowsAndOneThatFits() throws {
    let size = CGSize(width: 200, height: 100)
    let over = try Self.fit(ScrollView { Color.clear.frame(width: 100, height: 300) }, size: size, name: nil)
    #expect(!over.fits, "\(over.verdict)")
    #expect(over.content >= 300 - Self.tolerance, "\(over.verdict)")
    let under = try Self.fit(ScrollView { Color.clear.frame(width: 100, height: 50) }, size: size, name: nil)
    #expect(under.fits, "\(under.verdict)")
    #expect(under.viewport >= 100 - Self.tolerance, "\(under.verdict)")
  }

  @Test(arguments: Shown.allCases)
  func everyStepStateFitsTheSetupWindow(_ shown: Shown) async throws {
    let prepared = try await prepare(shown)
    let fit = try Self.fit(
      OnboardingWindow(model: prepared.model), size: OnboardingWindow.contentSize, name: shown.rawValue)
    #expect(fit.fits, "\(shown.rawValue): \(fit.verdict)")
    withExtendedLifetime(prepared.keep) {}
  }

  @Test(arguments: OnboardingWindowTests.helperCases)
  func theUnplugProtectionStepFitsInEveryHelperState(_ item: OnboardingWindowTests.HelperCase) throws {
    let fixture = try OnboardingWindowTests.Fixture(helper: item.state)
    fixture.model.begin()
    fixture.walk(to: .unplugProtection)
    try #require(fixture.model.currentStep == .unplugProtection)
    try #require(fixture.helper.uiState == item.shown)
    let name = "unplug-" + item.name.replacingOccurrences(of: " ", with: "-")
    let fit = try Self.fit(OnboardingWindow(model: fixture.model), size: OnboardingWindow.contentSize, name: name)
    #expect(fit.fits, "\(name): \(fit.verdict)")
  }

  private func prepare(_ shown: Shown) async throws -> Prepared {
    switch shown {
    case .welcome:
      let fixture = try OnboardingWindowTests.Fixture()
      fixture.model.begin()
      try #require(fixture.model.currentStep == .welcome)
      return Prepared(model: fixture.model, keep: fixture)
    case .loginNotRegistered, .loginOn, .loginNeedsApproval, .loginError:
      return try login(shown)
    case .notificationsNoPort, .notificationsNotDetermined, .notificationsAuthorized, .notificationsProvisional,
      .notificationsDenied:
      return try await notifications(shown)
    case .hotspotNotChosen, .hotspotNotChosenUnreadable, .hotspotChosenNoLocationPort, .hotspotNotDetermined,
      .hotspotDenied, .hotspotRestricted, .hotspotAuthorized, .hotspotNotDeterminedUnreadable, .hotspotDeniedUnreadable:
      return try await hotspot(shown)
    case .checksPassing, .checksWarnings, .checksUnread, .checksCancelledPrompt, .checksFailedPrompt:
      return try await checks(shown)
    case .selfTestWaiting, .selfTestRunning, .selfTestPassed, .selfTestFailed, .selfTestSkippedSleepDisabled,
      .selfTestSkippedAmphetamine:
      return try selfTest(shown)
    }
  }

  private func login(_ shown: Shown) throws -> Prepared {
    let status: LoginItemStatus =
      switch shown {
      case .loginOn: .enabled
      case .loginNeedsApproval: .requiresApproval
      default: .notRegistered
      }
    let fixture = try OnboardingWindowTests.Fixture(login: status)
    fixture.model.begin()
    fixture.walk(to: .launchAtLogin)
    try #require(fixture.model.currentStep == .launchAtLogin)
    switch shown {
    case .loginError:
      fixture.login.refuse = true
      fixture.panel.setLaunchAtLogin(true)
      try #require(fixture.panel.loginItemCaption?.tone == .error)
    case .loginNeedsApproval:
      try #require(fixture.panel.loginItemCaption?.text == LoginItemCaption.approvalText)
    case .loginOn:
      try #require(fixture.model.stepBody == OnboardingFlow.launchAtLoginOnBody)
    default:
      try #require(fixture.panel.loginItemCaption == nil)
    }
    return Prepared(model: fixture.model, keep: fixture)
  }

  private func notifications(_ shown: Shown) async throws -> Prepared {
    let status: NotificationAuthorization? =
      switch shown {
      case .notificationsNotDetermined: .notDetermined
      case .notificationsAuthorized: .authorized
      case .notificationsProvisional: .provisional
      case .notificationsDenied: .denied
      default: nil
      }
    let fixture = try OnboardingWindowTests.Fixture(notifications: status)
    fixture.model.begin()
    fixture.walk(to: .notifications)
    try #require(fixture.model.currentStep == .notifications)
    if let status {
      try #require(await waitUntil { fixture.model.notificationAuthorization == status })
      try #require(fixture.model.notificationRow == NotificationStatusRow.for(status))
    } else {
      try #require(fixture.model.notificationRow == nil)
    }
    return Prepared(model: fixture.model, keep: fixture)
  }

  private func hotspot(_ shown: Shown) async throws -> Prepared {
    let location: LocationAuthorization? =
      switch shown {
      case .hotspotChosenNoLocationPort: nil
      case .hotspotDenied, .hotspotDeniedUnreadable: .denied
      case .hotspotRestricted: .restricted
      case .hotspotAuthorized: .authorized
      default: .notDetermined
      }
    let chosen = shown != .hotspotNotChosen && shown != .hotspotNotChosenUnreadable
    let unreadable = [.hotspotNotChosenUnreadable, .hotspotNotDeterminedUnreadable, .hotspotDeniedUnreadable].contains(
      shown)
    let fixture = try OnboardingWindowTests.Fixture(
      location: location, hotspot: chosen ? .autoDetect : .none, networks: unreadable ? nil : [])
    let settings = fixture.settings
    fixture.model.begin()
    fixture.walk(to: .location)
    try #require(fixture.model.currentStep == .location)
    try #require(await waitUntil { settings.knownNetworksRead })
    try #require(fixture.model.context.hotspotChosen == chosen)
    try #require(settings.hotspotCaption == (unreadable ? HotspotPicker.unreadableCaption : nil))
    let row = chosen ? location.map { LocationRow.for($0) } : nil
    try #require(fixture.model.locationRow == row)
    return Prepared(model: fixture.model, keep: fixture)
  }

  private func checks(_ shown: Shown) async throws -> Prepared {
    let fixture: OnboardingWindowTests.ChecksFixture =
      switch shown {
      case .checksPassing:
        try OnboardingWindowTests.ChecksFixture(lock: .immediate, networks: ["iPhone"], sleepDisabled: [false])
      case .checksWarnings:
        try OnboardingWindowTests.ChecksFixture(lock: .delayed(seconds: 300), networks: [], sleepDisabled: [true])
      case .checksCancelledPrompt:
        try OnboardingWindowTests.ChecksFixture(
          lock: .unknown, networks: nil, sleepDisabled: [true], outcomes: [.cancelled])
      case .checksFailedPrompt:
        try OnboardingWindowTests.ChecksFixture(
          lock: .unknown, networks: nil, sleepDisabled: [true], outcomes: [.failed("Operation not permitted")])
      default:
        try OnboardingWindowTests.ChecksFixture(lock: .unknown, networks: nil, sleepDisabled: [true])
      }
    try #require(await fixture.reachChecks())
    try #require(fixture.model.currentStep == .checks)
    if shown == .checksPassing {
      try #require(await waitUntil { fixture.model.systemSleep == OnboardingWindowTests.sleepOn })
    } else {
      try #require(await waitUntil { fixture.model.systemSleep == .sleepDisabledRow })
    }
    let lock: ScreenLockStatus =
      switch shown {
      case .checksPassing: .immediate
      case .checksWarnings: .delayed(seconds: 300)
      default: .unknown
      }
    try #require(fixture.model.screenLockRow == OnboardingChecks.screenLock(lock))
    if shown == .checksCancelledPrompt || shown == .checksFailedPrompt {
      await fixture.pane.turnSleepBackOn()
      try #require(fixture.prompt.calls == 1)
      try #require(fixture.pane.clearCaption != nil)
      try #require(fixture.model.systemSleep == .sleepDisabledRow)
    }
    return Prepared(model: fixture.model, keep: fixture)
  }

  private func selfTest(_ shown: Shown) throws -> Prepared {
    let status: SelfTestStatus =
      switch shown {
      case .selfTestRunning: .running
      case .selfTestPassed: .passed
      case .selfTestFailed: .failed(.clamshellRefused(Self.refusal))
      case .selfTestSkippedSleepDisabled: .skipped(.sleepDisabled)
      case .selfTestSkippedAmphetamine: .skipped(.amphetamine)
      default: .notRun
      }
    let fixture = try OnboardingWindowTests.Fixture()
    fixture.panel.apply(OnboardingWindowTests.idle(status, runs: status == .notRun ? 0 : 1, lidClosed: true))
    fixture.model.begin()
    fixture.walk(to: .selfTest)
    try #require(fixture.model.currentStep == .selfTest)
    try #require(!fixture.model.canStartSelfTest)
    try #require(fixture.model.shownSelfTest == (status == .notRun ? .waiting : status))
    try #require((fixture.model.selfTestNote != nil) == (shown == .selfTestFailed))
    return Prepared(model: fixture.model, keep: fixture)
  }

  static func fit(_ view: some View, size: CGSize, name: String?) throws -> Fit {
    let appearance = NSAppearance(named: .darkAqua)
    let hosting = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
    hosting.appearance = appearance
    let window = NSWindow(
      contentRect: CGRect(origin: offscreenOrigin, size: size), styleMask: [.borderless], backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = appearance
    window.contentView = hosting
    hosting.frame = CGRect(origin: .zero, size: size)
    hosting.layoutSubtreeIfNeeded()
    defer {
      window.contentView = nil
      window.close()
    }
    let scrollViews = allViews(hosting).compactMap { $0 as? NSScrollView }
    try #require(scrollViews.count == 1, "found \(scrollViews.count) scroll views")
    let scroll = try #require(scrollViews.first)
    let document = try #require(scroll.documentView)
    if let name, let directory = renderDirectory {
      try write(hosting, name: name, into: URL(fileURLWithPath: directory, isDirectory: true))
    }
    return Fit(content: document.frame.height, viewport: scroll.contentView.bounds.height)
  }

  static func allViews(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap { allViews($0) }
  }

  static func write(_ view: NSView, name: String, into folder: URL) throws {
    let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: rep)
    let data = try #require(rep.representation(using: .png, properties: [:]))
    try data.write(to: folder.appendingPathComponent("\(name).png"))
  }
}
