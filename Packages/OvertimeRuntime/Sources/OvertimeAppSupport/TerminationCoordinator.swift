import Foundation
import OvertimeCore
import OvertimeEngine
import os

public final class TerminationCoordinator: Sendable {
  public static let defaultOuterBoundSeconds = Engine.stopWaitSeconds + 2

  private let beforeStop: @Sendable () -> Void
  private let stop: @Sendable () async -> Void
  private let shutdown: @Sendable () -> Void
  private let outerBoundSeconds: Double
  private let run = OSAllocatedUnfairLock<Task<Bool, Never>?>(initialState: nil)

  public init(
    beforeStop: @escaping @Sendable () -> Void = {},
    stop: @escaping @Sendable () async -> Void,
    shutdown: @escaping @Sendable () -> Void,
    outerBoundSeconds: Double = TerminationCoordinator.defaultOuterBoundSeconds
  ) {
    self.beforeStop = beforeStop
    self.stop = stop
    self.shutdown = shutdown
    self.outerBoundSeconds = outerBoundSeconds
  }

  public func terminate() async -> Bool {
    let task = run.withLock { current -> Task<Bool, Never> in
      if let current { return current }
      let beforeStop = beforeStop
      let stop = stop
      let shutdown = shutdown
      let bound = outerBoundSeconds
      let created = Task {
        beforeStop()
        let finished = await Engine.bounded(seconds: bound) { await stop() }
        shutdown()
        return finished
      }
      current = created
      return created
    }
    return await task.value
  }
}

public enum RelaunchSuppression {
  @discardableResult
  public static func stamp(at url: URL, log: (Decision) -> Void = { _ in }) -> Bool {
    let path = url.path(percentEncoded: false)
    let flags = O_WRONLY | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
    var descriptor = open(path, flags, 0o600)
    if descriptor < 0, errno == ELOOP, unlink(path) == 0 {
      descriptor = open(path, flags, 0o600)
    }
    guard descriptor >= 0 else {
      log(failure(errno))
      return false
    }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0 else {
      log(failure(errno))
      return false
    }
    guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
      log(failure(EPERM))
      return false
    }
    guard fchmod(descriptor, 0o600) == 0, futimes(descriptor, nil) == 0 else {
      log(failure(errno))
      return false
    }
    return true
  }

  @discardableResult
  public static func consume(at url: URL, log: (Decision) -> Void = { _ in }) -> Bool {
    guard unlink(url.path(percentEncoded: false)) != 0 else { return true }
    let code = errno
    guard code != ENOENT else { return true }
    log(
      Decision(
        keyword: .error, verb: "relaunch stamp remove failed",
        fields: [DecisionField(key: "errno", value: String(code))]))
    return false
  }

  static func failure(_ code: Int32) -> Decision {
    Decision(keyword: .error, verb: "relaunch stamp failed", fields: [DecisionField(key: "errno", value: String(code))])
  }
}
