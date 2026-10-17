import Foundation

public final class HelperXPCService: NSObject, NSXPCListenerDelegate, HelperXPCProtocol, @unchecked Sendable {
  public static let noConnectionReason = "connection"

  private let machine: HelperMachine
  private let log: any HelperLogPort
  private let queue: DispatchQueue
  private let afterEvent: @Sendable () -> Void
  private let onExit: @Sendable () -> Void
  private var live: [ObjectIdentifier: HelperConnectionID] = [:]
  private var accepted: UInt64 = 0
  private var exitRequested = false

  public init(
    machine: HelperMachine, log: any HelperLogPort, queue: DispatchQueue,
    afterEvent: @escaping @Sendable () -> Void = {}, onExit: @escaping @Sendable () -> Void
  ) {
    self.machine = machine
    self.log = log
    self.queue = queue
    self.afterEvent = afterEvent
    self.onExit = onExit
  }

  public func configure(_ listener: NSXPCListener, requirement: String) {
    listener.setConnectionCodeSigningRequirement(requirement)
    listener.delegate = self
  }

  public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
    let identifier = ObjectIdentifier(connection)
    connection.exportedInterface = NSXPCInterface(with: HelperXPCProtocol.self)
    connection.exportedObject = self
    connection.invalidationHandler = { [weak self] in
      self?.ended(identifier)
    }
    connection.interruptionHandler = { [weak self, weak connection] in
      self?.ended(identifier)
      connection?.invalidate()
    }
    queue.async {
      self.accepted += 1
      self.live[identifier] = HelperConnectionID(self.accepted)
      self.machine.connectionOpened()
    }
    connection.resume()
    return true
  }

  public func setSleepDisabled(
    _ enabled: Bool, batteryFloorPercent: Int, temperatureCeilingCelsius: Int,
    reply: @escaping @Sendable (Int32, String) -> Void
  ) {
    let caller = NSXPCConnection.current().map { ObjectIdentifier($0) }
    let floor = batteryFloorPercent
    let ceiling = temperatureCeilingCelsius
    let requested = HelperSafetyLimits(requestedBatteryFloorPercent: floor, requestedTemperatureCeilingCelsius: ceiling)
    queue.async {
      let answer: HelperReply
      if !enabled {
        answer = self.machine.clear()
      } else if let caller, let connection = self.live[caller] {
        answer = self.machine.set(from: connection, limits: requested)
      } else {
        self.log.record("set refused reason=\(Self.noConnectionReason)")
        answer = HelperReply(code: .refused, message: Self.noConnectionReason)
      }
      reply(answer.code.rawValue, answer.message)
      self.settle()
    }
  }

  public func status(appHelperVersion: Int, reply: @escaping @Sendable (Data) -> Void) {
    let caller = NSXPCConnection.current().map { ObjectIdentifier($0) }
    queue.async {
      let connection = caller.flatMap { self.live[$0] }
      let answer = self.machine.status(appVersion: appHelperVersion, from: connection)
      reply(answer.status.encoded())
      self.settle()
    }
  }

  private func ended(_ identifier: ObjectIdentifier) {
    queue.async {
      guard let connection = self.live.removeValue(forKey: identifier) else { return }
      self.machine.connectionEnded(connection, remaining: self.live.count)
      self.settle()
    }
  }

  private func settle() {
    if machine.shouldExit, !exitRequested {
      exitRequested = true
      onExit()
    }
    afterEvent()
  }
}
