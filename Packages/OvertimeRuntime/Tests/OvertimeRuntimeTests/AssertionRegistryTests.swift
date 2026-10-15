import Foundation
import OvertimeCore
import OvertimeSystem
import Testing
import os

final class BlockingCreateSyscalls: AssertionSyscalls {
  let entered = DispatchSemaphore(value: 0)
  let unblock = DispatchSemaphore(value: 0)

  func create(_ kind: AssertionKind, name: String) -> (result: Int32, id: UInt32) {
    entered.signal()
    _ = unblock.wait(timeout: .now() + 30)
    return (0, 900)
  }

  func setTimeout(_ id: UInt32, seconds: Int) -> Int32 { 0 }
  func setReleaseOnTimeout(_ id: UInt32) -> Int32 { 0 }
  func release(_ id: UInt32) -> Int32 { 0 }
}

struct AssertionRegistryTests {
  @Test func theBackendRecordsEachCreatedIDPerKindAndRemovesItOnRelease() {
    let registry = AssertionRegistry()
    let syscalls = FakeAssertionSyscalls()
    let backend = IOPMAssertionBackend(syscalls: syscalls, registry: registry)
    #expect(backend.acquireOrRenew(.preventUserIdleSystemSleep, timeoutSeconds: 300) == .succeeded)
    #expect(backend.acquireOrRenew(.preventUserIdleDisplaySleep, timeoutSeconds: 300) == .succeeded)
    #expect(registry.current(.preventUserIdleSystemSleep) == 101)
    #expect(registry.current(.preventUserIdleDisplaySleep) == 102)
    #expect(registry.snapshot().map(\.1) == [101, 102])
    #expect(backend.release(.preventUserIdleSystemSleep) == .succeeded)
    #expect(registry.current(.preventUserIdleSystemSleep) == nil)
    #expect(registry.snapshot().map(\.0) == [.preventUserIdleDisplaySleep])
    #expect(syscalls.calls.contains(.release(101)))
  }

  @Test func aBackendWithTheDefaultRegistryDoesNotShareIDs() {
    let first = IOPMAssertionBackend(syscalls: FakeAssertionSyscalls())
    let second = IOPMAssertionBackend(syscalls: FakeAssertionSyscalls())
    #expect(first.acquireOrRenew(.preventUserIdleSystemSleep, timeoutSeconds: 300) == .succeeded)
    #expect(second.currentID(.preventUserIdleSystemSleep) == nil)
    #expect(AssertionRegistry.shared.current(.preventUserIdleSystemSleep) == nil)
  }

  @Test func removeLeavesANewerIDInPlace() {
    let registry = AssertionRegistry()
    registry.record(.preventUserIdleSystemSleep, id: 7)
    registry.record(.preventUserIdleSystemSleep, id: 8)
    #expect(registry.remove(.preventUserIdleSystemSleep, ifID: 7) == false)
    #expect(registry.current(.preventUserIdleSystemSleep) == 8)
    #expect(registry.remove(.preventUserIdleSystemSleep, ifID: 8))
    #expect(registry.current(.preventUserIdleSystemSleep) == nil)
  }

  @Test func snapshotReturnsAtOnceWhileTheBackendSerialLockIsHeld() async {
    let registry = AssertionRegistry()
    registry.record(.preventUserIdleDisplaySleep, id: 42)
    let syscalls = BlockingCreateSyscalls()
    let backend = IOPMAssertionBackend(syscalls: syscalls, registry: registry)
    let finished = DispatchSemaphore(value: 0)
    Thread {
      _ = backend.acquireOrRenew(.preventUserIdleSystemSleep, timeoutSeconds: 300)
      finished.signal()
    }.start()
    let entered = syscalls.entered
    #expect(await OffPool.run { entered.wait(timeout: .now() + 30) } == .success)
    let start = ContinuousClock.now
    let snapshot = await OffPool.bounded(seconds: 30) { registry.snapshot().map { Entry(kind: $0.0, id: $0.1) } }
    let elapsed = ContinuousClock.now - start
    #expect(snapshot == [Entry(kind: .preventUserIdleDisplaySleep, id: 42)])
    #expect(elapsed < .seconds(5))
    syscalls.unblock.signal()
    #expect(await OffPool.run { finished.wait(timeout: .now() + 30) } == .success)
    #expect(registry.current(.preventUserIdleSystemSleep) == 900)
  }

  struct Entry: Sendable, Equatable {
    let kind: AssertionKind
    let id: UInt32
  }
}
