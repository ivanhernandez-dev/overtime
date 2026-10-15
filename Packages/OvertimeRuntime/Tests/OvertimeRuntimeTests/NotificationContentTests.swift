import Foundation
import OvertimeAppSupport
import Testing

struct NotificationContentTests {
  static let plugIn = "Plug in to keep working with the lid closed."

  static var everyIntent: [NotificationIntent] {
    [
      NotificationContent.keepAwakeFailed(),
      NotificationContent.selfTestFailed(),
      NotificationContent.batteryFloor(floorPercent: 10),
      NotificationContent.belowFloorAtStart(percent: 8, floorPercent: 10),
      NotificationContent.belowFloorAtStart(percent: nil, floorPercent: 10),
      NotificationContent.lidClosedSummary(lines: everyJournalLine),
      NotificationContent.forceReminder(hours: 3),
    ]
  }

  static var everyJournalLine: [String] {
    [
      NotificationContent.batteryReleaseLine(floorPercent: 10),
      NotificationContent.stuckReleaseLine,
      NotificationContent.holdErrorLine(count: 1),
      NotificationContent.holdErrorLine(count: 3),
      NotificationContent.sentinelClearLine,
      NotificationContent.unexpectedSleepLine,
      NotificationContent.hotspotSwitchLine,
      NotificationContent.wifiCycleLine(count: 1),
      NotificationContent.wifiCycleLine(count: 3),
    ]
  }

  @Test func theNetworkJournalLinesMatchTheirCopyAndAddNoCategory() {
    #expect(NotificationContent.hotspotSwitchLine == "Overtime switched the Mac to your iPhone hotspot to stay online.")
    #expect(
      NotificationContent.wifiCycleLine(count: 1) == "Overtime restarted the wireless connection to get back online.")
    #expect(
      NotificationContent.wifiCycleLine(count: 3)
        == "Overtime restarted the wireless connection 3 times to get back online.")
    #expect(
      Set(NotificationCategory.allCases)
        == [.keepAwakeFailed, .batteryFloor, .belowFloorAtStart, .lidClosedSummary, .forceReminder])
  }

  @Test func theKeepAwakeFailedCopyMatchesTheSpec() {
    let intent = NotificationContent.keepAwakeFailed()
    #expect(intent.category == .keepAwakeFailed)
    #expect(intent.title == "Keep-awake failed")
    #expect(
      intent.body
        == "Overtime couldn't keep the Mac awake while Claude is working, and will retry. Until it succeeds, the Mac may sleep."
    )
  }

  @Test func theSelfTestVariantSharesTheCategoryWithItsOwnCopy() {
    let intent = NotificationContent.selfTestFailed()
    #expect(intent.category == .keepAwakeFailed)
    #expect(intent.identifier == "overtime.keepAwakeFailed")
    #expect(intent.title == "Keep-awake self-test failed")
    #expect(
      intent.body
        == "Overtime's lid-close control failed its test. Until it passes, the Mac may sleep with the lid closed. Open Settings > Diagnostics for details."
    )
    #expect(intent.sound)
  }

  @Test(arguments: [10, 25])
  func theBatteryCopyUsesTheConfiguredFloor(_ floor: Int) {
    let intent = NotificationContent.batteryFloor(floorPercent: floor)
    #expect(intent.title == "Battery low")
    #expect(intent.body == "Battery at \(floor)%. Overtime stopped keeping the Mac awake. \(Self.plugIn)")
    let start = NotificationContent.belowFloorAtStart(percent: 8, floorPercent: floor)
    #expect(start.title == "Battery too low to keep awake")
    #expect(
      start.body
        == "Claude started with the battery at 8%. Overtime won't keep the Mac awake below \(floor)%. \(Self.plugIn)")
    #expect(
      NotificationContent.belowFloorAtStart(percent: nil, floorPercent: floor).body
        == "Claude started with the battery below \(floor)%. Overtime won't keep the Mac awake below \(floor)%. \(Self.plugIn)"
    )
  }

  @Test func theForceReminderNamesTheConfiguredHours() {
    #expect(NotificationContent.hours(1) == "1 hour")
    #expect(NotificationContent.hours(2) == "2 hours")
    #expect(NotificationContent.hours(12) == "12 hours")
    let intent = NotificationContent.forceReminder(hours: 3)
    #expect(intent.category == .forceReminder)
    #expect(intent.title == "Keep Awake is still on")
    #expect(intent.body == "Keep Awake has been on for 3 hours with no Claude activity.")
    #expect(intent.turnOffAction)
    #expect(
      NotificationContent.forceReminderBody(hours: 1) == "Keep Awake has been on for 1 hour with no Claude activity.")
    #expect(NotificationContent.turnOffActionTitle == "Turn Off")
  }

  @Test func theJournalLinesMatchTheSpec() {
    #expect(
      NotificationContent.batteryReleaseLine(floorPercent: 10) == "Battery reached 10%, so Overtime let the Mac sleep.")
    #expect(
      NotificationContent.batteryReleaseLine(floorPercent: 20) == "Battery reached 20%, so Overtime let the Mac sleep.")
    #expect(NotificationContent.stuckReleaseLine == "A Claude session looked stuck, so Overtime stopped counting it.")
    #expect(NotificationContent.holdErrorLine(count: 1) == "Keep-awake failed and was retried.")
    #expect(NotificationContent.holdErrorLine(count: 2) == "Keep-awake failed 2 times and was retried.")
    #expect(NotificationContent.holdErrorLine(count: 3) == "Keep-awake failed 3 times and was retried.")
    #expect(
      NotificationContent.sentinelClearLine == "Overtime stopped unexpectedly. Its watchdog restored normal sleep.")
    #expect(NotificationContent.unexpectedSleepLine == "The Mac slept while Claude was working.")
  }

  @Test func theLidClosedSummaryShowsThreeLinesAndCountsTheRest() {
    let lines = Self.everyJournalLine
    #expect(NotificationContent.lidClosedSummaryTitle == "While the lid was closed")
    #expect(NotificationContent.maxSummaryLines == 3)
    #expect(NotificationContent.moreLine(2) == "And 2 more. Details are in the log.")
    #expect(NotificationContent.lidClosedSummaryBody(lines: Array(lines.prefix(1))) == lines[0])
    #expect(
      NotificationContent.lidClosedSummaryBody(lines: Array(lines.prefix(3))) == lines.prefix(3).joined(separator: "\n")
    )
    #expect(
      NotificationContent.lidClosedSummaryBody(lines: Array(lines.prefix(5)))
        == (Array(lines.prefix(3)) + ["And 2 more. Details are in the log."]).joined(separator: "\n"))
    let intent = NotificationContent.lidClosedSummary(lines: Array(lines.prefix(4)))
    #expect(intent.category == .lidClosedSummary)
    #expect(intent.title == "While the lid was closed")
    #expect(intent.body.components(separatedBy: "\n").last == "And 1 more. Details are in the log.")
  }

  @Test func soundIsOnOnlyForTheActionableCategories() {
    for intent in Self.everyIntent {
      let expected = [.keepAwakeFailed, .batteryFloor, .belowFloorAtStart].contains(intent.category)
      #expect(intent.sound == expected, "\(intent.category)")
      #expect(intent.turnOffAction == (intent.category == .forceReminder), "\(intent.category)")
    }
    #expect(Set(Self.everyIntent.map(\.category)) == Set(NotificationCategory.allCases))
  }

  @Test func noCopyCarriesAPathANetworkNameOrAPlaceholder() {
    let texts = Self.everyIntent.flatMap { [$0.title, $0.body] } + Self.everyJournalLine
    for text in texts {
      #expect(!text.isEmpty)
      for marker in ["/", "~", "%@", "%d", "{", "}", "<", "SSID", "Wi-Fi", "network", "pid"] {
        #expect(!text.contains(marker), "\(text) contains \(marker)")
      }
      #expect(!text.contains("!"))
    }
  }
}
