import Foundation
import OvertimeAppSupport
import os

final class FakeUninstallSystem: UninstallSystem {
  enum Call: Sendable, Equatable {
    case stop
    case status
    case ownership
    case record
    case clear
    case unregister
    case readSleepDisabled
    case admin(UninstallAdminCommand)
    case unregisterLoginItem
    case purgeDefaults(String)
    case removeUserItems([PurgeItem])
    case updateStagedForQuit
    case removeStagedUpdate([String], PurgeItem)
    case trashApp(String)
  }

  enum Slow: Sendable, Hashable {
    case stop
    case status
    case ownership
    case record
    case clear
    case unregister
    case read
    case admin
    case loginItem
    case defaults
    case userItems
    case staged
    case stagedRemove
    case trash
  }

  struct Answers: Sendable {
    var stop = UninstallEngineStop.stopped
    var status = HelperInstallerStatus.notRegistered
    var ownership = HelperOwnership.owned
    var record = HelperOwnership.notOwned
    var clear = true
    var unregister = true
    var sleepDisabled: [Bool?] = [false]
    var admin = AdminOutcome.succeeded
    var loginItem = true
    var userItems = true
    var staged = false
    var stagedRemoved = true
    var trash = UninstallTrashResult.trashed
    var delays: [Slow: Double] = [:]
  }

  private struct State: Sendable {
    var answers: Answers
    var calls: [Call] = []
    var reads = 0
  }

  private let state: OSAllocatedUnfairLock<State>

  init(_ configure: (inout Answers) -> Void = { _ in }) {
    var answers = Answers()
    configure(&answers)
    state = OSAllocatedUnfairLock(initialState: State(answers: answers))
  }

  var calls: [Call] {
    state.withLock { $0.calls }
  }

  var adminCalls: Int {
    state.withLock { $0.calls.filter { if case .admin = $0 { true } else { false } }.count }
  }

  func update(_ change: @Sendable (inout Answers) -> Void) {
    state.withLock { change(&$0.answers) }
  }

  private func record(_ call: Call, slow: Slow? = nil) -> Answers {
    let answers = state.withLock { state -> Answers in
      state.calls.append(call)
      return state.answers
    }
    if let slow, let delay = answers.delays[slow] {
      Thread.sleep(forTimeInterval: delay)
    }
    return answers
  }

  func stopKeepAwake() async -> UninstallEngineStop {
    let answers = state.withLock { state -> Answers in
      state.calls.append(.stop)
      return state.answers
    }
    if let delay = answers.delays[.stop] {
      try? await Task.sleep(for: .seconds(delay))
    }
    return answers.stop
  }

  func helperStatus() -> HelperInstallerStatus {
    record(.status, slow: .status).status
  }

  func helperOwnership() -> HelperOwnership {
    record(.ownership, slow: .ownership).ownership
  }

  func recordOwnership() -> HelperOwnership {
    record(.record, slow: .record).record
  }

  func helperClear() -> Bool {
    record(.clear, slow: .clear).clear
  }

  func unregisterHelper() -> Bool {
    record(.unregister, slow: .unregister).unregister
  }

  func readSleepDisabled() -> Bool? {
    let (answers, index) = state.withLock { state -> (Answers, Int) in
      state.calls.append(.readSleepDisabled)
      defer { state.reads += 1 }
      return (state.answers, state.reads)
    }
    if let delay = answers.delays[.read] {
      Thread.sleep(forTimeInterval: delay)
    }
    guard let last = answers.sleepDisabled.last else { return nil }
    return index < answers.sleepDisabled.count ? answers.sleepDisabled[index] : last
  }

  func runAdmin(_ command: UninstallAdminCommand) -> AdminOutcome {
    record(.admin(command), slow: .admin).admin
  }

  func unregisterLoginItem() -> Bool {
    record(.unregisterLoginItem, slow: .loginItem).loginItem
  }

  func purgeDefaults(appIdentifier: String) {
    _ = record(.purgeDefaults(appIdentifier), slow: .defaults)
  }

  func removeUserItems(_ items: [PurgeItem]) -> Bool {
    record(.removeUserItems(items), slow: .userItems).userItems
  }

  func updateStagedForQuit() -> Bool {
    record(.updateStagedForQuit, slow: .staged).staged
  }

  func removeStagedUpdate(labels: [String], cache: PurgeItem) -> Bool {
    record(.removeStagedUpdate(labels, cache), slow: .stagedRemove).stagedRemoved
  }

  func trashApp(expectedIdentifier: String) -> UninstallTrashResult {
    record(.trashApp(expectedIdentifier), slow: .trash).trash
  }
}
