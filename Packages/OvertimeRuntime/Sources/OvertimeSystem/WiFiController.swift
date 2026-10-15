import Foundation
import OvertimeCore
import os

public final class WiFiController: Sendable {
  public static let networksetup = "/usr/sbin/networksetup"
  public static let joinVerb = "-setairportnetwork"
  public static let powerVerb = "-setairportpower"
  public static let joinBudgetSeconds: Double = 14
  public static let fallbackMinimumSeconds: Double = 6
  public static let fallbackMaxSeconds: Double = 12
  public static let fallbackReserveSeconds: Double = 2
  public static let radioCallSeconds: Double = 5
  public static let radioJoinSeconds: Double = 2 * radioCallSeconds
  public static let knownNetworksKey = "wifi.known"
  public static let offSeconds: Double = 3
  public static let cycleBudgetSeconds: Double = 22
  public static let actuationWaitSeconds: Double = 5
  public static let offFallbackMinimumSeconds: Double = 7
  public static let settleSeconds: Double = 5
  public static let markerMaxAgeSeconds: Double = 600

  public enum Code: Int32, Sendable, CaseIterable {
    case invalidName = -20
    case invalidInterface = -21
    case adminRequired = -22
    case notKnown = -23
    case budget = -24
    case notFound = -25
    case joinFailed = -26
    case wifiOff = -27
    case toolFailed = -28
    case stillOff = -29
    case markerFailed = -30
    case busy = -31
    case offFailed = -32
    case insecureProfile = -33
    case powerUnknown = -34

    public var outcome: EffectOutcome {
      .failed(code: rawValue)
    }
  }

  private let radio: any WiFiRadio
  private let knownNetworks: @Sendable () -> [String]?
  private let locationAuthorized: @Sendable () -> Bool
  private let clock: any ClockPort
  private let makeTools: @Sendable (Double) -> any ToolPort
  private let readTimeoutSeconds: Double
  private let marker: WiFiCycleMarker?
  private let sleep: @Sendable (Double) -> Void
  private let actuationWait: Double
  private let actuation = NSLock()
  private let runner = DeadlineRunner()
  private let logSink = OSAllocatedUnfairLock<(@Sendable (Decision) -> Void)?>(initialState: nil)
  private let kept = OSAllocatedUnfairLock<Bool?>(initialState: nil)

  public init(
    radio: any WiFiRadio = CoreWLANRadio(),
    knownNetworks: @escaping @Sendable () -> [String]? = KnownNetworks.names,
    locationAuthorized: @escaping @Sendable () -> Bool,
    clock: any ClockPort = SystemClock(),
    makeTools: @escaping @Sendable (Double) -> any ToolPort = { ToolRunner(timeoutSeconds: $0) },
    readTimeoutSeconds: Double = WiFiController.radioCallSeconds,
    marker: WiFiCycleMarker? = nil,
    sleep: @escaping @Sendable (Double) -> Void = { Thread.sleep(forTimeInterval: $0) },
    actuationWaitSeconds: Double = WiFiController.actuationWaitSeconds
  ) {
    self.radio = radio
    self.knownNetworks = knownNetworks
    self.locationAuthorized = locationAuthorized
    self.clock = clock
    self.makeTools = makeTools
    self.readTimeoutSeconds = readTimeoutSeconds
    self.marker = marker
    self.sleep = sleep
    actuationWait = actuationWaitSeconds
  }

  public func attachLog(_ log: @escaping @Sendable (Decision) -> Void) {
    logSink.withLock { $0 = log }
  }

  public var markerPresent: Bool {
    guard let marker else { return false }
    return marker.read() != .absent
  }

  public var markerKept: Bool {
    if let known = kept.withLock({ $0 }) { return known }
    let present = markerPresent
    return kept.withLock { state in
      if let state { return state }
      state = present
      return present
    }
  }

  private func noteMarker() {
    let present = markerPresent
    kept.withLock { $0 = present }
  }

  public func recoverIfLeftOff(waitSeconds: Double) -> EffectOutcome {
    guard marker != nil else { return .succeeded }
    guard actuation.lock(before: Date(timeIntervalSinceNow: waitSeconds)) else { return Code.busy.outcome }
    defer { actuation.unlock() }
    defer { noteMarker() }
    return recoverLocked()
  }

  public func cycleWifi() -> EffectOutcome {
    let start = clock.mono()
    guard actuation.lock(before: Date(timeIntervalSinceNow: actuationWait)) else { return Code.busy.outcome }
    defer { actuation.unlock() }
    defer { noteMarker() }
    _ = recoverLocked()
    guard let interface = radio.interfaceName(), Self.isValidInterface(interface) else {
      return Code.invalidInterface.outcome
    }
    switch radio.adminRequirements(interface: interface)?.power {
    case false?:
      break
    case true?:
      return Code.adminRequired.outcome
    case nil:
      return Code.powerUnknown.outcome
    }
    switch radio.powerOn(interface: interface) {
    case true?:
      break
    case false?:
      return Code.wifiOff.outcome
    case nil:
      return Code.powerUnknown.outcome
    }
    let startedAt = clock.wall()
    guard let marker, marker.write(interface: interface, startedAt: startedAt) else {
      return Code.markerFailed.outcome
    }
    let off = turnOff(interface: interface, start: start)
    self.sleep(Self.offSeconds)
    guard turnOnConfirmed(interface: interface) else { return Code.stillOff.outcome }
    if offSettled(interface: interface, off: off) {
      _ = marker.write(interface: interface, startedAt: startedAt, settled: true)
      _ = marker.remove()
    }
    return off.done ? .succeeded : Code.offFailed.outcome
  }

  private func offSettled(interface: String, off: OffResult) -> Bool {
    guard off.uncertain else { return true }
    if !offPending(off) { return confirmedOn(interface: interface) }
    self.sleep(Self.settleSeconds)
    if !offPending(off) { return confirmedOn(interface: interface) }
    if radio.powerOn(interface: interface) != true { _ = turnOnConfirmed(interface: interface) }
    return !radio.powerCallPending() && radio.powerOn(interface: interface) == true
  }

  private func offPending(_ off: OffResult) -> Bool {
    off.toolTimedOut || (off.radioTimedOut && radio.powerCallPending())
  }

  private func confirmedOn(interface: String) -> Bool {
    radio.powerOn(interface: interface) == true || turnOnConfirmed(interface: interface)
  }

  public func joinHotspot(_ name: String) -> EffectOutcome {
    let start = clock.mono()
    guard actuation.lock(before: Date(timeIntervalSinceNow: actuationWait)) else { return Code.busy.outcome }
    defer { actuation.unlock() }
    defer { noteMarker() }
    let recovered = recoverLocked()
    guard recovered != Code.stillOff.outcome else { return recovered }
    return joinLocked(name, start: start)
  }

  private func recoverLocked() -> EffectOutcome {
    guard let marker else { return .succeeded }
    let (state, startedAt, settled) = marker.readWithStart()
    guard state != .absent else { return .succeeded }
    if settled {
      guard marker.remove() else { return Code.markerFailed.outcome }
      if let startedAt, clock.wall().timeIntervalSince(startedAt) > Self.markerMaxAgeSeconds {
        logSink.withLock { $0 }?(Self.markerExpired)
      }
      return .succeeded
    }
    guard let interface = recoveryInterface(state) else { return Code.invalidInterface.outcome }
    if radio.powerOn(interface: interface) != true {
      guard turnOnConfirmed(interface: interface) else { return Code.stillOff.outcome }
    }
    guard !radio.powerCallPending() else { return .succeeded }
    return marker.remove() ? .succeeded : Code.markerFailed.outcome
  }

  public static let markerExpired = Decision(keyword: .net, verb: "marker expired")

  private func recoveryInterface(_ state: MarkerState) -> String? {
    if let current = radio.interfaceName(), Self.isValidInterface(current) { return current }
    if case .present(let interface) = state { return interface }
    return nil
  }

  private struct OffResult {
    var done: Bool
    var radioTimedOut = false
    var toolTimedOut = false

    var uncertain: Bool {
      radioTimedOut || toolTimedOut
    }
  }

  private func turnOff(interface: String, start: Instant) -> OffResult {
    let radioOff = radio.setPower(interface: interface, on: false)
    if case .success = radioOff { return OffResult(done: true) }
    var result = OffResult(done: false)
    if case .failure(.timedOut) = radioOff { result.radioTimedOut = true }
    let left = Self.cycleBudgetSeconds - clock.mono().seconds(since: start)
    guard left >= Self.offFallbackMinimumSeconds else { return result }
    let outcome = runPowerTool(interface: interface, on: false)
    result.done = Self.powerToolSucceeded(outcome)
    result.toolTimedOut = outcome == .timedOut
    return result
  }

  private func turnOnConfirmed(interface: String) -> Bool {
    if case .failure = radio.setPower(interface: interface, on: true) {
      _ = runPowerTool(interface: interface, on: true)
    }
    if radio.powerOn(interface: interface) == true { return true }
    if case .success = radio.setPower(interface: interface, on: true), radio.powerOn(interface: interface) == true {
      return true
    }
    _ = runPowerTool(interface: interface, on: true)
    return radio.powerOn(interface: interface) == true
  }

  private func joinLocked(_ name: String, start: Instant) -> EffectOutcome {
    guard Settings.isValidSSID(name) else { return Code.invalidName.outcome }
    guard let interface = radio.interfaceName(), Self.isValidInterface(interface) else {
      return Code.invalidInterface.outcome
    }
    guard radio.adminRequirements(interface: interface)?.association == false else {
      return Code.adminRequired.outcome
    }
    guard let known = readKnownNetworks(), let ssid = known.first(where: { $0 == name }) else {
      return Code.notKnown.outcome
    }
    guard CoreWLANRadio.acceptsSaved(radio.savedSecurity(interface: interface, ssid: ssid)) else {
      return Code.insecureProfile.outcome
    }
    if remainingSeconds(since: start) >= Self.radioJoinSeconds, locationAuthorized() {
      switch radio.joinSaved(interface: interface, ssid: ssid) {
      case .success: return .succeeded
      case .failure(.insecureOnly): return Code.insecureProfile.outcome
      case .failure: break
      }
    }
    let remaining = remainingSeconds(since: start)
    guard remaining >= Self.fallbackMinimumSeconds else { return Code.budget.outcome }
    let tools = makeTools(min(Self.fallbackMaxSeconds, remaining - Self.fallbackReserveSeconds))
    return Self.joinOutcome(tools.run(Self.networksetup, [Self.joinVerb, interface, ssid]))
  }

  public static func isValidInterface(_ name: String) -> Bool {
    let bytes = Array(name.utf8)
    guard bytes.count > 2, bytes[0] == UInt8(ascii: "e"), bytes[1] == UInt8(ascii: "n") else { return false }
    return bytes.dropFirst(2).allSatisfy { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }
  }

  public static func joinOutcome(_ outcome: ToolOutcome) -> EffectOutcome {
    switch outcome {
    case .timedOut:
      return .timedOut
    case .launchFailed:
      return Code.toolFailed.outcome
    case .finished(_, let stdout, let stderr):
      let text = stdout + stderr
      if text.allSatisfy(\.isWhitespace) { return .succeeded }
      if text.contains("Could not find network") { return Code.notFound.outcome }
      if text.contains("Failed to join network") { return Code.joinFailed.outcome }
      if text.contains("requires admin") { return Code.adminRequired.outcome }
      if text.contains("Wi-Fi power is off") { return Code.wifiOff.outcome }
      return Code.toolFailed.outcome
    }
  }

  public static func powerToolSucceeded(_ outcome: ToolOutcome) -> Bool {
    guard case .finished(_, let stdout, let stderr) = outcome else { return false }
    return (stdout + stderr).allSatisfy(\.isWhitespace)
  }

  private func runPowerTool(interface: String, on: Bool) -> ToolOutcome {
    let tool = Self.networksetup
    return makeTools(Self.radioCallSeconds).run(tool, [Self.powerVerb, interface, on ? "on" : "off"])
  }

  private func remainingSeconds(since start: Instant) -> Double {
    Self.joinBudgetSeconds - clock.mono().seconds(since: start)
  }

  private func readKnownNetworks() -> [String]? {
    let read = knownNetworks
    switch runner.run(timeout: readTimeoutSeconds, key: Self.knownNetworksKey, read) {
    case .value(let names): return names
    case .timedOut: return nil
    }
  }
}
