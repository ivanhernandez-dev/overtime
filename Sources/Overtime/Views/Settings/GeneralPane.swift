import AppKit
import OvertimeAppSupport
import OvertimeCore
import SwiftUI

struct NotificationStatusRow: Equatable {
  enum Tone: Equatable {
    case success
    case info
    case warning
  }

  enum Action: Equatable {
    case allowNotifications
    case openNotificationSettings
  }

  static let allowedTitle = "Notifications are allowed."
  static let notDeterminedTitle = "Notifications aren't set up yet."
  static let deniedTitle = "Notifications are off for Overtime in System Settings."
  static let allowLabel = "Allow Notifications"
  static let openLabel = "Open Notification Settings"

  let symbol: String
  let tone: Tone
  let title: String
  let action: Action?

  var actionLabel: String? {
    switch action {
    case .allowNotifications: Self.allowLabel
    case .openNotificationSettings: Self.openLabel
    case nil: nil
    }
  }

  static func `for`(_ authorization: NotificationAuthorization) -> NotificationStatusRow {
    switch authorization {
    case .authorized, .provisional:
      NotificationStatusRow(symbol: "checkmark.circle.fill", tone: .success, title: allowedTitle, action: nil)
    case .notDetermined:
      NotificationStatusRow(
        symbol: "info.circle", tone: .info, title: notDeterminedTitle, action: .allowNotifications)
    case .denied:
      NotificationStatusRow(
        symbol: "exclamationmark.triangle.fill", tone: .warning, title: deniedTitle,
        action: .openNotificationSettings)
    }
  }
}

struct GeneralPane: View {
  static let startupTitle = "Startup"
  static let displayTitle = "Display"
  static let keepDisplayOnLabel = "Keep display on while Claude works"
  static let keepDisplayOnCaption =
    "With the lid closed and no external display, the display still turns off so the screen locks."
  static let notificationsTitle = "Notifications"
  static let remindAfterLabel = "Remind after"
  static let notificationsBlockedCaption = "Overtime won't show notifications until you allow them."

  static func notificationLabel(_ category: NotificationCategory) -> String {
    switch category {
    case .keepAwakeFailed: "Keep-awake failed"
    case .batteryFloor: "Battery floor"
    case .belowFloorAtStart: "Battery low when Claude starts"
    case .batteryTemperature: "Battery temperature"
    case .lidClosedSummary: "Lid-closed summary"
    case .forceReminder: "\(ControlMapping.keepAwakeLabel) reminder"
    }
  }

  static let batteryProtectionOffCaption = "Battery protection is off in Settings > Battery."
  static let temperatureProtectionOffCaption = "Temperature protection is off in Settings > Battery."

  static func notificationCaption(
    _ category: NotificationCategory, floorPercent: Int, releaseCelsius: Int = Settings().temperatureReleaseCelsius,
    batteryProtectionEnabled: Bool = true, temperatureProtectionEnabled: Bool = true
  ) -> String {
    switch category {
    case .keepAwakeFailed:
      "When Overtime can't keep the Mac awake while Claude works, or its self-test fails."
    case .batteryFloor:
      batteryProtectionEnabled
        ? "When the battery reaches \(floorPercent)% with the lid open." : batteryProtectionOffCaption
    case .belowFloorAtStart:
      batteryProtectionEnabled
        ? "When Claude starts while the battery is already below \(floorPercent)%." : batteryProtectionOffCaption
    case .batteryTemperature:
      temperatureProtectionEnabled
        ? "When the battery reaches \(releaseCelsius)°C with the lid open." : temperatureProtectionOffCaption
    case .lidClosedSummary:
      "One summary when you open the lid, only if something happened while it was closed."
    case .forceReminder:
      "When \(ControlMapping.keepAwakeLabel) has been on with no Claude activity."
    }
  }

  let model: SettingsModel

  var body: some View {
    Form {
      SaveErrorSection(model: model)
      Section {
        LoginItemSection(model: model)
      } header: {
        SettingsSectionHeader(title: Self.startupTitle)
      }
      Section {
        VStack(alignment: .leading, spacing: 4) {
          Toggle(
            Self.keepDisplayOnLabel,
            isOn: Binding(
              get: { model.keepDisplayOn },
              set: { enabled in
                Task { await model.setKeepDisplayOn(enabled) }
              })
          )
          .toggleStyle(.switch)
          .controlSize(.mini)
          .disabled(!model.canEdit)
          .accessibilityHint(Text(Self.keepDisplayOnCaption))
          SettingsSectionCaption(text: Self.keepDisplayOnCaption)
            .accessibilityHidden(true)
        }
      } header: {
        SettingsSectionHeader(title: Self.displayTitle)
      }
      NotificationsSection(model: model)
    }
    .formStyle(.grouped)
    .transaction { $0.animation = nil }
    .task { await model.refreshNotificationAuthorization() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      Task { await model.refreshNotificationAuthorization() }
    }
  }
}

struct NotificationsSection: View {
  let model: SettingsModel

  var body: some View {
    Section {
      if let row = model.notificationStatusRow {
        NotificationStatusRowView(row: row, model: model)
      }
      ForEach(NotificationCategory.allCases, id: \.self) { category in
        NotificationSwitchRow(category: category, model: model)
      }
      Picker(GeneralPane.remindAfterLabel, selection: reminderHours) {
        ForEach(SettingsModel.reminderHourChoices, id: \.self) { hours in
          Text(NotificationContent.hours(hours))
            .monospacedDigit()
            .tag(hours)
        }
      }
      .pickerStyle(.menu)
      .disabled(!model.canChangeForceReminderHours)
    } header: {
      SettingsSectionHeader(title: GeneralPane.notificationsTitle)
    } footer: {
      if model.showsNotificationsBlockedCaption {
        SettingsSectionCaption(text: GeneralPane.notificationsBlockedCaption)
      }
    }
  }

  private var reminderHours: Binding<Int> {
    Binding(get: { model.forceReminderHours }, set: { model.setForceReminderHours($0) })
  }
}

struct NotificationStatusRowView: View {
  let row: NotificationStatusRow
  let model: SettingsModel

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      StatusRow(symbol: row.symbol, tint: tint, title: row.title)
      switch row.action {
      case .allowNotifications:
        Button(NotificationStatusRow.allowLabel) {
          Task { await model.allowNotifications() }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(model.requestingNotifications)
      case .openNotificationSettings:
        Button(NotificationStatusRow.openLabel) { model.openNotificationSettings() }
          .buttonStyle(.link)
          .font(.subheadline)
      case nil:
        EmptyView()
      }
    }
  }

  private var tint: Color {
    switch row.tone {
    case .success: .green
    case .info: .secondary
    case .warning: .orange
    }
  }
}

struct NotificationSwitchRow: View {
  let category: NotificationCategory
  let model: SettingsModel

  var body: some View {
    let settings = model.settings
    let caption = GeneralPane.notificationCaption(
      category, floorPercent: settings.batteryLowPercent, releaseCelsius: settings.temperatureReleaseCelsius,
      batteryProtectionEnabled: settings.batteryProtectionEnabled,
      temperatureProtectionEnabled: settings.temperatureProtectionEnabled)
    VStack(alignment: .leading, spacing: 4) {
      Toggle(
        GeneralPane.notificationLabel(category),
        isOn: Binding(
          get: { model.isNotificationEnabled(category) },
          set: { model.setNotification(category, enabled: $0) })
      )
      .toggleStyle(.switch)
      .controlSize(.mini)
      .accessibilityHint(Text(caption))
      SettingsSectionCaption(text: caption)
        .monospacedDigit()
        .accessibilityHidden(true)
    }
  }
}
