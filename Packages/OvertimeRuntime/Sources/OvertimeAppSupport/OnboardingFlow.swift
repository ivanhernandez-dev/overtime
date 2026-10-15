import Foundation
import OvertimeCore
import OvertimeSystem

public enum OnboardingStep: String, Sendable, Equatable, CaseIterable, Identifiable {
  case welcome
  case launchAtLogin
  case notifications
  case location
  case checks
  case unplugProtection
  case selfTest

  public var id: Self { self }

  public var title: String {
    switch self {
    case .welcome: "Welcome to Overtime"
    case .launchAtLogin: "Start at login"
    case .notifications: "Notifications"
    case .location: "Location (optional)"
    case .checks: "Check your setup"
    case .unplugProtection: "Unplug protection (optional)"
    case .selfTest: "Test keep-awake"
    }
  }

  public var symbol: String {
    switch self {
    case .welcome: "laptopcomputer"
    case .launchAtLogin: "power"
    case .notifications: "bell.badge"
    case .location: "location"
    case .checks: "checklist"
    case .unplugProtection: "powerplug"
    case .selfTest: "checkmark.seal"
    }
  }

  public var body: String {
    switch self {
    case .welcome:
      "Overtime keeps your Mac awake while Claude Code works, and lets it sleep when the work is done."
    case .launchAtLogin:
      "Overtime needs to be running to keep the Mac awake. Starting it at login means you never have to remember."
    case .notifications:
      "Overtime notifies you only when you need to act: when keep-awake fails, when the battery is too low to keep going, once when you open the lid if something happened, and when \(ControlMapping.keepAwakeLabel) is left on. You can turn off each kind in Settings."
    case .location:
      "Location is optional. Hotspot failover works without it, but with Location access, Overtime can find and join your iPhone hotspot directly. Overtime never stores or sends your location."
    case .checks:
      "A few macOS settings affect how well Overtime works."
    case .unplugProtection:
      "With the lid closed, macOS can still sleep when you unplug the charger or a display, even while Claude works. Unplug protection prevents this with a small helper that runs as an administrator."
    case .selfTest:
      "Overtime briefly turns its lid-close control on and off to check that it works on this Mac. The display and the Mac are not affected. \(OnboardingFlow.finishHint)"
    }
  }
}

public struct OnboardingWelcomeRow: Sendable, Equatable, Identifiable {
  public let symbol: String
  public let text: String

  public var id: String { symbol }
}

public enum OnboardingStepResult: String, Sendable, Equatable {
  case done
  case skipped
}

public enum OnboardingInFlight: Sendable, Equatable {
  case authorization
  case install
}

public enum OnboardingDefaultAction: Sendable, Equatable {
  case advance
  case allowNotifications
  case allowLocation
  case installHelper
  case finish
}

public struct OnboardingButton: Sendable, Equatable {
  public let title: String
  public let action: OnboardingDefaultAction
  public let enabled: Bool

  public init(title: String, action: OnboardingDefaultAction, enabled: Bool = true) {
    self.title = title
    self.action = action
    self.enabled = enabled
  }
}

public enum OnboardingDot: Sendable, Equatable {
  case completed
  case current
  case upcoming
}

public struct OnboardingContext: Sendable, Equatable {
  public var notifications: NotificationAuthorization?
  public var location: LocationAuthorization?
  public var loginItem: LoginItemStatus?
  public var helperInstalled: Bool?
  public var installPressed: Bool
  public var inFlight: OnboardingInFlight?
  public var selfTest: SelfTestStatus

  public init(
    notifications: NotificationAuthorization? = nil, location: LocationAuthorization? = nil,
    loginItem: LoginItemStatus? = nil, helperInstalled: Bool? = nil, installPressed: Bool = false,
    inFlight: OnboardingInFlight? = nil, selfTest: SelfTestStatus = .notRun
  ) {
    self.notifications = notifications
    self.location = location
    self.loginItem = loginItem
    self.helperInstalled = helperInstalled
    self.installPressed = installPressed
    self.inFlight = inFlight
    self.selfTest = selfTest
  }

  public var actionInFlight: Bool {
    inFlight != nil || selfTest == .running
  }
}

public enum OnboardingRecordState: Sendable, Equatable {
  case missing
  case recorded(OnboardingRecord)
  case unreadable
}

public enum OnboardingFlow {
  public static let version = 1

  public static let continueLabel = "Continue"
  public static let backLabel = "Back"
  public static let skipLabel = "Skip This Step"
  public static let finishLabel = "Finish Setup"
  public static let finishHint = "Overtime lives in the menu bar. \(finishLabel) opens it."
  public static let allowNotificationsLabel = "Allow Notifications"
  public static let allowLocationLabel = "Allow Location Access"
  public static let installHelperLabel = "Install Unplug Protection…"
  public static let selfTestFailedCaption = "You can finish setup. Overtime shows an error until the test passes."

  public static let welcomeRows = [
    OnboardingWelcomeRow(
      symbol: "terminal", text: "It notices when Claude Code works in a terminal, an editor or a subagent."),
    OnboardingWelcomeRow(
      symbol: "sun.max.fill",
      text: "While Claude works, the Mac doesn't sleep on its own, with the lid open or closed."),
    OnboardingWelcomeRow(
      symbol: "moon.zzz", text: "When Claude finishes, or if Overtime stops, the Mac sleeps normally again."),
  ]

  public static func progressLabel(step: OnboardingStep, in steps: [OnboardingStep]) -> String {
    "Step \((steps.firstIndex(of: step) ?? 0) + 1) of \(steps.count)"
  }

  public static func accessibilityLabel(step: OnboardingStep, in steps: [OnboardingStep]) -> String {
    "\(progressLabel(step: step, in: steps)), \(step.title)"
  }

  public static func dots(current: OnboardingStep, in steps: [OnboardingStep]) -> [OnboardingDot] {
    let index = steps.firstIndex(of: current) ?? 0
    return steps.indices.map { $0 < index ? .completed : $0 == index ? .current : .upcoming }
  }

  public static func showsBack(step: OnboardingStep, in steps: [OnboardingStep]) -> Bool {
    step != steps.first
  }

  public static func backEnabled(context: OnboardingContext) -> Bool {
    !context.actionInFlight
  }

  public static func skipAllowed(step: OnboardingStep, context: OnboardingContext) -> Bool {
    switch step {
    case .welcome, .launchAtLogin, .checks, .selfTest:
      false
    case .notifications:
      context.notifications == .notDetermined
    case .location:
      context.location == .notDetermined
    case .unplugProtection:
      context.helperInstalled == false && !context.installPressed
    }
  }

  public static func skipEnabled(context: OnboardingContext) -> Bool {
    !context.actionInFlight
  }

  public static func defaultButton(step: OnboardingStep, context: OnboardingContext) -> OnboardingButton {
    let advance = OnboardingButton(title: continueLabel, action: .advance)
    let idle = context.inFlight == nil
    switch step {
    case .welcome, .launchAtLogin, .checks:
      return advance
    case .notifications:
      guard context.notifications == .notDetermined else { return advance }
      return OnboardingButton(title: allowNotificationsLabel, action: .allowNotifications, enabled: idle)
    case .location:
      guard context.location == .notDetermined else { return advance }
      return OnboardingButton(title: allowLocationLabel, action: .allowLocation, enabled: idle)
    case .unplugProtection:
      guard context.helperInstalled == false, !context.installPressed else { return advance }
      return OnboardingButton(title: installHelperLabel, action: .installHelper, enabled: idle)
    case .selfTest:
      return OnboardingButton(title: finishLabel, action: .finish, enabled: context.selfTest != .running)
    }
  }

  public static func shownSelfTest(
    status: SelfTestStatus, runs: UInt64, runsAtEntry: UInt64, requesting: Bool, requested: Bool
  ) -> SelfTestStatus {
    if requesting || status == .running { return .running }
    if runs > runsAtEntry { return status }
    if requested, case .skipped = status { return status }
    return .waiting
  }

  public static func record(
    outcome: OnboardingOutcome, results: [OnboardingStep: OnboardingStepResult], at: Date
  ) -> OnboardingRecord {
    OnboardingRecord(
      version: version, outcome: outcome,
      steps: Dictionary(uniqueKeysWithValues: results.map { ($0.key.rawValue, $0.value.rawValue) }), at: at)
  }

  public static func recordState(at url: URL) -> OnboardingRecordState {
    let data: Data
    switch PrivateFile.read(at: url.path(percentEncoded: false), maxBytes: AppPreferencesStore.maxFileBytes) {
    case .data(let contents): data = contents
    case .missing: return .missing
    case .notRegular, .tooLarge, .failed: return .unreadable
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return (try? decoder.decode(StoredRecord.self, from: data))?.state ?? .unreadable
  }

  private struct StoredRecord: Decodable {
    let state: OnboardingRecordState

    enum CodingKeys: String, CodingKey {
      case onboarding
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      if try !container.contains(.onboarding) || container.decodeNil(forKey: .onboarding) {
        state = .missing
      } else {
        state = (try? container.decode(OnboardingRecord.self, forKey: .onboarding)).map { .recorded($0) } ?? .unreadable
      }
    }
  }

  public static func shouldOpen(record: OnboardingRecordState) -> Bool {
    record == .missing
  }
}
