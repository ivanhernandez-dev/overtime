import Foundation

public struct UpdateReminder: Sendable, Equatable {
  public private(set) var waitingVersion: String?
  public private(set) var stagedForQuit = false

  public init() {}

  public var isWaiting: Bool {
    waitingVersion != nil
  }

  public static func sparkleShowsScheduledUpdate(immediateFocus: Bool) -> Bool {
    immediateFocus
  }

  public mutating func willShowUpdate(handledBySparkle: Bool, version: String) {
    guard !handledBySparkle else { return }
    waitingVersion = version
  }

  public mutating func userAttended() {
    waitingVersion = nil
  }

  public mutating func sessionFinished() {
    waitingVersion = nil
  }

  public mutating func noteStagedForQuit() {
    stagedForQuit = true
  }
}

public enum UpdateCheckGate {
  public static func allowsCheck(terminating: Bool, uninstalling: Bool) -> Bool {
    !terminating && !uninstalling
  }

  public static func allowsInstall(uninstalling: Bool) -> Bool {
    !uninstalling
  }
}

public enum UpdaterHost: Sendable, Equatable {
  case testHost
  case blocked
  case live
}

public enum UpdaterBuildPolicy {
  public static func buildsUpdater(host: UpdaterHost, debugBuild: Bool) -> Bool {
    host == .live && !debugBuild
  }
}
