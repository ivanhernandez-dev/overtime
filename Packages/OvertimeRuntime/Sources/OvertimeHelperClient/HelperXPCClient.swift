import Foundation
import OvertimeHelperCore
import os

public enum HelperCallResult<Value: Sendable & Equatable>: Sendable, Equatable {
  case success(Value)
  case failed(String)
  case timedOut
}

public final class HelperXPCClient: @unchecked Sendable {
  public static let defaultTimeoutSeconds: Double = 5
  public static let noProxyReason = "noProxy"
  public static let undecodableStatusReason = "undecodableStatus"

  private final class Gate<Value: Sendable & Equatable>: Sendable {
    private let result = OSAllocatedUnfairLock<HelperCallResult<Value>?>(initialState: nil)
    private let done = DispatchSemaphore(value: 0)

    func resolve(_ value: HelperCallResult<Value>) {
      let first = result.withLock { current -> Bool in
        guard current == nil else { return false }
        current = value
        return true
      }
      if first { done.signal() }
    }

    func wait(seconds: Double) -> HelperCallResult<Value> {
      if done.wait(timeout: .now() + seconds) == .timedOut {
        resolve(.timedOut)
      }
      return result.withLock { $0 } ?? .timedOut
    }
  }

  public let requirement: String
  public let timeoutSeconds: Double
  private let makeConnection: @Sendable () -> NSXPCConnection
  private let connection = OSAllocatedUnfairLock<NSXPCConnection?>(uncheckedState: nil)

  public init(
    requirement: String, timeoutSeconds: Double = HelperXPCClient.defaultTimeoutSeconds,
    makeConnection: @escaping @Sendable () -> NSXPCConnection
  ) {
    self.requirement = requirement
    self.timeoutSeconds = timeoutSeconds
    self.makeConnection = makeConnection
  }

  public static func privileged(
    identity: HelperIdentity, timeoutSeconds: Double = HelperXPCClient.defaultTimeoutSeconds
  ) -> HelperXPCClient {
    let service = identity.machService
    return HelperXPCClient(requirement: identity.helperRequirement, timeoutSeconds: timeoutSeconds) {
      NSXPCConnection(machServiceName: service, options: .privileged)
    }
  }

  public func set(_ enabled: Bool) -> HelperCallResult<HelperReply> {
    call { proxy, gate in
      proxy.setSleepDisabled(enabled) { code, message in
        guard let known = HelperReplyCode(rawValue: code) else {
          return gate.resolve(.failed("replyCode \(code)"))
        }
        gate.resolve(.success(HelperReply(code: known, message: message)))
      }
    }
  }

  public func status(appVersion: Int) -> HelperCallResult<HelperStatus> {
    call { proxy, gate in
      proxy.status(appHelperVersion: appVersion) { data in
        guard let status = HelperStatus.decode(data) else {
          return gate.resolve(.failed(Self.undecodableStatusReason))
        }
        gate.resolve(.success(status))
      }
    }
  }

  public func invalidate() {
    let current = connection.withLockUnchecked { held -> NSXPCConnection? in
      defer { held = nil }
      return held
    }
    current?.invalidate()
  }

  private func call<Value: Sendable & Equatable>(
    _ send: (any HelperXPCProtocol, Gate<Value>) -> Void
  ) -> HelperCallResult<Value> {
    let gate = Gate<Value>()
    let current = live()
    let remote = current.remoteObjectProxyWithErrorHandler { error in
      let failure = error as NSError
      gate.resolve(.failed("\(failure.domain) \(failure.code)"))
    }
    if let proxy = remote as? any HelperXPCProtocol {
      send(proxy, gate)
    } else {
      gate.resolve(.failed(Self.noProxyReason))
    }
    let result = gate.wait(seconds: timeoutSeconds)
    if case .success = result { return result }
    drop(current)
    return result
  }

  private func live() -> NSXPCConnection {
    connection.withLockUnchecked { held in
      if let held { return held }
      let made = makeConnection()
      made.remoteObjectInterface = NSXPCInterface(with: HelperXPCProtocol.self)
      made.setCodeSigningRequirement(requirement)
      made.resume()
      held = made
      return made
    }
  }

  private func drop(_ failed: NSXPCConnection) {
    connection.withLockUnchecked { held in
      if held === failed { held = nil }
    }
    failed.invalidate()
  }
}
