import Foundation

public struct BatteryState: Sendable, Equatable {
  public var blocked: Bool

  public init(blocked: Bool = false) {
    self.blocked = blocked
  }
}

public enum Battery {
  public static let unknownPercentMessage = "Battery level unknown: releasing the Mac so it can sleep"

  public static func step(
    _ state: inout BatteryState, _ reading: PowerReading, low: Int, resume: Int, enabled: Bool = true
  ) -> [Decision] {
    let percent: Int
    switch reading {
    case .ac, .noBattery:
      guard state.blocked else { return [] }
      state.blocked = false
      return [
        Decision(
          keyword: .battery,
          verb: "unblock",
          fields: [
            DecisionField(key: "source", value: "ac"),
            DecisionField(key: "msg", value: "Charger connected: resuming"),
          ]
        )
      ]
    case .battery(nil):
      guard !state.blocked else { return [] }
      state.blocked = true
      return [
        Decision(
          keyword: .battery,
          verb: "block",
          fields: [
            DecisionField(key: "source", value: "battery"),
            DecisionField(key: "percent", value: "unknown"),
            DecisionField(key: "msg", value: unknownPercentMessage),
          ]
        )
      ]
    case .battery(let known?):
      percent = known
    }
    guard enabled else {
      guard state.blocked else { return [] }
      state.blocked = false
      return [
        Decision(
          keyword: .battery,
          verb: "unblock",
          fields: [
            DecisionField(key: "reason", value: "off"),
            DecisionField(key: "msg", value: "Battery protection off: resuming"),
          ]
        )
      ]
    }
    if percent <= low && !state.blocked {
      state.blocked = true
      return [decision("block", percent: percent, message: "Battery at \(percent)%: releasing the Mac so it can sleep")]
    }
    if percent >= resume && state.blocked {
      state.blocked = false
      return [decision("unblock", percent: percent, message: "Battery at \(percent)%: resuming")]
    }
    return []
  }

  static func decision(_ verb: String, percent: Int, message: String) -> Decision {
    Decision(
      keyword: .battery,
      verb: verb,
      fields: [
        DecisionField(key: "source", value: "battery"),
        DecisionField(key: "percent", value: String(percent)),
        DecisionField(key: "msg", value: message),
      ]
    )
  }
}
