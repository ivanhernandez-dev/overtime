import OvertimeHelperCore
import os

final class FakeHelperSystem: HelperSystemPort, HelperRecordPort, HelperLogPort, HelperClock, Sendable {
  enum Call: Sendable, Equatable {
    case readSleepDisabled
    case writeSleepDisabled(Bool)
    case lidClosed
    case clamshellEdge
    case power
    case thermal
    case pause(Int)
    case recordRead
    case recordWrite(owns: Bool, prior: Bool)
    case log(String)

    var isHoldCall: Bool {
      switch self {
      case .readSleepDisabled, .writeSleepDisabled, .clamshellEdge, .recordWrite:
        return true
      case .lidClosed, .power, .thermal, .pause, .recordRead, .log:
        return false
      }
    }
  }

  static let startSeconds: Double = 1_000
  static let onPower = HelperPowerFacts(onBattery: false, percent: 80, warningLevel: HelperPowerFacts.warningNone)
  static let nominal = HelperThermalFacts(pressureLevel: 0, critical: false)

  private struct State {
    var calls: [Call] = []
    var sleepDisabled: Bool?
    var registryFollowsWrites = true
    var registryLagReads = 0
    var pendingValue: Bool?
    var pendingReads = 0
    var writeSucceeds = true
    var lid: Bool?
    var edgeSucceeds = true
    var power: HelperPowerFacts? = FakeHelperSystem.onPower
    var thermal: HelperThermalFacts? = FakeHelperSystem.nominal
    var now = FakeHelperSystem.startSeconds
    var stored: HelperRecordRead
    var recordWriteSucceeds = true
  }

  private let state: OSAllocatedUnfairLock<State>

  init(sleepDisabled: Bool? = false, lid: Bool? = true, stored: HelperRecordRead = .missing) {
    state = OSAllocatedUnfairLock(initialState: State(sleepDisabled: sleepDisabled, lid: lid, stored: stored))
  }

  var calls: [Call] { state.withLock { $0.calls } }
  var holdCalls: [Call] { calls.filter(\.isHoldCall) }
  var actions: [Call] {
    calls.filter {
      if case .log = $0 { return false }
      return true
    }
  }
  var pmsetWrites: [Bool] {
    calls.compactMap {
      if case .writeSleepDisabled(let value) = $0 { return value }
      return nil
    }
  }
  var edgeCount: Int { calls.filter { $0 == .clamshellEdge }.count }
  var sleepDisabledReads: Int { calls.filter { $0 == .readSleepDisabled }.count }
  var pauses: [Int] {
    calls.compactMap {
      if case .pause(let milliseconds) = $0 { return milliseconds }
      return nil
    }
  }
  var logLines: [String] {
    calls.compactMap {
      if case .log(let line) = $0 { return line }
      return nil
    }
  }
  var sleepDisabled: Bool? { state.withLock { $0.sleepDisabled } }
  var stored: HelperRecordRead { state.withLock { $0.stored } }
  var storedRecord: HelperRecord? {
    if case .loaded(let record) = stored { return record }
    return nil
  }
  var seconds: Double { state.withLock { $0.now } }

  func forget() {
    state.withLock { $0.calls.removeAll() }
  }

  func advance(seconds: Double) {
    state.withLock { $0.now += seconds }
  }

  func setSleepDisabled(_ value: Bool?) {
    state.withLock {
      $0.sleepDisabled = value
      $0.pendingValue = nil
    }
  }

  func setRegistryFollowsWrites(_ follows: Bool) {
    state.withLock { $0.registryFollowsWrites = follows }
  }

  func setRegistryLagReads(_ reads: Int) {
    state.withLock { $0.registryLagReads = reads }
  }

  func setWriteSucceeds(_ succeeds: Bool) {
    state.withLock { $0.writeSucceeds = succeeds }
  }

  func setLid(_ closed: Bool?) {
    state.withLock { $0.lid = closed }
  }

  func setEdgeSucceeds(_ succeeds: Bool) {
    state.withLock { $0.edgeSucceeds = succeeds }
  }

  func setPower(_ facts: HelperPowerFacts?) {
    state.withLock { $0.power = facts }
  }

  func setThermal(_ facts: HelperThermalFacts?) {
    state.withLock { $0.thermal = facts }
  }

  func setStored(_ read: HelperRecordRead) {
    state.withLock { $0.stored = read }
  }

  func setRecordWriteSucceeds(_ succeeds: Bool) {
    state.withLock { $0.recordWriteSucceeds = succeeds }
  }

  func readSleepDisabled() -> Bool? {
    state.withLock {
      $0.calls.append(.readSleepDisabled)
      if let pending = $0.pendingValue {
        if $0.pendingReads == 0 {
          $0.sleepDisabled = pending
          $0.pendingValue = nil
        } else {
          $0.pendingReads -= 1
        }
      }
      return $0.sleepDisabled
    }
  }

  func writeSleepDisabled(_ disabled: Bool) -> Bool {
    state.withLock {
      $0.calls.append(.writeSleepDisabled(disabled))
      guard $0.writeSucceeds else { return false }
      guard $0.registryFollowsWrites else { return true }
      if $0.registryLagReads == 0 {
        $0.sleepDisabled = disabled
        $0.pendingValue = nil
      } else {
        $0.pendingValue = disabled
        $0.pendingReads = $0.registryLagReads
      }
      return true
    }
  }

  func lidClosed() -> Bool? {
    state.withLock {
      $0.calls.append(.lidClosed)
      return $0.lid
    }
  }

  func clamshellEdge() -> Bool {
    state.withLock {
      $0.calls.append(.clamshellEdge)
      return $0.edgeSucceeds
    }
  }

  func power() -> HelperPowerFacts? {
    state.withLock {
      $0.calls.append(.power)
      return $0.power
    }
  }

  func thermal() -> HelperThermalFacts? {
    state.withLock {
      $0.calls.append(.thermal)
      return $0.thermal
    }
  }

  func pause(milliseconds: Int) {
    state.withLock {
      $0.calls.append(.pause(milliseconds))
      $0.now += Double(milliseconds) / 1_000
    }
  }

  func read() -> HelperRecordRead {
    state.withLock {
      $0.calls.append(.recordRead)
      return $0.stored
    }
  }

  func write(_ record: HelperRecord) -> Bool {
    state.withLock {
      $0.calls.append(.recordWrite(owns: record.owns, prior: record.prior))
      guard $0.recordWriteSucceeds else { return false }
      $0.stored = .loaded(record)
      return true
    }
  }

  func record(_ line: String) {
    state.withLock { $0.calls.append(.log(line)) }
  }

  func now() -> Double {
    state.withLock { $0.now }
  }
}
