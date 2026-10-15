import Foundation
import OvertimeCore
import OvertimeSystem

public final class HeldLocks: Sendable, Equatable {
  public let primary: InstanceLock
  public let secondary: InstanceLock?

  public init(primary: InstanceLock, secondary: InstanceLock?) {
    self.primary = primary
    self.secondary = secondary
  }

  public func release() {
    primary.release()
    secondary?.release()
  }

  public static func == (lhs: HeldLocks, rhs: HeldLocks) -> Bool {
    lhs === rhs
  }
}

public struct HandoffTarget: Sendable, Equatable {
  public var url: URL
  public var pid: Int32

  public init(url: URL, pid: Int32) {
    self.url = url
    self.pid = pid
  }
}

public struct HandoffCandidate: Sendable, Equatable {
  public var target: HandoffTarget
  public var finishedLaunching: Bool
  public var terminated: Bool

  public init(target: HandoffTarget, finishedLaunching: Bool, terminated: Bool = false) {
    self.target = target
    self.finishedLaunching = finishedLaunching
    self.terminated = terminated
  }
}

public enum InstanceGateResult: Sendable, Equatable {
  case acquired(HeldLocks)
  case handoff(HandoffTarget)
  case blocked(HostFailure)
}

public enum InstanceGateResolution: Sendable, Equatable {
  case acquired(HeldLocks)
  case blocked(HostFailure)
  case handedOff
}

public enum InstanceGate {
  public static let maxHandoffs = 3
  public static let handoffWaitSeconds =
    TerminationCoordinator.defaultOuterBoundSeconds + Timing.systemCallTimeoutSeconds

  public static func resolve(
    acquire: () -> InstanceGateResult,
    open: (URL) -> Void,
    waitForExit: (Int32, Double) -> Bool,
    maxHandoffs: Int = InstanceGate.maxHandoffs,
    waitSeconds: Double = InstanceGate.handoffWaitSeconds
  ) -> InstanceGateResolution {
    var handoffs = 0
    while true {
      switch acquire() {
      case .acquired(let locks):
        return .acquired(locks)
      case .blocked(let failure):
        return .blocked(failure)
      case .handoff(let target):
        guard handoffs < maxHandoffs else { return .blocked(.lockHeldElsewhere) }
        handoffs += 1
        open(target.url)
        guard waitForExit(target.pid, waitSeconds) else { return .handedOff }
      }
    }
  }

  public static func acquire(
    primaryLockFile: URL, secondaryLockFile: URL?, otherInstance: () -> HandoffTarget?
  ) -> InstanceGateResult {
    var secondary: InstanceLock?
    if let secondaryLockFile, secondaryLockFile.standardizedFileURL != primaryLockFile.standardizedFileURL {
      do {
        secondary = try InstanceLock.acquire(at: secondaryLockFile)
      } catch {
        return refused(otherInstance)
      }
    }
    do {
      let primary = try InstanceLock.acquire(at: primaryLockFile)
      return .acquired(HeldLocks(primary: primary, secondary: secondary))
    } catch {
      secondary?.release()
      return refused(otherInstance)
    }
  }

  public static func handoffTarget(from candidates: [HandoffCandidate], ownPID: Int32) -> HandoffTarget? {
    let others = candidates.filter { $0.target.pid != ownPID && !$0.terminated }
    return (others.first { $0.finishedLaunching } ?? others.first)?.target
  }

  private static func refused(_ otherInstance: () -> HandoffTarget?) -> InstanceGateResult {
    if let target = otherInstance() {
      return .handoff(target)
    }
    return .blocked(.lockHeldElsewhere)
  }
}

public enum ProcessWatch {
  public static let pollSeconds: Double = 0.1

  public static func waitForExit(
    pid: Int32, seconds: Double, pollSeconds: Double = ProcessWatch.pollSeconds,
    isAlive: (Int32) -> Bool = ProcessWatch.isAlive
  ) -> Bool {
    let deadline = ContinuousClock.now + .milliseconds(Int(max(0, seconds) * 1000))
    while isAlive(pid) {
      guard ContinuousClock.now < deadline else { return false }
      Thread.sleep(forTimeInterval: pollSeconds)
    }
    return true
  }

  public static func isAlive(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
  }
}
