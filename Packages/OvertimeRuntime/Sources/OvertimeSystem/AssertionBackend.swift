import Foundation
import IOKit
import IOKit.pwr_mgt
import OvertimeCore
import os

public enum AssertionKind: Sendable, Equatable, Hashable {
  case preventUserIdleSystemSleep
  case preventUserIdleDisplaySleep
}

public protocol AssertionPort: Sendable {
  func acquireOrRenew(_ kind: AssertionKind, timeoutSeconds: Int) -> EffectOutcome
  func release(_ kind: AssertionKind) -> EffectOutcome
}

public protocol AssertionSyscalls: Sendable {
  func create(_ kind: AssertionKind, name: String) -> (result: Int32, id: UInt32)
  func setTimeout(_ id: UInt32, seconds: Int) -> Int32
  func setReleaseOnTimeout(_ id: UInt32) -> Int32
  func release(_ id: UInt32) -> Int32
}

public struct RealAssertionSyscalls: AssertionSyscalls {
  public init() {}

  public func create(_ kind: AssertionKind, name: String) -> (result: Int32, id: UInt32) {
    let type: String
    switch kind {
    case .preventUserIdleSystemSleep: type = kIOPMAssertPreventUserIdleSystemSleep
    case .preventUserIdleDisplaySleep: type = kIOPMAssertPreventUserIdleDisplaySleep
    }
    var id: IOPMAssertionID = 0
    let result = IOPMAssertionCreateWithName(
      type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), name as CFString, &id)
    return (result, id)
  }

  public func setTimeout(_ id: UInt32, seconds: Int) -> Int32 {
    IOPMAssertionSetProperty(id, kIOPMAssertionTimeoutKey as CFString, seconds as CFNumber)
  }

  public func setReleaseOnTimeout(_ id: UInt32) -> Int32 {
    IOPMAssertionSetProperty(
      id, kIOPMAssertionTimeoutActionKey as CFString, kIOPMAssertionTimeoutActionRelease as CFString)
  }

  public func release(_ id: UInt32) -> Int32 {
    IOPMAssertionRelease(id)
  }
}

public final class IOPMAssertionBackend: AssertionPort, Sendable {
  public static let assertionName = "Overtime: Claude Code is working"
  public static let lockBusyCode: Int32 = -4
  static let success: Int32 = 0

  private let syscalls: any AssertionSyscalls
  private let lockWaitSeconds: Double
  private let serial = NSLock()
  private let registry: AssertionRegistry

  public init(
    syscalls: any AssertionSyscalls,
    registry: AssertionRegistry = AssertionRegistry(),
    lockWaitSeconds: Double = Timing.systemCallTimeoutSeconds
  ) {
    self.syscalls = syscalls
    self.registry = registry
    self.lockWaitSeconds = lockWaitSeconds
  }

  private func serialized(_ body: () -> EffectOutcome) -> EffectOutcome {
    guard serial.lock(before: Date(timeIntervalSinceNow: lockWaitSeconds)) else {
      return .failed(code: Self.lockBusyCode)
    }
    defer { serial.unlock() }
    return body()
  }

  public func acquireOrRenew(_ kind: AssertionKind, timeoutSeconds: Int) -> EffectOutcome {
    serialized {
      if let id = registry.current(kind) {
        if syscalls.setTimeout(id, seconds: timeoutSeconds) == Self.success {
          return .succeeded
        }
        registry.remove(kind, ifID: id)
      }
      let created = syscalls.create(kind, name: Self.assertionName)
      guard created.result == Self.success else { return .failed(code: created.result) }
      let timeout = syscalls.setTimeout(created.id, seconds: timeoutSeconds)
      let action = timeout == Self.success ? syscalls.setReleaseOnTimeout(created.id) : timeout
      guard action == Self.success else {
        _ = syscalls.release(created.id)
        return .failed(code: action)
      }
      registry.record(kind, id: created.id)
      return .succeeded
    }
  }

  public func release(_ kind: AssertionKind) -> EffectOutcome {
    serialized {
      guard let id = registry.current(kind) else { return .succeeded }
      let result = syscalls.release(id)
      registry.remove(kind, ifID: id)
      return result == Self.success ? .succeeded : .failed(code: result)
    }
  }

  public func currentID(_ kind: AssertionKind) -> UInt32? {
    registry.current(kind)
  }
}
