import Foundation
import OvertimeAppSupport
import OvertimeCore
import Testing

struct OnboardingFlowTests {
  struct StepCopy: Sendable {
    let step: OnboardingStep
    let title: String
    let symbol: String
    let body: String
  }

  static let stepCopy = [
    StepCopy(
      step: .welcome, title: "Welcome to Overtime", symbol: "laptopcomputer",
      body: "Overtime keeps your Mac awake while Claude Code works, and lets it sleep when the work is done."),
    StepCopy(
      step: .launchAtLogin, title: "Launch at login", symbol: "power",
      body:
        "Overtime needs to be running to keep the Mac awake. Launching it at login means you never have to remember."
    ),
    StepCopy(
      step: .notifications, title: "Notifications", symbol: "bell.badge",
      body:
        "Overtime notifies you only when you need to act: when keep-awake fails, when the battery is too low to keep going, once when you open the lid if something happened, and when Keep Awake is left on. You can turn off each kind in Settings."
    ),
    StepCopy(
      step: .location, title: "iPhone hotspot (optional)", symbol: "personalhotspot",
      body:
        "If the network stops working while the lid is closed and Claude is working, Overtime can switch the Mac to your iPhone hotspot, and back when you open the lid. Choose your hotspot to turn this on, or continue without it."
    ),
    StepCopy(
      step: .checks, title: "Recommended macOS settings", symbol: "checklist",
      body:
        "A few macOS settings affect how well Overtime works. You can change them now or later, and you can finish setup either way."
    ),
    StepCopy(
      step: .unplugProtection, title: "Unplug protection (optional)", symbol: "powerplug",
      body:
        "With the lid closed, macOS can still sleep when you unplug the charger or a display, even while Claude works. Unplug protection prevents this with a small helper that runs as an administrator. You can skip it if you never unplug the charger or a display while the lid is closed, and install it later in Settings > Unplug Protection."
    ),
    StepCopy(
      step: .selfTest, title: "Setup complete", symbol: "checkmark.seal",
      body:
        "There's nothing left to do. Overtime checks on its own that it can keep this Mac awake, and the check doesn't affect the display."
    ),
  ]
  static let removedControlPhrase = "lid-close control"
  static let waitingCaption =
    "It runs each time Overtime starts, once the lid is open and Claude isn't working. The result appears under Self-test in Settings > Diagnostics."
  static let ranAt = Date(timeIntervalSince1970: 1_800_000_000)
  static let record = SelfTestRecord(outcome: .passed, reason: nil, at: ranAt, osBuild: "26A428", osVersion: "27.0")

  static let seven: [OnboardingStep] = [
    .welcome, .launchAtLogin, .notifications, .location, .checks, .unplugProtection, .selfTest,
  ]
  static let at = Date(timeIntervalSince1970: 1_800_000_000)

  @Test func theFlowHasTheSevenStepsInUISpecOrder() {
    #expect(
      OnboardingStep.allCases == [
        .welcome, .launchAtLogin, .notifications, .location, .checks, .unplugProtection, .selfTest,
      ])
  }

  @Test func theProgressLabelCountsTheStepsOfTheFlowInUse() {
    #expect(OnboardingFlow.progressLabel(step: .launchAtLogin, in: Self.seven) == "Step 2 of 7")
    #expect(OnboardingFlow.progressLabel(step: .notifications, in: Self.seven) == "Step 3 of 7")
    #expect(OnboardingFlow.progressLabel(step: .welcome, in: Self.seven) == "Step 1 of 7")
    #expect(OnboardingFlow.progressLabel(step: .selfTest, in: Self.seven) == "Step 7 of 7")
    #expect(OnboardingFlow.accessibilityLabel(step: .launchAtLogin, in: Self.seven) == "Step 2 of 7, Launch at login")
  }

  static let loginBodyWhenOn =
    "Overtime needs to be running to keep the Mac awake. Launch at login is already on, so it starts every time you log in. You can turn it off here, or later in Settings > General."
  static let loginBodyWhenOff =
    "Overtime needs to be running to keep the Mac awake. Launching it at login means you never have to remember."

  @Test func theLoginStepSaysLaunchAtLoginIsAlreadyOnWhenItIs() {
    let enabled = OnboardingContext(loginItem: .enabled)
    #expect(OnboardingFlow.body(step: .launchAtLogin, context: enabled) == Self.loginBodyWhenOn)
    for status in [LoginItemStatus.notRegistered, .notFound, .requiresApproval] {
      let context = OnboardingContext(loginItem: status)
      #expect(OnboardingFlow.body(step: .launchAtLogin, context: context) == Self.loginBodyWhenOff, "\(status)")
    }
    #expect(OnboardingFlow.body(step: .launchAtLogin, context: OnboardingContext()) == Self.loginBodyWhenOff)
    for step in OnboardingStep.allCases where step != .launchAtLogin {
      #expect(OnboardingFlow.body(step: step, context: OnboardingContext()) == step.body, "\(step)")
    }
  }

  @Test func theDotsMarkCompletedCurrentAndUpcomingSteps() {
    #expect(
      OnboardingFlow.dots(current: .launchAtLogin, in: Self.seven)
        == [.completed, .current, .upcoming, .upcoming, .upcoming, .upcoming, .upcoming])
    #expect(OnboardingFlow.dots(current: .welcome, in: Self.seven).first == .current)
    #expect(
      OnboardingFlow.dots(current: .selfTest, in: Self.seven) == Array(repeating: .completed, count: 6) + [.current])
  }

  @Test(arguments: stepCopy)
  func eachStepCarriesItsUISpecTitleIconAndBody(_ item: StepCopy) {
    #expect(item.step.title == item.title)
    #expect(item.step.symbol == item.symbol)
    #expect(item.step.body == item.body)
  }

  @Test func theTableCoversEveryStep() {
    #expect(Self.stepCopy.map(\.step) == OnboardingStep.allCases)
  }

  static let hotspotBodyNoChoice =
    "If the network stops working while the lid is closed and Claude is working, Overtime can switch the Mac to your iPhone hotspot, and back when you open the lid. Choose your hotspot to turn this on, or continue without it."
  static let hotspotBodyChosen =
    "Overtime switches the Mac to this hotspot when the network stops working while the lid is closed and Claude is working. Location access is optional: without it, failover still works, but joining your hotspot is less likely to succeed."
  static let locationRowTexts = [
    "Since macOS 14.4, apps can see the names of nearby Wi-Fi networks only with Location access, because those names can reveal where you are.",
    "Overtime uses it only to find and join your iPhone hotspot when the network stops working with the lid closed.",
    "It never reads where you are, and never stores or sends your location.",
  ]
  static let stalePhrases = ["later version", "will need", "is needed"]

  @Test func noStepSaysFailoverArrivesLaterOrThatLocationIsNeeded() {
    let chosen = OnboardingFlow.body(step: .location, context: OnboardingContext(hotspotChosen: true))
    let texts = OnboardingStep.allCases.map(\.body) + [chosen] + OnboardingFlow.locationRows.map(\.text)
    for text in texts {
      for phrase in Self.stalePhrases {
        #expect(!text.contains(phrase), "\(text)")
      }
    }
    #expect(OnboardingStep.location.title == "iPhone hotspot (optional)")
    #expect(chosen.contains("Location access is optional"))
  }

  @Test func theHotspotStepBodyFollowsTheChoice() {
    #expect(OnboardingStep.location.body == Self.hotspotBodyNoChoice)
    for location in [nil, LocationAuthorization.notDetermined, .authorized, .denied, .restricted] {
      #expect(
        OnboardingFlow.body(step: .location, context: OnboardingContext(location: location))
          == Self.hotspotBodyNoChoice)
      #expect(
        OnboardingFlow.body(step: .location, context: OnboardingContext(location: location, hotspotChosen: true))
          == Self.hotspotBodyChosen)
    }
  }

  @Test func theLocationStepSaysWhyWhatAndWhatNot() {
    #expect(OnboardingFlow.locationRows.map(\.symbol) == ["wifi", "personalhotspot", "hand.raised"])
    #expect(OnboardingFlow.locationRows.map(\.text) == Self.locationRowTexts)
    let never = OnboardingFlow.locationRows.last?.text ?? ""
    #expect(never.contains("never reads where you are"))
    #expect(never.contains("never stores or sends your location"))
  }

  @Test func theWelcomeRowsAreTheUISpecOnes() {
    #expect(OnboardingFlow.welcomeRows.map(\.symbol) == ["terminal", "sun.max.fill", "moon.zzz"])
    #expect(
      OnboardingFlow.welcomeRows.map(\.text) == [
        "It notices when Claude Code works in a terminal, an editor or a subagent.",
        "While Claude works, the Mac doesn't sleep on its own, with the lid open or closed.",
        "When Claude finishes, or if Overtime stops, the Mac sleeps normally again.",
      ])
  }

  @Test func theFooterLabelsAreTheUISpecOnes() {
    #expect(OnboardingFlow.continueLabel == "Continue")
    #expect(OnboardingFlow.backLabel == "Back")
    #expect(OnboardingFlow.skipLabel == "Skip This Step")
    #expect(OnboardingFlow.finishLabel == "Finish Setup")
    #expect(OnboardingFlow.allowNotificationsLabel == "Allow Notifications")
    #expect(OnboardingFlow.allowLocationLabel == "Allow Location Access")
    #expect(
      OnboardingFlow.selfTestFailedCaption
        == "You can still finish setup. Overtime shows an error in the menu bar until the check passes.")
  }

  @Test func theLastStepSaysWhereOvertimeLives() {
    #expect(OnboardingFlow.finishHint == "Overtime lives in the menu bar. Finish Setup opens its panel.")
    #expect(OnboardingFlow.finishHint.contains(OnboardingFlow.finishLabel))
    #expect(OnboardingFlow.finishRow.symbol == "menubar.rectangle")
    #expect(OnboardingFlow.finishRow.text == OnboardingFlow.finishHint)
    for step in OnboardingStep.allCases {
      #expect(!step.body.contains("menu bar"), "\(step)")
    }
    #expect(OnboardingStep.allCases.last == .selfTest)
  }

  static let waitingRecords: [(SelfTestRecord?, String?)] = [
    (nil, nil),
    (record, "26A428"),
    (record, "26A430"),
    (record, nil),
  ]

  @Test func theLastStepSaysAWaitingTestRunsOnItsOwn() {
    #expect(OnboardingFlow.selfTestWaitingSymbol == "info.circle")
    #expect(OnboardingFlow.selfTestWaitingTitle == "Runs on its own")
    #expect(OnboardingFlow.selfTestWaitingCaption == Self.waitingCaption)
    let expected = SelfTestRow(
      icon: .symbol("info.circle"), tone: .secondary, title: "Runs on its own", caption: Self.waitingCaption)
    for (record, build) in Self.waitingRecords {
      let row = OnboardingFlow.selfTestRow(status: .waiting, record: record, currentBuild: build)
      #expect(row == expected, "\(String(describing: record)) \(String(describing: build))")
      #expect(
        row != SelfTestPresentation.row(status: .waiting, record: record, currentBuild: build),
        "\(String(describing: build))")
    }
  }

  static let otherStatuses: [SelfTestStatus] = [
    .notRun, .running, .passed, .failed(.timedOut), .skipped(.sleepDisabled),
  ]

  @Test(arguments: otherStatuses)
  func theLastStepShowsEveryOtherStatusAsSettingsDoes(_ status: SelfTestStatus) {
    for record in [nil, Self.record] {
      #expect(
        OnboardingFlow.selfTestRow(status: status, record: record, currentBuild: "26A428")
          == SelfTestPresentation.row(status: status, record: record, currentBuild: "26A428"))
    }
  }

  @Test func theLastStepBodyNamesNoInternalControl() {
    let body = OnboardingStep.selfTest.body
    #expect(body.hasPrefix("There's nothing left to do."))
    #expect(!body.contains(Self.removedControlPhrase))
    #expect(!body.contains("self-test"))
    #expect(!body.contains("Self-test"))
  }

  @Test func theStepLabelsEqualTheLabelsOfTheSurfacesTheyComeFrom() {
    #expect(OnboardingFlow.allowLocationLabel == LocationRow.allowLabel)
    #expect(HelperStatusAction.install.label == "Install Unplug Protection…")
  }

  struct SkipCase: Sendable {
    let name: String
    let step: OnboardingStep
    let context: OnboardingContext
    let allowed: Bool
  }

  static let skipCases = [
    SkipCase(name: "welcome", step: .welcome, context: OnboardingContext(), allowed: false),
    SkipCase(
      name: "login", step: .launchAtLogin, context: OnboardingContext(loginItem: .notRegistered), allowed: false),
    SkipCase(name: "checks", step: .checks, context: OnboardingContext(), allowed: false),
    SkipCase(name: "self-test", step: .selfTest, context: OnboardingContext(), allowed: false),
    SkipCase(
      name: "notifications not determined", step: .notifications,
      context: OnboardingContext(notifications: .notDetermined), allowed: true),
    SkipCase(
      name: "notifications authorized", step: .notifications, context: OnboardingContext(notifications: .authorized),
      allowed: false),
    SkipCase(
      name: "notifications denied", step: .notifications, context: OnboardingContext(notifications: .denied),
      allowed: false),
    SkipCase(name: "notifications unread", step: .notifications, context: OnboardingContext(), allowed: false),
    SkipCase(
      name: "location not determined, no hotspot", step: .location,
      context: OnboardingContext(location: .notDetermined), allowed: false),
    SkipCase(
      name: "location authorized, no hotspot", step: .location, context: OnboardingContext(location: .authorized),
      allowed: false),
    SkipCase(
      name: "location denied, no hotspot", step: .location, context: OnboardingContext(location: .denied),
      allowed: false),
    SkipCase(name: "location unread, no hotspot", step: .location, context: OnboardingContext(), allowed: false),
    SkipCase(
      name: "location not determined, hotspot chosen", step: .location,
      context: OnboardingContext(location: .notDetermined, hotspotChosen: true), allowed: true),
    SkipCase(
      name: "location authorized, hotspot chosen", step: .location,
      context: OnboardingContext(location: .authorized, hotspotChosen: true), allowed: false),
    SkipCase(
      name: "location denied, hotspot chosen", step: .location,
      context: OnboardingContext(location: .denied, hotspotChosen: true), allowed: false),
    SkipCase(
      name: "location restricted, hotspot chosen", step: .location,
      context: OnboardingContext(location: .restricted, hotspotChosen: true), allowed: false),
    SkipCase(
      name: "location unread, hotspot chosen", step: .location, context: OnboardingContext(hotspotChosen: true),
      allowed: false),
    SkipCase(
      name: "helper not installed", step: .unplugProtection, context: OnboardingContext(helperInstalled: false),
      allowed: false),
    SkipCase(
      name: "helper not installed, install in flight", step: .unplugProtection,
      context: OnboardingContext(helperInstalled: false, inFlight: .install), allowed: false),
    SkipCase(
      name: "helper installed", step: .unplugProtection, context: OnboardingContext(helperInstalled: true),
      allowed: false),
    SkipCase(name: "helper unread", step: .unplugProtection, context: OnboardingContext(), allowed: false),
  ]

  @Test(arguments: skipCases)
  func skipIsOfferedOnlyWhereTheUISpecListsIt(_ item: SkipCase) {
    #expect(OnboardingFlow.skipAllowed(step: item.step, context: item.context) == item.allowed, "\(item.name)")
  }

  struct ButtonCase: Sendable {
    let name: String
    let step: OnboardingStep
    let context: OnboardingContext
    let button: OnboardingButton
  }

  static let advance = OnboardingButton(title: "Continue", action: .advance)

  static let buttonCases = [
    ButtonCase(name: "welcome", step: .welcome, context: OnboardingContext(), button: advance),
    ButtonCase(name: "login", step: .launchAtLogin, context: OnboardingContext(loginItem: .enabled), button: advance),
    ButtonCase(name: "checks", step: .checks, context: OnboardingContext(), button: advance),
    ButtonCase(
      name: "notifications not determined", step: .notifications,
      context: OnboardingContext(notifications: .notDetermined),
      button: OnboardingButton(title: "Allow Notifications", action: .allowNotifications)),
    ButtonCase(
      name: "notifications request in flight", step: .notifications,
      context: OnboardingContext(notifications: .notDetermined, inFlight: .authorization),
      button: OnboardingButton(title: "Allow Notifications", action: .allowNotifications, enabled: false)),
    ButtonCase(
      name: "notifications authorized", step: .notifications, context: OnboardingContext(notifications: .authorized),
      button: advance),
    ButtonCase(
      name: "notifications provisional", step: .notifications,
      context: OnboardingContext(notifications: .provisional), button: advance),
    ButtonCase(
      name: "notifications denied", step: .notifications, context: OnboardingContext(notifications: .denied),
      button: advance),
    ButtonCase(name: "notifications unread", step: .notifications, context: OnboardingContext(), button: advance),
    ButtonCase(
      name: "location not determined, no hotspot", step: .location,
      context: OnboardingContext(location: .notDetermined), button: advance),
    ButtonCase(
      name: "location request in flight, no hotspot", step: .location,
      context: OnboardingContext(location: .notDetermined, inFlight: .authorization), button: advance),
    ButtonCase(
      name: "location authorized, no hotspot", step: .location, context: OnboardingContext(location: .authorized),
      button: advance),
    ButtonCase(
      name: "location restricted, no hotspot", step: .location, context: OnboardingContext(location: .restricted),
      button: advance),
    ButtonCase(name: "location unread, no hotspot", step: .location, context: OnboardingContext(), button: advance),
    ButtonCase(
      name: "location not determined, hotspot chosen", step: .location,
      context: OnboardingContext(location: .notDetermined, hotspotChosen: true),
      button: OnboardingButton(title: "Allow Location Access", action: .allowLocation)),
    ButtonCase(
      name: "location request in flight, hotspot chosen", step: .location,
      context: OnboardingContext(location: .notDetermined, inFlight: .authorization, hotspotChosen: true),
      button: OnboardingButton(title: "Allow Location Access", action: .allowLocation, enabled: false)),
    ButtonCase(
      name: "location authorized, hotspot chosen", step: .location,
      context: OnboardingContext(location: .authorized, hotspotChosen: true), button: advance),
    ButtonCase(
      name: "location denied, hotspot chosen", step: .location,
      context: OnboardingContext(location: .denied, hotspotChosen: true), button: advance),
    ButtonCase(
      name: "location restricted, hotspot chosen", step: .location,
      context: OnboardingContext(location: .restricted, hotspotChosen: true), button: advance),
    ButtonCase(
      name: "location unread, hotspot chosen", step: .location, context: OnboardingContext(hotspotChosen: true),
      button: advance),
    ButtonCase(
      name: "helper not installed", step: .unplugProtection, context: OnboardingContext(helperInstalled: false),
      button: advance),
    ButtonCase(
      name: "helper install in flight", step: .unplugProtection,
      context: OnboardingContext(helperInstalled: false, inFlight: .install), button: advance),
    ButtonCase(
      name: "helper installed", step: .unplugProtection, context: OnboardingContext(helperInstalled: true),
      button: advance),
    ButtonCase(name: "helper unread", step: .unplugProtection, context: OnboardingContext(), button: advance),
    ButtonCase(
      name: "self-test", step: .selfTest, context: OnboardingContext(selfTest: .waiting),
      button: OnboardingButton(title: "Finish Setup", action: .finish)),
  ]

  @Test(arguments: buttonCases)
  func theDefaultButtonFollowsTheStepsTable(_ item: ButtonCase) {
    #expect(OnboardingFlow.defaultButton(step: item.step, context: item.context) == item.button, "\(item.name)")
  }

  static let selfTestStatuses: [SelfTestStatus] = [
    .notRun, .waiting, .running, .passed, .failed(.timedOut), .failed(.clamshellRefused(-5)), .skipped(.amphetamine),
    .skipped(.sleepDisabled),
  ]

  @Test(arguments: selfTestStatuses)
  func finishSetupIsOnWhateverTheCheckShows(_ status: SelfTestStatus) {
    let button = OnboardingFlow.defaultButton(step: .selfTest, context: OnboardingContext(selfTest: status))
    #expect(button.title == "Finish Setup")
    #expect(button.action == .finish)
    #expect(button.enabled)
  }

  @Test func backIsHiddenOnTheFirstStepOnly() {
    #expect(!OnboardingFlow.showsBack(step: .welcome, in: Self.seven))
    for step in Self.seven.dropFirst() {
      #expect(OnboardingFlow.showsBack(step: step, in: Self.seven))
    }
  }

  static let inFlightContexts = [
    OnboardingContext(inFlight: .install),
    OnboardingContext(inFlight: .authorization),
    OnboardingContext(selfTest: .running),
  ]

  @Test(arguments: inFlightContexts)
  func backAndSkipAreOffWhileAnActionIsInFlight(_ context: OnboardingContext) {
    #expect(context.actionInFlight)
    #expect(!OnboardingFlow.backEnabled(context: context))
    #expect(!OnboardingFlow.skipEnabled(context: context))
  }

  static let settledContexts = [
    OnboardingContext(),
    OnboardingContext(selfTest: .passed),
    OnboardingContext(selfTest: .waiting),
  ]

  @Test(arguments: settledContexts)
  func backAndSkipAreOnWhenNothingIsInFlight(_ context: OnboardingContext) {
    #expect(!context.actionInFlight)
    #expect(OnboardingFlow.backEnabled(context: context))
    #expect(OnboardingFlow.skipEnabled(context: context))
  }

  @Test(arguments: [NotificationAuthorization.authorized, .provisional])
  func theNotificationsStepWithNotificationsAllowedShowsOnlyContinue(_ status: NotificationAuthorization) {
    let context = OnboardingContext(notifications: status)
    #expect(OnboardingFlow.defaultButton(step: .notifications, context: context) == Self.advance)
    #expect(!OnboardingFlow.skipAllowed(step: .notifications, context: context))
    #expect(OnboardingFlow.backEnabled(context: context))
  }

  @Test func finishSetupWritesCompletedWithVersionOneAndEveryStepResult() {
    let record = OnboardingFlow.record(
      outcome: .completed, results: [.welcome: .done, .notifications: .skipped, .selfTest: .done], at: Self.at)
    #expect(OnboardingFlow.version == 1)
    #expect(
      record
        == OnboardingRecord(
          version: 1, outcome: .completed, steps: ["welcome": "done", "notifications": "skipped", "selfTest": "done"],
          at: Self.at))
  }

  @Test func closingWritesDismissedWithVersionOne() {
    let record = OnboardingFlow.record(outcome: .dismissed, results: [.welcome: .done], at: Self.at)
    #expect(record == OnboardingRecord(version: 1, outcome: .dismissed, steps: ["welcome": "done"], at: Self.at))
    #expect(
      OnboardingFlow.record(outcome: .dismissed, results: [:], at: Self.at)
        == OnboardingRecord(version: 1, outcome: .dismissed, steps: [:], at: Self.at))
  }

  @Test func continueRecordsDoneAndSkipRecordsSkipped() {
    #expect(OnboardingStepResult.done.rawValue == "done")
    #expect(OnboardingStepResult.skipped.rawValue == "skipped")
    #expect(
      Self.seven.map(\.rawValue) == [
        "welcome", "launchAtLogin", "notifications", "location", "checks", "unplugProtection", "selfTest",
      ])
  }

  struct ShownCase: Sendable {
    let status: SelfTestStatus
    let requesting: Bool
    let shown: SelfTestStatus
  }

  static let shownCases = [
    ShownCase(status: .notRun, requesting: false, shown: .waiting),
    ShownCase(status: .waiting, requesting: false, shown: .waiting),
    ShownCase(status: .running, requesting: false, shown: .running),
    ShownCase(status: .passed, requesting: true, shown: .running),
    ShownCase(status: .notRun, requesting: true, shown: .running),
    ShownCase(status: .passed, requesting: false, shown: .passed),
    ShownCase(status: .failed(.watchdogNotRunning), requesting: false, shown: .failed(.watchdogNotRunning)),
    ShownCase(status: .skipped(.sleepDisabled), requesting: false, shown: .skipped(.sleepDisabled)),
  ]

  @Test(arguments: shownCases)
  func theLastStepShowsTheLatestResultOfThisLaunch(_ item: ShownCase) {
    #expect(
      OnboardingFlow.shownSelfTest(status: item.status, requesting: item.requesting) == item.shown,
      "\(item.status) \(item.requesting)")
  }

  @Test func withNoRecordOnboardingOpens() throws {
    let temp = try TempDirectory()
    let file = temp.url.appendingPathComponent("preferences.json")
    #expect(OnboardingFlow.recordState(at: file) == .missing)
    #expect(OnboardingFlow.shouldOpen(record: .missing))
    #expect(OnboardingFlow.shouldOpen(record: OnboardingFlow.recordState(at: file)))
    var preferences = AppPreferences()
    preferences.forceReminderHours = 5
    try AppPreferencesStore.write(preferences, to: file)
    #expect(OnboardingFlow.recordState(at: file) == .missing)
    #expect(OnboardingFlow.shouldOpen(record: OnboardingFlow.recordState(at: file)))
  }

  static func stored(_ outcome: OnboardingOutcome, version: Int) -> OnboardingRecord {
    OnboardingRecord(version: version, outcome: outcome, steps: ["welcome": "done"], at: at)
  }

  static func plant(_ text: String, at url: URL) throws {
    try Data(text.utf8).write(to: url)
  }

  struct StoredCase: Sendable {
    let name: String
    let outcome: OnboardingOutcome
    let version: Int
  }

  static let storedCases = [
    StoredCase(name: "completed", outcome: .completed, version: 1),
    StoredCase(name: "dismissed", outcome: .dismissed, version: 1),
    StoredCase(name: "completed by an older version", outcome: .completed, version: 0),
    StoredCase(name: "dismissed by an older version", outcome: .dismissed, version: 0),
    StoredCase(name: "completed by a newer version", outcome: .completed, version: 2),
  ]

  @Test(arguments: storedCases)
  func anyStoredRecordKeepsOnboardingClosed(_ item: StoredCase) throws {
    let temp = try TempDirectory()
    let file = temp.url.appendingPathComponent("preferences.json")
    let record = Self.stored(item.outcome, version: item.version)
    try AppPreferencesStore.update(at: file) { $0.onboarding = record }
    #expect(OnboardingFlow.recordState(at: file) == .recorded(record), "\(item.name)")
    #expect(!OnboardingFlow.shouldOpen(record: OnboardingFlow.recordState(at: file)), "\(item.name)")
    #expect(!OnboardingFlow.shouldOpen(record: .recorded(record)), "\(item.name)")
  }

  @Test func onlyAMissingRecordOpensOnboarding() {
    #expect(OnboardingFlow.shouldOpen(record: .missing))
    #expect(!OnboardingFlow.shouldOpen(record: .unreadable))
    #expect(!OnboardingFlow.shouldOpen(record: .recorded(Self.stored(.completed, version: 1))))
    #expect(!OnboardingFlow.shouldOpen(record: .recorded(Self.stored(.dismissed, version: 1))))
  }

  static let unreadableFiles = [
    "not json at all",
    "",
    "[]",
    "{\"onboarding\": {\"version\": 1",
  ]

  @Test(arguments: unreadableFiles)
  func anUnreadableFileKeepsOnboardingClosed(_ text: String) throws {
    let temp = try TempDirectory()
    let file = temp.url.appendingPathComponent("preferences.json")
    try Self.plant(text, at: file)
    #expect(AppPreferencesStore.read(at: file) == .unreadable)
    #expect(OnboardingFlow.recordState(at: file) == .unreadable)
    #expect(!OnboardingFlow.shouldOpen(record: OnboardingFlow.recordState(at: file)))
  }

  @Test func aFileOverTheSizeCapOrThatIsNotARegularFileKeepsOnboardingClosed() throws {
    let temp = try TempDirectory()
    let large = temp.url.appendingPathComponent("large.json")
    try Self.plant(
      "{\"padding\": \"" + String(repeating: "x", count: AppPreferencesStore.maxFileBytes) + "\"}", at: large)
    #expect(OnboardingFlow.recordState(at: large) == .unreadable)
    let folder = temp.url.appendingPathComponent("preferences.json", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    #expect(OnboardingFlow.recordState(at: folder) == .unreadable)
    let target = temp.url.appendingPathComponent("target.json")
    try Self.plant("{}", at: target)
    let link = temp.url.appendingPathComponent("link.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    #expect(OnboardingFlow.recordState(at: target) == .missing)
    #expect(OnboardingFlow.recordState(at: link) == .unreadable)
    #expect(!OnboardingFlow.shouldOpen(record: OnboardingFlow.recordState(at: link)))
  }

  static let unreadableRecords = [
    "{\"onboarding\": 5}",
    "{\"onboarding\": \"completed\"}",
    "{\"onboarding\": {}}",
    "{\"onboarding\": {\"version\": \"one\", \"outcome\": \"completed\", \"steps\": {}, \"at\": \"2027-01-15T08:00:00Z\"}}",
    "{\"onboarding\": {\"version\": 1, \"outcome\": \"abandoned\", \"steps\": {}, \"at\": \"2027-01-15T08:00:00Z\"}}",
    "{\"forceReminderHours\": 5, \"onboarding\": {\"version\": 1, \"outcome\": \"completed\", \"steps\": {}}}",
  ]

  @Test(arguments: unreadableRecords)
  func aRecordThatIsThereButCannotBeReadKeepsOnboardingClosed(_ text: String) throws {
    let temp = try TempDirectory()
    let file = temp.url.appendingPathComponent("preferences.json")
    try Self.plant(text, at: file)
    #expect(AppPreferencesStore.read(at: file).preferences.onboarding == nil)
    #expect(OnboardingFlow.recordState(at: file) == .unreadable)
    #expect(!OnboardingFlow.shouldOpen(record: OnboardingFlow.recordState(at: file)))
  }

  @Test func aFileWithNoRecordOrANullRecordStillOpensOnboarding() throws {
    let temp = try TempDirectory()
    let file = temp.url.appendingPathComponent("preferences.json")
    for text in ["{}", "{\"onboarding\": null}", "{\"forceReminderHours\": 5, \"selfTest\": 3}"] {
      try Self.plant(text, at: file)
      #expect(OnboardingFlow.recordState(at: file) == .missing, "\(text)")
      #expect(OnboardingFlow.shouldOpen(record: OnboardingFlow.recordState(at: file)), "\(text)")
    }
  }

  @Test func aRecordWrittenOverAnUnreadableRecordIsReadAgain() throws {
    let temp = try TempDirectory()
    let file = temp.url.appendingPathComponent("preferences.json")
    try Self.plant("{\"forceReminderHours\": 5, \"onboarding\": 5}", at: file)
    #expect(OnboardingFlow.recordState(at: file) == .unreadable)
    let record = Self.stored(.dismissed, version: 1)
    let written = try AppPreferencesStore.update(at: file) { $0.onboarding = record }
    #expect(written.forceReminderHours == 5)
    #expect(OnboardingFlow.recordState(at: file) == .recorded(record))
  }
}
