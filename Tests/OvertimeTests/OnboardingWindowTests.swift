import AppKit
import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import OvertimeHelperClient
import OvertimeHelperCore
import OvertimeSystem
import Testing
import os

import struct SwiftUI.Color

@testable import Overtime

@MainActor
struct OnboardingWindowTests {
  static let startedAt = Date(timeIntervalSince1970: 1_790_505_720)

  final class Counter {
    private(set) var count = 0

    func increment() {
      count += 1
    }
  }

  final class Calls {
    private(set) var names: [String] = []

    func record(_ name: String) {
      names.append(name)
    }
  }

  final class LoggedDecisions {
    private(set) var decisions: [Decision] = []

    func append(_ decision: Decision) {
      decisions.append(decision)
    }
  }

  final class HeldRequestPort: NotificationPort {
    private struct State {
      var requests = 0
      var answer: NotificationAuthorization?
      var waiting: [AsyncStream<Void>.Continuation] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var requests: Int {
      state.withLock { $0.requests }
    }

    func answer(_ status: NotificationAuthorization) {
      let waiting = state.withLock { state -> [AsyncStream<Void>.Continuation] in
        state.answer = status
        defer { state.waiting = [] }
        return state.waiting
      }
      for continuation in waiting {
        continuation.finish()
      }
    }

    func authorization() async -> NotificationAuthorization {
      state.withLock { $0.answer } ?? .notDetermined
    }

    func requestAuthorization() async -> NotificationAuthorization {
      let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
      let answered = state.withLock { state -> Bool in
        state.requests += 1
        if state.answer == nil { state.waiting.append(continuation) }
        return state.answer != nil
      }
      if answered { continuation.finish() }
      for await _ in stream {}
      return await authorization()
    }

    func post(_ intent: NotificationIntent) async -> Bool {
      false
    }
  }

  @MainActor struct Fixture {
    let folder: TestFolder
    let clock = TestClock(wall: OnboardingWindowTests.startedAt)
    let host: FakeEngineHost
    let panel = PanelModel()
    let login: PanelModelTests.FakeLoginItem
    let model: OnboardingModel
    let closes = Counter()
    let helperSource: HelperPaneTests.FakeHelperSource
    let helper: HelperPaneModel
    let logged = LoggedDecisions()
    let port: SettingsWindowTests.FakeNotificationPort?
    let location: SettingsWindowTests.FakeLocationStatus?
    let locationsMade = Counter()
    let opened = SettingsWindowTests.OpenedURLs()
    let settings: SettingsModel

    init(
      login status: LoginItemStatus = .notRegistered, bound: Bool = true,
      notifications: NotificationAuthorization? = nil, afterRequest: NotificationAuthorization? = nil,
      location locationStatus: LocationAuthorization? = nil, helper state: HelperMonitorState = HelperMonitorState(),
      structHost: Bool = false, hotspot: HotspotChoice = .none, networks: [String]? = []
    ) throws {
      folder = try TestFolder()
      host = FakeEngineHost(clock: clock)
      panel.amphetamineLocator = .absent
      if bound {
        if structHost {
          panel.bind(to: StructEngineHost(fake: host))
        } else {
          panel.bind(to: host)
        }
      }
      login = PanelModelTests.FakeLoginItem(status: status)
      panel.attachLoginItem(login)
      let settingsFile = folder.url.appendingPathComponent("settings.json")
      if !hotspot.isNone {
        try SettingsStore.save(hotspot.apply(to: Settings()), to: settingsFile)
      }
      model = OnboardingModel(panel: panel, preferencesFile: folder.url.appendingPathComponent("preferences.json"))
      let settings = SettingsModel(
        settingsFile: settingsFile, host: host, wifi: SettingsWindowTests.FakeWiFi(networks: networks), panel: panel,
        preferencesFile: model.preferencesFile)
      self.settings = settings
      model.makeSettings = { settings }
      let notifier = notifications.map { SettingsWindowTests.FakeNotificationPort($0, afterRequest: afterRequest) }
      port = notifier
      let reader = locationStatus.map { SettingsWindowTests.FakeLocationStatus($0) }
      location = reader
      let closes = closes
      model.onClose = { closes.increment() }
      let helperSource = HelperPaneTests.FakeHelperSource(state)
      let helper = HelperPaneModel(panel: panel, source: helperSource)
      helper.pause = { _ in try? await Task.sleep(for: .milliseconds(20)) }
      helper.apply(state)
      model.helper = helper
      self.helperSource = helperSource
      self.helper = helper
      let logged = logged
      model.logError = { logged.append($0) }
      model.notifications = notifier
      if let reader {
        let made = locationsMade
        model.makeLocation = {
          made.increment()
          return reader
        }
      }
      let opened = opened
      model.openURL = { opened.append($0) }
    }

    var stored: AppPreferences {
      AppPreferencesStore.read(at: model.preferencesFile).preferences
    }

    func walk(to step: OnboardingStep) {
      for _ in model.steps where model.currentStep != step {
        model.continueStep()
      }
    }

    func requested(_ count: Int) async -> Bool {
      await waitUntil { host.selfTestRequests == count && !model.requestingSelfTest }
    }

    func pollsStopped() async -> Bool {
      try? await Task.sleep(for: .milliseconds(80))
      let count = helperSource.refreshes
      try? await Task.sleep(for: .milliseconds(150))
      return helperSource.refreshes == count
    }
  }

  static func idle(
    _ status: SelfTestStatus = .notRun, runs: UInt64 = 0, lidClosed: Bool? = false, wanted: Bool? = false,
    osBuild: String? = nil
  ) -> EngineSnapshot {
    EngineSnapshot(
      busy: wanted == true, wanted: wanted, reason: wanted == true ? "busy" : "idle", lidClosed: lidClosed,
      selfTest: status, selfTestRuns: runs, osBuild: osBuild)
  }

  @Test func aFirstLaunchRegistersTheLoginItemOnceAndThenOpensOnboarding() throws {
    let fixture = try Fixture()
    let recordURL = fixture.folder.url.appendingPathComponent("login-item.json")
    let preferencesFile = fixture.model.preferencesFile
    let events = Calls()
    let register = {
      if FirstRunLogin.apply(service: fixture.login, recordURL: recordURL, now: Self.startedAt) {
        events.record("register")
      }
    }
    let presenter = OnboardingPresenter(model: fixture.model) { _ in events.record("open") }
    #expect(
      AppDelegate.openOnboardingAtLaunch(presenter, preferencesFile: preferencesFile, registerLoginItem: register))
    #expect(events.names == ["register", "open"])
    #expect(fixture.login.calls == ["register"])
    #expect(fixture.model.isActive)
    #expect(fixture.model.currentStep == .welcome)
    #expect(fixture.model.steps.count == 7)
    let second = OnboardingModel(panel: fixture.panel, preferencesFile: preferencesFile)
    let reopened = OnboardingPresenter(model: second) { _ in events.record("open") }
    #expect(
      AppDelegate.openOnboardingAtLaunch(reopened, preferencesFile: preferencesFile, registerLoginItem: register))
    #expect(events.names == ["register", "open", "open"])
    #expect(fixture.login.calls == ["register"])
    #expect(second.isActive)
    let completed = OnboardingRecord(version: 1, outcome: .completed, steps: [:], at: Self.startedAt)
    try AppPreferencesStore.update(at: preferencesFile) { $0.onboarding = completed }
    let third = OnboardingPresenter(model: OnboardingModel(panel: fixture.panel, preferencesFile: preferencesFile)) {
      _ in events.record("open")
    }
    #expect(
      !AppDelegate.openOnboardingAtLaunch(third, preferencesFile: preferencesFile, registerLoginItem: register))
    #expect(events.names == ["register", "open", "open"])
    #expect(fixture.login.calls == ["register"])
    #expect(!third.model.isActive)
  }

  @Test func withNoRecordTheOpenRuleAsksToOpenOnboardingOnceAfterTheHostStarts() throws {
    let fixture = try Fixture()
    let presented = Counter()
    let presenter = OnboardingPresenter(model: fixture.model) { _ in presented.increment() }
    #expect(!presenter.armed)
    #expect(!presenter.openIfArmed())
    #expect(presented.count == 0)
    AppDelegate.armOnboarding(presenter, preferencesFile: fixture.model.preferencesFile)
    #expect(presenter.armed)
    #expect(presented.count == 0)
    #expect(!fixture.model.isActive)
    #expect(presenter.openIfArmed())
    #expect(presented.count == 1)
    #expect(fixture.model.isActive)
    #expect(fixture.model.currentStep == .welcome)
    #expect(fixture.model.steps.count == 7)
    #expect(!presenter.armed)
    #expect(!presenter.openIfArmed())
    #expect(presented.count == 1)
    #expect(presenter.controller.window == nil)
    #expect(fixture.host.selfTestRequests == 0)
    #expect(fixture.login.calls.isEmpty)
    #expect(fixture.stored.onboarding == nil)
  }

  @Test func theWindowIsTitledSetUpOvertimeAt560By440AndCloses() throws {
    let fixture = try Fixture()
    let controller = OnboardingWindow.controller(model: fixture.model)
    #expect(controller.title == "Set Up Overtime")
    #expect(controller.contentSize == CGSize(width: 560, height: 440))
    #expect(AuxiliaryWindowController.styleMask == [.titled, .closable])
    #expect(controller.allowsClose)
    fixture.model.inFlight = .authorization
    #expect(controller.allowsClose)
    #expect(controller.window == nil)
  }

  @Test func theCloseShortcutClosesTheWindow() throws {
    let fixture = try Fixture()
    fixture.model.begin()
    fixture.model.close()
    #expect(fixture.closes.count == 1)
  }

  @Test func movingThroughTheStepsAsksForOneSelfTestWhenTheLastStepAppears() async throws {
    let fixture = try Fixture()
    fixture.panel.apply(Self.idle())
    fixture.model.begin()
    var seen: [OnboardingStep] = [fixture.model.currentStep]
    var labels = [fixture.model.progressLabel]
    for _ in 0..<5 {
      fixture.model.performDefault()
      seen.append(fixture.model.currentStep)
      labels.append(fixture.model.progressLabel)
      #expect(fixture.host.selfTestRequests == 0)
      #expect(!fixture.model.canStartSelfTest)
    }
    #expect(seen == [.welcome, .launchAtLogin, .notifications, .location, .checks, .unplugProtection])
    #expect(labels == ["Step 1 of 7", "Step 2 of 7", "Step 3 of 7", "Step 4 of 7", "Step 5 of 7", "Step 6 of 7"])
    fixture.model.performDefault()
    #expect(fixture.model.currentStep == .selfTest)
    #expect(fixture.model.progressLabel == "Step 7 of 7")
    #expect(fixture.model.progressAccessibilityLabel == "Step 7 of 7, Setup complete")
    #expect(await fixture.requested(1))
    #expect(fixture.model.startSelfTestIfDue() == nil)
    #expect(!fixture.model.canStartSelfTest)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(fixture.host.selfTestRequests == 1)
    #expect(fixture.host.requests.isEmpty)
    #expect(fixture.login.calls.isEmpty)
    #expect(fixture.helperSource.actions.isEmpty)
  }

  @Test func theLoginStepShowsTheServiceStatusAndOnlyTheSwitchRegisters() throws {
    let fixture = try Fixture(login: .notRegistered)
    fixture.model.begin()
    fixture.login.status = .requiresApproval
    fixture.model.performDefault()
    #expect(fixture.model.currentStep == .launchAtLogin)
    #expect(fixture.model.context.loginItem == .requiresApproval)
    #expect(fixture.panel.launchAtLogin)
    #expect(fixture.panel.loginItemCaption?.text == LoginItemCaption.approvalText)
    #expect(fixture.login.calls.isEmpty)
    #expect(!fixture.model.showsSkip)
    #expect(fixture.model.defaultButton == OnboardingButton(title: "Continue", action: .advance))
    fixture.login.status = .notRegistered
    fixture.panel.setLaunchAtLogin(true)
    #expect(fixture.login.calls == ["register"])
    #expect(fixture.model.context.loginItem == .enabled)
    fixture.model.performDefault()
    #expect(fixture.model.results[.launchAtLogin] == .done)
    #expect(fixture.login.calls == ["register"])
  }

  static let loginBodyWhenOn =
    "Overtime needs to be running to keep the Mac awake. Launch at login is already on, so it starts every time you log in. You can turn it off here, or later in Settings > General."

  @Test func theLoginStepBodyFollowsTheLoginItem() throws {
    let fixture = try Fixture(login: .enabled)
    fixture.model.begin()
    fixture.model.performDefault()
    #expect(fixture.model.currentStep == .launchAtLogin)
    #expect(fixture.model.context.loginItem == .enabled)
    #expect(fixture.model.stepBody == Self.loginBodyWhenOn)
    fixture.panel.setLaunchAtLogin(false)
    #expect(fixture.model.context.loginItem != .enabled)
    #expect(fixture.model.stepBody == OnboardingStep.launchAtLogin.body)
    fixture.panel.setLaunchAtLogin(true)
    #expect(fixture.model.context.loginItem == .enabled)
    #expect(fixture.model.stepBody == Self.loginBodyWhenOn)
  }

  @Test func reachingEveryStepRequestsNothingRegistersNothingAndRunsNoStepAction() async throws {
    let fixture = try Fixture(notifications: .notDetermined, location: .notDetermined)
    let port = try #require(fixture.port)
    let location = try #require(fixture.location)
    fixture.panel.apply(Self.idle(lidClosed: true))
    fixture.model.begin()
    fixture.model.performDefault()
    fixture.model.performDefault()
    #expect(fixture.model.currentStep == .notifications)
    #expect(await waitUntil { fixture.model.notificationAuthorization == .notDetermined })
    fixture.model.skipStep()
    #expect(fixture.model.currentStep == .location)
    #expect(fixture.model.locationStatus == .notDetermined)
    fixture.model.performDefault()
    fixture.model.performDefault()
    fixture.model.performDefault()
    #expect(fixture.model.currentStep == .selfTest)
    #expect(
      fixture.model.results == [
        .welcome: .done, .launchAtLogin: .done, .notifications: .skipped, .location: .done, .checks: .done,
        .unplugProtection: .done,
      ])
    #expect(port.requests == 0)
    #expect(port.posted.isEmpty)
    #expect(location.requests == 0)
    #expect(fixture.opened.urls.isEmpty)
    #expect(fixture.model.inFlight == nil)
    #expect(fixture.login.calls.isEmpty)
    #expect(fixture.helperSource.actions.isEmpty)
    #expect(fixture.host.selfTestRequests == 0)
    #expect(fixture.host.requests.isEmpty)
    #expect(fixture.host.appliedSettings.isEmpty)
    #expect(fixture.stored.onboarding == nil)
  }

  @Test func theLocationAndHelperStatesReachTheirStepsButtons() async throws {
    let fixture = try Fixture(location: .notDetermined)
    fixture.model.begin()
    fixture.walk(to: .notifications)
    #expect(fixture.model.context.location == nil)
    fixture.model.continueStep()
    #expect(fixture.model.currentStep == .location)
    #expect(fixture.model.defaultButton == Self.advance)
    #expect(!fixture.model.showsSkip)
    await fixture.settings.selectHotspot(.autoDetect)
    #expect(fixture.model.defaultButton == OnboardingButton(title: "Allow Location Access", action: .allowLocation))
    #expect(fixture.model.showsSkip)
    fixture.model.skipStep()
    fixture.model.performDefault()
    #expect(fixture.model.currentStep == .unplugProtection)
    #expect(fixture.model.defaultButton == OnboardingButton(title: "Continue", action: .advance))
    #expect(fixture.model.context.helperInstalled == nil)
    fixture.helperSource.set(HelperMonitorState(installer: .notRegistered))
    fixture.helper.apply(HelperMonitorState(installer: .notRegistered))
    #expect(fixture.model.context.helperInstalled == false)
    #expect(fixture.model.defaultButton == Self.advance)
    #expect(!fixture.model.showsSkip)
    #expect(fixture.model.helperRowActions == [.install])
    let helper = fixture.helper
    let install = Task { await helper.perform(.install) }
    await install.value
    #expect(fixture.helperSource.actions == ["install"])
    #expect(fixture.model.defaultButton == Self.advance)
    #expect(!fixture.model.showsSkip)
    #expect(fixture.model.currentStep == .unplugProtection)
    #expect(await waitUntil { fixture.model.backEnabled })
    fixture.model.begin()
    #expect(fixture.model.results.isEmpty)
    #expect(fixture.model.context.location == .notDetermined)
    #expect(fixture.model.context.helperInstalled == false)
    #expect(fixture.helperSource.actions == ["install"])
  }

  @Test func onlyTheLastStepFinishesAndItNeverContinues() throws {
    let fixture = try Fixture()
    fixture.panel.apply(Self.idle(lidClosed: true))
    fixture.model.begin()
    fixture.model.finish()
    #expect(fixture.model.isActive)
    #expect(fixture.stored.onboarding == nil)
    #expect(fixture.closes.count == 0)
    fixture.walk(to: .checks)
    fixture.model.finish()
    #expect(fixture.model.isActive)
    #expect(fixture.stored.onboarding == nil)
    fixture.walk(to: .selfTest)
    fixture.model.continueStep()
    fixture.model.skipStep()
    #expect(fixture.model.currentStep == .selfTest)
    #expect(fixture.model.index == 6)
    #expect(fixture.model.results[.selfTest] == nil)
    fixture.model.finish()
    #expect(fixture.stored.onboarding?.outcome == .completed)
    #expect(fixture.closes.count == 1)
  }

  @Test func afterTheWindowIsClosedNoStepActionAndNoSelfTestStarts() async throws {
    let fixture = try Fixture()
    fixture.panel.apply(Self.idle(lidClosed: true))
    fixture.model.begin()
    fixture.model.performDefault()
    #expect(fixture.model.currentStep == .launchAtLogin)
    fixture.model.dismissed()
    fixture.model.performDefault()
    fixture.model.skipStep()
    fixture.model.back()
    fixture.model.continueStep()
    #expect(fixture.helperSource.actions.isEmpty)
    #expect(fixture.login.calls.isEmpty)
    #expect(fixture.model.currentStep == .launchAtLogin)
    #expect(fixture.model.results == [.welcome: .done])
    #expect(fixture.stored.onboarding?.outcome == .dismissed)
    fixture.model.begin()
    fixture.walk(to: .selfTest)
    fixture.model.dismissed()
    fixture.panel.apply(Self.idle())
    #expect(!fixture.model.canStartSelfTest)
    #expect(fixture.model.startSelfTestIfDue() == nil)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(fixture.host.selfTestRequests == 0)
  }

  static let runsOnItsOwn = SelfTestRow(
    icon: .symbol("info.circle"), tone: .secondary, title: "Runs on its own",
    caption:
      "It runs each time Overtime starts, once the lid is open and Claude isn't working. The result appears under Self-test in Settings > Diagnostics."
  )
  static let failedNote = "You can still finish setup. Overtime shows an error in the menu bar until the check passes."

  @Test func theStepReloadsTheStoredRecordAndSaysTheTestRunsOnItsOwn() throws {
    let fixture = try Fixture()
    let record = SelfTestRecord(
      outcome: .passed, reason: nil, at: Self.startedAt.addingTimeInterval(-86_400), osBuild: "99Z998",
      osVersion: "99.8")
    fixture.panel.apply(Self.idle(.waiting, lidClosed: true, osBuild: "99Z999"))
    fixture.model.begin()
    #expect(fixture.model.selfTestRecord == nil)
    try AppPreferencesStore.update(at: fixture.model.preferencesFile) { $0.selfTest = record }
    fixture.walk(to: .selfTest)
    #expect(fixture.model.selfTestRecord == record)
    #expect(fixture.model.shownSelfTest == .waiting)
    #expect(fixture.model.selfTestRow == Self.runsOnItsOwn)
  }

  @Test func theCloseGateAsksBeforeClosingAndReportsAClosedWindow() {
    let asked = Counter()
    let closed = Counter()
    var allow = false
    let ask: () -> Bool = {
      asked.increment()
      return allow
    }
    let gate = CloseGate(shouldClose: ask, didClose: { closed.increment() })
    #expect(closed.count == 0)
    gate.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    #expect(closed.count == 1)
    #expect(asked.count == 0)
    let plain = AuxiliaryWindowController(
      title: "Plain", contentSize: .zero, makeContent: { fatalError("never shown") })
    #expect(plain.allowsClose)
    plain.didClose()
    let gated = AuxiliaryWindowController(
      title: "Gated", contentSize: .zero, shouldClose: ask, didClose: { closed.increment() },
      makeContent: { fatalError("never shown") })
    #expect(!gated.allowsClose)
    #expect(asked.count == 1)
    allow = true
    #expect(gated.allowsClose)
    gated.didClose()
    #expect(closed.count == 2)
    #expect(gated.window == nil)
  }

  @Test func backReturnsToThePreviousStepWithItsStateIntactAndIsOffWhileInFlight() async throws {
    let fixture = try Fixture(notifications: .notDetermined)
    fixture.model.begin()
    fixture.model.back()
    #expect(fixture.model.currentStep == .welcome)
    fixture.model.performDefault()
    fixture.model.performDefault()
    #expect(fixture.model.currentStep == .notifications)
    #expect(await waitUntil { fixture.model.notificationAuthorization == .notDetermined })
    fixture.model.skipStep()
    #expect(fixture.model.currentStep == .location)
    fixture.model.inFlight = .authorization
    #expect(!fixture.model.backEnabled)
    fixture.model.back()
    #expect(fixture.model.currentStep == .location)
    fixture.model.inFlight = nil
    #expect(fixture.model.backEnabled)
    fixture.model.back()
    #expect(fixture.model.currentStep == .notifications)
    fixture.model.back()
    #expect(fixture.model.currentStep == .launchAtLogin)
    #expect(fixture.model.results == [.welcome: .done, .launchAtLogin: .done, .notifications: .skipped])
    #expect(fixture.model.defaultButton == OnboardingButton(title: "Continue", action: .advance))
    fixture.model.performDefault()
    #expect(fixture.model.results[.launchAtLogin] == .done)
    #expect(fixture.model.currentStep == .notifications)
  }

  @Test func finishSetupWritesTheCompletedRecordAndKeepsTheOtherPreferences() async throws {
    let fixture = try Fixture()
    var before = AppPreferences()
    before.notifications["batteryFloor"] = false
    before.forceReminderHours = 7
    before.selfTest = SelfTestRecord(
      outcome: .passed, reason: nil, at: Self.startedAt.addingTimeInterval(-86_400), osBuild: "99Z999",
      osVersion: "99.9")
    try AppPreferencesStore.write(before, to: fixture.model.preferencesFile)
    fixture.panel.apply(Self.idle(.passed, runs: 4, osBuild: "99Z999"))
    fixture.model.begin()
    fixture.walk(to: .selfTest)
    #expect(await fixture.requested(1))
    fixture.panel.apply(Self.idle(.passed, runs: 5, osBuild: "99Z999"))
    #expect(fixture.model.shownSelfTest == .passed)
    #expect(fixture.model.defaultButton == OnboardingButton(title: "Finish Setup", action: .finish))
    #expect(fixture.stored.onboarding == nil)
    fixture.clock.advance(seconds: 90)
    fixture.model.performDefault()
    var expected = before
    expected.onboarding = OnboardingRecord(
      version: 1, outcome: .completed,
      steps: [
        "welcome": "done", "launchAtLogin": "done", "notifications": "done", "location": "done", "checks": "done",
        "unplugProtection": "done", "selfTest": "done",
      ], at: Self.startedAt.addingTimeInterval(90))
    #expect(fixture.stored == expected)
    #expect(fixture.closes.count == 1)
    #expect(!fixture.model.isActive)
    #expect(fixture.logged.decisions.isEmpty)
    fixture.clock.advance(seconds: 60)
    fixture.model.dismissed()
    fixture.model.performDefault()
    fixture.model.finish()
    #expect(fixture.stored == expected)
    #expect(fixture.closes.count == 1)
    #expect(
      OnboardingFlow.recordState(at: fixture.model.preferencesFile) == .recorded(try #require(expected.onboarding)))
  }

  @Test func finishSetupAsksForTheMenuBarPanelOnce() async throws {
    let fixture = try Fixture()
    let calls = Calls()
    fixture.model.onClose = { calls.record("close") }
    fixture.model.onFinish = { calls.record("finish hook") }
    fixture.panel.apply(Self.idle())
    fixture.model.begin()
    #expect(fixture.model.currentStep == .welcome)
    fixture.model.finish()
    #expect(calls.names == [])
    fixture.model.close()
    #expect(calls.names == ["close"])
    fixture.walk(to: .selfTest)
    #expect(await fixture.requested(1))
    fixture.panel.apply(Self.idle(.passed, runs: 1))
    #expect(fixture.model.defaultButton == OnboardingButton(title: OnboardingFlow.finishLabel, action: .finish))
    fixture.model.performDefault()
    #expect(calls.names == ["close", "close", "finish hook"])
    #expect(!fixture.model.isActive)
    fixture.model.dismissed()
    fixture.model.performDefault()
    fixture.model.finish()
    #expect(calls.names == ["close", "close", "finish hook"])
    fixture.model.close()
    #expect(calls.names == ["close", "close", "finish hook", "close"])

    let dismissed = try Fixture()
    let dismissedCalls = Calls()
    dismissed.model.onClose = { dismissedCalls.record("close") }
    dismissed.model.onFinish = { dismissedCalls.record("finish hook") }
    dismissed.panel.apply(Self.idle(.passed, runs: 1))
    dismissed.model.begin()
    dismissed.walk(to: .selfTest)
    dismissed.model.dismissed()
    #expect(!dismissed.model.isActive)
    dismissed.model.finish()
    #expect(dismissedCalls.names == [])
  }

  @Test func finishSetupFinishesWhileTheTestRuns() async throws {
    let fixture = try Fixture()
    fixture.panel.apply(Self.idle())
    fixture.model.begin()
    fixture.walk(to: .selfTest)
    #expect(await fixture.requested(1))
    fixture.panel.apply(Self.idle(.running))
    #expect(fixture.model.shownSelfTest == .running)
    #expect(fixture.model.selfTestRow == SelfTestRow(icon: .progress, tone: .secondary, title: "Running…"))
    #expect(fixture.model.defaultButton == OnboardingButton(title: "Finish Setup", action: .finish))
    #expect(!fixture.model.backEnabled)
    fixture.model.back()
    #expect(fixture.model.currentStep == .selfTest)
    fixture.model.performDefault()
    #expect(fixture.stored.onboarding?.outcome == .completed)
    #expect(fixture.stored.onboarding?.steps["selfTest"] == "done")
    #expect(fixture.closes.count == 1)
    #expect(!fixture.model.isActive)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(fixture.host.selfTestRequests == 1)
  }

  @Test func aFailedSelfTestShowsItsReasonAndSaysSetupCanStillBeFinished() async throws {
    let fixture = try Fixture()
    fixture.panel.apply(Self.idle())
    fixture.model.begin()
    fixture.walk(to: .selfTest)
    #expect(await fixture.requested(1))
    let refusal = Int32(bitPattern: 0xE000_02C2)
    fixture.panel.apply(
      EngineSnapshot(
        wanted: false, reason: "idle", lidClosed: false, selfTest: .failed(.clamshellRefused(refusal)),
        selfTestErrorActive: true, selfTestFailures: 1, selfTestRuns: 1))
    #expect(
      fixture.model.selfTestRow
        == SelfTestRow(
          icon: .symbol("xmark.circle.fill"), tone: .error, title: "Failed",
          caption: "macOS refused the lid-close control (error 0xE00002C2)."))
    #expect(fixture.model.selfTestNote == Self.failedNote)
    #expect(fixture.model.defaultButton == OnboardingButton(title: "Finish Setup", action: .finish))
    fixture.model.performDefault()
    #expect(fixture.stored.onboarding?.outcome == .completed)
    #expect(fixture.stored.onboarding?.steps["selfTest"] == "done")
  }

  @Test func aSkippedSelfTestShowsItsReasonAndNoFinishCaption() async throws {
    let fixture = try Fixture()
    fixture.panel.apply(Self.idle(.skipped(.sleepDisabled)))
    fixture.model.begin()
    fixture.walk(to: .selfTest)
    #expect(fixture.model.selfTestRow.title == "Running…")
    #expect(await fixture.requested(1))
    #expect(
      fixture.model.selfTestRow
        == SelfTestRow(
          icon: .symbol("minus.circle.fill"), tone: .warning, title: "Skipped",
          caption: "Sleep is turned off system-wide (SleepDisabled), so Overtime didn't touch the lid-close control."))
    #expect(fixture.model.selfTestNote == nil)
    #expect(fixture.model.defaultButton.enabled)
  }

  @Test func whenTheTestHasNotRunTheStepSaysItRunsOnItsOwnAndAsksOnlyOnceItCan() async throws {
    let fixture = try Fixture()
    fixture.panel.apply(Self.idle(.notRun, lidClosed: true))
    fixture.model.begin()
    fixture.walk(to: .selfTest)
    #expect(!fixture.model.canStartSelfTest)
    #expect(fixture.model.startSelfTestIfDue() == nil)
    #expect(fixture.model.selfTestRow == Self.runsOnItsOwn)
    #expect(fixture.model.defaultButton == OnboardingButton(title: "Finish Setup", action: .finish))
    #expect(fixture.model.backEnabled)
    fixture.panel.apply(Self.idle(.notRun, wanted: true))
    #expect(!fixture.model.canStartSelfTest)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(fixture.host.selfTestRequests == 0)
    fixture.panel.apply(Self.idle(.notRun))
    #expect(fixture.model.canStartSelfTest)
    #expect(fixture.model.selfTestRow.title == "Runs on its own")
    #expect(fixture.model.startSelfTestIfDue() != nil)
    #expect(fixture.model.selfTestRow.title == "Running…")
    #expect(await fixture.requested(1))
    #expect(fixture.model.selfTestRow.title == "Runs on its own")
    fixture.panel.apply(Self.idle(.passed, runs: 1))
    #expect(fixture.model.selfTestRow.title == "Passed")
    #expect(fixture.host.selfTestRequests == 1)
  }

  @Test func aResultFromEarlierInThisLaunchShowsOnTheLastStep() async throws {
    let fixture = try Fixture()
    let record = SelfTestRecord(
      outcome: .passed, reason: nil, at: Self.startedAt.addingTimeInterval(-600), osBuild: "99Z999",
      osVersion: "99.9")
    try AppPreferencesStore.update(at: fixture.model.preferencesFile) { $0.selfTest = record }
    fixture.panel.apply(Self.idle(.passed, runs: 2, lidClosed: true))
    fixture.model.begin()
    fixture.walk(to: .selfTest)
    #expect(fixture.model.selfTestRow == SelfTestPresentation.row(status: .passed, record: record, currentBuild: nil))
    #expect(fixture.model.selfTestNote == nil)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(fixture.host.selfTestRequests == 0)
    fixture.panel.apply(Self.idle(.failed(.timedOut), runs: 3, lidClosed: true))
    #expect(
      fixture.model.selfTestRow
        == SelfTestPresentation.row(status: .failed(.timedOut), record: record, currentBuild: nil))
    #expect(fixture.model.selfTestRow.title == "Failed")
    #expect(fixture.model.selfTestNote == Self.failedNote)
  }

  @Test func goingBackAndForwardAsksForNoSecondSelfTest() async throws {
    let fixture = try Fixture()
    fixture.panel.apply(Self.idle())
    fixture.model.begin()
    fixture.walk(to: .selfTest)
    #expect(await fixture.requested(1))
    fixture.panel.apply(Self.idle(.passed, runs: 1))
    fixture.model.back()
    #expect(fixture.model.currentStep == .unplugProtection)
    #expect(fixture.model.context.selfTest == .notRun)
    fixture.model.performDefault()
    #expect(fixture.model.currentStep == .selfTest)
    #expect(fixture.model.selfTestRow.title == "Passed")
    try? await Task.sleep(for: .milliseconds(50))
    #expect(fixture.host.selfTestRequests == 1)
  }

  @Test func aRestartedEngineIsAskedForItsOwnSelfTestWhenTheStepIsShownAgain() async throws {
    let fixture = try Fixture()
    fixture.panel.apply(Self.idle())
    fixture.model.begin()
    fixture.walk(to: .selfTest)
    #expect(await fixture.requested(1))
    fixture.panel.apply(Self.idle(.passed, runs: 1))
    fixture.model.back()
    let restarted = FakeEngineHost(clock: fixture.clock)
    fixture.panel.rebind(to: restarted)
    fixture.panel.apply(Self.idle())
    fixture.model.performDefault()
    #expect(fixture.model.currentStep == .selfTest)
    #expect(
      await waitUntil { restarted.selfTestRequests == 1 && !fixture.model.requestingSelfTest },
      "A-WR-03: the onboarding bookkeeping belongs to the engine that ran the test")
    #expect(fixture.host.selfTestRequests == 1)
    fixture.panel.apply(Self.idle(.passed, runs: 1))
    #expect(fixture.model.selfTestRow.title == "Passed")
  }

  @Test func onAStructHostGoingBackAndForwardAsksForNoSecondSelfTest() async throws {
    let fixture = try Fixture(structHost: true)
    fixture.panel.apply(Self.idle())
    fixture.model.begin()
    fixture.walk(to: .selfTest)
    #expect(await fixture.requested(1))
    fixture.panel.apply(Self.idle(.passed, runs: 1))
    for _ in 0..<3 {
      fixture.model.back()
      #expect(fixture.model.currentStep == .unplugProtection)
      fixture.model.performDefault()
      #expect(fixture.model.currentStep == .selfTest)
      #expect(fixture.model.selfTestRow.title == "Passed")
      #expect(!fixture.model.requestingSelfTest, "R2-WR-02: the same engine is not asked again")
    }
    #expect(fixture.host.selfTestRequests == 1)
  }

  @Test func onAStructHostARestartedEngineIsAskedForItsOwnSelfTest() async throws {
    let fixture = try Fixture(structHost: true)
    fixture.panel.apply(Self.idle())
    fixture.model.begin()
    fixture.walk(to: .selfTest)
    #expect(await fixture.requested(1))
    fixture.panel.apply(Self.idle(.passed, runs: 1))
    fixture.model.back()
    let restarted = FakeEngineHost(clock: fixture.clock)
    fixture.panel.rebind(to: StructEngineHost(fake: restarted))
    fixture.panel.apply(Self.idle())
    fixture.model.performDefault()
    #expect(fixture.model.currentStep == .selfTest)
    #expect(
      await waitUntil { restarted.selfTestRequests == 1 && !fixture.model.requestingSelfTest },
      "R2-WR-02: the restarted engine is told apart from the first one")
    #expect(fixture.host.selfTestRequests == 1)
  }

  @Test func aTestRunningOnAnotherStepNeitherBlocksBackNorShowsAsInFlight() throws {
    let fixture = try Fixture()
    fixture.model.begin()
    fixture.walk(to: .location)
    fixture.panel.apply(Self.idle(.passed, runs: 3))
    #expect(fixture.model.shownSelfTest == .passed)
    #expect(fixture.model.selfTestRow.title == "Passed")
    fixture.panel.apply(Self.idle(.running, runs: 3))
    #expect(fixture.model.backEnabled)
    #expect(!fixture.model.context.actionInFlight)
    fixture.model.back()
    #expect(fixture.model.currentStep == .notifications)
  }

  @Test func withoutAnEngineTheLastStepWaitsAndSetupCanStillBeFinished() throws {
    let fixture = try Fixture(bound: false)
    fixture.model.begin()
    fixture.walk(to: .selfTest)
    #expect(!fixture.model.canStartSelfTest)
    #expect(fixture.model.startSelfTestIfDue() == nil)
    #expect(fixture.model.selfTestRow.title == "Runs on its own")
    #expect(fixture.model.defaultButton.enabled)
    fixture.model.performDefault()
    #expect(fixture.stored.onboarding?.outcome == .completed)
    #expect(fixture.host.selfTestRequests == 0)
  }

  @Test func theStoredSelfTestRecordGivesTheLastRunLine() async throws {
    let fixture = try Fixture()
    fixture.panel.apply(Self.idle(osBuild: "99Z999"))
    fixture.model.begin()
    fixture.walk(to: .selfTest)
    #expect(await fixture.requested(1))
    fixture.panel.apply(Self.idle(.passed, runs: 1, osBuild: "99Z999"))
    #expect(
      fixture.model.selfTestRow == SelfTestRow(icon: .symbol("checkmark.circle.fill"), tone: .success, title: "Passed"))
    let record = SelfTestRecord(outcome: .passed, reason: nil, at: Self.startedAt, osBuild: "99Z999", osVersion: "99.9")
    try AppPreferencesStore.update(at: fixture.model.preferencesFile) { $0.selfTest = record }
    fixture.model.reloadSelfTestRecord()
    #expect(fixture.model.selfTestRow.caption == SelfTestPresentation.lastRun(record))
  }

  @Test func aRecordThatCannotBeWrittenIsLoggedAndTheWindowStillCloses() throws {
    let folder = try TestFolder()
    let locked = folder.url.appendingPathComponent("locked", isDirectory: true)
    try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path(percentEncoded: false))
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: locked.path(percentEncoded: false))
    }
    let model = OnboardingModel(panel: PanelModel(), preferencesFile: locked.appendingPathComponent("preferences.json"))
    let logged = LoggedDecisions()
    model.logError = { logged.append($0) }
    let closes = Counter()
    model.onClose = { closes.increment() }
    model.begin()
    for _ in model.steps {
      model.performDefault()
    }
    #expect(logged.decisions == [Decision(keyword: .error, verb: "onboarding record write failed")])
    #expect(closes.count == 1)
    #expect(!model.isActive)
    #expect(OnboardingFlow.recordState(at: model.preferencesFile) == .missing)
  }

  @Test func theStepAndWelcomeSymbolsAreInThePhaseList() {
    let listed = Set(SymbolAvailabilityTests.phaseThreeSymbols)
    #expect(Set(OnboardingStep.allCases.map(\.symbol)).isSubset(of: listed))
    #expect(Set(OnboardingFlow.welcomeRows.map(\.symbol)).isSubset(of: listed))
  }

  @MainActor @Test func theLastStepShowsWhereOvertimeLivesWithASymbolThatFitsTheIconColumn() throws {
    let width = try #require(SymbolAvailabilityTests.bodySizeWidth(of: OnboardingFlow.finishRow.symbol))
    #expect(width > 0)
    #expect(width <= StatusRowLayout.iconWidth)
  }

  @Test func theAllowNotificationsLabelIsTheGeneralPanesLabel() {
    #expect(OnboardingFlow.allowNotificationsLabel == NotificationStatusRow.allowLabel)
  }

  @Test func theDelegateBuildsNoOnboardingInTheTestHost() throws {
    let delegate = try #require(AppDelegate.shared)
    #expect(delegate.onboardingModel == nil)
  }

  struct StoredCase: Sendable {
    let outcome: OnboardingOutcome
    let version: Int
  }

  nonisolated static let storedCases = [
    StoredCase(outcome: .completed, version: 1),
    StoredCase(outcome: .dismissed, version: 1),
    StoredCase(outcome: .completed, version: 0),
    StoredCase(outcome: .dismissed, version: 0),
  ]

  @Test(arguments: storedCases)
  func aLaterLaunchWithAStoredRecordDoesNotOpenOnboarding(_ item: StoredCase) throws {
    let fixture = try Fixture()
    let record = OnboardingRecord(version: item.version, outcome: item.outcome, steps: [:], at: Self.startedAt)
    try AppPreferencesStore.update(at: fixture.model.preferencesFile) { $0.onboarding = record }
    let presented = Counter()
    let presenter = OnboardingPresenter(model: fixture.model) { _ in presented.increment() }
    AppDelegate.armOnboarding(presenter, preferencesFile: fixture.model.preferencesFile)
    #expect(!presenter.armed)
    #expect(!presenter.openIfArmed())
    #expect(presented.count == 0)
    #expect(!fixture.model.isActive)
    #expect(fixture.stored.onboarding == record)
  }

  @Test func anUnreadablePreferencesFileKeepsOnboardingClosedAtLaunch() throws {
    let fixture = try Fixture()
    try Data("not json".utf8).write(to: fixture.model.preferencesFile)
    let presented = Counter()
    let presenter = OnboardingPresenter(model: fixture.model) { _ in presented.increment() }
    AppDelegate.armOnboarding(presenter, preferencesFile: fixture.model.preferencesFile)
    #expect(!presenter.armed)
    #expect(!presenter.openIfArmed())
    #expect(presented.count == 0)
    #expect(!fixture.model.isActive)
  }

  @Test func closingTheWindowMidFlowRecordsDismissedWithVersionOneAndItNeverOpensByItselfAgain() throws {
    let fixture = try Fixture()
    try AppPreferencesStore.update(at: fixture.model.preferencesFile) { $0.forceReminderHours = 9 }
    let presented = Counter()
    let presenter = OnboardingPresenter(model: fixture.model) { _ in presented.increment() }
    AppDelegate.armOnboarding(presenter, preferencesFile: fixture.model.preferencesFile)
    #expect(presenter.openIfArmed())
    fixture.model.performDefault()
    fixture.model.skipStep()
    fixture.model.performDefault()
    #expect(fixture.model.currentStep == .notifications)
    fixture.clock.advance(seconds: 30)
    presenter.controller.didClose()
    let dismissed = OnboardingRecord(
      version: 1, outcome: .dismissed, steps: ["welcome": "done", "launchAtLogin": "done"],
      at: Self.startedAt.addingTimeInterval(30))
    #expect(fixture.stored.onboarding == dismissed)
    #expect(fixture.stored.forceReminderHours == 9)
    #expect(!fixture.model.isActive)
    #expect(fixture.closes.count == 0)
    fixture.clock.advance(seconds: 30)
    presenter.controller.didClose()
    fixture.model.performDefault()
    #expect(fixture.stored.onboarding == dismissed)
    #expect(fixture.model.currentStep == .notifications)
    AppDelegate.armOnboarding(presenter, preferencesFile: fixture.model.preferencesFile)
    #expect(!presenter.armed)
    #expect(!presenter.openIfArmed())
    #expect(presented.count == 1)
    #expect(fixture.logged.decisions.isEmpty)
  }

  @Test func closingOnTheFirstStepRecordsDismissedWithNoStepResults() throws {
    let fixture = try Fixture()
    let controller = OnboardingWindow.controller(model: fixture.model)
    controller.didClose()
    #expect(fixture.stored.onboarding == nil)
    fixture.model.begin()
    controller.didClose()
    #expect(
      fixture.stored.onboarding
        == OnboardingRecord(version: 1, outcome: .dismissed, steps: [:], at: Self.startedAt))
  }

  @MainActor struct SettingsFixture {
    let onboarding: Fixture
    let settings: SettingsModel
    let presenter: OnboardingPresenter
    let presented = Counter()

    init(login status: LoginItemStatus = .notRegistered) throws {
      onboarding = try Fixture(login: status)
      settings = onboarding.settings
      let presented = presented
      let presenter = OnboardingPresenter(model: onboarding.model) { _ in presented.increment() }
      self.presenter = presenter
      settings.onRunOnboarding = { AppDelegate.runOnboardingAgain(presenter) }
    }
  }

  @Test func runOnboardingAgainOpensItAtStepOneWithTheCurrentStateOfEachStep() async throws {
    let fixture = try SettingsFixture()
    let model = fixture.onboarding.model
    let completed = OnboardingRecord(
      version: 1, outcome: .completed, steps: ["welcome": "done"], at: Self.startedAt.addingTimeInterval(-3_600))
    try AppPreferencesStore.update(at: model.preferencesFile) { $0.onboarding = completed }
    AppDelegate.armOnboarding(fixture.presenter, preferencesFile: model.preferencesFile)
    #expect(!fixture.presenter.armed)
    #expect(fixture.presented.count == 0)
    fixture.onboarding.login.status = .enabled
    fixture.onboarding.panel.apply(Self.idle())
    fixture.settings.runOnboardingAgain()
    #expect(fixture.presented.count == 1)
    #expect(model.isActive)
    #expect(model.currentStep == .welcome)
    #expect(model.progressLabel == "Step 1 of 7")
    #expect(model.results.isEmpty)
    #expect(fixture.presenter.controller.window == nil)
    #expect(fixture.onboarding.stored.onboarding == completed)
    model.performDefault()
    #expect(model.currentStep == .launchAtLogin)
    #expect(fixture.onboarding.panel.launchAtLogin)
    #expect(model.context.loginItem == .enabled)
    #expect(fixture.onboarding.login.calls.isEmpty)
    fixture.onboarding.walk(to: .selfTest)
    #expect(await fixture.onboarding.requested(1))
    #expect(model.selfTestRow.title == "Runs on its own")
    fixture.onboarding.panel.apply(Self.idle(.passed, runs: 7))
    #expect(model.selfTestRow.title == "Passed")
    fixture.onboarding.clock.advance(seconds: 10)
    model.performDefault()
    #expect(fixture.onboarding.stored.onboarding?.outcome == .completed)
    #expect(fixture.onboarding.stored.onboarding?.at == Self.startedAt.addingTimeInterval(10))
    #expect(fixture.onboarding.stored.onboarding?.steps.count == 7)
    fixture.settings.runOnboardingAgain()
    #expect(fixture.presented.count == 2)
    #expect(model.isActive)
    #expect(model.currentStep == .welcome)
    #expect(model.results.isEmpty)
    fixture.onboarding.walk(to: .selfTest)
    #expect(await fixture.onboarding.requested(2))
    #expect(model.selfTestRow.title == "Passed")
    fixture.onboarding.clock.advance(seconds: 10)
    fixture.presenter.controller.didClose()
    #expect(fixture.onboarding.stored.onboarding?.outcome == .dismissed)
    #expect(fixture.onboarding.stored.onboarding?.version == 1)
    #expect(fixture.onboarding.stored.onboarding?.at == Self.startedAt.addingTimeInterval(20))
  }

  @Test func runOnboardingAgainWhileItIsOpenGoesBackToStepOne() throws {
    let fixture = try SettingsFixture()
    let model = fixture.onboarding.model
    fixture.settings.runOnboardingAgain()
    fixture.onboarding.walk(to: .location)
    #expect(model.results.count == 3)
    fixture.settings.runOnboardingAgain()
    #expect(fixture.presented.count == 2)
    #expect(model.isActive)
    #expect(model.currentStep == .welcome)
    #expect(model.index == 0)
    #expect(model.results.isEmpty)
    #expect(fixture.onboarding.stored.onboarding == nil)
  }

  @Test func runOnboardingAgainWhileAnActionIsInFlightOnlyBringsTheWindowBack() throws {
    let fixture = try SettingsFixture()
    let model = fixture.onboarding.model
    fixture.settings.runOnboardingAgain()
    fixture.onboarding.walk(to: .notifications)
    #expect(model.currentStep == .notifications)
    model.inFlight = .authorization
    fixture.settings.runOnboardingAgain()
    #expect(fixture.presented.count == 2)
    #expect(model.currentStep == .notifications)
    #expect(model.steps.count == 7)
    #expect(model.results[.welcome] == .done)
  }

  @Test func runOnboardingAgainDisarmsAFirstRunThatHasNotOpenedYet() throws {
    let fixture = try SettingsFixture()
    AppDelegate.armOnboarding(fixture.presenter, preferencesFile: fixture.onboarding.model.preferencesFile)
    #expect(fixture.presenter.armed)
    fixture.settings.runOnboardingAgain()
    #expect(fixture.presented.count == 1)
    #expect(!fixture.presenter.armed)
    #expect(!fixture.presenter.openIfArmed())
    #expect(fixture.presented.count == 1)
  }

  @Test func theSetupSectionNamesItsButtonAndShowsTheVersionCaption() throws {
    let fixture = try SettingsFixture()
    #expect(DiagnosticsPane.setupTitle == "Setup")
    #expect(DiagnosticsPane.runOnboardingTitle == "Run Onboarding Again")
    let full = SetupInfo(appVersion: "0.1.0", osVersion: "27.0", osBuild: "26A428", hardwareModel: "Mac17,7")
    #expect(DiagnosticsPane.setupCaption(full) == "Overtime 0.1.0 on macOS 27.0 (26A428), Mac17,7.")
    #expect(
      DiagnosticsPane.setupCaption(
        SetupInfo(appVersion: "0.1.0", osVersion: "27.0.1", osBuild: nil, hardwareModel: "Mac17,7"))
        == "Overtime 0.1.0 on macOS 27.0.1, Mac17,7.")
    #expect(
      DiagnosticsPane.setupCaption(
        SetupInfo(appVersion: "0.1.0", osVersion: "27.0", osBuild: "26A428", hardwareModel: nil))
        == "Overtime 0.1.0 on macOS 27.0 (26A428).")
    fixture.settings.setupInfo = full
    #expect(fixture.settings.setupCaption == "Overtime 0.1.0 on macOS 27.0 (26A428), Mac17,7.")
  }

  @Test func theSetupInfoOfThisBuildNamesTheAppAndTheSystem() throws {
    let info = SetupInfo.current()
    #expect(info.appVersion == Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
    #expect(!info.appVersion.isEmpty)
    #expect(info.osVersion == SystemInfo.osVersion())
    #expect(info.osBuild == SystemInfo.osBuild())
    #expect(info.hardwareModel == SystemInfo.hardwareModel())
    #expect(try SettingsFixture().settings.setupInfo == info)
  }

  @Test func showOnboardingInTheTestHostOpensNoWindow() throws {
    let delegate = try #require(AppDelegate.shared)
    let before = NSApp.windows.count
    delegate.showOnboarding()
    #expect(delegate.onboardingModel == nil)
    #expect(NSApp.windows.count == before)
  }

  static let advance = OnboardingButton(title: "Continue", action: .advance)
  static let allowNotifications = OnboardingButton(title: "Allow Notifications", action: .allowNotifications)
  static let allowLocation = OnboardingButton(title: "Allow Location Access", action: .allowLocation)

  @Test func reachingTheNotificationsStepReadsTheStatusAndRequestsNothing() async throws {
    let fixture = try Fixture(notifications: .notDetermined)
    let port = try #require(fixture.port)
    fixture.model.begin()
    fixture.model.performDefault()
    #expect(port.reads == 0)
    #expect(fixture.model.notificationRow == nil)
    fixture.model.performDefault()
    #expect(fixture.model.currentStep == .notifications)
    #expect(fixture.model.defaultButton == Self.advance)
    #expect(await waitUntil { fixture.model.notificationAuthorization == .notDetermined })
    #expect(port.reads == 1)
    #expect(port.requests == 0)
    #expect(fixture.model.notificationRow == NotificationStatusRow.for(.notDetermined))
    #expect(fixture.model.notificationRow?.title == "Notifications aren't set up yet.")
    #expect(fixture.model.defaultButton == Self.allowNotifications)
    #expect(fixture.model.showsSkip)
    #expect(fixture.model.inFlight == nil)
    fixture.model.skipStep()
    #expect(fixture.model.results[.notifications] == .skipped)
    #expect(fixture.model.currentStep == .location)
    fixture.model.back()
    #expect(await waitUntil { port.reads == 2 })
    #expect(port.requests == 0)
    #expect(port.posted.isEmpty)
    #expect(fixture.helperSource.actions.isEmpty)
  }

  @Test func pressingAllowNotificationsRequestsOnceAndTheStepShowsTheAnswer() async throws {
    let fixture = try Fixture(notifications: .notDetermined, afterRequest: .authorized)
    let port = try #require(fixture.port)
    fixture.model.begin()
    fixture.walk(to: .notifications)
    #expect(await waitUntil { fixture.model.notificationAuthorization == .notDetermined })
    fixture.model.performDefault()
    #expect(fixture.model.inFlight == .authorization)
    #expect(
      fixture.model.defaultButton
        == OnboardingButton(title: "Allow Notifications", action: .allowNotifications, enabled: false))
    #expect(!fixture.model.backEnabled)
    #expect(!fixture.model.skipEnabled)
    fixture.model.performDefault()
    fixture.model.skipStep()
    fixture.model.back()
    #expect(await waitUntil { fixture.model.inFlight == nil })
    #expect(port.requests == 1)
    #expect(fixture.model.notificationAuthorization == .authorized)
    #expect(fixture.model.notificationRow == NotificationStatusRow.for(.authorized))
    #expect(fixture.model.notificationRow?.title == "Notifications are allowed.")
    #expect(fixture.model.notificationRow?.action == nil)
    #expect(fixture.model.currentStep == .notifications)
    #expect(fixture.model.defaultButton == Self.advance)
    #expect(!fixture.model.showsSkip)
    #expect(fixture.model.backEnabled)
    #expect(fixture.model.results[.notifications] == nil)
    fixture.model.performDefault()
    #expect(fixture.model.currentStep == .location)
    #expect(fixture.model.results[.notifications] == .done)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(port.requests == 1)
    #expect(port.posted.isEmpty)
    #expect(fixture.helperSource.actions.isEmpty)
  }

  @Test func aDeniedAnswerShowsTheOffRowWithItsLinkAndIsNeverAskedAgain() async throws {
    let fixture = try Fixture(notifications: .notDetermined, afterRequest: .denied)
    let port = try #require(fixture.port)
    fixture.model.begin()
    fixture.walk(to: .notifications)
    #expect(await waitUntil { fixture.model.notificationAuthorization == .notDetermined })
    fixture.model.performDefault()
    #expect(await waitUntil { fixture.model.inFlight == nil })
    #expect(fixture.model.notificationAuthorization == .denied)
    #expect(fixture.model.notificationRow == NotificationStatusRow.for(.denied))
    #expect(fixture.model.notificationRow?.title == "Notifications are off for Overtime in System Settings.")
    #expect(fixture.model.notificationRow?.actionLabel == "Open Notification Settings")
    #expect(fixture.model.defaultButton == Self.advance)
    #expect(!fixture.model.showsSkip)
    #expect(fixture.opened.urls.isEmpty)
    fixture.model.openNotificationSettings()
    #expect(fixture.opened.urls == [SystemSettingsLinks.notifications])
    fixture.model.performDefault()
    #expect(fixture.model.currentStep == .location)
    fixture.model.back()
    #expect(await waitUntil { port.reads == 2 })
    #expect(fixture.model.defaultButton == Self.advance)
    #expect(port.requests == 1)
  }

  @Test(arguments: [NotificationAuthorization.authorized, .provisional, .denied])
  func aNotificationStatusThatIsAlreadyDecidedShowsOnlyContinue(_ status: NotificationAuthorization) async throws {
    let fixture = try Fixture(notifications: status)
    let port = try #require(fixture.port)
    fixture.model.begin()
    fixture.walk(to: .notifications)
    #expect(await waitUntil { fixture.model.notificationAuthorization == status })
    #expect(fixture.model.notificationRow == NotificationStatusRow.for(status))
    #expect(fixture.model.defaultButton == Self.advance)
    #expect(!fixture.model.showsSkip)
    fixture.model.performDefault()
    #expect(fixture.model.currentStep == .location)
    #expect(fixture.model.results[.notifications] == .done)
    #expect(port.requests == 0)
    #expect(fixture.model.inFlight == nil)
  }

  @Test func withoutANotificationOrLocationPortTheStepsShowNoRowAndContinue() throws {
    let fixture = try Fixture()
    fixture.model.begin()
    fixture.walk(to: .notifications)
    #expect(fixture.model.notificationRow == nil)
    #expect(fixture.model.readNotificationAuthorization() == nil)
    #expect(fixture.model.defaultButton == Self.advance)
    #expect(!fixture.model.showsSkip)
    fixture.model.performDefault()
    #expect(fixture.model.currentStep == .location)
    #expect(fixture.model.locationRow == nil)
    #expect(fixture.model.location == nil)
    #expect(fixture.model.defaultButton == Self.advance)
    #expect(!fixture.model.showsSkip)
    fixture.model.refreshLocationStatus()
    fixture.model.performDefault()
    #expect(fixture.model.currentStep == .checks)
    #expect(fixture.model.inFlight == nil)
  }

  @Test func aReadThatStartedBeforeTheAnswerNeverOverwritesIt() async throws {
    let fixture = try Fixture(notifications: .notDetermined, afterRequest: .authorized)
    let port = try #require(fixture.port)
    fixture.model.begin()
    fixture.walk(to: .notifications)
    #expect(await waitUntil { fixture.model.notificationAuthorization == .notDetermined })
    port.holdNextRead()
    fixture.model.refreshStep()
    #expect(await waitUntil { port.reads == 2 })
    fixture.model.performDefault()
    #expect(await waitUntil { fixture.model.notificationAuthorization == .authorized && fixture.model.inFlight == nil })
    port.releaseRead()
    try? await Task.sleep(for: .milliseconds(100))
    #expect(fixture.model.notificationAuthorization == .authorized)
    port.set(.denied)
    fixture.model.refreshStep()
    #expect(await waitUntil { fixture.model.notificationAuthorization == .denied })
    #expect(port.requests == 1)
  }

  @Test func anUnansweredRequestStopsBlockingTheStepAfterItsBoundAndALateAnswerStillShows() async throws {
    let fixture = try Fixture()
    let port = HeldRequestPort()
    fixture.model.notifications = port
    #expect(fixture.model.authorizationWaitSeconds == 5)
    fixture.model.authorizationWaitSeconds = 0.4
    fixture.model.begin()
    fixture.walk(to: .notifications)
    #expect(await waitUntil { fixture.model.notificationAuthorization == .notDetermined })
    fixture.model.performDefault()
    #expect(fixture.model.inFlight == .authorization)
    #expect(!fixture.model.backEnabled)
    #expect(!fixture.model.skipEnabled)
    #expect(!fixture.model.defaultButton.enabled)
    #expect(await waitUntil { port.requests == 1 })
    #expect(await waitUntil { fixture.model.inFlight == nil })
    #expect(fixture.model.notificationAuthorization == .notDetermined)
    #expect(fixture.model.backEnabled)
    #expect(fixture.model.defaultButton == Self.allowNotifications)
    #expect(fixture.model.showsSkip)
    #expect(fixture.model.skipEnabled)
    fixture.model.skipStep()
    #expect(fixture.model.currentStep == .location)
    port.answer(.authorized)
    #expect(await waitUntil { fixture.model.notificationAuthorization == .authorized })
    #expect(port.requests == 1)
    #expect(fixture.model.inFlight == nil)
    #expect(fixture.model.currentStep == .location)
  }

  @Test func closingTheWindowDuringARequestLeavesNothingInFlightForTheNextRun() async throws {
    let fixture = try Fixture()
    let port = HeldRequestPort()
    fixture.model.notifications = port
    let controller = OnboardingWindow.controller(model: fixture.model)
    fixture.model.begin()
    fixture.walk(to: .notifications)
    #expect(await waitUntil { fixture.model.notificationAuthorization == .notDetermined })
    fixture.model.performDefault()
    #expect(fixture.model.inFlight == .authorization)
    #expect(controller.allowsClose)
    controller.didClose()
    #expect(!fixture.model.isActive)
    #expect(fixture.stored.onboarding?.outcome == .dismissed)
    fixture.model.begin()
    #expect(fixture.model.isActive)
    #expect(fixture.model.inFlight == nil)
    fixture.walk(to: .notifications)
    #expect(fixture.model.backEnabled)
    #expect(fixture.model.defaultButton == Self.allowNotifications)
    port.answer(.denied)
    #expect(await waitUntil { fixture.model.notificationAuthorization == .denied })
    #expect(fixture.model.inFlight == nil)
    #expect(port.requests == 1)
  }

  static let hotspotBodyNoChoice =
    "If the network stops working while the lid is closed and Claude is working, Overtime can switch the Mac to your iPhone hotspot, and back when you open the lid. Choose your hotspot to turn this on, or continue without it."
  static let hotspotBodyChosen =
    "Overtime switches the Mac to this hotspot when the network stops working while the lid is closed and Claude is working. Location access is optional: without it, failover still works, but joining your hotspot is less likely to succeed."

  @Test func theHotspotStepWithNoChoiceRequestsNothingAndContinues() async throws {
    let fixture = try Fixture(location: .notDetermined)
    let location = try #require(fixture.location)
    fixture.model.begin()
    fixture.walk(to: .location)
    #expect(fixture.model.currentStep == .location)
    #expect(fixture.locationsMade.count == 1)
    #expect(location.statusReads == 1)
    #expect(fixture.model.settings === fixture.settings)
    #expect(fixture.model.hotspotChoice == .none)
    #expect(!fixture.model.context.hotspotChosen)
    #expect(fixture.model.stepBody == Self.hotspotBodyNoChoice)
    #expect(fixture.model.locationRow == nil)
    #expect(fixture.model.defaultButton == Self.advance)
    #expect(!fixture.model.showsSkip)
    fixture.model.performDefault()
    #expect(fixture.model.currentStep == .checks)
    #expect(fixture.model.results[.location] == .done)
    #expect(location.requests == 0)
    #expect(fixture.host.appliedSettings.isEmpty)
  }

  @Test func choosingAHotspotOnTheStepSavesItExplainsLocationAndOffersIt() async throws {
    let fixture = try Fixture(location: .notDetermined, networks: ["Team iPhone"])
    let location = try #require(fixture.location)
    let settings = fixture.settings
    fixture.model.begin()
    fixture.walk(to: .location)
    #expect(await waitUntil { settings.knownNetworksRead })
    let result = await settings.selectHotspot(.autoDetect)
    #expect(result == .applied)
    #expect(fixture.host.appliedSettings.last?.hotspotAutoDetect == true)
    guard case .loaded(let saved) = SettingsStore.load(from: settings.settingsFile) else {
      Issue.record("the hotspot choice was not saved")
      return
    }
    #expect(saved.hotspotAutoDetect)
    #expect(fixture.model.hotspotChoice == .autoDetect)
    #expect(fixture.model.context.hotspotChosen)
    #expect(fixture.model.stepBody == Self.hotspotBodyChosen)
    #expect(fixture.model.locationRow == LocationRow.for(.notDetermined, choice: .autoDetect))
    #expect(fixture.model.defaultButton == Self.allowLocation)
    #expect(fixture.model.showsSkip)
    #expect(location.requests == 0)
    fixture.model.performDefault()
    #expect(location.requests == 1)
    #expect(fixture.model.inFlight == .authorization)
    location.current = .authorized
    fixture.model.refreshLocationStatus()
    #expect(fixture.model.inFlight == nil)
    await settings.selectHotspot(.none)
    #expect(fixture.model.hotspotChoice == .none)
    #expect(!fixture.model.context.hotspotChosen)
    #expect(fixture.model.locationRow == nil)
    #expect(fixture.model.defaultButton == Self.advance)
    #expect(fixture.model.stepBody == Self.hotspotBodyNoChoice)
    #expect(location.requests == 1)
  }

  @Test func theHotspotStepReadsTheKnownNetworksOfSettings() async throws {
    let fixture = try Fixture(networks: ["Team iPhone"])
    let settings = fixture.settings
    fixture.model.begin()
    fixture.walk(to: .notifications)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(!settings.knownNetworksRead)
    fixture.model.continueStep()
    #expect(fixture.model.currentStep == .location)
    #expect(await waitUntil { settings.knownNetworksRead })
    #expect(settings.hotspotEntries.contains(.choice(.named("Team iPhone"))))
    #expect(fixture.host.appliedSettings.isEmpty)
  }

  @Test func reachingTheLocationStepReadsTheStatusAndRequestsNothing() throws {
    let fixture = try Fixture(location: .notDetermined, hotspot: .autoDetect)
    let location = try #require(fixture.location)
    fixture.model.begin()
    fixture.walk(to: .notifications)
    #expect(fixture.locationsMade.count == 0)
    #expect(location.statusReads == 0)
    #expect(fixture.model.locationRow == nil)
    fixture.model.continueStep()
    #expect(fixture.model.currentStep == .location)
    #expect(fixture.locationsMade.count == 1)
    #expect(location.statusReads == 1)
    #expect(location.requests == 0)
    #expect(fixture.model.context.hotspotChosen)
    #expect(fixture.model.locationRow == LocationRow.for(.notDetermined, choice: .autoDetect))
    #expect(
      fixture.model.locationRow?.title == "Location access lets Overtime join your iPhone hotspot directly.")
    #expect(fixture.model.defaultButton == Self.allowLocation)
    #expect(fixture.model.showsSkip)
    #expect(fixture.model.inFlight == nil)
    fixture.model.skipStep()
    #expect(fixture.model.results[.location] == .skipped)
    fixture.model.back()
    #expect(fixture.locationsMade.count == 1)
    #expect(location.statusReads == 2)
    #expect(location.requests == 0)
    #expect(fixture.opened.urls.isEmpty)
  }

  @Test func pressingAllowLocationAccessRequestsOnceAndTheStepFollowsTheNewStatus() throws {
    let fixture = try Fixture(location: .notDetermined, hotspot: .autoDetect)
    let location = try #require(fixture.location)
    fixture.model.begin()
    fixture.walk(to: .location)
    fixture.model.performDefault()
    #expect(location.requests == 1)
    #expect(fixture.model.inFlight == .authorization)
    #expect(
      fixture.model.defaultButton
        == OnboardingButton(title: "Allow Location Access", action: .allowLocation, enabled: false))
    #expect(!fixture.model.backEnabled)
    #expect(!fixture.model.skipEnabled)
    fixture.model.performDefault()
    fixture.model.skipStep()
    fixture.model.back()
    #expect(location.requests == 1)
    #expect(fixture.model.currentStep == .location)
    fixture.model.refreshLocationStatus()
    #expect(fixture.model.inFlight == .authorization)
    location.current = .authorized
    fixture.model.refreshLocationStatus()
    #expect(fixture.model.locationStatus == .authorized)
    #expect(fixture.model.inFlight == nil)
    #expect(fixture.model.locationRow == LocationRow.for(.authorized))
    #expect(fixture.model.locationRow?.title == "Location access is on.")
    #expect(fixture.model.defaultButton == Self.advance)
    #expect(!fixture.model.showsSkip)
    #expect(fixture.model.backEnabled)
    fixture.model.performDefault()
    #expect(fixture.model.currentStep == .checks)
    #expect(fixture.model.results[.location] == .done)
    #expect(location.requests == 1)
    #expect(fixture.helperSource.actions.isEmpty)
  }

  @Test func anUnansweredLocationRequestStopsBlockingTheStepAfterItsBound() async throws {
    let fixture = try Fixture(location: .notDetermined, hotspot: .autoDetect)
    let location = try #require(fixture.location)
    fixture.model.authorizationWaitSeconds = 0.4
    fixture.model.begin()
    fixture.walk(to: .location)
    fixture.model.performDefault()
    #expect(fixture.model.inFlight == .authorization)
    #expect(!fixture.model.backEnabled)
    #expect(await waitUntil { fixture.model.inFlight == nil })
    #expect(fixture.model.locationStatus == .notDetermined)
    #expect(fixture.model.defaultButton == Self.allowLocation)
    #expect(fixture.model.showsSkip)
    #expect(fixture.model.backEnabled)
    #expect(location.requests == 1)
    fixture.model.performDefault()
    #expect(location.requests == 2)
    #expect(fixture.model.inFlight == .authorization)
    location.current = .denied
    fixture.model.refreshLocationStatus()
    #expect(fixture.model.inFlight == nil)
    #expect(fixture.model.defaultButton == Self.advance)
  }

  @Test func theBoundOfAnEarlierRequestNeverEndsALaterOne() async throws {
    let fixture = try Fixture(location: .notDetermined, hotspot: .autoDetect)
    let location = try #require(fixture.location)
    let port = HeldRequestPort()
    fixture.model.notifications = port
    fixture.model.authorizationWaitSeconds = 0.3
    fixture.model.begin()
    fixture.walk(to: .location)
    fixture.model.performDefault()
    location.current = .authorized
    fixture.model.refreshLocationStatus()
    #expect(fixture.model.inFlight == nil)
    fixture.model.back()
    #expect(fixture.model.currentStep == .notifications)
    #expect(await waitUntil { fixture.model.notificationAuthorization == .notDetermined })
    fixture.model.authorizationWaitSeconds = 30
    fixture.model.performDefault()
    #expect(fixture.model.inFlight == .authorization)
    #expect(await waitUntil { port.requests == 1 })
    try? await Task.sleep(for: .milliseconds(600))
    #expect(fixture.model.inFlight == .authorization)
    fixture.model.refreshLocationStatus()
    #expect(fixture.model.inFlight == .authorization)
    port.answer(.authorized)
    #expect(await waitUntil { fixture.model.inFlight == nil })
    #expect(fixture.model.notificationAuthorization == .authorized)
  }

  @Test func aRequestNeverEndsAnInstallThatIsInFlight() async throws {
    let fixture = try Fixture(location: .notDetermined, hotspot: .autoDetect)
    let location = try #require(fixture.location)
    fixture.model.authorizationWaitSeconds = 0.2
    fixture.model.begin()
    fixture.walk(to: .location)
    fixture.model.performDefault()
    #expect(fixture.model.inFlight == .authorization)
    fixture.model.inFlight = .install
    try? await Task.sleep(for: .milliseconds(500))
    #expect(fixture.model.inFlight == .install)
    location.current = .authorized
    fixture.model.refreshLocationStatus()
    #expect(fixture.model.locationStatus == .authorized)
    #expect(fixture.model.inFlight == .install)
  }

  @Test func aLocationRequestStaysInFlightUntilItsBoundOrANewStatus() async throws {
    let fixture = try Fixture(location: .notDetermined, hotspot: .autoDetect)
    let location = try #require(fixture.location)
    fixture.model.begin()
    fixture.walk(to: .location)
    fixture.model.performDefault()
    try? await Task.sleep(for: .milliseconds(200))
    #expect(fixture.model.inFlight == .authorization)
    #expect(!fixture.model.backEnabled)
    #expect(location.requests == 1)
    location.current = .authorized
    fixture.model.refreshLocationStatus()
    #expect(fixture.model.inFlight == nil)
  }

  @Test(arguments: [LocationAuthorization.denied, .restricted])
  func locationThatIsOffShowsItsRowWithTheLinkAndOnlyContinue(_ status: LocationAuthorization) throws {
    let fixture = try Fixture(location: status, hotspot: .autoDetect)
    let location = try #require(fixture.location)
    fixture.model.begin()
    fixture.walk(to: .location)
    #expect(fixture.model.locationRow == LocationRow.for(status))
    #expect(fixture.model.locationRow?.title == "Location access is off for Overtime.")
    #expect(fixture.model.locationRow?.actionLabel == "Open Location Services")
    #expect(fixture.model.defaultButton == Self.advance)
    #expect(!fixture.model.showsSkip)
    fixture.model.openLocationServices()
    #expect(fixture.opened.urls == [SystemSettingsLinks.locationServices])
    fixture.model.performDefault()
    #expect(fixture.model.currentStep == .checks)
    #expect(location.requests == 0)
    #expect(fixture.model.inFlight == nil)
  }

  @Test func comingBackToTheAppReadsOnlyTheShownStepAndNothingOnceTheWindowIsClosed() async throws {
    let fixture = try Fixture(notifications: .denied, location: .denied)
    let port = try #require(fixture.port)
    let location = try #require(fixture.location)
    fixture.model.refreshStep()
    fixture.model.begin()
    fixture.model.refreshStep()
    #expect(fixture.locationsMade.count == 0)
    fixture.model.continueStep()
    #expect(fixture.model.currentStep == .launchAtLogin)
    fixture.login.status = .enabled
    #expect(fixture.model.context.loginItem == .notRegistered)
    fixture.model.refreshStep()
    #expect(fixture.model.context.loginItem == .enabled)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(port.reads == 0)
    #expect(location.statusReads == 0)
    fixture.model.continueStep()
    #expect(await waitUntil { fixture.model.notificationAuthorization == .denied })
    #expect(port.reads == 1)
    port.set(.authorized)
    fixture.model.refreshStep()
    #expect(await waitUntil { fixture.model.notificationAuthorization == .authorized })
    #expect(port.reads == 2)
    #expect(location.statusReads == 0)
    fixture.model.continueStep()
    #expect(fixture.model.locationStatus == .denied)
    #expect(location.statusReads == 1)
    location.current = .authorized
    fixture.model.refreshStep()
    #expect(fixture.model.locationStatus == .authorized)
    #expect(location.statusReads == 2)
    fixture.model.dismissed()
    fixture.model.refreshStep()
    try? await Task.sleep(for: .milliseconds(50))
    #expect(location.statusReads == 2)
    #expect(port.reads == 2)
    #expect(port.requests == 0)
    #expect(location.requests == 0)
    #expect(fixture.host.selfTestRequests == 0)
  }

  @Test func comingBackToTheAppOnTheLastStepAsksForTheTestOnceItCanRun() async throws {
    let fixture = try Fixture()
    fixture.panel.apply(Self.idle(lidClosed: true))
    fixture.model.begin()
    fixture.walk(to: .selfTest)
    fixture.model.refreshStep()
    try? await Task.sleep(for: .milliseconds(50))
    #expect(fixture.host.selfTestRequests == 0)
    fixture.panel.apply(Self.idle())
    fixture.model.refreshStep()
    #expect(await fixture.requested(1))
    fixture.model.refreshStep()
    try? await Task.sleep(for: .milliseconds(50))
    #expect(fixture.host.selfTestRequests == 1)
  }

  @Test func theStatusRowsUseOnlyListedSymbolsAndTheSettingsLabels() {
    let listed = Set(SymbolAvailabilityTests.phaseThreeSymbols)
    let notifications: [NotificationAuthorization] = [.authorized, .provisional, .notDetermined, .denied]
    let location: [LocationAuthorization] = [.authorized, .notDetermined, .denied, .restricted]
    #expect(Set(notifications.map { NotificationStatusRow.for($0).symbol }).isSubset(of: listed))
    #expect(Set(location.map { LocationRow.for($0).symbol }).isSubset(of: listed))
    #expect(OnboardingFlow.allowLocationLabel == LocationRow.allowLabel)
  }

  final class FakeScreenLock: Sendable {
    private struct State {
      var status: ScreenLockStatus
      var reads = 0
      var holding = false
      var heldReturned = 0
    }

    private let state: OSAllocatedUnfairLock<State>
    private let gate = DispatchSemaphore(value: 0)

    init(_ status: ScreenLockStatus) {
      state = OSAllocatedUnfairLock(initialState: State(status: status))
    }

    var reads: Int {
      state.withLock { $0.reads }
    }

    var heldReturned: Int {
      state.withLock { $0.heldReturned }
    }

    func set(_ status: ScreenLockStatus) {
      state.withLock { $0.status = status }
    }

    func hold() {
      state.withLock { $0.holding = true }
    }

    func release() {
      state.withLock { $0.holding = false }
      for _ in 0..<4 { gate.signal() }
    }

    func read() -> ScreenLockStatus {
      let (status, holds) = state.withLock { state -> (ScreenLockStatus, Bool) in
        state.reads += 1
        return (state.status, state.holding)
      }
      if holds {
        _ = gate.wait(timeout: .now() + FakeHelperInstaller.heldSeconds)
        state.withLock { $0.heldReturned += 1 }
      }
      return status
    }
  }

  final class FakeNetworks: WiFiInfoPort {
    private struct State {
      var names: [String]?
      var reads = 0
      var interfaceReads = 0
      var holding = false
      var heldReturned = 0
    }

    private let state: OSAllocatedUnfairLock<State>
    private let gate = DispatchSemaphore(value: 0)

    init(_ names: [String]?) {
      state = OSAllocatedUnfairLock(initialState: State(names: names))
    }

    var reads: Int {
      state.withLock { $0.reads }
    }

    var interfaceReads: Int {
      state.withLock { $0.interfaceReads }
    }

    var heldReturned: Int {
      state.withLock { $0.heldReturned }
    }

    func set(_ names: [String]?) {
      state.withLock { $0.names = names }
    }

    func hold() {
      state.withLock { $0.holding = true }
    }

    func release() {
      state.withLock { $0.holding = false }
      for _ in 0..<4 { gate.signal() }
    }

    func interfaceName() -> String? {
      state.withLock { $0.interfaceReads += 1 }
      return "en0"
    }

    func knownNetworkNames() -> [String]? {
      let (names, holds) = state.withLock { state -> ([String]?, Bool) in
        state.reads += 1
        return (state.names, state.holding)
      }
      if holds {
        _ = gate.wait(timeout: .now() + FakeHelperInstaller.heldSeconds)
        state.withLock { $0.heldReturned += 1 }
      }
      return names
    }
  }

  @MainActor struct ChecksFixture {
    let onboarding: Fixture
    let lock: FakeScreenLock
    let networks: FakeNetworks
    let log: HelperPaneTests.EventLog
    let reader: HelperPaneTests.ScriptedReader
    let prompt: HelperPaneTests.FakeAdminPrompt
    let copied: HelperPaneTests.EventLog

    init(
      lock status: ScreenLockStatus = .immediate, networks names: [String]? = [], sleepDisabled: [Bool?] = [false],
      outcomes: [AdminOutcome] = [], helper state: HelperMonitorState = HelperMonitorState(installer: .notRegistered),
      location: LocationAuthorization? = nil
    ) throws {
      onboarding = try Fixture(location: location, helper: state)
      let lock = FakeScreenLock(status)
      let networks = FakeNetworks(names)
      let log = HelperPaneTests.EventLog()
      let reader = HelperPaneTests.ScriptedReader(sleepDisabled, log: log)
      let prompt = HelperPaneTests.FakeAdminPrompt(outcomes, log: log)
      let copied = HelperPaneTests.EventLog()
      onboarding.helper.readSleepDisabled = { reader.read() }
      onboarding.helper.adminPrompt = prompt
      onboarding.helper.copyToPasteboard = { copied.append($0) }
      onboarding.model.readScreenLock = { lock.read() }
      onboarding.model.wifi = networks
      self.lock = lock
      self.networks = networks
      self.log = log
      self.reader = reader
      self.prompt = prompt
      self.copied = copied
    }

    var model: OnboardingModel {
      onboarding.model
    }

    var pane: HelperPaneModel {
      onboarding.helper
    }

    var source: HelperPaneTests.FakeHelperSource {
      onboarding.helperSource
    }

    func reachChecks() async -> Bool {
      model.begin()
      onboarding.walk(to: .checks)
      return await waitUntil { model.screenLockRow != nil && model.hotspotRow != nil && reader.reads >= 1 }
    }
  }

  nonisolated static let sleepOn = SystemSleepCheck.row(
    CheckRow(check: .systemSleep, icon: .pass, title: "System sleep is on."))
  nonisolated static let owning = HelperMonitorState(
    installer: .enabled, reachability: .reachable,
    status: HelperStatus(helperVersion: HelperIdentity.version, sleepDisabled: true, owns: true))

  @Test func theChecksStepReadsTheScreenLockAndTheKnownNetworksOnceWhenItAppearsAndNeverWhileItStaysVisible()
    async throws
  {
    let fixture = try ChecksFixture(
      lock: .delayed(seconds: 5), networks: ["Home", "Ivan's iPhone"], location: .notDetermined)
    let location = try #require(fixture.onboarding.location)
    let model = fixture.model
    model.begin()
    fixture.onboarding.walk(to: .location)
    model.refreshStep()
    try? await Task.sleep(for: .milliseconds(50))
    #expect(fixture.lock.reads == 0)
    #expect(fixture.networks.reads == 0)
    #expect(model.screenLockRow == nil)
    #expect(model.hotspotRow == nil)
    #expect(model.checkRows == [OnboardingChecks.askToJoin])
    model.continueStep()
    #expect(model.currentStep == .checks)
    #expect(await waitUntil { model.screenLockRow != nil && model.hotspotRow != nil })
    #expect(
      model.checkRows.map(\.title) == [
        "Screen lock waits before asking for your password.", "A known iPhone hotspot was found.",
        "Check Ask to join hotspots.",
      ])
    #expect(model.checkRows.map(\.check) == [.screenLock, .hotspot, .askToJoin])
    #expect(fixture.lock.reads == 1)
    #expect(fixture.networks.reads == 1)
    fixture.lock.set(.immediate)
    fixture.networks.set([])
    model.refreshStep()
    model.refreshStep()
    try? await Task.sleep(for: .milliseconds(100))
    #expect(fixture.lock.reads == 1)
    #expect(fixture.networks.reads == 1)
    #expect(model.screenLockRow == OnboardingChecks.screenLock(.delayed(seconds: 5)))
    #expect(model.hotspotRow?.title == "A known iPhone hotspot was found.")
    #expect(fixture.networks.interfaceReads == 0)
    #expect(location.requests == 0)
    #expect(fixture.onboarding.opened.urls.isEmpty)
    #expect(model.defaultButton == Self.advance)
    #expect(!model.showsSkip)
    model.back()
    #expect(model.currentStep == .location)
    #expect(fixture.lock.reads == 1)
    model.continueStep()
    #expect(await waitUntil { model.screenLockRow == OnboardingChecks.screenLock(.immediate) })
    #expect(await waitUntil { model.hotspotRow?.title == "No iPhone hotspot among your known networks." })
    #expect(fixture.lock.reads == 2)
    #expect(fixture.networks.reads == 2)
    #expect(location.requests == 0)
  }

  @Test func whatTheChecksStepCannotReadShowsTheExplanationAndTheSettingsLinkNeverAPassOrAFail() async throws {
    let fixture = try ChecksFixture(lock: .unknown, networks: nil, sleepDisabled: [nil])
    #expect(await fixture.reachChecks())
    let rows = fixture.model.checkRows
    #expect(
      rows.map(\.title) == [
        "Overtime couldn't read the screen lock setting.", "Overtime couldn't read your known networks.",
        "Check Ask to join hotspots.",
      ])
    #expect(rows.map(\.icon) == [.info, .info, .info])
    #expect(rows.map(\.link) == [.lockScreen, .wifi, .wifi])
    #expect(rows.map { $0.link?.label } == ["Open Lock Screen Settings", "Open Wi-Fi Settings", "Open Wi-Fi Settings"])
    #expect(rows.allSatisfy { $0.caption != nil })
    #expect(fixture.model.systemSleep == .nothing)
    #expect(!fixture.pane.showsSleepDisabledRow)
    #expect(fixture.onboarding.opened.urls.isEmpty)
    for row in rows {
      fixture.model.open(try #require(row.link))
    }
    #expect(
      fixture.onboarding.opened.urls == [
        SystemSettingsLinks.lockScreen, SystemSettingsLinks.wifi, SystemSettingsLinks.wifi,
      ])
  }

  @Test func askToJoinHotspotsIsNeverReadAndAlwaysShowsItsExplanation() async throws {
    for names in [["Ivan's iPhone"], [], nil] as [[String]?] {
      let fixture = try ChecksFixture(networks: names)
      #expect(fixture.model.checkRows == [OnboardingChecks.askToJoin])
      #expect(await fixture.reachChecks())
      #expect(fixture.model.checkRows.last == OnboardingChecks.askToJoin)
      #expect(fixture.model.checkRows.last?.icon == .info)
      #expect(fixture.model.checkRows.last?.link == .wifi)
      #expect(fixture.networks.interfaceReads == 0)
    }
  }

  @Test func aCheckThatOutlastsItsBoundIsShownAsUnreadAndTheNextVisitReadsAgain() async throws {
    let fixture = try ChecksFixture(lock: .immediate, networks: ["iPhone"])
    let model = fixture.model
    model.checksTimeoutSeconds = 0.1
    fixture.lock.hold()
    fixture.networks.hold()
    defer {
      fixture.lock.release()
      fixture.networks.release()
    }
    #expect(await fixture.reachChecks())
    #expect(model.screenLockRow == OnboardingChecks.screenLock(.unknown))
    #expect(model.hotspotRow == OnboardingChecks.hotspot(knownNetworks: nil))
    #expect(fixture.lock.heldReturned == 0)
    fixture.lock.release()
    fixture.networks.release()
    #expect(await waitUntil { fixture.lock.heldReturned == 1 && fixture.networks.heldReturned == 1 })
    try? await Task.sleep(for: .milliseconds(300))
    #expect(model.screenLockRow == OnboardingChecks.screenLock(.unknown))
    model.back()
    model.continueStep()
    #expect(model.currentStep == .checks)
    #expect(await waitUntil { model.screenLockRow == OnboardingChecks.screenLock(.immediate) })
    #expect(await waitUntil { model.hotspotRow?.title == "A known iPhone hotspot was found." })
  }

  @Test func aVisitWhileAReadIsStillRunningStartsNoSecondRead() async throws {
    let fixture = try ChecksFixture(lock: .off, networks: ["iPhone"])
    let model = fixture.model
    fixture.lock.hold()
    fixture.networks.hold()
    defer {
      fixture.lock.release()
      fixture.networks.release()
    }
    model.begin()
    fixture.onboarding.walk(to: .checks)
    #expect(await waitUntil { fixture.lock.reads == 1 && fixture.networks.reads == 1 })
    model.back()
    model.continueStep()
    model.back()
    model.continueStep()
    #expect(model.currentStep == .checks)
    try? await Task.sleep(for: .milliseconds(100))
    #expect(fixture.lock.reads == 1)
    #expect(fixture.networks.reads == 1)
    #expect(model.screenLockRow == nil)
    fixture.lock.release()
    fixture.networks.release()
    #expect(await waitUntil { model.screenLockRow == OnboardingChecks.screenLock(.off) && model.hotspotRow != nil })
    #expect(fixture.lock.reads == 1)
    #expect(fixture.networks.reads == 1)
  }

  @Test func theChecksAreBoundedByTheSystemCallTimeout() throws {
    let fixture = try Fixture()
    #expect(fixture.model.checksTimeoutSeconds == Timing.systemCallTimeoutSeconds)
    #expect(Timing.systemCallTimeoutSeconds == 5)
  }

  @Test func theChecksAreReadOffTheMainThread() async throws {
    let fixture = try ChecksFixture()
    let threads = HelperPaneTests.EventLog()
    let lock = fixture.lock
    fixture.model.readScreenLock = {
      threads.append(Thread.isMainThread ? "main" : "background")
      return lock.read()
    }
    #expect(await fixture.reachChecks())
    #expect(threads.all == ["background"])
  }

  @Test func withoutACheckSourceTheStepShowsOnlyTheAskToJoinExplanationAndClaimsNothing() async throws {
    let fixture = try Fixture()
    fixture.model.begin()
    fixture.walk(to: .checks)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(fixture.model.checkRows == [OnboardingChecks.askToJoin])
    #expect(fixture.model.systemSleep == .nothing)
    #expect(fixture.model.defaultButton == Self.advance)
    #expect(!fixture.model.showsSkip)
    fixture.model.performDefault()
    #expect(fixture.model.currentStep == .unplugProtection)
    #expect(fixture.model.results[.checks] == .done)
  }

  @Test(arguments: HelperPaneTests.ownershipCases)
  func theChecksStepShowsTheSleepDisabledRowOnlyForAOneTheHelperDoesNotOwn(
    _ ownership: HelperPaneTests.OwnershipCase
  ) async throws {
    let fixture = try ChecksFixture(sleepDisabled: [true], helper: ownership.state)
    fixture.onboarding.panel.apply(EngineSnapshot(helperEngaged: ownership.engaged))
    #expect(fixture.model.systemSleep == .nothing)
    #expect(await fixture.reachChecks())
    #expect(await waitUntil { fixture.pane.sleepDisabled == true })
    #expect(fixture.model.systemSleep == (ownership.shown ? .sleepDisabledRow : .nothing))
    #expect(fixture.pane.showsSleepDisabledRow == ownership.shown)
    #expect(fixture.prompt.calls == 0)
    #expect(fixture.source.refreshes == 0)
    #expect(fixture.source.actions.isEmpty)
    #expect(!fixture.pane.isPolling)
  }

  @Test(arguments: HelperPaneTests.ownershipCases)
  func aSleepDisabledValueOfZeroReadsAsSystemSleepOnWhoeverOwnsIt(_ ownership: HelperPaneTests.OwnershipCase)
    async throws
  {
    let fixture = try ChecksFixture(sleepDisabled: [false], helper: ownership.state)
    fixture.onboarding.panel.apply(EngineSnapshot(helperEngaged: ownership.engaged))
    #expect(await fixture.reachChecks())
    #expect(await waitUntil { fixture.pane.sleepDisabled == false })
    #expect(fixture.model.systemSleep == Self.sleepOn)
    #expect(!fixture.pane.showsSleepDisabledRow)
  }

  @Test func anUnreadableSleepDisabledValueShowsNoSystemSleepRow() async throws {
    let fixture = try ChecksFixture(sleepDisabled: [nil])
    #expect(await fixture.reachChecks())
    try? await Task.sleep(for: .milliseconds(50))
    #expect(fixture.pane.sleepDisabled == nil)
    #expect(fixture.model.systemSleep == .nothing)
    #expect(!fixture.pane.showsSleepDisabledRow)
    await fixture.pane.turnSleepBackOn()
    #expect(fixture.prompt.calls == 0)
  }

  @Test func sleepDisabledIsReadWhenTheChecksStepAppearsAndWhenTheAppBecomesActiveAndNeverBefore() async throws {
    let fixture = try ChecksFixture(sleepDisabled: [true, false])
    let model = fixture.model
    model.begin()
    fixture.onboarding.walk(to: .location)
    model.refreshStep()
    try? await Task.sleep(for: .milliseconds(50))
    #expect(fixture.reader.reads == 0)
    #expect(model.systemSleep == .nothing)
    model.continueStep()
    #expect(model.currentStep == .checks)
    #expect(await waitUntil { fixture.pane.sleepDisabled == true })
    #expect(model.systemSleep == .sleepDisabledRow)
    try? await Task.sleep(for: .milliseconds(100))
    #expect(fixture.reader.reads == 1)
    model.refreshStep()
    #expect(await waitUntil { fixture.pane.sleepDisabled == false })
    #expect(fixture.reader.reads == 2)
    #expect(model.systemSleep == Self.sleepOn)
    model.refreshStep()
    #expect(await waitUntil { fixture.reader.reads == 3 })
    #expect(model.systemSleep == Self.sleepOn)
    #expect(fixture.lock.reads == 1)
    #expect(fixture.networks.reads == 1)
    model.dismissed()
    model.refreshStep()
    try? await Task.sleep(for: .milliseconds(50))
    #expect(fixture.reader.reads == 3)
    #expect(fixture.source.refreshes == 0)
    #expect(fixture.prompt.calls == 0)
  }

  @Test func turnSleepBackOnInTheChecksStepPromptsOnlyAfterTheReaderReportsOne() async throws {
    let fixture = try ChecksFixture(sleepDisabled: [true, true, false], outcomes: [.succeeded])
    #expect(await fixture.reachChecks())
    #expect(await waitUntil { fixture.model.systemSleep == .sleepDisabledRow })
    #expect(fixture.log.all == ["read"])
    #expect(fixture.prompt.calls == 0)
    await fixture.pane.turnSleepBackOn()
    #expect(fixture.log.all == ["read", "read", "prompt", "read"])
    #expect(fixture.prompt.calls == 1)
    #expect(fixture.model.systemSleep == Self.sleepOn)
    #expect(!fixture.pane.showsSleepDisabledRow)
    #expect(fixture.pane.clearCaption == nil)
  }

  @Test func turnSleepBackOnShowsNoPromptWhenTheValueAlreadyReadsZero() async throws {
    let fixture = try ChecksFixture(sleepDisabled: [true, false])
    #expect(await fixture.reachChecks())
    #expect(await waitUntil { fixture.model.systemSleep == .sleepDisabledRow })
    await fixture.pane.turnSleepBackOn()
    #expect(fixture.log.all == ["read", "read"])
    #expect(fixture.prompt.calls == 0)
    #expect(fixture.model.systemSleep == Self.sleepOn)
  }

  @Test func turnSleepBackOnDoesNothingWhileTheHelperOwnsTheValue() async throws {
    let fixture = try ChecksFixture(sleepDisabled: [true], helper: Self.owning)
    #expect(await fixture.reachChecks())
    #expect(await waitUntil { fixture.pane.sleepDisabled == true })
    #expect(fixture.model.systemSleep == .nothing)
    await fixture.pane.turnSleepBackOn()
    #expect(fixture.reader.reads == 1)
    #expect(fixture.prompt.calls == 0)
  }

  @Test func aCancelledPromptKeepsTheSleepDisabledRowInTheChecksStepAndCopyCommandPromptsNothing() async throws {
    let fixture = try ChecksFixture(sleepDisabled: [true], outcomes: [.cancelled])
    #expect(await fixture.reachChecks())
    #expect(await waitUntil { fixture.model.systemSleep == .sleepDisabledRow })
    fixture.pane.copyCommand()
    #expect(fixture.copied.all == ["sudo pmset -a disablesleep 0"])
    #expect(fixture.prompt.calls == 0)
    await fixture.pane.turnSleepBackOn()
    #expect(fixture.prompt.calls == 1)
    #expect(fixture.model.systemSleep == .sleepDisabledRow)
    #expect(fixture.pane.clearCaption == HelperPaneTests.cancelledCaption)
    #expect(fixture.model.defaultButton == Self.advance)
  }

  @Test func theCheckRowsUseListedSymbolsAndTheUISpecColoursAndLabels() {
    let listed = Set(SymbolAvailabilityTests.phaseThreeSymbols)
    #expect(Set(CheckRow.Icon.allCases.map(\.symbol)).isSubset(of: listed))
    #expect(OnboardingCheckRows.tint(for: .pass) == Color.green)
    #expect(OnboardingCheckRows.tint(for: .warning) == Color.orange)
    #expect(OnboardingCheckRows.tint(for: .info) == Color.secondary)
    #expect(SleepDisabledRow.symbol == CheckRow.Icon.warning.symbol)
    #expect(CheckRow.Link.allCases.map(\.label) == ["Open Lock Screen Settings", "Open Wi-Fi Settings"])
    #expect(SleepDisabledClearing.rowTitle == "Sleep is turned off system-wide (SleepDisabled)")
  }

  final class HeldHelperSource: HelperMonitoring {
    private struct State {
      var state: HelperMonitorState
      var installs = 0
      var finished = 0
      var waiting: [AsyncStream<Void>.Continuation] = []
    }

    private let stored: OSAllocatedUnfairLock<State>

    init(_ state: HelperMonitorState) {
      stored = OSAllocatedUnfairLock(initialState: State(state: state))
    }

    var installs: Int {
      stored.withLock { $0.installs }
    }

    var finished: Int {
      stored.withLock { $0.finished }
    }

    func release(with state: HelperMonitorState) {
      let waiting = stored.withLock { stored -> [AsyncStream<Void>.Continuation] in
        stored.state = state
        defer { stored.waiting = [] }
        return stored.waiting
      }
      for continuation in waiting {
        continuation.finish()
      }
    }

    func refresh() async -> HelperMonitorState {
      stored.withLock { $0.state }
    }

    func reconnect() async -> HelperMonitorState {
      stored.withLock { $0.state }
    }

    func acknowledgeRemovalFailure() -> HelperMonitorState {
      stored.withLock { $0.state }
    }

    func install() async -> HelperMonitorState {
      let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
      stored.withLock { stored in
        stored.installs += 1
        stored.waiting.append(continuation)
      }
      for await _ in stream {}
      return stored.withLock { stored in
        stored.finished += 1
        return stored.state
      }
    }

    func remove() async -> HelperMonitorState {
      stored.withLock { $0.state }
    }

    func openLoginItems() async {
    }
  }

  @MainActor struct InstallFixture {
    let onboarding: Fixture
    let installer: FakeHelperInstaller
    let connections: HelperPaneTests.EventLog
    let pane: HelperPaneModel
    let monitor: HelperMonitor

    init(status: HelperInstallerStatus = .notRegistered) throws {
      onboarding = try Fixture()
      let installer = FakeHelperInstaller(status: status)
      let connections = HelperPaneTests.EventLog()
      let client = HelperXPCClient(requirement: "anchor apple") {
        connections.append("connection")
        return NSXPCConnection(listenerEndpoint: NSXPCListener.anonymous().endpoint)
      }
      let made = HelperPaneModel.monitored(
        panel: onboarding.panel, installer: installer, port: XPCHelperPort(client: client))
      made.pane.pause = { _ in try? await Task.sleep(for: .milliseconds(20)) }
      onboarding.model.helper = made.pane
      self.installer = installer
      self.connections = connections
      pane = made.pane
      monitor = made.monitor
    }

    var model: OnboardingModel {
      onboarding.model
    }

    func reachHelperStep() async -> Bool {
      model.setWindowVisible(true)
      model.begin()
      onboarding.walk(to: .unplugProtection)
      return await waitUntil { pane.state.installer != nil }
    }
  }

  struct HelperCase: Sendable, CustomTestStringConvertible {
    let name: String
    let state: HelperMonitorState
    let shown: HelperUIState

    var testDescription: String {
      name
    }
  }

  nonisolated static let off = HelperMonitorState(installer: .notRegistered)
  nonisolated static let waitingForApproval = HelperMonitorState(installer: .requiresApproval)
  nonisolated static let stale = HelperStatus(helperVersion: 0)

  nonisolated static let helperCases = [
    HelperCase(name: "checking", state: HelperMonitorState(), shown: .checking),
    HelperCase(name: "off", state: off, shown: .off),
    HelperCase(name: "not found", state: HelperMonitorState(installer: .notFound), shown: .off),
    HelperCase(
      name: "installing", state: HelperMonitorState(installer: .notRegistered, inFlight: .installing),
      shown: .installing),
    HelperCase(name: "waiting for approval", state: waitingForApproval, shown: .waitingForApproval),
    HelperCase(name: "on", state: HelperPaneTests.standingBy, shown: .onStandingBy),
    HelperCase(
      name: "needs approval again", state: HelperMonitorState(installer: .enabled, reachability: .unreachable),
      shown: .needsApprovalAgain),
    HelperCase(
      name: "updating",
      state: HelperMonitorState(installer: .enabled, reachability: .reachable, status: stale, staleAttempts: 1),
      shown: .updating),
    HelperCase(
      name: "out of date",
      state: HelperMonitorState(installer: .enabled, reachability: .reachable, status: stale, staleAttempts: 2),
      shown: .outOfDate),
    HelperCase(
      name: "error with the helper enabled",
      state: HelperMonitorState(installer: .enabled, reachability: .reachable, lastError: "NSCocoaErrorDomain 4097"),
      shown: .error),
    HelperCase(
      name: "error after a failed install",
      state: HelperMonitorState(installer: .notRegistered, lastError: "Operation not permitted"), shown: .error),
    HelperCase(name: "removing", state: HelperMonitorState(installer: .enabled, inFlight: .removing), shown: .removing),
  ]

  @Test func theUnplugProtectionStepShowsTheFourNotesOfThePaneVerbatim() {
    #expect(
      OnboardingUnplugProtectionStep.notes == [
        "Installing it needs one approval in System Settings. While you approve it, Overtime's login item may briefly show that it needs approval too.",
        "It runs as an administrator and does one thing: it turns system sleep off while Claude works with the lid closed, and back on afterwards.",
        "While it holds the Mac on battery, macOS can't put the Mac to sleep in an emergency. The helper lets go at 10% battery or if the Mac gets too hot.",
        "Turning it off in System Settings also quits Overtime. Open Overtime again afterwards.",
      ])
    #expect(OnboardingUnplugProtectionStep.notes == UnplugProtectionPane.aboutNotes)
    #expect(
      OnboardingStep.unplugProtection.body
        == "With the lid closed, macOS can still sleep when you unplug the charger or a display, even while Claude works. Unplug protection prevents this with a small helper that runs as an administrator. You can skip it if you never unplug the charger or a display while the lid is closed, and install it later in Settings > Unplug Protection."
    )
    #expect(HelperStatusAction.install.label == "Install Unplug Protection…")
  }

  @Test func reachingTheUnplugProtectionStepRegistersNothingAndTheRowOffersTheInstallOnceTheStatusIsRead()
    async throws
  {
    let fixture = try InstallFixture()
    let model = fixture.model
    model.setWindowVisible(true)
    model.begin()
    fixture.onboarding.walk(to: .checks)
    try? await Task.sleep(for: .milliseconds(80))
    #expect(!fixture.pane.isPolling)
    #expect(fixture.installer.statusReads == 0)
    #expect(model.helperInstalled == nil)
    model.continueStep()
    #expect(model.currentStep == .unplugProtection)
    #expect(fixture.pane.isPolling)
    #expect(await waitUntil { model.helperInstalled == false })
    #expect(fixture.pane.uiState == .off)
    #expect(model.defaultButton == Self.advance)
    #expect(!model.showsSkip)
    #expect(model.helperRowActions == [.install])
    #expect(await waitUntil { fixture.installer.statusReads >= 3 })
    #expect(fixture.installer.calls.isEmpty)
    #expect(fixture.connections.all.isEmpty)
    #expect(model.inFlight == nil)
    model.performDefault()
    #expect(model.currentStep == .selfTest)
    #expect(model.results[.unplugProtection] == .done)
    #expect(fixture.installer.calls.isEmpty)
  }

  @Test func walkingEveryStepWithTheWindowOnScreenRegistersNothingAndOpensNoHelperConnection() async throws {
    let fixture = try InstallFixture()
    let model = fixture.model
    model.setWindowVisible(true)
    model.begin()
    fixture.onboarding.walk(to: .selfTest)
    #expect(model.currentStep == .selfTest)
    #expect(model.results[.unplugProtection] == .done)
    try? await Task.sleep(for: .milliseconds(100))
    #expect(fixture.installer.calls.isEmpty)
    #expect(fixture.connections.all.isEmpty)
    #expect(!fixture.pane.isPolling)
  }

  @Test func theRowsInstallRegistersOnceWhileContinueStaysTheDefault() async throws {
    let fixture = try InstallFixture()
    fixture.installer.failRegister(leaving: .requiresApproval)
    fixture.installer.holdCalls()
    defer { fixture.installer.releaseCalls() }
    #expect(await fixture.reachHelperStep())
    let model = fixture.model
    let pane = fixture.pane
    #expect(model.defaultButton == Self.advance)
    #expect(model.helperRowActions == [.install])
    let install = Task { await pane.perform(.install) }
    #expect(await waitUntil { pane.state.inFlight == .installing })
    #expect(model.defaultButton == Self.advance)
    #expect(!model.showsSkip)
    #expect(!model.backEnabled)
    #expect(model.inFlight == nil)
    #expect(model.currentStep == .unplugProtection)
    fixture.installer.releaseCalls()
    await install.value
    #expect(await waitUntil { pane.state.inFlight == nil && pane.uiState == .waitingForApproval })
    #expect(fixture.installer.calls == ["register", "openSystemSettings"])
    #expect(model.helperInstalled == true)
    #expect(model.defaultButton == Self.advance)
    #expect(!model.showsSkip)
    #expect(model.backEnabled)
    #expect(model.helperRowActions == [.openLoginItems, .remove])
    model.performDefault()
    #expect(model.currentStep == .selfTest)
    #expect(model.results[.unplugProtection] == .done)
    try? await Task.sleep(for: .milliseconds(80))
    #expect(fixture.installer.calls == ["register", "openSystemSettings"])
    #expect(fixture.connections.all.isEmpty)
    #expect(!fixture.pane.isPolling)
  }

  @Test(arguments: helperCases)
  func theDefaultButtonIsContinueInEveryHelperState(_ item: HelperCase) throws {
    let fixture = try Fixture(helper: item.state)
    fixture.model.begin()
    fixture.walk(to: .unplugProtection)
    #expect(fixture.helper.uiState == item.shown)
    #expect(fixture.model.defaultButton == Self.advance)
    #expect(!fixture.model.showsSkip)
    #expect(fixture.helperSource.actions.isEmpty)
  }

  @Test(arguments: helperCases)
  func onlyAHelperThatIsNotInstalledOffersTheInstallInItsRow(_ item: HelperCase) throws {
    let fixture = try Fixture(helper: item.state)
    fixture.model.begin()
    fixture.walk(to: .unplugProtection)
    let installing = item.state.inFlight == .installing
    #expect(fixture.helper.uiState == item.shown)
    #expect(fixture.model.helperInstalled == item.state.installer.map(\.isInstalled))
    #expect(fixture.model.defaultButton == Self.advance)
    #expect(!fixture.model.showsSkip)
    #expect(fixture.model.skipEnabled == !installing)
    #expect(fixture.model.backEnabled == !installing)
    #expect(fixture.model.context.inFlight == (installing ? .install : nil))
    #expect(fixture.model.inFlight == nil)
    #expect(fixture.model.helperRowActions == item.shown.actions)
    #expect(fixture.helperSource.actions.isEmpty)
  }

  @Test func theRowOffersItsOwnInstallOnTheStep() async throws {
    let fixture = try Fixture(helper: Self.off)
    fixture.model.begin()
    fixture.walk(to: .checks)
    #expect(fixture.model.helperRowActions == [.install])
    fixture.model.continueStep()
    #expect(fixture.model.currentStep == .unplugProtection)
    #expect(fixture.model.defaultButton == Self.advance)
    #expect(fixture.model.helperRowActions == [.install])
    await fixture.helper.perform(.install)
    #expect(fixture.helperSource.actions == ["install"])
    #expect(fixture.helper.uiState == .off)
    #expect(fixture.model.defaultButton == Self.advance)
    #expect(fixture.model.helperRowActions == [.install])
    #expect(fixture.model.currentStep == .unplugProtection)
  }

  @Test func removeInTheStepOnlyOpensTheConfirmationAndOpenLoginItemsOnlyOpensSystemSettings() async throws {
    let fixture = try Fixture(helper: Self.waitingForApproval)
    fixture.model.begin()
    fixture.walk(to: .unplugProtection)
    #expect(fixture.model.helperRowActions == [.openLoginItems, .remove])
    #expect(fixture.model.defaultButton == Self.advance)
    await fixture.helper.perform(.remove)
    #expect(fixture.helper.confirmingRemove)
    #expect(fixture.helperSource.actions.isEmpty)
    fixture.helper.keepProtection()
    #expect(!fixture.helper.confirmingRemove)
    await fixture.helper.perform(.openLoginItems)
    #expect(fixture.helperSource.actions == ["openLoginItems"])
    #expect(fixture.model.currentStep == .unplugProtection)
  }

  @Test func whileTheRowsInstallIsInFlightBackWaitsAndContinueStaysOn() async throws {
    let held = HeldHelperSource(Self.off)
    let fixture = try Fixture()
    let pane = HelperPaneModel(panel: fixture.panel, source: held)
    pane.apply(Self.off)
    fixture.model.helper = pane
    let model = fixture.model
    model.begin()
    fixture.walk(to: .unplugProtection)
    #expect(model.defaultButton == Self.advance)
    Task { await pane.perform(.install) }
    #expect(await waitUntil { held.installs == 1 })
    pane.apply(HelperMonitorState(installer: .notRegistered, inFlight: .installing))
    try? await Task.sleep(for: .milliseconds(80))
    #expect(model.context.inFlight == .install)
    #expect(model.inFlight == nil)
    #expect(model.defaultButton == Self.advance)
    #expect(!model.showsSkip)
    #expect(!model.backEnabled)
    model.back()
    model.skipStep()
    #expect(model.currentStep == .unplugProtection)
    model.performDefault()
    #expect(model.currentStep == .selfTest)
    #expect(model.results[.unplugProtection] == .done)
    #expect(!model.backEnabled)
    model.back()
    #expect(model.currentStep == .selfTest)
    held.release(with: Self.waitingForApproval)
    #expect(await waitUntil { model.context.inFlight == nil })
    #expect(held.installs == 1)
    #expect(model.backEnabled)
    model.back()
    #expect(model.currentStep == .unplugProtection)
    #expect(pane.uiState == .waitingForApproval)
    #expect(model.defaultButton == Self.advance)
  }

  @Test func theEndOfAnInstallNeverEndsARequestThatIsInFlight() async throws {
    let held = HeldHelperSource(Self.off)
    let port = HeldRequestPort()
    let fixture = try Fixture()
    let pane = HelperPaneModel(panel: fixture.panel, source: held)
    pane.apply(Self.off)
    fixture.model.helper = pane
    fixture.model.notifications = port
    let model = fixture.model
    model.begin()
    fixture.walk(to: .unplugProtection)
    Task { await pane.perform(.install) }
    #expect(await waitUntil { held.installs == 1 })
    #expect(model.inFlight == nil)
    model.dismissed()
    model.begin()
    #expect(model.inFlight == nil)
    fixture.walk(to: .notifications)
    #expect(await waitUntil { model.notificationAuthorization == .notDetermined })
    model.performDefault()
    #expect(model.inFlight == .authorization)
    held.release(with: Self.off)
    #expect(await waitUntil { held.finished == 1 })
    try? await Task.sleep(for: .milliseconds(80))
    #expect(model.inFlight == .authorization)
    port.answer(.authorized)
    #expect(await waitUntil { model.inFlight == nil })
    #expect(port.requests == 1)
  }

  @Test func anInstallThatOutlivesAClosedWindowKeepsBackOffInTheNextRunUntilItEnds() async throws {
    let fixture = try InstallFixture()
    fixture.installer.failRegister(leaving: .requiresApproval)
    fixture.installer.holdCalls()
    defer { fixture.installer.releaseCalls() }
    #expect(await fixture.reachHelperStep())
    let model = fixture.model
    let pane = fixture.pane
    Task { await pane.perform(.install) }
    #expect(await waitUntil { fixture.pane.state.inFlight == .installing })
    model.dismissed()
    #expect(!fixture.pane.isPolling)
    model.begin()
    #expect(model.isActive)
    #expect(model.inFlight == nil)
    #expect(model.context.inFlight == .install)
    #expect(model.context.actionInFlight)
    model.continueStep()
    #expect(model.index == 1)
    #expect(!model.backEnabled)
    model.begin()
    #expect(model.index == 1)
    #expect(fixture.installer.heldReturned == 0)
    fixture.installer.releaseCalls()
    #expect(await waitUntil { fixture.pane.state.inFlight == nil })
    #expect(model.context.inFlight == nil)
    #expect(model.backEnabled)
    #expect(fixture.installer.calls == ["register", "openSystemSettings"])
    #expect(fixture.connections.all.isEmpty)
  }

  @Test func afterTheWindowIsClosedTheStepInstallsNothing() async throws {
    let fixture = try Fixture(helper: Self.off)
    fixture.model.begin()
    fixture.walk(to: .unplugProtection)
    #expect(fixture.model.defaultButton == Self.advance)
    fixture.model.dismissed()
    fixture.model.performDefault()
    try? await Task.sleep(for: .milliseconds(50))
    #expect(fixture.helperSource.actions.isEmpty)
    #expect(fixture.model.inFlight == nil)
    #expect(fixture.model.currentStep == .unplugProtection)
    #expect(fixture.model.results[.unplugProtection] == nil)
  }

  @Test func theHelperStatusIsPolledOnlyWhileTheUnplugProtectionStepIsOnScreen() async throws {
    let fixture = try Fixture(helper: Self.off)
    let model = fixture.model
    model.setWindowVisible(true)
    #expect(!fixture.helper.isPolling)
    model.begin()
    fixture.walk(to: .checks)
    try? await Task.sleep(for: .milliseconds(80))
    #expect(!fixture.helper.isPolling)
    #expect(fixture.helperSource.refreshes == 0)
    model.continueStep()
    #expect(model.currentStep == .unplugProtection)
    #expect(fixture.helper.isPolling)
    #expect(await waitUntil { fixture.helperSource.refreshes >= 2 })
    model.continueStep()
    #expect(model.currentStep == .selfTest)
    #expect(!fixture.helper.isPolling)
    #expect(await fixture.pollsStopped())
    model.back()
    #expect(fixture.helper.isPolling)
    model.setWindowVisible(false)
    #expect(!fixture.helper.isPolling)
    #expect(await fixture.pollsStopped())
    model.setWindowVisible(true)
    #expect(fixture.helper.isPolling)
    model.back()
    #expect(model.currentStep == .checks)
    #expect(!fixture.helper.isPolling)
    model.continueStep()
    #expect(fixture.helper.isPolling)
    model.dismissed()
    #expect(!fixture.helper.isPolling)
    #expect(await fixture.pollsStopped())
    model.setWindowVisible(false)
    model.setWindowVisible(true)
    #expect(!fixture.helper.isPolling)
    #expect(fixture.helperSource.actions.isEmpty)
  }

  @Test func aWindowThatIsNotOnScreenNeverPollsTheHelper() async throws {
    let fixture = try Fixture(helper: Self.off)
    fixture.model.begin()
    fixture.walk(to: .unplugProtection)
    try? await Task.sleep(for: .milliseconds(80))
    #expect(!fixture.helper.isPolling)
    #expect(fixture.helperSource.refreshes == 0)
    fixture.model.setWindowVisible(true)
    #expect(fixture.helper.isPolling)
    #expect(await waitUntil { fixture.helperSource.refreshes >= 1 })
  }

  @Test func runningOnboardingAgainStopsThePollUntilTheStepIsReachedAgain() async throws {
    let fixture = try Fixture(helper: Self.waitingForApproval)
    let model = fixture.model
    model.setWindowVisible(true)
    model.begin()
    fixture.walk(to: .unplugProtection)
    #expect(fixture.helper.isPolling)
    model.begin()
    #expect(model.currentStep == .welcome)
    #expect(!fixture.helper.isPolling)
    #expect(await fixture.pollsStopped())
    fixture.walk(to: .unplugProtection)
    #expect(fixture.helper.isPolling)
  }

  @Test func theSettingsPaneKeepsItsOwnPollWhenTheStepIsLeft() async throws {
    let fixture = try Fixture(helper: Self.off)
    let settingsPane = ObjectIdentifier(NSObject.self)
    let model = fixture.model
    model.setWindowVisible(true)
    model.begin()
    fixture.helper.setVisible(true, host: settingsPane)
    #expect(fixture.helper.isPolling)
    fixture.walk(to: .unplugProtection)
    #expect(fixture.helper.isPolling)
    model.continueStep()
    #expect(fixture.helper.isPolling)
    fixture.helper.setVisible(false, host: settingsPane)
    #expect(!fixture.helper.isPolling)
    model.back()
    #expect(fixture.helper.isPolling)
    fixture.helper.setVisible(true, host: settingsPane)
    model.dismissed()
    #expect(fixture.helper.isPolling)
    fixture.helper.setVisible(false, host: settingsPane)
    #expect(!fixture.helper.isPolling)
  }

  @Test func withoutAHelperPaneTheStepShowsOnlyItsNotesAndContinue() throws {
    let fixture = try Fixture()
    fixture.model.helper = nil
    fixture.model.setWindowVisible(true)
    fixture.model.begin()
    fixture.walk(to: .unplugProtection)
    #expect(fixture.model.helperInstalled == nil)
    #expect(fixture.model.defaultButton == Self.advance)
    #expect(!fixture.model.showsSkip)
    #expect(fixture.model.helperRowActions.isEmpty)
    #expect(fixture.model.context.inFlight == nil)
    #expect(fixture.model.systemSleep == .nothing)
    #expect(OnboardingUnplugProtectionStep.notes.count == 4)
    fixture.model.performDefault()
    #expect(fixture.model.currentStep == .selfTest)
    #expect(fixture.model.results[.unplugProtection] == .done)
  }

  @Test func eachStepChangeAsksForTheFocusOnTheProgressElementWhoseLabelNamesTheStep() async throws {
    let fixture = try Fixture(notifications: .notDetermined)
    let model = fixture.model
    #expect(model.stepChanges == 0)
    model.back()
    model.performDefault()
    #expect(model.stepChanges == 0)
    model.begin()
    #expect(model.stepChanges == 1)
    #expect(model.progressAccessibilityLabel == "Step 1 of 7, Welcome to Overtime")
    model.back()
    model.skipStep()
    model.refreshStep()
    #expect(model.stepChanges == 1)
    model.performDefault()
    #expect(model.stepChanges == 2)
    #expect(model.progressAccessibilityLabel == "Step 2 of 7, Launch at login")
    model.back()
    #expect(model.stepChanges == 3)
    #expect(model.progressAccessibilityLabel == "Step 1 of 7, Welcome to Overtime")
    model.continueStep()
    model.continueStep()
    #expect(model.stepChanges == 5)
    #expect(model.progressAccessibilityLabel == "Step 3 of 7, Notifications")
    #expect(await waitUntil { model.notificationAuthorization == .notDetermined })
    model.refreshStep()
    #expect(model.stepChanges == 5)
    model.skipStep()
    #expect(model.stepChanges == 6)
    #expect(model.progressAccessibilityLabel == "Step 4 of 7, iPhone hotspot (optional)")
    model.begin()
    #expect(model.stepChanges == 7)
    #expect(model.progressAccessibilityLabel == "Step 1 of 7, Welcome to Overtime")
    model.dismissed()
    model.performDefault()
    model.continueStep()
    #expect(model.stepChanges == 7)
  }

  @Test func theProgressElementNamesEveryStep() throws {
    let fixture = try Fixture()
    let titles = [
      "Welcome to Overtime", "Launch at login", "Notifications", "iPhone hotspot (optional)",
      "Recommended macOS settings",
      "Unplug protection (optional)", "Setup complete",
    ]
    fixture.model.begin()
    var spoken = [fixture.model.progressAccessibilityLabel]
    for _ in 1..<7 {
      fixture.model.continueStep()
      spoken.append(fixture.model.progressAccessibilityLabel)
    }
    #expect(spoken == titles.enumerated().map { "Step \($0.offset + 1) of 7, \($0.element)" })
    #expect(fixture.model.stepChanges == 7)
  }
}
