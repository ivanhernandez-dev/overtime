import Foundation
import OvertimeSystem
import os

public typealias NotificationCategoryKey = String

public enum OnboardingOutcome: String, Codable, Sendable, Equatable {
  case completed
  case dismissed
}

public struct OnboardingRecord: Codable, Sendable, Equatable {
  public var version: Int
  public var outcome: OnboardingOutcome
  public var steps: [String: String]
  public var at: Date

  public init(version: Int, outcome: OnboardingOutcome, steps: [String: String], at: Date) {
    self.version = version
    self.outcome = outcome
    self.steps = steps
    self.at = at
  }
}

public enum SelfTestOutcome: String, Codable, Sendable, Equatable {
  case passed
  case failed
  case skipped
}

public struct SelfTestRecord: Codable, Sendable, Equatable {
  public var outcome: SelfTestOutcome
  public var reason: String?
  public var at: Date
  public var osBuild: String
  public var osVersion: String

  public init(outcome: SelfTestOutcome, reason: String?, at: Date, osBuild: String, osVersion: String) {
    self.outcome = outcome
    self.reason = reason
    self.at = at
    self.osBuild = osBuild
    self.osVersion = osVersion
  }
}

public struct AppPreferences: Codable, Sendable, Equatable {
  public static let categoryKeys: [NotificationCategoryKey] = [
    "keepAwakeFailed", "batteryFloor", "belowFloorAtStart", "batteryTemperature", "lidClosedSummary", "forceReminder",
  ]
  public static let forceReminderHoursRange = 1...12
  public static let defaultForceReminderHours = 3

  public var notifications: [NotificationCategoryKey: Bool]
  public var forceReminderHours: Int
  public var onboarding: OnboardingRecord?
  public var selfTest: SelfTestRecord?

  public init() {
    notifications = Dictionary(uniqueKeysWithValues: Self.categoryKeys.map { ($0, true) })
    forceReminderHours = Self.defaultForceReminderHours
    onboarding = nil
    selfTest = nil
  }

  enum CodingKeys: String, CodingKey {
    case notifications
    case forceReminderHours
    case onboarding
    case selfTest
  }

  public init(from decoder: any Decoder) throws {
    self.init()
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let stored = try? container.decodeIfPresent([String: Bool].self, forKey: .notifications) {
      notifications.merge(stored) { _, stored in stored }
    }
    if let hours = try? container.decodeIfPresent(Int.self, forKey: .forceReminderHours),
      Self.forceReminderHoursRange.contains(hours)
    {
      forceReminderHours = hours
    }
    onboarding = (try? container.decodeIfPresent(OnboardingRecord.self, forKey: .onboarding)) ?? nil
    selfTest = (try? container.decodeIfPresent(SelfTestRecord.self, forKey: .selfTest)) ?? nil
  }

  public func isEnabled(_ key: NotificationCategoryKey) -> Bool {
    notifications[key] ?? true
  }
}

public enum AppPreferencesRead: Sendable, Equatable {
  case missing
  case loaded(AppPreferences)
  case unreadable

  public var preferences: AppPreferences {
    if case .loaded(let preferences) = self { return preferences }
    return AppPreferences()
  }
}

public enum AppPreferencesStore {
  public static let maxFileBytes = 4_096

  public static func read(at url: URL) -> AppPreferencesRead {
    let data: Data
    switch PrivateFile.read(at: url.path(percentEncoded: false), maxBytes: maxFileBytes) {
    case .data(let contents): data = contents
    case .missing: return .missing
    case .notRegular, .tooLarge, .failed: return .unreadable
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let preferences = try? decoder.decode(AppPreferences.self, from: data) else { return .unreadable }
    return .loaded(preferences)
  }

  private static let updateLock = OSAllocatedUnfairLock()
  public static let unreadableSuffix = ".unreadable"

  enum Stored {
    case missing
    case loaded(AppPreferences)
    case damaged
    case readFailed
  }

  static func stored(at url: URL) -> Stored {
    let data: Data
    switch PrivateFile.read(at: url.path(percentEncoded: false), maxBytes: maxFileBytes) {
    case .data(let contents): data = contents
    case .missing: return .missing
    case .notRegular, .tooLarge: return .damaged
    case .failed: return .readFailed
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let preferences = try? decoder.decode(AppPreferences.self, from: data) else { return .damaged }
    return .loaded(preferences)
  }

  public static func asideURL(for url: URL) -> URL {
    url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + unreadableSuffix)
  }

  @discardableResult
  public static func update(at url: URL, _ change: (inout AppPreferences) -> Void) throws -> AppPreferences {
    try updateLock.withLockUnchecked {
      let record = OnboardingFlow.recordState(at: url)
      var preferences: AppPreferences
      var setAside: URL?
      switch stored(at: url) {
      case .missing:
        preferences = AppPreferences()
      case .loaded(let loaded):
        preferences = loaded
      case .readFailed:
        throw CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: url])
      case .damaged:
        let aside = asideURL(for: url)
        guard rename(url.path(percentEncoded: false), aside.path(percentEncoded: false)) == 0 else {
          throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: url])
        }
        setAside = aside
        preferences = AppPreferences()
      }
      if preferences.onboarding == nil, record == .unreadable {
        preferences.onboarding = OnboardingRecord(
          version: OnboardingFlow.version, outcome: .dismissed, steps: [:],
          at: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)))
      }
      change(&preferences)
      do {
        try write(preferences, to: url)
      } catch {
        if let setAside {
          _ = rename(setAside.path(percentEncoded: false), url.path(percentEncoded: false))
        }
        throw error
      }
      return preferences
    }
  }

  public static func write(_ preferences: AppPreferences, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(preferences)
    guard data.count <= maxFileBytes else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: url])
    }
    try data.write(to: url, options: .atomic)
    guard chmod(url.path(percentEncoded: false), 0o600) == 0 else {
      throw CocoaError(.fileWriteNoPermission, userInfo: [NSURLErrorKey: url])
    }
  }
}
