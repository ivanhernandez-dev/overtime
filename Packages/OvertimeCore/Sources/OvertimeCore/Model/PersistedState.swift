import Foundation

public struct PersistedPause: Codable, Sendable, Equatable {
  public static let timed = "timed"
  public static let until = "until"
  public static let indefinite = "indefinite"

  public var kind: String
  public var monoDeadlineNanoseconds: UInt64?
  public var wallDeadline: Date?

  public init(kind: String, monoDeadlineNanoseconds: UInt64? = nil, wallDeadline: Date? = nil) {
    self.kind = kind
    self.monoDeadlineNanoseconds = monoDeadlineNanoseconds
    self.wallDeadline = wallDeadline
  }

  public init?(_ pause: PauseState?) {
    switch pause {
    case .untilMono(let deadline, let wall):
      self.init(kind: Self.timed, monoDeadlineNanoseconds: deadline.nanoseconds, wallDeadline: wall)
    case .untilWall(let date):
      self.init(kind: Self.until, wallDeadline: date)
    case .indefinite:
      self.init(kind: Self.indefinite)
    case nil:
      return nil
    }
  }
}

public struct PersistedState: Codable, Sendable, Equatable {
  public static let currentVersion = 1

  public var version: Int
  public var bootSessionUUID: String?
  public var ownsHold: Bool
  public var sentinelArmed: Bool
  public var switchedToHotspot: Bool
  public var pause: PersistedPause?
  public var releaseUntilIdle: Bool
  public var forceActive: Bool
  public var hotspotJoinStarted: Bool

  public init(
    version: Int = PersistedState.currentVersion,
    bootSessionUUID: String? = nil,
    ownsHold: Bool = false,
    sentinelArmed: Bool = false,
    switchedToHotspot: Bool = false,
    pause: PersistedPause? = nil,
    releaseUntilIdle: Bool = false,
    forceActive: Bool = false,
    hotspotJoinStarted: Bool = false
  ) {
    self.version = version
    self.bootSessionUUID = bootSessionUUID
    self.ownsHold = ownsHold
    self.sentinelArmed = sentinelArmed
    self.switchedToHotspot = switchedToHotspot
    self.pause = pause
    self.releaseUntilIdle = releaseUntilIdle
    self.forceActive = forceActive
    self.hotspotJoinStarted = hotspotJoinStarted
  }
}

public enum PersistedSnapshot: Sendable, Equatable {
  case missing
  case corrupt
  case state(PersistedState)
}

public struct LaunchFacts: Sendable, Equatable {
  public var persisted: PersistedSnapshot
  public var bootSessionUUID: String?

  public init(persisted: PersistedSnapshot, bootSessionUUID: String?) {
    self.persisted = persisted
    self.bootSessionUUID = bootSessionUUID
  }
}
