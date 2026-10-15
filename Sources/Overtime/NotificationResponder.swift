import Foundation
import OvertimeAppSupport
import OvertimeEngine
import OvertimeSystem

final class NotificationResponder {
  nonisolated static let openAction = "open"

  private let host: () -> (any EngineHosting)?
  private let onOpenSettings: (SettingsPane) -> Void
  private let now: () -> Date
  private let calendar: Calendar

  init(
    host: @escaping () -> (any EngineHosting)?, onOpenSettings: @escaping (SettingsPane) -> Void,
    now: @escaping () -> Date = { Date() }, calendar: Calendar = .current
  ) {
    self.host = host
    self.onOpenSettings = onOpenSettings
    self.now = now
    self.calendar = calendar
  }

  func handle(category: NotificationCategory, actionIdentifier: String) async {
    switch (category, actionIdentifier) {
    case (.forceReminder, NotificationContent.turnOffActionIdentifier):
      await turnOff()
    case (.keepAwakeFailed, Self.openAction):
      onOpenSettings(.diagnostics)
    default:
      return
    }
  }

  private func turnOff() async {
    guard let host = host(), let snapshot = await host.probe(), snapshot.force != nil else { return }
    _ = await host.send(ControlMapping.request(for: .stopKeepingAwake, now: now(), calendar: calendar))
  }
}
