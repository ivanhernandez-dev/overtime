import Foundation
import OvertimeAppSupport
import OvertimeEngine
import OvertimeSystem
import Testing

@testable import Overtime

@MainActor
struct NotificationResponderTests {
  final class Opened {
    var panes: [SettingsPane] = []
  }

  static let forced = EngineSnapshot(wanted: true, reason: "force", force: .indefinite)

  static func responder(host: FakeEngineHost?) -> (NotificationResponder, Opened) {
    let opened = Opened()
    let responder = NotificationResponder(
      host: { host }, onOpenSettings: { opened.panes.append($0) },
      now: { Date(timeIntervalSince1970: 1_800_000_000) }, calendar: Calendar(identifier: .gregorian))
    return (responder, opened)
  }

  @Test func turnOffOnAForceReminderSendsTheStopKeepingAwakeRequestOnce() async {
    let host = FakeEngineHost()
    host.scriptProbe(Self.forced)
    let (responder, opened) = Self.responder(host: host)
    await responder.handle(category: .forceReminder, actionIdentifier: "turnOff")
    #expect(host.requests == [.resume])
    #expect(
      host.requests.first
        == ControlMapping.request(
          for: .stopKeepingAwake, now: Date(timeIntervalSince1970: 1_800_000_000),
          calendar: Calendar(identifier: .gregorian)))
    #expect(opened.panes.isEmpty)
  }

  @Test(arguments: [EngineSnapshot(wanted: false, reason: "paused", pause: .indefinite), nil])
  func aStaleTurnOffAfterTheForceEndedSendsNothing(_ probed: EngineSnapshot?) async {
    let host = FakeEngineHost()
    host.scriptProbe(probed)
    let (responder, _) = Self.responder(host: host)
    await responder.handle(category: .forceReminder, actionIdentifier: "turnOff")
    #expect(host.probes == 1)
    #expect(host.requests.isEmpty)
  }

  @Test func turnOffWithNoRunningEngineDoesNothing() async {
    let (responder, opened) = Self.responder(host: nil)
    await responder.handle(category: .forceReminder, actionIdentifier: "turnOff")
    #expect(opened.panes.isEmpty)
  }

  @Test(arguments: [
    NotificationCategory.keepAwakeFailed, .batteryFloor, .belowFloorAtStart, .batteryTemperature, .lidClosedSummary,
  ])
  func turnOffOnAnyOtherCategoryReachesNoEngine(_ category: NotificationCategory) async {
    let host = FakeEngineHost()
    host.scriptProbe(Self.forced)
    let (responder, opened) = Self.responder(host: host)
    await responder.handle(category: category, actionIdentifier: "turnOff")
    #expect(host.probes == 0)
    #expect(host.requests.isEmpty)
    #expect(opened.panes.isEmpty)
  }

  @Test func theDefaultActionOnKeepAwakeFailedOpensDiagnostics() async {
    let host = FakeEngineHost()
    let (responder, opened) = Self.responder(host: host)
    await responder.handle(category: .keepAwakeFailed, actionIdentifier: NotificationResponder.openAction)
    #expect(opened.panes == [.diagnostics])
    #expect(host.requests.isEmpty)
  }

  @Test(arguments: [
    NotificationCategory.batteryFloor, .belowFloorAtStart, .batteryTemperature, .lidClosedSummary, .forceReminder,
  ])
  func theDefaultActionOnOtherCategoriesOnlyDismisses(_ category: NotificationCategory) async {
    let host = FakeEngineHost()
    host.scriptProbe(Self.forced)
    let (responder, opened) = Self.responder(host: host)
    await responder.handle(category: category, actionIdentifier: NotificationResponder.openAction)
    #expect(opened.panes.isEmpty)
    #expect(host.probes == 0)
    #expect(host.requests.isEmpty)
  }

  @Test(arguments: ["", "com.apple.UNNotificationDismissActionIdentifier", "TurnOff", "turnOff "])
  func anUnknownActionDoesNothing(_ action: String) async {
    let host = FakeEngineHost()
    host.scriptProbe(Self.forced)
    let (responder, opened) = Self.responder(host: host)
    for category in NotificationCategory.allCases {
      await responder.handle(category: category, actionIdentifier: action)
    }
    #expect(opened.panes.isEmpty)
    #expect(host.requests.isEmpty)
  }

  @Test func theAdapterMapsTheDefaultActionAndRegistersOnlyTheReminderAction() {
    #expect(
      UserNotificationsAdapter.actionIdentifier("com.apple.UNNotificationDefaultActionIdentifier")
        == NotificationResponder.openAction)
    #expect(UserNotificationsAdapter.actionIdentifier("turnOff") == "turnOff")
    let category = UserNotificationsAdapter.forceReminderCategory
    #expect(category.identifier == "overtime.forceReminder")
    #expect(category.actions.map(\.identifier) == ["turnOff"])
    #expect(category.actions.map(\.title) == ["Turn Off"])
    #expect(category.actions.first?.options == [])
  }
}
