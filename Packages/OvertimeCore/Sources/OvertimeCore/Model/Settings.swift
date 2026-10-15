import Foundation

public struct Settings: Codable, Sendable, Equatable {
  public var batteryLowPercent: Int
  public var batteryResumePercent: Int
  public var transcriptWindowSeconds: Double
  public var releaseGraceSeconds: Double
  public var stuckWindowSeconds: Double
  public var transcriptRoots: [String]?
  public var ignoredEntrypoints: [String]
  public var keepDisplayOn: Bool
  public var hotspot: String
  public var hotspotAutoDetect: Bool

  public init(
    batteryLowPercent: Int = 10,
    batteryResumePercent: Int = 20,
    transcriptWindowSeconds: Double = 120,
    releaseGraceSeconds: Double = 60,
    stuckWindowSeconds: Double = 1800,
    transcriptRoots: [String]? = nil,
    ignoredEntrypoints: [String] = ["sdk-*"],
    keepDisplayOn: Bool = false,
    hotspot: String = "",
    hotspotAutoDetect: Bool = false
  ) {
    self.batteryLowPercent = batteryLowPercent
    self.batteryResumePercent = batteryResumePercent
    self.transcriptWindowSeconds = transcriptWindowSeconds
    self.releaseGraceSeconds = releaseGraceSeconds
    self.stuckWindowSeconds = stuckWindowSeconds
    self.transcriptRoots = transcriptRoots
    self.ignoredEntrypoints = ignoredEntrypoints
    self.keepDisplayOn = keepDisplayOn
    self.hotspot = hotspot
    self.hotspotAutoDetect = hotspotAutoDetect
  }

  private enum CodingKeys: String, CodingKey {
    case batteryLowPercent
    case batteryResumePercent
    case transcriptWindowSeconds
    case releaseGraceSeconds
    case stuckWindowSeconds
    case transcriptRoots
    case ignoredEntrypoints
    case keepDisplayOn
    case hotspot
    case hotspotAutoDetect
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = Settings()
    batteryLowPercent =
      try container.decodeIfPresent(Int.self, forKey: .batteryLowPercent) ?? defaults.batteryLowPercent
    batteryResumePercent =
      try container.decodeIfPresent(Int.self, forKey: .batteryResumePercent) ?? defaults.batteryResumePercent
    transcriptWindowSeconds =
      try container.decodeIfPresent(Double.self, forKey: .transcriptWindowSeconds)
      ?? defaults.transcriptWindowSeconds
    releaseGraceSeconds =
      try container.decodeIfPresent(Double.self, forKey: .releaseGraceSeconds) ?? defaults.releaseGraceSeconds
    stuckWindowSeconds =
      try container.decodeIfPresent(Double.self, forKey: .stuckWindowSeconds) ?? defaults.stuckWindowSeconds
    transcriptRoots = try container.decodeIfPresent([String].self, forKey: .transcriptRoots)
    ignoredEntrypoints =
      try container.decodeIfPresent([String].self, forKey: .ignoredEntrypoints) ?? defaults.ignoredEntrypoints
    keepDisplayOn = try container.decodeIfPresent(Bool.self, forKey: .keepDisplayOn) ?? defaults.keepDisplayOn
    hotspot = try container.decodeIfPresent(String.self, forKey: .hotspot) ?? defaults.hotspot
    hotspotAutoDetect =
      try container.decodeIfPresent(Bool.self, forKey: .hotspotAutoDetect) ?? defaults.hotspotAutoDetect
  }

  public static func defaultTranscriptRoots(environment: [String: String], homeDirectory: String) -> [String] {
    TranscriptRoots.defaults(environment: environment, homeDirectory: homeDirectory).map(\.path)
  }

  public func resolvedTranscriptRoots(environment: [String: String], homeDirectory: String) -> [String] {
    transcriptRootSet(environment: environment, homeDirectory: homeDirectory).map(\.path)
  }

  public func transcriptRootSet(environment: [String: String], homeDirectory: String) -> [TranscriptRoot] {
    if let transcriptRoots, !transcriptRoots.isEmpty {
      return transcriptRoots.map { TranscriptRoot(path: $0, origin: .configured) }
    }
    return TranscriptRoots.defaults(environment: environment, homeDirectory: homeDirectory)
  }
}

public struct SettingsAdjustment: Sendable, Equatable {
  public var key: String
  public var from: String
  public var to: String

  public init(key: String, from: String, to: String) {
    self.key = key
    self.from = from
    self.to = to
  }

  public var decision: Decision {
    Decision(
      keyword: .warn, verb: "settingsClamped",
      fields: [
        DecisionField(key: "key", value: key),
        DecisionField(key: "from", value: from),
        DecisionField(key: "to", value: to),
      ])
  }
}

extension Settings {
  public static let batteryLowRange = 1...50
  public static let batteryResumeMax = 100
  public static let transcriptWindowRange: ClosedRange<Double> = 10...3600
  public static let releaseGraceRange: ClosedRange<Double> = 1...3600
  public static let stuckWindowMinSeconds: Double = 60
  public static let stuckWindowMaxSeconds: Double = 14_400
  public static let maxSSIDBytes = 32

  public static func isValidSSID(_ name: String) -> Bool {
    let bytes = name.utf8.count
    guard bytes >= 1, bytes <= maxSSIDBytes else { return false }
    return name.unicodeScalars.allSatisfy { scalar in
      scalar.value >= 0x20 && !(0x7F...0x9F).contains(scalar.value)
    }
  }

  public func validated() -> (settings: Settings, adjustments: [SettingsAdjustment]) {
    let defaults = Settings()
    var result = self
    var adjustments: [SettingsAdjustment] = []
    func record(_ key: String, _ from: String, _ to: String) {
      guard from != to else { return }
      adjustments.append(SettingsAdjustment(key: key, from: from, to: to))
    }
    func clamp(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
      value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
    }
    result.batteryLowPercent = min(
      max(batteryLowPercent, Self.batteryLowRange.lowerBound), Self.batteryLowRange.upperBound)
    record("batteryLowPercent", String(batteryLowPercent), String(result.batteryLowPercent))
    result.batteryResumePercent = min(max(batteryResumePercent, result.batteryLowPercent + 1), Self.batteryResumeMax)
    record("batteryResumePercent", String(batteryResumePercent), String(result.batteryResumePercent))
    result.transcriptWindowSeconds = clamp(
      transcriptWindowSeconds, Self.transcriptWindowRange, fallback: defaults.transcriptWindowSeconds)
    record(
      "transcriptWindowSeconds", Busy.seconds(transcriptWindowSeconds), Busy.seconds(result.transcriptWindowSeconds))
    result.releaseGraceSeconds = clamp(
      releaseGraceSeconds, Self.releaseGraceRange, fallback: defaults.releaseGraceSeconds)
    record("releaseGraceSeconds", Busy.seconds(releaseGraceSeconds), Busy.seconds(result.releaseGraceSeconds))
    let stuckRange = max(Self.stuckWindowMinSeconds, result.transcriptWindowSeconds)...Self.stuckWindowMaxSeconds
    result.stuckWindowSeconds = clamp(
      stuckWindowSeconds, stuckRange,
      fallback: min(max(defaults.stuckWindowSeconds, stuckRange.lowerBound), stuckRange.upperBound))
    record("stuckWindowSeconds", Busy.seconds(stuckWindowSeconds), Busy.seconds(result.stuckWindowSeconds))
    if !result.hotspot.isEmpty, !Self.isValidSSID(result.hotspot) {
      result.hotspot = ""
      record("hotspot", "invalid", "")
    }
    return (result, adjustments)
  }
}
