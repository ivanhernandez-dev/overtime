import AppKit
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine

final class TerminationLifecycle {
  static let logoutResetSeconds: Double = 30

  private let host: AppHost
  private let center: NotificationCenter
  private let onFinished: () -> Void
  private let prepare: () async -> Void
  private let logoutResetSeconds: Double
  private var logoutReset: Task<Void, Never>?
  private var powerOffObserver: (any NSObjectProtocol)?
  private var terminationTask: Task<Void, Never>?
  private(set) var logoutPending = false

  var isTerminating: Bool {
    terminationTask != nil
  }

  init(
    host: AppHost, center: NotificationCenter = NSWorkspace.shared.notificationCenter,
    logoutResetSeconds: Double = TerminationLifecycle.logoutResetSeconds,
    prepare: @escaping () async -> Void = {}, onFinished: @escaping () -> Void = {}
  ) {
    self.logoutResetSeconds = logoutResetSeconds
    self.host = host
    self.center = center
    self.prepare = prepare
    self.onFinished = onFinished
  }

  func observePowerOff() {
    guard powerOffObserver == nil else { return }
    powerOffObserver = center.addObserver(
      forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.powerOffBegan()
      }
    }
  }

  func powerOffBegan() {
    guard !logoutPending else { return }
    logoutPending = true
    guard terminationTask == nil else { return }
    host.runningHost?.engine.logImmediately(Decision(keyword: .check, verb: "logout pending"))
    let milliseconds = Int(max(0, logoutResetSeconds) * 1000)
    logoutReset = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(milliseconds))
      guard !Task.isCancelled else { return }
      self?.logoutNotFollowedByQuit()
    }
  }

  private func logoutNotFollowedByQuit() {
    guard terminationTask == nil else { return }
    logoutPending = false
  }

  func begin() -> Task<Void, Never> {
    if let terminationTask { return terminationTask }
    logoutReset?.cancel()
    logoutReset = nil
    let host = host
    let prepare = prepare
    let onFinished = onFinished
    let task = Task {
      let prepared = Task { await prepare() }
      _ = await host.terminate()
      await prepared.value
      onFinished()
    }
    terminationTask = task
    return task
  }
}
