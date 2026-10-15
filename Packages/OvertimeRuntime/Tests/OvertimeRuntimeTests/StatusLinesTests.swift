import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import Testing

struct StatusLinesTests {
  @Test func lidValues() {
    #expect(StatusLines.lid(nil, externalDisplays: nil) == "Unknown")
    #expect(StatusLines.lid(false, externalDisplays: nil) == "Open")
    #expect(StatusLines.lid(false, externalDisplays: 2) == "Open")
    #expect(StatusLines.lid(true, externalDisplays: nil) == "Closed")
    #expect(StatusLines.lid(true, externalDisplays: 0) == "Closed")
    #expect(StatusLines.lid(true, externalDisplays: 1) == "Closed, external display")
  }

  @Test(arguments: [
    (PowerReading.battery(percent: 72), false, 10, "72%, on battery"),
    (PowerReading.ac(percent: 72), false, 10, "72%, charging"),
    (PowerReading.ac(percent: 100), false, 10, "100%, on power adapter"),
    (PowerReading.battery(percent: 9), true, 10, "9%, on battery (below 10%)"),
    (PowerReading.battery(percent: 9), true, 15, "9%, on battery (below 15%)"),
    (PowerReading.battery(percent: 9), false, 10, "9%, on battery"),
    (PowerReading.noBattery, false, 10, "No battery"),
    (PowerReading.battery(percent: nil), false, 10, "Unknown"),
    (PowerReading.ac(percent: nil), false, 10, "Unknown"),
  ])
  func batteryValues(_ reading: PowerReading, _ blocked: Bool, _ low: Int, _ text: String) {
    #expect(StatusLines.battery(reading, blocked: blocked, lowPercent: low) == text)
  }

  @Test func anUnreadableBatteryIsUnknown() {
    #expect(StatusLines.battery(nil, blocked: false, lowPercent: 10) == "Unknown")
  }

  @Test func networkFailoverIsOffWithoutASummary() {
    #expect(StatusLines.network(nil, lidClosed: nil).value == "Failover off")
    #expect(StatusLines.network(nil, lidClosed: nil).detail == nil)
    #expect(StatusLines.rows(for: EngineSnapshot()).last?.value == "Failover off")
  }

  @Test func theNetworkRowFollowsTheSnapshotSummary() {
    let armed = EngineSnapshot(network: NetworkSummary(wifiFound: true, readiness: .armed(.configured)))
    #expect(StatusLines.rows(for: armed).last?.value == "Failover on")
    let summary = NetworkSummary(wifiFound: true, onHotspot: true, switched: true)
    let closed = EngineSnapshot(lidClosed: true, network: summary)
    #expect(StatusLines.rows(for: closed).last?.value == "On your iPhone hotspot")
    #expect(StatusLines.rows(for: closed).last?.detail == StatusLines.onHotspotDetail)
    let opened = EngineSnapshot(lidClosed: false, network: summary)
    #expect(StatusLines.rows(for: opened).last?.value == StatusLines.returning)
    #expect(StatusLines.rows(for: opened).last?.detail == nil)
  }

  @Test func theRowsCarryTheirLabelsIconsAndSpokenText() {
    let snapshot = EngineSnapshot(lidClosed: false, power: .ac(percent: 100))
    let rows = StatusLines.rows(for: snapshot)
    #expect(rows.map(\.label) == ["Lid", "Battery", "Network"])
    #expect(rows.map(\.icon) == ["laptopcomputer", "battery.100percent.bolt", "wifi"])
    #expect(rows.map(\.value) == ["Open", "100%, on power adapter", "Failover off"])
    #expect(rows.first?.accessibilityText == "Lid, open")
  }

  static let batteryGlyphSteps: [(ClosedRange<Int>, String)] = [
    (0...12, "battery.0percent"), (13...37, "battery.25percent"), (38...62, "battery.50percent"),
    (63...87, "battery.75percent"), (88...100, "battery.100percent"),
  ]

  @Test func theBatteryGlyphFollowsTheLevelAndThePowerSource() {
    for (range, glyph) in Self.batteryGlyphSteps {
      for percent in [range.lowerBound, range.upperBound] {
        #expect(StatusLines.batteryIcon(for: .battery(percent: percent)) == glyph, "\(percent)% on battery")
      }
    }
    for percent in [0, 9, 50, 100] {
      #expect(StatusLines.batteryIcon(for: .ac(percent: percent)) == "battery.100percent.bolt", "\(percent)% on power")
    }
    #expect(StatusLines.batteryIcon(for: .ac(percent: nil)) == "battery.100percent.bolt")
    #expect(StatusLines.batteryIcon(for: .noBattery) == "battery.100percent")
    #expect(StatusLines.batteryIcon(for: .battery(percent: nil)) == "battery.100percent")
    #expect(StatusLines.batteryIcon(for: nil) == "battery.100percent")
  }

  @Test func theBatteryGlyphListHoldsEveryGlyphTheRowCanShow() {
    var readings: [PowerReading?] = [.noBattery, .battery(percent: nil), .ac(percent: nil), nil]
    for percent in 0...100 {
      readings.append(.battery(percent: percent))
      readings.append(.ac(percent: percent))
    }
    let shown = Set(readings.map { StatusLines.batteryIcon(for: $0) })
    #expect(shown == Set(StatusLines.batteryIcons))
    #expect(StatusLines.batteryIcons.count == 6)
    #expect(Set(StatusLines.batteryIcons).count == 6)
  }

  @Test func theBatteryRowDrawsTheGlyphOfItsReading() {
    let low = StatusLines.rows(for: EngineSnapshot(lidClosed: true, power: .battery(percent: 9)))
    #expect(low.map(\.icon) == ["laptopcomputer", "battery.0percent", "wifi"])
    #expect(StatusLines.rows(for: nil).map(\.icon) == ["laptopcomputer", "battery.100percent", "wifi"])
  }

  @Test func noSnapshotReadsUnknown() {
    #expect(StatusLines.rows(for: nil).map(\.value) == ["Unknown", "Unknown", "Failover off"])
    #expect(StatusLines.rows(for: nil).allSatisfy { $0.detail == nil })
  }

  @Test(arguments: [
    ("On your iPhone hotspot", "on your iPhone hotspot"),
    ("Still on your iPhone hotspot", "still on your iPhone hotspot"),
    ("Failover on", "failover on"),
    ("Returning to your usual network…", "returning to your usual network…"),
    ("Switching networks…", "switching networks…"),
    ("Closed, external display", "closed, external display"),
    ("72%, on battery", "72%, on battery"),
    ("Unknown", "unknown"),
    ("OK", "OK"),
    ("A", "A"),
    ("iPhone", "iPhone"),
    ("", ""),
  ])
  func theSpokenValueLowersOnlyAPlainFirstCapital(_ value: String, _ spoken: String) {
    #expect(StatusLine.spokenValue(value) == spoken)
  }

  @Test func theLidAndBatteryRowsAreSpokenAsBefore() {
    let rows = StatusLines.rows(for: EngineSnapshot(lidClosed: true, power: .battery(percent: 72), externalDisplays: 1))
    #expect(rows.prefix(2).map(\.accessibilityText) == ["Lid, closed, external display", "Battery, 72%, on battery"])
  }
}
