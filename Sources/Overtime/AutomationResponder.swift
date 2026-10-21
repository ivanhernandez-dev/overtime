import Foundation
import OvertimeAppSupport
import OvertimeCore

final class AutomationResponder {
  static var scheme: String {
    #if DEBUG
      AutomationURL.debugScheme
    #else
      AutomationURL.releaseScheme
    #endif
  }

  private let model: PanelModel
  private let scheme: String
  private let calendar: Calendar
  private let log: (Decision) -> Void
  private var awaitingEngine: Bool
  private(set) var pending: AutomationCommand?
  private var tail: Task<Void, Never>?

  init(
    model: PanelModel, awaitingEngine: Bool, scheme: String = AutomationResponder.scheme,
    calendar: Calendar = .current, log: @escaping (Decision) -> Void
  ) {
    self.model = model
    self.awaitingEngine = awaitingEngine
    self.scheme = scheme
    self.calendar = calendar
    self.log = log
  }

  @discardableResult
  func enqueue(_ text: String) -> Task<Void, Never> {
    chain { responder in await responder.receive(text) }
  }

  @discardableResult
  func engineStarted() -> Task<Void, Never> {
    chain { responder in await responder.replayPending() }
  }

  func engineFailed() {
    awaitingEngine = false
    guard let command = pending else { return }
    pending = nil
    log(AutomationOutcome.failed(command).decision)
  }

  @discardableResult
  func receive(_ text: String) async -> AutomationOutcome {
    let outcome: AutomationOutcome
    switch AutomationURL.parse(text, scheme: scheme) {
    case .failure(let error):
      outcome = .rejected(error)
    case .success(let command) where awaitingEngine && model.host == nil:
      pending = command
      outcome = .waitingForEngine(command)
    case .success(let command):
      outcome = await run(command)
    }
    log(outcome.decision)
    return outcome
  }

  private func replayPending() async {
    awaitingEngine = false
    guard let command = pending else { return }
    pending = nil
    log(await run(command).decision)
  }

  private func run(_ command: AutomationCommand) async -> AutomationOutcome {
    guard model.controls.engineControlsEnabled else { return .controlsUnavailable(command) }
    if command == .stopKeepAwake {
      guard let host = model.host, let snapshot = await host.probe(), snapshot.force != nil else {
        return .nothingToStop
      }
    }
    let action = AutomationURL.action(for: command, now: model.clock.wall(), calendar: calendar)
    let response = await model.perform(action)
    return ControlFeedback.failed(response) ? .failed(command) : .sent(command)
  }

  private func chain(_ work: @escaping (AutomationResponder) async -> Void) -> Task<Void, Never> {
    let previous = tail
    let task = Task { [weak self] in
      await previous?.value
      guard let self else { return }
      await work(self)
    }
    tail = task
    return task
  }
}
