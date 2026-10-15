import Foundation
import OvertimeAppSupport
import UserNotifications

@MainActor
final class UserNotificationsAdapter: NSObject, NotificationPort, UNUserNotificationCenterDelegate {
  var responder: NotificationResponder?

  func attach() {
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    center.setNotificationCategories([Self.forceReminderCategory])
  }

  static var forceReminderCategory: UNNotificationCategory {
    let turnOff = UNNotificationAction(
      identifier: NotificationContent.turnOffActionIdentifier, title: NotificationContent.turnOffActionTitle,
      options: [])
    return UNNotificationCategory(
      identifier: NotificationCategory.forceReminder.identifier, actions: [turnOff], intentIdentifiers: [],
      options: [])
  }

  nonisolated static func actionIdentifier(_ identifier: String) -> String {
    identifier == UNNotificationDefaultActionIdentifier ? NotificationResponder.openAction : identifier
  }

  private func respond(category: NotificationCategory, actionIdentifier: String) async {
    await responder?.handle(category: category, actionIdentifier: actionIdentifier)
  }

  nonisolated func authorization() async -> NotificationAuthorization {
    let settings = await UNUserNotificationCenter.current().notificationSettings()
    return Self.authorization(settings.authorizationStatus)
  }

  nonisolated func requestAuthorization() async -> NotificationAuthorization {
    _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    return await authorization()
  }

  nonisolated func post(_ intent: NotificationIntent) async -> Bool {
    let content = UNMutableNotificationContent()
    content.title = intent.title
    content.body = intent.body
    content.sound = intent.sound ? .default : nil
    content.interruptionLevel = .active
    content.threadIdentifier = intent.threadIdentifier
    content.categoryIdentifier = intent.identifier
    let request = UNNotificationRequest(identifier: intent.identifier, content: content, trigger: nil)
    do {
      try await UNUserNotificationCenter.current().add(request)
      return true
    } catch {
      return false
    }
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .list, .sound]
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    guard let category = NotificationCategory(identifier: response.notification.request.identifier) else { return }
    await respond(category: category, actionIdentifier: Self.actionIdentifier(response.actionIdentifier))
  }

  nonisolated static func authorization(_ status: UNAuthorizationStatus) -> NotificationAuthorization {
    switch status {
    case .authorized:
      .authorized
    case .provisional:
      .provisional
    case .denied:
      .denied
    case .notDetermined:
      .notDetermined
    @unknown default:
      .notDetermined
    }
  }
}
