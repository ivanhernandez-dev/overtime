import Foundation

public enum NotificationContent {
  public static let keepAwakeFailedTitle = "Keep-awake failed"
  public static let keepAwakeFailedBody =
    "Overtime couldn't keep the Mac awake while Claude is working, and will retry. Until it succeeds, the Mac may sleep."
  public static let selfTestFailedTitle = "Keep-awake self-test failed"
  public static let selfTestFailedBody =
    "Overtime's lid-close control failed its test. Until it passes, the Mac may sleep with the lid closed. Open Settings > Diagnostics for details."
  public static let batteryFloorTitle = "Battery low"
  public static let belowFloorAtStartTitle = "Battery too low to keep awake"
  public static let plugInSentence = "Plug in to keep working with the lid closed."
  public static let lidClosedSummaryTitle = "While the lid was closed"
  public static let forceReminderTitle = "\(ControlMapping.keepAwakeLabel) is still on"
  public static let turnOffActionTitle = "Turn Off"
  public static let turnOffActionIdentifier = "turnOff"
  public static let stuckReleaseLine = "A Claude session looked stuck, so Overtime stopped counting it."
  public static let sentinelClearLine = "Overtime stopped unexpectedly. Its watchdog restored normal sleep."
  public static let unexpectedSleepLine = "The Mac slept while Claude was working."
  public static let hotspotSwitchLine = "Overtime switched the Mac to your iPhone hotspot to stay online."
  public static let maxSummaryLines = 3

  public static func keepAwakeFailed() -> NotificationIntent {
    intent(.keepAwakeFailed, title: keepAwakeFailedTitle, body: keepAwakeFailedBody)
  }

  public static func selfTestFailed() -> NotificationIntent {
    intent(.keepAwakeFailed, title: selfTestFailedTitle, body: selfTestFailedBody)
  }

  public static func batteryFloorBody(floorPercent: Int) -> String {
    "Battery at \(floorPercent)%. Overtime stopped keeping the Mac awake. \(plugInSentence)"
  }

  public static func batteryFloor(floorPercent: Int) -> NotificationIntent {
    intent(.batteryFloor, title: batteryFloorTitle, body: batteryFloorBody(floorPercent: floorPercent))
  }

  public static func belowFloorAtStartBody(percent: Int?, floorPercent: Int) -> String {
    let level = percent.map { "at \($0)%" } ?? "below \(floorPercent)%"
    return "Claude started with the battery \(level). Overtime won't keep the Mac awake below \(floorPercent)%. "
      + plugInSentence
  }

  public static func belowFloorAtStart(percent: Int?, floorPercent: Int) -> NotificationIntent {
    intent(
      .belowFloorAtStart, title: belowFloorAtStartTitle,
      body: belowFloorAtStartBody(percent: percent, floorPercent: floorPercent))
  }

  public static func lidClosedSummaryBody(lines: [String], omitted: Int = 0) -> String {
    var shown = Array(lines.prefix(maxSummaryLines))
    let (total, overflow) = lines.count.addingReportingOverflow(max(0, omitted))
    let more = (overflow ? Int.max : total) - shown.count
    if more > 0 {
      shown.append(moreLine(more))
    }
    return shown.joined(separator: "\n")
  }

  public static func lidClosedSummary(lines: [String], omitted: Int = 0) -> NotificationIntent {
    intent(
      .lidClosedSummary, title: lidClosedSummaryTitle, body: lidClosedSummaryBody(lines: lines, omitted: omitted))
  }

  public static func hours(_ count: Int) -> String {
    count == 1 ? "1 hour" : "\(count) hours"
  }

  public static func forceReminderBody(hours count: Int) -> String {
    "\(ControlMapping.keepAwakeLabel) has been on for \(hours(count)) with no Claude activity."
  }

  public static func forceReminder(hours count: Int) -> NotificationIntent {
    intent(.forceReminder, title: forceReminderTitle, body: forceReminderBody(hours: count), turnOffAction: true)
  }

  public static func batteryReleaseLine(floorPercent: Int) -> String {
    "Battery reached \(floorPercent)%, so Overtime let the Mac sleep."
  }

  public static func holdErrorLine(count: Int) -> String {
    count <= 1 ? "Keep-awake failed and was retried." : "Keep-awake failed \(count) times and was retried."
  }

  public static func wifiCycleLine(count: Int) -> String {
    count <= 1
      ? "Overtime restarted the wireless connection to get back online."
      : "Overtime restarted the wireless connection \(count) times to get back online."
  }

  public static func moreLine(_ count: Int) -> String {
    "And \(count) more. Details are in the log."
  }

  public static func sound(for category: NotificationCategory) -> Bool {
    switch category {
    case .keepAwakeFailed, .batteryFloor, .belowFloorAtStart:
      true
    case .lidClosedSummary, .forceReminder:
      false
    }
  }

  static func intent(
    _ category: NotificationCategory, title: String, body: String, turnOffAction: Bool = false
  ) -> NotificationIntent {
    NotificationIntent(
      category: category, title: title, body: body, sound: sound(for: category), turnOffAction: turnOffAction)
  }
}
