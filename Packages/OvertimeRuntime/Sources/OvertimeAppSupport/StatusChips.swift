import Foundation
import OvertimeCore
import OvertimeEngine

public struct StatusChip: Sendable, Equatable, Identifiable {
  public enum Kind: Sendable, Equatable, Hashable, CaseIterable {
    case lid
    case battery
    case network
  }

  public var kind: Kind
  public var symbol: String
  public var text: String
  public var help: String
  public var accessibilityText: String

  public var id: Kind { kind }

  public init(kind: Kind, symbol: String, text: String, help: String, accessibilityText: String) {
    self.kind = kind
    self.symbol = symbol
    self.text = text
    self.help = help
    self.accessibilityText = accessibilityText
  }
}

public struct StatusDetail: Sendable, Equatable, Identifiable {
  public var kind: StatusChip.Kind
  public var symbol: String
  public var text: String

  public var id: StatusChip.Kind { kind }

  public init(kind: StatusChip.Kind, symbol: String, text: String) {
    self.kind = kind
    self.symbol = symbol
    self.text = text
  }
}

public struct StatusChipSummary: Sendable, Equatable {
  public var chips: [StatusChip]
  public var details: [StatusDetail]

  public init(chips: [StatusChip], details: [StatusDetail]) {
    self.chips = chips
    self.details = details
  }

  public static func make(for snapshot: EngineSnapshot?) -> StatusChipSummary {
    let rows = StatusLines.rows(for: snapshot)
    guard rows.count == 3 else { return StatusChipSummary(chips: [], details: []) }
    let lid = rows[0]
    let battery = rows[1]
    let network = rows[2]
    let chips = [
      chip(.lid, row: lid, text: StatusChips.lidText(snapshot?.lidClosed)),
      chip(.battery, row: battery, text: StatusChips.batteryText(snapshot?.power, row: battery)),
      chip(.network, row: network, text: network.value),
    ]
    var details: [StatusDetail] = []
    if snapshot?.lidClosed == true, (snapshot?.externalDisplays ?? 0) > 0 {
      details.append(StatusDetail(kind: .lid, symbol: lid.icon, text: StatusChips.externalDisplayDetail))
    }
    if case .battery(_?)? = snapshot?.power, snapshot?.batteryBlocked == true {
      let lowPercent = snapshot?.batteryLowPercent ?? Settings().batteryLowPercent
      details.append(StatusDetail(kind: .battery, symbol: battery.icon, text: StatusChips.belowFloorDetail(lowPercent)))
    }
    if let detail = network.detail {
      details.append(StatusDetail(kind: .network, symbol: network.icon, text: detail))
    }
    return StatusChipSummary(chips: chips, details: details)
  }

  private static func chip(_ kind: StatusChip.Kind, row: StatusLine, text: String) -> StatusChip {
    StatusChip(
      kind: kind, symbol: row.icon, text: text, help: "\(row.label): \(row.value)",
      accessibilityText: row.accessibilityText)
  }
}

public enum StatusChips {
  public static let lidOpen = "Lid open"
  public static let lidClosed = "Lid closed"
  public static let lidUnknown = "Lid unknown"
  public static let batteryUnknown = "Battery unknown"
  public static let externalDisplayDetail = "An external display is connected."

  public static func belowFloorDetail(_ lowPercent: Int) -> String {
    "On battery, below \(lowPercent)%."
  }

  static func lidText(_ closed: Bool?) -> String {
    switch closed {
    case false?: lidOpen
    case true?: lidClosed
    case nil: lidUnknown
    }
  }

  static func batteryText(_ reading: PowerReading?, row: StatusLine) -> String {
    switch reading {
    case .noBattery?: row.value
    case let reading?: reading.percent.map { "\($0)%" } ?? batteryUnknown
    case nil: batteryUnknown
    }
  }
}
