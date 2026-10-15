import Foundation
import OvertimeSystem
import Testing

@Suite(.serialized)
struct InstanceLockTests {
  @Test func aSecondAcquireIsRefusedUntilTheFirstIsReleased() throws {
    let temp = try TempDirectory.short()
    let url = temp.url.appendingPathComponent("overtimed-shadow.lock")
    let first = try InstanceLock.acquire(at: url)
    #expect(throws: InstanceLockError.alreadyRunning) { try InstanceLock.acquire(at: url) }
    first.release()
    let second = try InstanceLock.acquire(at: url)
    second.release()
  }

  @Test func theLockFileIsPrivate() throws {
    let temp = try TempDirectory.short()
    let url = temp.url.appendingPathComponent("overtimed-shadow.lock")
    let lock = try InstanceLock.acquire(at: url)
    defer { lock.release() }
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  }

  @Test func releasingTwiceIsHarmlessAndDeinitReleases() throws {
    let temp = try TempDirectory.short()
    let url = temp.url.appendingPathComponent("overtimed-shadow.lock")
    do {
      let lock = try InstanceLock.acquire(at: url)
      lock.release()
      lock.release()
    }
    do {
      _ = try InstanceLock.acquire(at: url)
    }
    let again = try InstanceLock.acquire(at: url)
    again.release()
  }
}
