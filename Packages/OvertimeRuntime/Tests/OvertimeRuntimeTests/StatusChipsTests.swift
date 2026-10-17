import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import Testing

struct StatusChipsTests {
  static let kinds: [StatusChip.Kind] = [.lid, .battery, .network]

  static func chip(_ kind: StatusChip.Kind, in summary: StatusChipSummary) throws -> StatusChip {
    try #require(summary.chips.first { $0.kind == kind }, "no \(kind) chip")
  }

  @Test func theLidChipNamesTheLidAndMovesTheExternalDisplayToADetail() throws {
    let cases: [(EngineSnapshot?, String)] = [
      (EngineSnapshot(lidClosed: false), "Lid open"),
      (EngineSnapshot(lidClosed: false, externalDisplays: 2), "Lid open"),
      (EngineSnapshot(lidClosed: true), "Lid closed"),
      (EngineSnapshot(lidClosed: true, externalDisplays: 0), "Lid closed"),
      (nil, "Lid unknown"),
    ]
    for (snapshot, text) in cases {
      let summary = StatusChipSummary.make(for: snapshot)
      let lid = try Self.chip(.lid, in: summary)
      #expect(lid.text == text)
      #expect(lid.symbol == "laptopcomputer")
      #expect(!summary.details.contains { $0.kind == .lid }, "\(text)")
    }
    let docked = StatusChipSummary.make(for: EngineSnapshot(lidClosed: true, externalDisplays: 1))
    let lid = try Self.chip(.lid, in: docked)
    #expect(lid.text == "Lid closed")
    let details = docked.details.filter { $0.kind == .lid }
    try #require(details.count == 1)
    #expect(details[0].text == "An external display is connected.")
    #expect(details[0].symbol == "laptopcomputer")
    #expect(StatusChips.externalDisplayDetail == "An external display is connected.")
  }

  struct LidDetailCase: Sendable, CustomTestStringConvertible {
    let name: String
    let snapshot: EngineSnapshot
    let detail: String?

    var testDescription: String { name }
  }

  static let holdOffCopy = "Closing the lid lets the Mac sleep."
  static let onBatteryCopy = "On battery, closing the lid lets the Mac sleep."
  static let unknownPowerCopy = "Until Overtime can read the power source, closing the lid lets the Mac sleep."

  static let lidDetailCases: [LidDetailCase] = [
    LidDetailCase(
      name: "never on power",
      snapshot: EngineSnapshot(
        wanted: true, lidClosed: false, power: .ac(percent: 80), lidClosedKeepAwake: .never,
        lidClosedHoldAllowed: false),
      detail: holdOffCopy),
    LidDetailCase(
      name: "power adapter on battery",
      snapshot: EngineSnapshot(
        wanted: true, lidClosed: false, power: .battery(percent: 50), lidClosedKeepAwake: .onPowerAdapter,
        lidClosedHoldAllowed: false),
      detail: onBatteryCopy),
    LidDetailCase(
      name: "power adapter with no reading",
      snapshot: EngineSnapshot(
        wanted: true, lidClosed: false, lidClosedKeepAwake: .onPowerAdapter, lidClosedHoldAllowed: false),
      detail: unknownPowerCopy),
    LidDetailCase(
      name: "power adapter on battery, lid unknown",
      snapshot: EngineSnapshot(
        wanted: true, power: .battery(percent: 50), lidClosedKeepAwake: .onPowerAdapter,
        lidClosedHoldAllowed: false),
      detail: onBatteryCopy),
    LidDetailCase(
      name: "power adapter on power, allowed",
      snapshot: EngineSnapshot(
        wanted: true, lidClosed: false, power: .ac(percent: 80), lidClosedKeepAwake: .onPowerAdapter,
        lidClosedHoldAllowed: true),
      detail: nil),
    LidDetailCase(
      name: "always, allowed",
      snapshot: EngineSnapshot(wanted: true, lidClosed: false, power: .battery(percent: 50)),
      detail: nil),
    LidDetailCase(
      name: "never, not wanted",
      snapshot: EngineSnapshot(
        wanted: false, lidClosed: false, power: .ac(percent: 80), lidClosedKeepAwake: .never,
        lidClosedHoldAllowed: false),
      detail: nil),
    LidDetailCase(
      name: "never, lid closed",
      snapshot: EngineSnapshot(
        wanted: true, lidClosed: true, power: .ac(percent: 80), lidClosedKeepAwake: .never,
        lidClosedHoldAllowed: false),
      detail: nil),
    LidDetailCase(
      name: "never, lid closed with a display",
      snapshot: EngineSnapshot(
        wanted: true, lidClosed: true, power: .ac(percent: 80), externalDisplays: 1, lidClosedKeepAwake: .never,
        lidClosedHoldAllowed: false),
      detail: StatusChips.externalDisplayDetail),
  ]

  @Test(arguments: lidDetailCases)
  func theLidDetailSaysWhatClosingTheLidDoesWhileTheHoldIsOff(_ item: LidDetailCase) throws {
    let summary = StatusChipSummary.make(for: item.snapshot)
    let lid = try Self.chip(.lid, in: summary)
    let details = summary.details.filter { $0.kind == .lid }
    if let detail = item.detail {
      try #require(details.count == 1)
      #expect(details[0].text == detail)
      #expect(details[0].symbol == lid.symbol)
    } else {
      #expect(details.isEmpty)
    }
    #expect(StatusChips.lidClosedHoldOffDetail == Self.holdOffCopy)
    #expect(StatusChips.onBatteryLidDetail == Self.onBatteryCopy)
    #expect(StatusChips.unknownPowerLidDetail == Self.unknownPowerCopy)
  }

  @Test func theBatteryChipShowsThePercentageAndTheGlyphOfItsReading() throws {
    let cases: [(PowerReading?, String, String)] = [
      (.battery(percent: 72), "72%", "battery.75percent"),
      (.ac(percent: 82), "82%", "battery.100percent.bolt"),
      (.ac(percent: 100), "100%", "battery.100percent.bolt"),
      (.noBattery, "No battery", "battery.100percent"),
      (nil, "Battery unknown", "battery.100percent"),
      (.battery(percent: nil), "Battery unknown", "battery.100percent"),
      (.ac(percent: nil), "Battery unknown", "battery.100percent.bolt"),
    ]
    for (reading, text, symbol) in cases {
      let summary = StatusChipSummary.make(for: EngineSnapshot(power: reading))
      let battery = try Self.chip(.battery, in: summary)
      #expect(battery.text == text)
      #expect(battery.symbol == symbol)
      #expect(!summary.details.contains { $0.kind == .battery }, "\(text)")
    }
    let unblocked = StatusChipSummary.make(for: EngineSnapshot(batteryBlocked: false, power: .battery(percent: 9)))
    #expect(!unblocked.details.contains { $0.kind == .battery })
    let floor = StatusChipSummary.make(
      for: EngineSnapshot(batteryBlocked: true, batteryLowPercent: 10, power: .battery(percent: 9)))
    let battery = try Self.chip(.battery, in: floor)
    #expect(battery.text == "9%")
    #expect(battery.symbol == "battery.0percent")
    let details = floor.details.filter { $0.kind == .battery }
    try #require(details.count == 1)
    #expect(details[0].text == "On battery, below 10%.")
    #expect(details[0].symbol == "battery.0percent")
    #expect(StatusChips.belowFloorDetail(15) == "On battery, below 15%.")
  }

  @Test func aHotBatteryAddsTheTemperatureDetail() throws {
    for power in [PowerReading.battery(percent: 50), .ac(percent: 80)] {
      let hot = StatusChipSummary.make(
        for: EngineSnapshot(power: power, temperatureBlocked: true, temperatureReleaseCelsius: 45))
      let battery = try Self.chip(.battery, in: hot)
      let details = hot.details.filter { $0.kind == .battery }
      try #require(details.count == 1)
      #expect(details[0].text == "Battery at or above 45°C.")
      #expect(details[0].symbol == battery.symbol)
    }
    #expect(StatusChips.hotDetail(releaseCelsius: 50) == "Battery at or above 50°C.")
    let both = StatusChipSummary.make(
      for: EngineSnapshot(
        batteryBlocked: true, batteryLowPercent: 10, power: .battery(percent: 9), temperatureBlocked: true,
        temperatureReleaseCelsius: 45))
    let details = both.details.filter { $0.kind == .battery }.map(\.text)
    #expect(details == ["On battery, below 10%."])
  }

  @Test func theNetworkChipKeepsTheRowValueAndItsDetail() throws {
    let switched = NetworkStatusLineTests.summary(switched: true, readiness: .armed(.configured))
    let cases: [(EngineSnapshot, String, String, String?)] = [
      (EngineSnapshot(), "Failover off", "wifi", nil),
      (
        EngineSnapshot(network: NetworkStatusLineTests.summary(readiness: .armed(.configured))), "Failover on", "wifi",
        nil
      ),
      (
        EngineSnapshot(lidClosed: true, network: switched), "On your iPhone hotspot", "personalhotspot",
        "Returns to your usual network when you open the lid."
      ),
      (
        EngineSnapshot(network: NetworkStatusLineTests.summary(readiness: .off(.wifiOff))), "Failover off", "wifi",
        "Wi-Fi is off. Failover resumes when it's back on."
      ),
    ]
    for (snapshot, text, symbol, detail) in cases {
      let summary = StatusChipSummary.make(for: snapshot)
      let row = try #require(StatusLines.rows(for: snapshot).last)
      let network = try Self.chip(.network, in: summary)
      #expect(network.text == text)
      #expect(network.text == row.value)
      #expect(network.symbol == symbol)
      #expect(network.symbol == row.icon)
      let details = summary.details.filter { $0.kind == .network }
      #expect(details.map(\.text) == (detail.map { [$0] } ?? []))
      #expect(details.map(\.text) == (row.detail.map { [$0] } ?? []))
      #expect(details.allSatisfy { $0.symbol == row.icon })
    }
  }

  static let snapshots: [EngineSnapshot?] = [
    nil,
    EngineSnapshot(),
    EngineSnapshot(lidClosed: false, power: .ac(percent: 100)),
    EngineSnapshot(lidClosed: true, power: .battery(percent: 72), externalDisplays: 1),
    EngineSnapshot(batteryBlocked: true, lidClosed: true, batteryLowPercent: 10, power: .battery(percent: 9)),
    EngineSnapshot(lidClosed: false, power: .noBattery),
    EngineSnapshot(power: .battery(percent: nil)),
    EngineSnapshot(
      lidClosed: true, power: .ac(percent: 82), network: NetworkStatusLineTests.summary(readiness: .armed(.configured))),
    EngineSnapshot(
      lidClosed: true, power: .battery(percent: 40),
      network: NetworkStatusLineTests.summary(switched: true, readiness: .armed(.configured))),
    EngineSnapshot(lidClosed: false, network: NetworkStatusLineTests.summary(readiness: .off(.wifiOff))),
    EngineSnapshot(
      batteryBlocked: true, lidClosed: true, batteryLowPercent: 15, power: .battery(percent: 12), externalDisplays: 2,
      network: NetworkStatusLineTests.summary(readiness: .off(.wired))),
  ]

  @Test(arguments: snapshots)
  func everyChipIsSpokenAsItsStatusLine(_ snapshot: EngineSnapshot?) throws {
    #expect(Self.snapshots.count >= 8)
    let rows = StatusLines.rows(for: snapshot)
    let summary = StatusChipSummary.make(for: snapshot)
    try #require(summary.chips.count == 3)
    #expect(summary.chips.map(\.kind) == Self.kinds)
    for (chip, row) in zip(summary.chips, rows) {
      #expect(chip.accessibilityText == row.accessibilityText)
      #expect(chip.symbol == row.icon)
      #expect(chip.help == "\(row.label): \(row.value)")
    }
    for (kind, row) in zip(Self.kinds, rows) {
      guard let detail = row.detail else { continue }
      #expect(summary.details.contains { $0.kind == kind && $0.text == detail }, "\(kind): \(detail)")
    }
    let floor = StatusChips.belowFloorDetail(snapshot?.batteryLowPercent ?? Settings().batteryLowPercent)
    for detail in summary.details {
      let fromRow = zip(Self.kinds, rows).contains { $0 == detail.kind && $1.detail == detail.text }
      let display = detail.kind == .lid && detail.text == StatusChips.externalDisplayDetail
      let battery = detail.kind == .battery && detail.text == floor
      #expect(fromRow || display || battery, "\(detail.kind): \(detail.text)")
    }
    let order = summary.details.compactMap { detail in Self.kinds.firstIndex(of: detail.kind) }
    #expect(order == order.sorted())
  }
}
