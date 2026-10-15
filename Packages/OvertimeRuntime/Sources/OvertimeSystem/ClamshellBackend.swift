import Foundation
import IOKit
import OvertimeClamshell
import OvertimeCore

public protocol ClamshellPort: Sendable {
  func write(on: Bool) -> EffectOutcome
}

public protocol ClamshellSelector: Sendable {
  func write(on: Bool) -> kern_return_t
}

extension ClamshellWriter: ClamshellSelector {}

public final class ClamshellBackend: ClamshellPort {
  public static let lockBusyCode: Int32 = -4

  private let writer: any ClamshellSelector
  private let lockWaitSeconds: Double
  private let serial = NSLock()

  public init(writer: any ClamshellSelector, lockWaitSeconds: Double = Timing.systemCallTimeoutSeconds) {
    self.writer = writer
    self.lockWaitSeconds = lockWaitSeconds
  }

  public func write(on: Bool) -> EffectOutcome {
    guard serial.lock(before: Date(timeIntervalSinceNow: lockWaitSeconds)) else {
      return .failed(code: Self.lockBusyCode)
    }
    defer { serial.unlock() }
    let result = writer.write(on: on)
    return result == KERN_SUCCESS ? .succeeded : .failed(code: result)
  }
}
