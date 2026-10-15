import Foundation
import os

public enum InstanceLockError: Error, Equatable {
  case alreadyRunning
  case open(errno: Int32)
  case lock(errno: Int32)
}

public final class InstanceLock: Sendable {
  private let descriptor: OSAllocatedUnfairLock<Int32>

  private init(descriptor: Int32) {
    self.descriptor = OSAllocatedUnfairLock(initialState: descriptor)
  }

  public static func acquire(at url: URL) throws -> InstanceLock {
    let path = url.path(percentEncoded: false)
    let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw InstanceLockError.open(errno: errno) }
    _ = fchmod(descriptor, 0o600)
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      let code = errno
      close(descriptor)
      throw code == EWOULDBLOCK ? InstanceLockError.alreadyRunning : InstanceLockError.lock(errno: code)
    }
    return InstanceLock(descriptor: descriptor)
  }

  public func release() {
    descriptor.withLock { descriptor in
      guard descriptor >= 0 else { return }
      flock(descriptor, LOCK_UN)
      close(descriptor)
      descriptor = -1
    }
  }

  deinit {
    release()
  }
}
