import Foundation

public struct EffectID: Sendable, Hashable, Codable {
  public var value: UInt64

  public init(value: UInt64) {
    self.value = value
  }
}

public enum AssertionAction: Sendable, Equatable {
  case acquireOrRenew(timeoutSeconds: Int)
  case release
}

public enum ClamshellWhy: String, Sendable, Equatable {
  case engage
  case reassert
  case reassertAfterWake
  case release
  case reclaim
  case clearStale
  case watchdogLost
  case selfTest
}

public enum SentinelCommand: Sendable, Equatable {
  case arm
  case disarm
  case bye
  case respawn
}

public enum HelperAction: String, Sendable, Equatable, CaseIterable {
  case engage
  case release
  case heartbeat
}

public enum Effect: Sendable, Equatable {
  case log(Decision)
  case persist(PersistedState)
  case idleAssertion(AssertionAction, id: EffectID)
  case displayAssertion(AssertionAction, id: EffectID)
  case sentinel(SentinelCommand)
  case clamshell(on: Bool, id: EffectID, why: ClamshellWhy)
  case displaySleepNow(id: EffectID)
  case requestSleep(id: EffectID)
  case net(NetEffect)
  case helper(HelperAction, id: EffectID)
}

public enum NetEffect: Sendable, Equatable {
  case probe
  case joinHotspot(String)
  case cycleWifi
}
