import Foundation
import OvertimeCore
import OvertimeSystem
import os

final class FakeWiFiRadio: WiFiRadio {
  enum Kind: String, Sendable, CaseIterable {
    case interfaceName
    case adminRequirements
    case savedSecurity
    case powerOn
    case setPower
    case joinSaved
  }

  enum Call: Sendable, Equatable {
    case interfaceName
    case adminRequirements(interface: String)
    case savedSecurity(interface: String, ssid: String)
    case powerOn(interface: String)
    case setPower(interface: String, on: Bool)
    case joinSaved(interface: String, ssid: String)

    var kind: Kind {
      switch self {
      case .interfaceName: .interfaceName
      case .adminRequirements: .adminRequirements
      case .savedSecurity: .savedSecurity
      case .powerOn: .powerOn
      case .setPower: .setPower
      case .joinSaved: .joinSaved
      }
    }

    var isWrite: Bool {
      switch self {
      case .setPower, .joinSaved: true
      case .interfaceName, .adminRequirements, .savedSecurity, .powerOn: false
      }
    }
  }

  static let wpa2Personal = SavedProfileSecurity.security(rawValue: 4)

  struct Script: Sendable {
    var interface: String? = "en0"
    var admin: AdminRequirements? = AdminRequirements(power: false, association: false)
    var saved: SavedProfileSecurity? = FakeWiFiRadio.wpa2Personal
    var powered: Bool? = true
    var poweredAnswers: [Bool?] = []
    var powerFollowsWrites = true
    var setPowerResult: Result<Void, RadioError> = .success(())
    var setPowerResults: [Result<Void, RadioError>] = []
    var joinResult: Result<Void, RadioError> = .success(())
    var seconds: [Kind: Double] = [:]
    var markerURL: URL?
    var holdNext: Kind?
    var powerCallPending = false
  }

  struct Entry: Sendable, Equatable {
    var call: Call
    var markerExists: Bool?
    var at: Instant?
  }

  private struct State: Sendable {
    var script: Script
    var entries: [Entry] = []
    var holding = false
  }

  private let state: OSAllocatedUnfairLock<State>
  private let clock: FakeClock?
  private let gate = DispatchSemaphore(value: 0)

  init(_ script: Script = Script(), clock: FakeClock? = nil) {
    state = OSAllocatedUnfairLock(initialState: State(script: script))
    self.clock = clock
  }

  var calls: [Call] {
    state.withLock { $0.entries.map(\.call) }
  }

  var entries: [Entry] {
    state.withLock { $0.entries }
  }

  var writes: [Call] {
    calls.filter(\.isWrite)
  }

  var isHolding: Bool {
    state.withLock { $0.holding }
  }

  var powered: Bool? {
    state.withLock { $0.script.powered }
  }

  func update(_ change: @Sendable (inout Script) -> Void) {
    state.withLock { change(&$0.script) }
  }

  func release() {
    gate.signal()
  }

  static func exists(_ url: URL?) -> Bool? {
    guard let url else { return nil }
    var info = stat()
    return lstat(url.path(percentEncoded: false), &info) == 0
  }

  private func record<T: Sendable>(_ call: Call, _ answer: @Sendable (inout Script) -> T) -> T {
    let at = clock?.mono()
    let holds = state.withLock { state -> Bool in
      state.entries.append(Entry(call: call, markerExists: Self.exists(state.script.markerURL), at: at))
      guard state.script.holdNext == call.kind else { return false }
      state.script.holdNext = nil
      state.holding = true
      return true
    }
    if holds {
      gate.wait()
      state.withLock { $0.holding = false }
    }
    let (value, seconds) = state.withLock { state -> (T, Double) in
      (answer(&state.script), state.script.seconds[call.kind] ?? 0)
    }
    if seconds > 0 { clock?.advance(seconds: seconds) }
    return value
  }

  func interfaceName() -> String? {
    record(.interfaceName) { $0.interface }
  }

  func adminRequirements(interface: String) -> AdminRequirements? {
    record(.adminRequirements(interface: interface)) { $0.admin }
  }

  func savedSecurity(interface: String, ssid: String) -> SavedProfileSecurity? {
    record(.savedSecurity(interface: interface, ssid: ssid)) { $0.saved }
  }

  func powerOn(interface: String) -> Bool? {
    record(.powerOn(interface: interface)) { script in
      guard !script.poweredAnswers.isEmpty else { return script.powered }
      return script.poweredAnswers.removeFirst()
    }
  }

  func setPower(interface: String, on: Bool) -> Result<Void, RadioError> {
    record(.setPower(interface: interface, on: on)) { script in
      let result = script.setPowerResults.isEmpty ? script.setPowerResult : script.setPowerResults.removeFirst()
      if case .success = result, script.powerFollowsWrites { script.powered = on }
      return result
    }
  }

  func joinSaved(interface: String, ssid: String) -> Result<Void, RadioError> {
    record(.joinSaved(interface: interface, ssid: ssid)) { $0.joinResult }
  }

  func powerCallPending() -> Bool {
    state.withLock { $0.script.powerCallPending }
  }
}

final class ToolFactoryRecorder: Sendable {
  let tool: FakeToolPort
  private let recorded = OSAllocatedUnfairLock<[Double]>(initialState: [])

  init(_ tool: FakeToolPort = FakeToolPort()) {
    self.tool = tool
  }

  var timeouts: [Double] {
    recorded.withLock { $0 }
  }

  var make: @Sendable (Double) -> any ToolPort {
    { [recorded, tool] timeout in
      recorded.withLock { $0.append(timeout) }
      return tool
    }
  }
}
