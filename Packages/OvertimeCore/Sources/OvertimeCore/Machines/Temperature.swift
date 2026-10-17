import Foundation

public struct TemperatureState: Sendable, Equatable {
  public var blocked: Bool
  public var reading: BatteryTemperatureReading?

  public init(blocked: Bool = false, reading: BatteryTemperatureReading? = nil) {
    self.blocked = blocked
    self.reading = reading
  }
}

public enum Temperature {
  public static func step(
    _ state: inout TemperatureState, _ reading: BatteryTemperatureReading, enabled: Bool, release: Int
  ) -> [Decision] {
    let stored = state.reading
    state.reading = reading
    guard enabled else {
      guard state.blocked else { return [] }
      state.blocked = false
      return [
        decision(
          "unblock", [DecisionField(key: "reason", value: "off")], message: "Temperature protection off: resuming")
      ]
    }
    switch reading {
    case .unreadable:
      guard stored != .unreadable else { return [] }
      return [
        decision(
          "unreadable", [DecisionField(key: "blocked", value: state.blocked ? "true" : "false")],
          message: "Battery temperature unreadable: keeping the last state")
      ]
    case .unavailable:
      if state.blocked {
        state.blocked = false
        return [
          decision(
            "unblock", [DecisionField(key: "reason", value: "unavailable")],
            message: "Battery temperature unavailable: resuming")
        ]
      }
      guard stored != .unavailable else { return [] }
      return [
        decision("unavailable", [], message: "Battery temperature unavailable: temperature protection cannot act")
      ]
    case .celsius(let celsius):
      if !state.blocked && celsius >= release {
        state.blocked = true
        return [
          decision(
            "block", [DecisionField(key: "celsius", value: String(celsius))],
            message: "Battery at \(celsius) degrees Celsius: releasing the Mac so it can sleep")
        ]
      }
      if state.blocked && celsius < release - Settings.temperatureResumeHysteresisCelsius {
        state.blocked = false
        return [
          decision(
            "unblock", [DecisionField(key: "celsius", value: String(celsius))],
            message: "Battery at \(celsius) degrees Celsius: resuming")
        ]
      }
      return []
    }
  }

  static func decision(_ verb: String, _ fields: [DecisionField], message: String) -> Decision {
    Decision(keyword: .temperature, verb: verb, fields: fields + [DecisionField(key: "msg", value: message)])
  }
}
