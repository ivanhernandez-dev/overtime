import Foundation
import OvertimeAppSupport
import os

final class FakeHelperInstaller: HelperInstallerService {
  struct FakeError: Error, CustomStringConvertible {
    var description: String { "Operation not permitted" }
  }

  private struct State {
    var status: HelperInstallerStatus
    var calls: [String] = []
    var statusReads = 0
    var failRegister = false
    var statusAfterFailure: HelperInstallerStatus?
    var failUnregister = false
    var holding = false
    var heldReturned = 0
  }

  static let heldSeconds: Double = 10

  private let state: OSAllocatedUnfairLock<State>
  private let gate = DispatchSemaphore(value: 0)

  init(status: HelperInstallerStatus = .notRegistered) {
    state = OSAllocatedUnfairLock(initialState: State(status: status))
  }

  var heldReturned: Int {
    state.withLock { $0.heldReturned }
  }

  var status: HelperInstallerStatus {
    state.withLock { state in
      state.statusReads += 1
      return state.status
    }
  }

  var calls: [String] {
    state.withLock { $0.calls }
  }

  var statusReads: Int {
    state.withLock { $0.statusReads }
  }

  func setStatus(_ status: HelperInstallerStatus) {
    state.withLock { $0.status = status }
  }

  func failRegister(leaving status: HelperInstallerStatus) {
    state.withLock {
      $0.failRegister = true
      $0.statusAfterFailure = status
    }
  }

  func failUnregister() {
    state.withLock { $0.failUnregister = true }
  }

  func holdCalls() {
    state.withLock { $0.holding = true }
  }

  func releaseCalls() {
    state.withLock { $0.holding = false }
    for _ in 0..<4 { gate.signal() }
  }

  func register() throws {
    let held = state.withLock { state -> Bool in
      state.calls.append("register")
      return state.holding
    }
    hold(held)
    try state.withLock { state in
      if state.failRegister {
        state.status = state.statusAfterFailure ?? state.status
        throw FakeError()
      }
      state.status = .enabled
    }
  }

  func unregister() throws {
    let held = state.withLock { state -> Bool in
      state.calls.append("unregister")
      return state.holding
    }
    hold(held)
    try state.withLock { state in
      if state.failUnregister { throw FakeError() }
      state.status = .notRegistered
    }
  }

  func openSystemSettings() {
    state.withLock { $0.calls.append("openSystemSettings") }
  }

  private func hold(_ held: Bool) {
    guard held else { return }
    _ = gate.wait(timeout: .now() + Self.heldSeconds)
    state.withLock { $0.heldReturned += 1 }
  }
}
