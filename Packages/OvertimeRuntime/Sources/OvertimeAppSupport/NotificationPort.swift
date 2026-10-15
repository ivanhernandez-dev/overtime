import Foundation

public enum NotificationCategory: String, CaseIterable, Sendable, Hashable {
  case keepAwakeFailed
  case batteryFloor
  case belowFloorAtStart
  case lidClosedSummary
  case forceReminder

  public static let identifierPrefix = "overtime."

  public var identifier: String {
    Self.identifierPrefix + rawValue
  }

  public var preferenceKey: NotificationCategoryKey {
    rawValue
  }

  public init?(identifier: String) {
    guard identifier.hasPrefix(Self.identifierPrefix) else { return nil }
    self.init(rawValue: String(identifier.dropFirst(Self.identifierPrefix.count)))
  }
}

public enum NotificationAuthorization: Sendable, Equatable {
  case notDetermined
  case denied
  case authorized
  case provisional

  public var allowsPosting: Bool {
    self == .authorized || self == .provisional
  }
}

public struct NotificationIntent: Sendable, Equatable {
  public var category: NotificationCategory
  public var title: String
  public var body: String
  public var sound: Bool
  public var turnOffAction: Bool

  public init(category: NotificationCategory, title: String, body: String, sound: Bool, turnOffAction: Bool = false) {
    self.category = category
    self.title = title
    self.body = body
    self.sound = sound
    self.turnOffAction = turnOffAction
  }

  public var identifier: String {
    category.identifier
  }

  public var threadIdentifier: String {
    category.identifier
  }
}

public protocol NotificationPort: Sendable {
  func authorization() async -> NotificationAuthorization
  func requestAuthorization() async -> NotificationAuthorization
  func post(_ intent: NotificationIntent) async -> Bool
}
