import Foundation
import OvertimeCore
import OvertimeSystem
import Testing
import os

final class FakeAssertionSyscalls: AssertionSyscalls {
  enum Call: Sendable, Equatable {
    case create(AssertionKind, String)
    case setTimeout(UInt32, Int)
    case setReleaseOnTimeout(UInt32)
    case release(UInt32)
  }

  private struct Script: Sendable {
    var calls: [Call] = []
    var nextID: UInt32 = 100
    var createResult: Int32 = 0
    var failingTimeoutIDs: Set<UInt32> = []
    var failingActionIDs: Set<UInt32> = []
  }

  private let script = OSAllocatedUnfairLock(initialState: Script())

  var calls: [Call] {
    script.withLock { $0.calls }
  }

  func failCreate(with code: Int32) {
    script.withLock { $0.createResult = code }
  }

  func failTimeout(for id: UInt32) {
    script.withLock { _ = $0.failingTimeoutIDs.insert(id) }
  }

  func failReleaseAction(for id: UInt32) {
    script.withLock { _ = $0.failingActionIDs.insert(id) }
  }

  func create(_ kind: AssertionKind, name: String) -> (result: Int32, id: UInt32) {
    script.withLock { script in
      script.calls.append(.create(kind, name))
      guard script.createResult == 0 else { return (script.createResult, 0) }
      script.nextID += 1
      return (0, script.nextID)
    }
  }

  func setTimeout(_ id: UInt32, seconds: Int) -> Int32 {
    script.withLock { script in
      script.calls.append(.setTimeout(id, seconds))
      return script.failingTimeoutIDs.contains(id) ? -536_870_160 : 0
    }
  }

  func setReleaseOnTimeout(_ id: UInt32) -> Int32 {
    script.withLock { script in
      script.calls.append(.setReleaseOnTimeout(id))
      return script.failingActionIDs.contains(id) ? -536_870_212 : 0
    }
  }

  func release(_ id: UInt32) -> Int32 {
    script.withLock { script in
      script.calls.append(.release(id))
      return 0
    }
  }
}

struct AssertionBackendFakeTests {
  static let name = "Overtime: Claude Code is working"

  @Test func firstAcquireCreatesWithTheNameAndATimedReleaseAction() {
    let syscalls = FakeAssertionSyscalls()
    let backend = IOPMAssertionBackend(syscalls: syscalls)
    #expect(backend.acquireOrRenew(.preventUserIdleSystemSleep, timeoutSeconds: 300) == .succeeded)
    #expect(
      syscalls.calls == [
        .create(.preventUserIdleSystemSleep, Self.name), .setTimeout(101, 300), .setReleaseOnTimeout(101),
      ])
    #expect(backend.currentID(.preventUserIdleSystemSleep) == 101)
    #expect(IOPMAssertionBackend.assertionName == Self.name)
  }

  @Test func aSecondAcquireOnlyReArmsTheTimeoutOnTheSameID() {
    let syscalls = FakeAssertionSyscalls()
    let backend = IOPMAssertionBackend(syscalls: syscalls)
    _ = backend.acquireOrRenew(.preventUserIdleSystemSleep, timeoutSeconds: 300)
    #expect(backend.acquireOrRenew(.preventUserIdleSystemSleep, timeoutSeconds: 300) == .succeeded)
    #expect(syscalls.calls.suffix(1) == [.setTimeout(101, 300)])
    #expect(syscalls.calls.filter { if case .create = $0 { true } else { false } }.count == 1)
  }

  @Test func aFailingReArmForgetsTheGoneIDAndCreatesANewOne() {
    let syscalls = FakeAssertionSyscalls()
    let backend = IOPMAssertionBackend(syscalls: syscalls)
    _ = backend.acquireOrRenew(.preventUserIdleSystemSleep, timeoutSeconds: 300)
    syscalls.failTimeout(for: 101)
    #expect(backend.acquireOrRenew(.preventUserIdleSystemSleep, timeoutSeconds: 300) == .succeeded)
    #expect(
      syscalls.calls.suffix(4) == [
        .setTimeout(101, 300), .create(.preventUserIdleSystemSleep, Self.name), .setTimeout(102, 300),
        .setReleaseOnTimeout(102),
      ])
    #expect(backend.currentID(.preventUserIdleSystemSleep) == 102)
  }

  @Test func releaseReleasesAndForgetsTheID() {
    let syscalls = FakeAssertionSyscalls()
    let backend = IOPMAssertionBackend(syscalls: syscalls)
    _ = backend.acquireOrRenew(.preventUserIdleSystemSleep, timeoutSeconds: 300)
    #expect(backend.release(.preventUserIdleSystemSleep) == .succeeded)
    #expect(syscalls.calls.last == .release(101))
    #expect(backend.currentID(.preventUserIdleSystemSleep) == nil)
    let count = syscalls.calls.count
    #expect(backend.release(.preventUserIdleSystemSleep) == .succeeded)
    #expect(syscalls.calls.count == count)
  }

  @Test func kindsAreIndependent() {
    let syscalls = FakeAssertionSyscalls()
    let backend = IOPMAssertionBackend(syscalls: syscalls)
    _ = backend.acquireOrRenew(.preventUserIdleSystemSleep, timeoutSeconds: 300)
    _ = backend.acquireOrRenew(.preventUserIdleDisplaySleep, timeoutSeconds: 300)
    #expect(backend.currentID(.preventUserIdleSystemSleep) == 101)
    #expect(backend.currentID(.preventUserIdleDisplaySleep) == 102)
    _ = backend.release(.preventUserIdleDisplaySleep)
    #expect(syscalls.calls.last == .release(102))
    #expect(backend.currentID(.preventUserIdleSystemSleep) == 101)
    #expect(syscalls.calls.contains(.create(.preventUserIdleDisplaySleep, Self.name)))
  }

  @Test func aFailedCreateIsReportedAndNothingIsKept() {
    let syscalls = FakeAssertionSyscalls()
    syscalls.failCreate(with: -536_870_199)
    let backend = IOPMAssertionBackend(syscalls: syscalls)
    #expect(backend.acquireOrRenew(.preventUserIdleSystemSleep, timeoutSeconds: 300) == .failed(code: -536_870_199))
    #expect(backend.currentID(.preventUserIdleSystemSleep) == nil)
  }

  @Test func anAssertionWhoseTimeoutCannotBeSetIsReleasedAtOnce() {
    let syscalls = FakeAssertionSyscalls()
    syscalls.failReleaseAction(for: 101)
    let backend = IOPMAssertionBackend(syscalls: syscalls)
    #expect(backend.acquireOrRenew(.preventUserIdleSystemSleep, timeoutSeconds: 300) == .failed(code: -536_870_212))
    #expect(syscalls.calls.last == .release(101))
    #expect(backend.currentID(.preventUserIdleSystemSleep) == nil)
    let noTimeout = FakeAssertionSyscalls()
    noTimeout.failTimeout(for: 101)
    let second = IOPMAssertionBackend(syscalls: noTimeout)
    #expect(second.acquireOrRenew(.preventUserIdleSystemSleep, timeoutSeconds: 300) == .failed(code: -536_870_160))
    #expect(noTimeout.calls.last == .release(101))
    #expect(!noTimeout.calls.contains(.setReleaseOnTimeout(101)))
  }
}

final class HangingAssertionSyscalls: AssertionSyscalls {
  let gate = DispatchSemaphore(value: 0)
  let entered = DispatchSemaphore(value: 0)

  func create(_ kind: AssertionKind, name: String) -> (result: Int32, id: UInt32) {
    entered.signal()
    gate.wait()
    return (0, 1)
  }

  func setTimeout(_ id: UInt32, seconds: Int) -> Int32 { 0 }
  func setReleaseOnTimeout(_ id: UInt32) -> Int32 { 0 }
  func release(_ id: UInt32) -> Int32 { 0 }
}

final class HangingSelector: ClamshellSelector {
  let gate = DispatchSemaphore(value: 0)
  let entered = DispatchSemaphore(value: 0)
  private let calls = OSAllocatedUnfairLock(initialState: 0)

  var count: Int { calls.withLock { $0 } }

  func write(on: Bool) -> kern_return_t {
    let index = calls.withLock { calls -> Int in
      calls += 1
      return calls
    }
    if index == 1 {
      entered.signal()
      gate.wait()
    }
    return KERN_SUCCESS
  }
}

struct BlockingCallLockTests {
  static let mustFinishSeconds: Double = 30
  static let ceilingSeconds: Double = 5

  @Test func aHungAssertionCallMakesLaterCallsFailWithinTheBound() async throws {
    let syscalls = HangingAssertionSyscalls()
    defer { syscalls.gate.signal() }
    let backend = IOPMAssertionBackend(syscalls: syscalls, lockWaitSeconds: 0.2)
    let hung = Thread { _ = backend.acquireOrRenew(.preventUserIdleSystemSleep, timeoutSeconds: 300) }
    hung.start()
    let entered = syscalls.entered
    try #require(await OffPool.run { entered.wait(timeout: .now() + Self.mustFinishSeconds) } == .success)
    let start = ContinuousClock.now
    let released = await OffPool.bounded(seconds: Self.mustFinishSeconds) {
      backend.release(.preventUserIdleDisplaySleep)
    }
    #expect(released == .failed(code: IOPMAssertionBackend.lockBusyCode))
    #expect(ContinuousClock.now - start < .seconds(Self.ceilingSeconds))
  }

  @Test func aHungClamshellWriteMakesLaterWritesFailWithinTheBound() async throws {
    let selector = HangingSelector()
    defer { selector.gate.signal() }
    let backend = ClamshellBackend(writer: selector, lockWaitSeconds: 0.2)
    let hung = Thread { _ = backend.write(on: true) }
    hung.start()
    let entered = selector.entered
    try #require(await OffPool.run { entered.wait(timeout: .now() + Self.mustFinishSeconds) } == .success)
    let start = ContinuousClock.now
    let written = await OffPool.bounded(seconds: Self.mustFinishSeconds) { backend.write(on: false) }
    #expect(written == .failed(code: ClamshellBackend.lockBusyCode))
    #expect(ContinuousClock.now - start < .seconds(Self.ceilingSeconds))
    #expect(selector.count == 1)
  }
}
