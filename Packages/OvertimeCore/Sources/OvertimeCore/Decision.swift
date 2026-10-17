import Foundation

public enum DecisionKeyword: String, Sendable, CaseIterable {
  case start = "START"
  case stop = "STOP"
  case busy = "BUSY"
  case want = "WANT"
  case stuck = "STUCK"
  case entrypoint = "ENTRYPOINT"
  case battery = "BATTERY"
  case override = "OVERRIDE"
  case hold = "HOLD"
  case lid = "LID"
  case display = "DISPLAY"
  case verify = "VERIFY"
  case warn = "WARN"
  case net = "NET"
  case sentinel = "SENTINEL"
  case check = "CHECK"
  case error = "ERROR"
  case command = "COMMAND"
  case settings = "SETTINGS"
  case selftest = "SELFTEST"
  case uninstall = "UNINSTALL"
  case temperature = "TEMPERATURE"
}

public struct DecisionField: Sendable, Equatable {
  public var key: String
  public var value: String

  public init(key: String, value: String) {
    self.key = key
    self.value = value
  }
}

public struct Decision: Sendable, Equatable {
  public var keyword: DecisionKeyword
  public var verb: String
  public var fields: [DecisionField]

  public init(keyword: DecisionKeyword, verb: String, fields: [DecisionField] = []) {
    self.keyword = keyword
    self.verb = verb
    self.fields = fields
  }
}

public enum DecisionFormatter {
  public static func line(_ decision: Decision, wall: Date, timeZone: TimeZone) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = timeZone
    var line = formatter.string(from: wall) + " " + decision.keyword.rawValue + " " + decision.verb
    for field in decision.fields {
      line += " " + field.key + "=" + quoted(field.value)
    }
    return line
  }

  static func quoted(_ value: String) -> String {
    guard value.contains(" ") || value.contains("\"") else { return value }
    return "\"" + value.replacingOccurrences(of: "\"", with: "\\\"") + "\""
  }
}
