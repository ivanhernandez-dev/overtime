import Foundation

public enum HelperReplyCode: Int32, Sendable, Equatable {
  case owned = 0
  case alreadyOn = 1
  case cleared = 2
  case refused = -1
}

public struct HelperReply: Sendable, Equatable {
  public let code: HelperReplyCode
  public let message: String

  public init(code: HelperReplyCode, message: String) {
    self.code = code
    self.message = message
  }
}

public struct HelperStatus: Codable, Sendable, Equatable {
  public var helperVersion: Int
  public var sleepDisabled: Bool?
  public var owns: Bool
  public var prior: Bool?
  public var engaged: Bool
  public var batteryPercent: Int?
  public var onBattery: Bool?
  public var warningLevel: Int?
  public var thermalLevel: Int?
  public var thermalCritical: Bool?
  public var lastReleaseReason: String?
  public var exiting: Bool

  private enum CodingKeys: String, CodingKey {
    case helperVersion
    case sleepDisabled
    case owns
    case prior
    case engaged
    case batteryPercent
    case onBattery
    case warningLevel
    case thermalLevel
    case thermalCritical
    case lastReleaseReason
    case exiting
  }

  public init(
    helperVersion: Int = 0, sleepDisabled: Bool? = nil, owns: Bool = false, prior: Bool? = nil, engaged: Bool = false,
    batteryPercent: Int? = nil, onBattery: Bool? = nil, warningLevel: Int? = nil, thermalLevel: Int? = nil,
    thermalCritical: Bool? = nil, lastReleaseReason: String? = nil, exiting: Bool = false
  ) {
    self.helperVersion = helperVersion
    self.sleepDisabled = sleepDisabled
    self.owns = owns
    self.prior = prior
    self.engaged = engaged
    self.batteryPercent = batteryPercent
    self.onBattery = onBattery
    self.warningLevel = warningLevel
    self.thermalLevel = thermalLevel
    self.thermalCritical = thermalCritical
    self.lastReleaseReason = lastReleaseReason
    self.exiting = exiting
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    helperVersion = Self.lenient(values, .helperVersion) ?? 0
    sleepDisabled = Self.lenient(values, .sleepDisabled)
    owns = Self.lenient(values, .owns) ?? false
    prior = Self.lenient(values, .prior)
    engaged = Self.lenient(values, .engaged) ?? false
    batteryPercent = Self.lenient(values, .batteryPercent)
    onBattery = Self.lenient(values, .onBattery)
    warningLevel = Self.lenient(values, .warningLevel)
    thermalLevel = Self.lenient(values, .thermalLevel)
    thermalCritical = Self.lenient(values, .thermalCritical)
    lastReleaseReason = Self.lenient(values, .lastReleaseReason)
    exiting = Self.lenient(values, .exiting) ?? false
  }

  public func encoded() -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return (try? encoder.encode(self)) ?? Data()
  }

  public static func decode(_ data: Data) -> HelperStatus? {
    try? JSONDecoder().decode(HelperStatus.self, from: data)
  }

  private static func lenient<Value: Decodable>(
    _ values: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
  ) -> Value? {
    try? values.decodeIfPresent(Value.self, forKey: key)
  }
}
