import Foundation
import OvertimeCore

public protocol NetworkPort: Sendable {
  func facts(lidClosed: Bool?) -> NetworkFacts?
  func autoDetectInUse(_ inUse: Bool)
  func probe() -> Bool
  func joinHotspot(_ name: String) -> EffectOutcome
  func cycleWifi() -> EffectOutcome
  func recoverIfLeftOff() -> EffectOutcome
  func recoverIfLeftOff(waitSeconds: Double) -> EffectOutcome
  func attachLog(_ log: @escaping @Sendable (Decision) -> Void)
}

extension NetworkPort {
  public func attachLog(_ log: @escaping @Sendable (Decision) -> Void) {}

  public func recoverIfLeftOff(waitSeconds: Double) -> EffectOutcome {
    recoverIfLeftOff()
  }
}

public struct NoNetworkPort: NetworkPort {
  public static let disabledCode: Int32 = -1

  public init() {}

  public func facts(lidClosed: Bool?) -> NetworkFacts? {
    nil
  }

  public func autoDetectInUse(_ inUse: Bool) {}

  public func probe() -> Bool {
    false
  }

  public func joinHotspot(_ name: String) -> EffectOutcome {
    .failed(code: Self.disabledCode)
  }

  public func cycleWifi() -> EffectOutcome {
    .failed(code: Self.disabledCode)
  }

  public func recoverIfLeftOff() -> EffectOutcome {
    .succeeded
  }
}
