import Foundation
import os

public final class AssertionRegistry: Sendable {
  public static let shared = AssertionRegistry()

  private let ids = OSAllocatedUnfairLock<[AssertionKind: UInt32]>(initialState: [:])

  public init() {}

  public func record(_ kind: AssertionKind, id: UInt32) {
    ids.withLock { $0[kind] = id }
  }

  @discardableResult
  public func remove(_ kind: AssertionKind, ifID id: UInt32) -> Bool {
    ids.withLock { ids in
      guard ids[kind] == id else { return false }
      ids[kind] = nil
      return true
    }
  }

  public func current(_ kind: AssertionKind) -> UInt32? {
    ids.withLock { $0[kind] }
  }

  public func snapshot() -> [(AssertionKind, UInt32)] {
    let held = ids.withLock { $0 }
    return AssertionKind.releaseOrder.compactMap { kind in held[kind].map { (kind, $0) } }
  }
}

extension AssertionKind {
  static let releaseOrder: [AssertionKind] = [.preventUserIdleSystemSleep, .preventUserIdleDisplaySleep]
}
