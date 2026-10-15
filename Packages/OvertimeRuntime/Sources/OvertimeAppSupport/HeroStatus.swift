import Foundation
import OvertimeCore
import OvertimeEngine

public enum HeroStatus {
  public static func isLit(_ state: PanelState) -> Bool {
    switch state {
    case .holding, .lidClosedHolding, .override:
      true
    case .starting, .idle, .grace, .paused, .releasedUntilIdle, .batteryFloor, .uninstalling, .error:
      false
    }
  }
}

public struct AwakeTime: Sendable, Equatable {
  public static let unit = "awake"
  public static let placeholder = "—"

  public var figure: String
  public var isPlaceholder: Bool
  public var note: String?
  public var spoken: String

  public init(figure: String, isPlaceholder: Bool, note: String?, spoken: String) {
    self.figure = figure
    self.isPlaceholder = isPlaceholder
    self.note = note
    self.spoken = spoken
  }

  public static func make(
    for presentation: StatusPresentation, snapshot: EngineSnapshot?, nowMono: Instant, nowWall: Date,
    calendar: Calendar = .current
  ) -> AwakeTime {
    let parts = TimingLine.parts(
      for: presentation, snapshot: snapshot, nowMono: nowMono, nowWall: nowWall, calendar: calendar)
    let line = TimingLine.line(
      for: presentation, snapshot: snapshot, nowMono: nowMono, nowWall: nowWall, calendar: calendar)
    let note = parts?.lead?.text
    let spoken = line?.spoken ?? ""
    guard let held = parts?.held else {
      return AwakeTime(figure: placeholder, isPlaceholder: true, note: note, spoken: spoken)
    }
    return AwakeTime(figure: held.text, isPlaceholder: false, note: note, spoken: spoken)
  }
}
