import CIOKitShim
import Foundation
import IOKit
import IOKit.pwr_mgt
import OvertimeCore

public final class PowerNotifications: @unchecked Sendable {
  private let queue = DispatchQueue(label: "io.github.ivanhernandez-dev.overtime.power-notifications")
  private let lock = NSLock()
  private var rootPort: io_connect_t = 0
  private var systemNotifyPort: IONotificationPortRef?
  private var systemNotifier: io_object_t = 0
  private var interestNotifyPort: IONotificationPortRef?
  private var interestNotifier: io_object_t = 0
  private var continuation: AsyncStream<Event>.Continuation?
  private var generation: UInt64 = 0

  public init() {}

  deinit {
    stopLocked()
  }

  public var isRegistered: Bool {
    lock.withLock { rootPort != 0 }
  }

  public var watchesClamshell: Bool {
    lock.withLock { interestNotifier != 0 }
  }

  public func start() -> AsyncStream<Event> {
    let (stream, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingNewest(64))
    let current = lock.withLock { () -> UInt64 in
      stopLocked()
      generation &+= 1
      self.continuation = continuation
      register()
      return generation
    }
    let queue = queue
    continuation.onTermination = { [weak self] _ in
      queue.async { [weak self] in self?.stop(generation: current) }
    }
    return stream
  }

  public func stop() {
    lock.withLock { stopLocked() }
  }

  func stop(generation stopping: UInt64) {
    lock.withLock {
      guard generation == stopping else { return }
      stopLocked()
    }
  }

  public static func systemEvent(message: UInt32) -> Event? {
    switch message {
    case OTMessageSystemWillSleep: .systemWillSleep
    case OTMessageSystemHasPoweredOn: .systemHasPoweredOn
    default: nil
    }
  }

  public static func needsAcknowledgement(message: UInt32) -> Bool {
    message == OTMessageCanSystemSleep || message == OTMessageSystemWillSleep
  }

  public static func interestEvent(message: UInt32, argument: UInt32) -> Event? {
    guard message == OTPMMessageClamshellStateChange else { return nil }
    return .lidChanged(
      closed: argument & OTClamshellStateBit != 0, sleepBit: argument & OTClamshellSleepBit != 0,
      externalDisplays: nil)
  }

  private func register() {
    let refcon = Unmanaged.passUnretained(self).toOpaque()
    rootPort = IORegisterForSystemPower(refcon, &systemNotifyPort, Self.systemCallback, &systemNotifier)
    if rootPort != 0, let systemNotifyPort {
      IONotificationPortSetDispatchQueue(systemNotifyPort, queue)
    }
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard service != IO_OBJECT_NULL else { return }
    defer { IOObjectRelease(service) }
    guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
    interestNotifyPort = port
    IONotificationPortSetDispatchQueue(port, queue)
    let result = IOServiceAddInterestNotification(
      port, service, kIOGeneralInterest, Self.interestCallback, refcon, &interestNotifier)
    if result != KERN_SUCCESS {
      interestNotifier = 0
    }
  }

  private func stopLocked() {
    if systemNotifier != 0 {
      IODeregisterForSystemPower(&systemNotifier)
      systemNotifier = 0
    }
    if rootPort != 0 {
      IOServiceClose(rootPort)
      rootPort = 0
    }
    if let systemNotifyPort {
      IONotificationPortDestroy(systemNotifyPort)
      self.systemNotifyPort = nil
    }
    if interestNotifier != 0 {
      IOObjectRelease(interestNotifier)
      interestNotifier = 0
    }
    if let interestNotifyPort {
      IONotificationPortDestroy(interestNotifyPort)
      self.interestNotifyPort = nil
    }
    let finished = continuation
    continuation = nil
    finished?.finish()
  }

  private func handleSystem(_ message: UInt32, _ argument: UnsafeMutableRawPointer?) {
    let (port, continuation) = lock.withLock { (rootPort, self.continuation) }
    if Self.needsAcknowledgement(message: message), port != 0 {
      IOAllowPowerChange(port, Int(bitPattern: argument))
    }
    if let event = Self.systemEvent(message: message) {
      continuation?.yield(event)
    }
  }

  private func handleInterest(_ message: UInt32, _ argument: UnsafeMutableRawPointer?) {
    let bits = UInt32(truncatingIfNeeded: UInt(bitPattern: argument))
    guard let event = Self.interestEvent(message: message, argument: bits) else { return }
    lock.withLock { continuation }?.yield(event)
  }

  private static let systemCallback: IOServiceInterestCallback = { refcon, _, message, argument in
    guard let refcon else { return }
    Unmanaged<PowerNotifications>.fromOpaque(refcon).takeUnretainedValue().handleSystem(message, argument)
  }

  private static let interestCallback: IOServiceInterestCallback = { refcon, _, message, argument in
    guard let refcon else { return }
    Unmanaged<PowerNotifications>.fromOpaque(refcon).takeUnretainedValue().handleInterest(message, argument)
  }
}
