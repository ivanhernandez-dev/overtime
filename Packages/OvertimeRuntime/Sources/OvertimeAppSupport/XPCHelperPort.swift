import Foundation
import OvertimeCore
import OvertimeEngine
import OvertimeHelperClient
import OvertimeHelperCore
import os

public struct HelperObservation: Sendable, Equatable {
  public var status: HelperStatus?
  public var owns: Bool

  public init(status: HelperStatus? = nil, owns: Bool = false) {
    self.status = status
    self.owns = owns
  }
}

public final class HelperObservations: Sendable {
  private let stored = OSAllocatedUnfairLock(initialState: HelperObservation())

  public init() {}

  public var current: HelperObservation {
    stored.withLock { $0 }
  }

  public var status: HelperStatus? {
    current.status
  }

  public var owns: Bool {
    current.owns
  }

  func note(_ status: HelperStatus) {
    stored.withLock { $0 = HelperObservation(status: status, owns: status.owns) }
  }

  func note(owns: Bool) {
    stored.withLock { $0.owns = owns }
  }

  func forget() {
    stored.withLock { $0 = HelperObservation() }
  }
}

public enum HelperProbe: Sendable, Equatable {
  case answered(HelperStatus)
  case engaged(HelperStatus?)
  case unreachable(String)
}

public final class XPCHelperPort: HelperPort {
  public static let notEngagedCode: Int32 = -6
  public static let marginSeconds: Double = 0.25
  public static let defaultBoundSeconds = Timing.systemCallTimeoutSeconds - marginSeconds
  public static let timedOutReason = "timedOut"
  static let replyCodePrefix = "replyCode"

  public let observations = HelperObservations()
  let client: HelperXPCClient
  let boundSeconds: Double
  private let conversation = NSLock()
  private let holding = OSAllocatedUnfairLock(initialState: false)

  public init(client: HelperXPCClient, boundSeconds: Double = XPCHelperPort.defaultBoundSeconds) {
    self.client = client
    self.boundSeconds = boundSeconds
  }

  public static func privileged(identity: HelperIdentity) -> XPCHelperPort {
    XPCHelperPort(client: HelperXPCClient.privileged(identity: identity, timeoutSeconds: defaultBoundSeconds))
  }

  public func engage() -> EffectOutcome {
    holding.withLock { $0 = true }
    return exchange {
      switch client.set(true) {
      case .success(let reply):
        guard reply.code == .owned || reply.code == .alreadyOn else {
          return .failed(code: LiveInterpreter.helperRefusedCode)
        }
        observations.note(owns: reply.code == .owned)
        return .succeeded
      case .failed(let reason):
        return .failed(code: Self.code(forFailure: reason))
      case .timedOut:
        return .timedOut
      }
    }
  }

  public func heartbeat() -> EffectOutcome {
    exchange {
      switch client.status(appVersion: HelperIdentity.version) {
      case .success(let status):
        guard status.engaged else { return .failed(code: Self.notEngagedCode) }
        observations.note(status)
        return .succeeded
      case .failed(let reason):
        return .failed(code: Self.code(forFailure: reason))
      case .timedOut:
        return .timedOut
      }
    }
  }

  public func release() -> EffectOutcome {
    holding.withLock { $0 = false }
    conversation.lock()
    defer { conversation.unlock() }
    let result = client.set(false)
    observations.forget()
    client.invalidate()
    switch result {
    case .success(let reply):
      return reply.code == .cleared ? .succeeded : .failed(code: LiveInterpreter.helperRefusedCode)
    case .failed(let reason):
      return .failed(code: Self.code(forFailure: reason))
    case .timedOut:
      return .timedOut
    }
  }

  public func probe() -> HelperProbe {
    if let held = heldAnswer() { return held }
    conversation.lock()
    defer { conversation.unlock() }
    if let held = heldAnswer() { return held }
    switch client.status(appVersion: HelperIdentity.version) {
    case .success(let status):
      observations.note(status)
      return .answered(status)
    case .failed(let reason):
      observations.forget()
      return .unreachable(reason)
    case .timedOut:
      observations.forget()
      return .unreachable(Self.timedOutReason)
    }
  }

  public static func code(forFailure reason: String) -> Int32 {
    let parts = reason.split(separator: " ")
    guard parts.count == 2, parts[0] != replyCodePrefix, let code = Int32(parts[1]) else {
      return LiveInterpreter.helperUnavailableCode
    }
    return code
  }

  private func heldAnswer() -> HelperProbe? {
    holding.withLock { $0 } ? .engaged(observations.status) : nil
  }

  private func exchange(_ call: () -> EffectOutcome) -> EffectOutcome {
    let started = DispatchTime.now().uptimeNanoseconds
    conversation.lock()
    defer { conversation.unlock() }
    var outcome = EffectOutcome.timedOut
    if !isLate(since: started) {
      outcome = call()
      if outcome == .succeeded, isLate(since: started) {
        outcome = .timedOut
      }
    }
    if outcome != .succeeded {
      holding.withLock { $0 = false }
      observations.forget()
      client.invalidate()
    }
    return outcome
  }

  private func isLate(since started: UInt64) -> Bool {
    let elapsed = DispatchTime.now().uptimeNanoseconds - started
    return Double(elapsed) / 1_000_000_000 >= boundSeconds
  }
}
