import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeSystem
import Testing

struct InstanceGateTests {
  struct Roots {
    let temp: TempDirectory
    let primary: URL
    let secondary: URL

    init() throws {
      temp = try TempDirectory()
      primary = temp.url.appendingPathComponent("debug-overtimed.lock")
      secondary = temp.url.appendingPathComponent("release-overtimed.lock")
    }
  }

  private func isFree(_ url: URL) -> Bool {
    guard let lock = try? InstanceLock.acquire(at: url) else { return false }
    lock.release()
    return true
  }

  @Test func aFreePrimaryIsAcquiredAndReallyHeld() throws {
    let roots = try Roots()
    let result = InstanceGate.acquire(primaryLockFile: roots.primary, secondaryLockFile: nil, otherInstance: { nil })
    guard case .acquired(let held) = result else {
      Issue.record("expected acquired, got \(result)")
      return
    }
    #expect(throws: InstanceLockError.alreadyRunning) { try InstanceLock.acquire(at: roots.primary) }
    held.release()
  }

  @Test func aHeldPrimaryWithARunningAppHandsOff() throws {
    let roots = try Roots()
    let other = try InstanceLock.acquire(at: roots.primary)
    let app = HandoffTarget(url: URL(fileURLWithPath: "/Applications/Overtime.app"), pid: 4242)
    let result = InstanceGate.acquire(primaryLockFile: roots.primary, secondaryLockFile: nil, otherInstance: { app })
    #expect(result == .handoff(app))
    other.release()
    #expect(isFree(roots.primary))
  }

  @Test func aHeldPrimaryWithNoAppIsBlocked() throws {
    let roots = try Roots()
    let other = try InstanceLock.acquire(at: roots.primary)
    let result = InstanceGate.acquire(primaryLockFile: roots.primary, secondaryLockFile: nil, otherInstance: { nil })
    #expect(result == .blocked(.lockHeldElsewhere))
    other.release()
  }

  @Test func aHeldReleaseRootLockBlocksTheDebugAppAndReleasesThePrimary() throws {
    let roots = try Roots()
    let overtimedLive = try InstanceLock.acquire(at: roots.secondary)
    let result = InstanceGate.acquire(
      primaryLockFile: roots.primary, secondaryLockFile: roots.secondary, otherInstance: { nil })
    #expect(result == .blocked(.lockHeldElsewhere))
    #expect(isFree(roots.primary))
    overtimedLive.release()
  }

  @Test func theReleaseRootLockIsTakenBesideThePrimary() throws {
    let roots = try Roots()
    let result = InstanceGate.acquire(
      primaryLockFile: roots.primary, secondaryLockFile: roots.secondary, otherInstance: { nil })
    guard case .acquired(let held) = result else {
      Issue.record("expected acquired, got \(result)")
      return
    }
    #expect(!isFree(roots.primary))
    #expect(!isFree(roots.secondary))
    held.release()
    #expect(isFree(roots.primary))
    #expect(isFree(roots.secondary))
  }

  @Test func theSamePathForBothRootsTakesOneLock() throws {
    let roots = try Roots()
    let result = InstanceGate.acquire(
      primaryLockFile: roots.primary, secondaryLockFile: roots.primary, otherInstance: { nil })
    guard case .acquired(let held) = result else {
      Issue.record("expected acquired, got \(result)")
      return
    }
    #expect(held.secondary == nil)
    held.release()
    #expect(isFree(roots.primary))
  }

  static let target = HandoffTarget(url: URL(fileURLWithPath: "/Applications/Overtime.app"), pid: 4242)

  @Test func aHandoffToAnInstanceThatKeepsRunningExitsWithoutTakingTheLock() {
    var opened: [URL] = []
    var acquires = 0
    let resolution = InstanceGate.resolve(
      acquire: {
        acquires += 1
        return .handoff(Self.target)
      },
      open: { opened.append($0) },
      waitForExit: { _, _ in false })
    #expect(resolution == .handedOff)
    #expect(opened == [Self.target.url])
    #expect(acquires == 1)
  }

  @Test func aHandoffToAQuittingInstanceWaitsForItAndTakesTheFreedLock() throws {
    let roots = try Roots()
    let quitting = try InstanceLock.acquire(at: roots.primary)
    var opened: [URL] = []
    var waits: [(pid: Int32, seconds: Double)] = []
    let resolution = InstanceGate.resolve(
      acquire: {
        InstanceGate.acquire(primaryLockFile: roots.primary, secondaryLockFile: nil, otherInstance: { Self.target })
      },
      open: { opened.append($0) },
      waitForExit: { pid, seconds in
        waits.append((pid, seconds))
        quitting.release()
        return true
      })
    guard case .acquired(let held) = resolution else {
      Issue.record("expected acquired, got \(resolution)")
      return
    }
    #expect(!isFree(roots.primary))
    #expect(opened == [Self.target.url])
    #expect(waits.map(\.pid) == [Self.target.pid])
    #expect(waits.map(\.seconds) == [InstanceGate.handoffWaitSeconds])
    held.release()
  }

  @Test func theHandoffWaitCoversAQuittingInstancesWholeStop() {
    #expect(
      InstanceGate.handoffWaitSeconds
        == TerminationCoordinator.defaultOuterBoundSeconds + Timing.systemCallTimeoutSeconds)
  }

  @Test func aChainOfQuittingInstancesIsReportedInsteadOfLeavingNothingRunning() {
    var opened = 0
    let resolution = InstanceGate.resolve(
      acquire: { .handoff(Self.target) },
      open: { _ in opened += 1 },
      waitForExit: { _, _ in true })
    #expect(resolution == .blocked(.lockHeldElsewhere))
    #expect(opened == InstanceGate.maxHandoffs)
  }

  @Test func aHandoffPrefersAnInstanceThatFinishedLaunchingOverOnesStillWaitingInTheGate() {
    let url = URL(fileURLWithPath: "/Applications/Overtime.app")
    func candidate(_ pid: Int32, finished: Bool, terminated: Bool = false) -> HandoffCandidate {
      HandoffCandidate(target: HandoffTarget(url: url, pid: pid), finishedLaunching: finished, terminated: terminated)
    }
    let waitingB = candidate(20, finished: false)
    let waitingC = candidate(30, finished: false)
    let healthy = candidate(10, finished: true)
    let quit = candidate(40, finished: true, terminated: true)
    #expect(InstanceGate.handoffTarget(from: [waitingB, waitingC, healthy], ownPID: 50)?.pid == 10)
    #expect(InstanceGate.handoffTarget(from: [quit, waitingB, healthy], ownPID: 30)?.pid == 10)
    #expect(InstanceGate.handoffTarget(from: [healthy, waitingB], ownPID: 10)?.pid == 20)
    #expect(InstanceGate.handoffTarget(from: [candidate(50, finished: true)], ownPID: 50) == nil)
    #expect(InstanceGate.handoffTarget(from: [quit], ownPID: 50) == nil)
    #expect(InstanceGate.handoffTarget(from: [], ownPID: 50) == nil)
  }

  @Test func theProcessWatchReportsAnExitAndGivesUpAtItsBound() async {
    var answers = [true, true, false]
    #expect(
      ProcessWatch.waitForExit(pid: 1, seconds: 5, pollSeconds: 0.01, isAlive: { _ in answers.removeFirst() }))
    #expect(answers.isEmpty)
    let started = ContinuousClock.now
    let exited = await OffPool.bounded(seconds: 30) {
      ProcessWatch.waitForExit(pid: 1, seconds: 0.2, pollSeconds: 0.01, isAlive: { _ in true })
    }
    #expect(exited == false)
    #expect(ContinuousClock.now - started < .seconds(5))
    #expect(ProcessWatch.isAlive(getpid()))
  }
}
