import Foundation
import Testing

@testable import OvertimeCore

struct SettingsTests {
  func decode(_ json: String) throws -> Settings {
    try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
  }

  @Test func theDefaultsAreTheDocumentedValues() {
    let settings = Settings()
    #expect(settings.batteryLowPercent == 10)
    #expect(settings.batteryResumePercent == 20)
    #expect(settings.transcriptWindowSeconds == 120)
    #expect(settings.releaseGraceSeconds == 60)
    #expect(settings.stuckWindowSeconds == 1800)
    #expect(settings.transcriptRoots == nil)
    #expect(settings.ignoredEntrypoints == ["sdk-*"])
    #expect(settings.keepDisplayOn == false)
    #expect(settings.hotspot == "")
    #expect(settings.hotspotAutoDetect == false)
    #expect(settings.batteryProtectionEnabled == true)
    #expect(settings.helperBatteryFloorPercent == 10)
    #expect(settings.temperatureProtectionEnabled == false)
    #expect(settings.temperatureReleaseCelsius == 45)
    #expect(settings.lidClosedKeepAwake == .always)
    #expect(settings.pauseFirstMinutes == 15)
    #expect(settings.pauseSecondMinutes == 60)
    #expect(settings.keepAwakeFirstMinutes == 30)
    #expect(settings.keepAwakeSecondMinutes == 120)
  }

  static let durationKeys = [
    "pauseFirstMinutes", "pauseSecondMinutes", "keepAwakeFirstMinutes", "keepAwakeSecondMinutes",
  ]

  static func durations(_ settings: Settings) -> [String: Int] {
    [
      "pauseFirstMinutes": settings.pauseFirstMinutes,
      "pauseSecondMinutes": settings.pauseSecondMinutes,
      "keepAwakeFirstMinutes": settings.keepAwakeFirstMinutes,
      "keepAwakeSecondMinutes": settings.keepAwakeSecondMinutes,
    ]
  }

  static func settings(_ key: String, minutes: Int) -> Settings {
    var settings = Settings()
    switch key {
    case "pauseFirstMinutes": settings.pauseFirstMinutes = minutes
    case "pauseSecondMinutes": settings.pauseSecondMinutes = minutes
    case "keepAwakeFirstMinutes": settings.keepAwakeFirstMinutes = minutes
    case "keepAwakeSecondMinutes": settings.keepAwakeSecondMinutes = minutes
    default: Issue.record("unknown duration key \(key)")
    }
    return settings
  }

  @Test func theDurationDefaultsAreTodaysChoices() {
    let expected = [
      "pauseFirstMinutes": 15, "pauseSecondMinutes": 60, "keepAwakeFirstMinutes": 30, "keepAwakeSecondMinutes": 120,
    ]
    #expect(Self.durations(Settings()) == expected)
  }

  @Test func aFileWithoutTheDurationKeysKeepsTodaysChoices() throws {
    #expect(Self.durations(try decode(#"{"batteryLowPercent":15}"#)) == Self.durations(Settings()))
  }

  @Test func theDurationRangeIsOneMinuteToADay() {
    #expect(Settings.presetMinutesRange == 1...1440)
  }

  @Test func theDurationsRoundTripThroughJSON() throws {
    let settings = Settings(
      pauseFirstMinutes: 45, pauseSecondMinutes: 90, keepAwakeFirstMinutes: 10, keepAwakeSecondMinutes: 1440)
    let data = try JSONEncoder().encode(settings)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["pauseFirstMinutes"] as? Int == 45)
    #expect(object["pauseSecondMinutes"] as? Int == 90)
    #expect(object["keepAwakeFirstMinutes"] as? Int == 10)
    #expect(object["keepAwakeSecondMinutes"] as? Int == 1440)
    #expect(try JSONDecoder().decode(Settings.self, from: data) == settings)
  }

  @Test(arguments: durationKeys, [(-5, 1), (0, 1), (1, 1), (45, 45), (1440, 1440), (1441, 1440), (Int.max, 1440)])
  func anOutOfRangeDurationIsClampedAndRecorded(_ key: String, _ pair: (value: Int, expected: Int)) {
    let validation = Self.settings(key, minutes: pair.value).validated()
    #expect(Self.durations(validation.settings)[key] == pair.expected)
    let recorded = validation.adjustments.filter { $0.key == key }
    if pair.value == pair.expected {
      #expect(recorded.isEmpty)
    } else {
      #expect(recorded == [SettingsAdjustment(key: key, from: String(pair.value), to: String(pair.expected))])
    }
  }

  @Test func aWrongTypeForADurationIsRejected() {
    #expect(throws: (any Error).self) { try decode(#"{"pauseFirstMinutes":"15"}"#) }
    #expect(throws: (any Error).self) { try decode(#"{"keepAwakeSecondMinutes":1.5}"#) }
  }

  @Test func aFileWithoutTheLidClosedKeyKeepsAlways() throws {
    let settings = try decode(#"{"batteryLowPercent":15}"#)
    #expect(settings == Settings(batteryLowPercent: 15))
    #expect(settings.lidClosedKeepAwake == .always)
  }

  @Test func theLidClosedSettingRoundTripsThroughJSON() throws {
    for value in LidClosedKeepAwake.allCases {
      let settings = Settings(lidClosedKeepAwake: value)
      let data = try JSONEncoder().encode(settings)
      let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
      #expect(object["lidClosedKeepAwake"] as? String == value.rawValue)
      #expect(try JSONDecoder().decode(Settings.self, from: data) == settings)
    }
  }

  @Test func anUnknownLidClosedValueIsRejected() {
    #expect(throws: (any Error).self) { try decode(#"{"lidClosedKeepAwake":"sometimes"}"#) }
    #expect(throws: (any Error).self) { try decode(#"{"lidClosedKeepAwake":true}"#) }
  }

  @Test func aFileWithoutTheProtectionKeysKeepsTheirDefaults() throws {
    #expect(try decode(#"{"batteryLowPercent":15}"#) == Settings(batteryLowPercent: 15))
  }

  @Test func aFileWithoutTheTemperatureKeyLeavesTemperatureProtectionOff() throws {
    let settings = try decode(#"{"batteryLowPercent":15,"temperatureReleaseCelsius":50}"#)
    #expect(settings.temperatureProtectionEnabled == false)
    #expect(settings.temperatureReleaseCelsius == 50)
    #expect(settings.batteryProtectionEnabled == true)
    #expect(settings.helperBatteryFloorPercent == 10)
    #expect(HelperLimits(settings: settings).temperatureCeilingCelsius == nil)
    #expect(HelperLimits(settings: Settings()) == HelperLimits(batteryFloorPercent: 10, temperatureCeilingCelsius: nil))
  }

  @Test func theProtectionSettingsRoundTripThroughJSON() throws {
    let settings = Settings(
      batteryProtectionEnabled: false, helperBatteryFloorPercent: 25, temperatureProtectionEnabled: false,
      temperatureReleaseCelsius: 50)
    let data = try JSONEncoder().encode(settings)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["batteryProtectionEnabled"] as? Bool == false)
    #expect(object["helperBatteryFloorPercent"] as? Int == 25)
    #expect(object["temperatureProtectionEnabled"] as? Bool == false)
    #expect(object["temperatureReleaseCelsius"] as? Int == 50)
    #expect(try JSONDecoder().decode(Settings.self, from: data) == settings)
  }

  @Test(arguments: [(-1, 5), (0, 5), (4, 5), (5, 5), (25, 25), (50, 50), (51, 50), (1000, 50)])
  func anOutOfRangeHelperFloorIsClampedAndRecorded(_ value: Int, _ expected: Int) {
    let validation = Settings(helperBatteryFloorPercent: value).validated()
    #expect(validation.settings.helperBatteryFloorPercent == expected)
    let recorded = validation.adjustments.filter { $0.key == "helperBatteryFloorPercent" }
    if value == expected {
      #expect(recorded.isEmpty)
    } else {
      #expect(
        recorded == [SettingsAdjustment(key: "helperBatteryFloorPercent", from: String(value), to: String(expected))])
    }
  }

  @Test(arguments: [(-5, 35), (20, 35), (34, 35), (35, 35), (45, 45), (60, 60), (61, 60)])
  func anOutOfRangeReleaseTemperatureIsClampedAndRecorded(_ value: Int, _ expected: Int) {
    let validation = Settings(temperatureReleaseCelsius: value).validated()
    #expect(validation.settings.temperatureReleaseCelsius == expected)
    let recorded = validation.adjustments.filter { $0.key == "temperatureReleaseCelsius" }
    if value == expected {
      #expect(recorded.isEmpty)
    } else {
      #expect(
        recorded == [SettingsAdjustment(key: "temperatureReleaseCelsius", from: String(value), to: String(expected))])
    }
  }

  @Test func theResumeTemperatureIsFiveDegreesBelowTheRelease() {
    #expect(Settings.temperatureResumeHysteresisCelsius == 5)
    #expect(Settings(temperatureReleaseCelsius: 45).temperatureResumeCelsius == 40)
    #expect(Settings(temperatureReleaseCelsius: 35).temperatureResumeCelsius == 30)
    #expect(Settings(temperatureReleaseCelsius: 60).temperatureResumeCelsius == 55)
  }

  @Test func aWrongTypeForAProtectionSwitchIsRejected() {
    #expect(throws: (any Error).self) { try decode(#"{"batteryProtectionEnabled":"no"}"#) }
    #expect(throws: (any Error).self) { try decode(#"{"temperatureReleaseCelsius":"hot"}"#) }
  }

  @Test func decodingAnEmptyObjectGivesTheDefaults() throws {
    #expect(try decode("{}") == Settings())
  }

  @Test func unknownKeysAreIgnored() throws {
    let settings = try decode(#"{"evil":"$(touch /tmp/pwned)","releaseGraceSeconds":30,"nested":{"a":1}}"#)
    #expect(settings == Settings(releaseGraceSeconds: 30))
  }

  @Test func wrongTypesAreRejected() {
    #expect(throws: (any Error).self) { try decode(#"{"releaseGraceSeconds":"sixty"}"#) }
  }

  @Test func roundTripsThroughJSON() throws {
    let settings = Settings(
      batteryLowPercent: 15,
      batteryResumePercent: 25,
      transcriptWindowSeconds: 90,
      releaseGraceSeconds: 30,
      stuckWindowSeconds: 600,
      transcriptRoots: ["/a", "/b"],
      ignoredEntrypoints: ["x", "sdk-*"],
      keepDisplayOn: true,
      hotspot: "Phone"
    )
    let data = try JSONEncoder().encode(settings)
    #expect(try JSONDecoder().decode(Settings.self, from: data) == settings)
  }

  @Test func anOlderFileWithoutHotspotAutoDetectLoadsWithItOff() throws {
    let settings = try decode(#"{"hotspot":"Ivan’s iPhone","keepDisplayOn":true}"#)
    #expect(settings == Settings(keepDisplayOn: true, hotspot: "Ivan’s iPhone"))
    #expect(settings.hotspotAutoDetect == false)
  }

  @Test func hotspotAutoDetectRoundTripsThroughJSON() throws {
    let settings = Settings(hotspotAutoDetect: true)
    let data = try JSONEncoder().encode(settings)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["hotspotAutoDetect"] as? Bool == true)
    #expect(object["hotspot"] as? String == "")
    #expect(try JSONDecoder().decode(Settings.self, from: data) == settings)
  }

  @Test func aWrongTypeForHotspotAutoDetectIsRejected() {
    #expect(throws: (any Error).self) { try decode(#"{"hotspotAutoDetect":"yes"}"#) }
  }

  @Test(arguments: [
    Settings(hotspot: "", hotspotAutoDetect: false),
    Settings(hotspot: "", hotspotAutoDetect: true),
    Settings(hotspot: "Ivan’s iPhone", hotspotAutoDetect: false),
    Settings(hotspot: "Ivan’s iPhone", hotspotAutoDetect: true),
  ])
  func validationNeverAdjustsTheHotspotChoice(_ settings: Settings) {
    let validation = settings.validated()
    #expect(validation.settings.hotspot == settings.hotspot)
    #expect(validation.settings.hotspotAutoDetect == settings.hotspotAutoDetect)
    #expect(validation.adjustments.isEmpty)
  }

  @Test func claudeConfigDirAddsItsProjectsDirectoryToTheHomeOne() {
    #expect(
      Settings().resolvedTranscriptRoots(environment: ["CLAUDE_CONFIG_DIR": "/cfg"], homeDirectory: "/Users/dev")
        == ["/Users/dev/.claude/projects", "/cfg/projects"])
    #expect(
      Settings().resolvedTranscriptRoots(environment: ["CLAUDE_CONFIG_DIR": "/cfg/"], homeDirectory: "/Users/dev")
        == ["/Users/dev/.claude/projects", "/cfg/projects"])
  }

  @Test func emptyOrMissingClaudeConfigDirFallsBackToHome() {
    #expect(
      Settings().resolvedTranscriptRoots(environment: ["CLAUDE_CONFIG_DIR": ""], homeDirectory: "/Users/dev")
        == ["/Users/dev/.claude/projects"])
    #expect(
      Settings().resolvedTranscriptRoots(environment: [:], homeDirectory: "/Users/dev")
        == ["/Users/dev/.claude/projects"])
  }

  @Test func explicitTranscriptRootsWin() {
    let settings = Settings(transcriptRoots: ["/x", "/y"])
    #expect(
      settings.resolvedTranscriptRoots(environment: ["CLAUDE_CONFIG_DIR": "/cfg"], homeDirectory: "/Users/dev")
        == ["/x", "/y"])
  }

  @Test func emptyExplicitRootsFallBackToTheHomeAndEnvironmentRoots() {
    let settings = Settings(transcriptRoots: [])
    #expect(
      settings.resolvedTranscriptRoots(environment: ["CLAUDE_CONFIG_DIR": "/cfg"], homeDirectory: "/Users/dev")
        == ["/Users/dev/.claude/projects", "/cfg/projects"])
  }

  @Test func defaultsNeedNoClamping() {
    let validation = Settings().validated()
    #expect(validation.settings == Settings())
    #expect(validation.adjustments.isEmpty)
  }

  @Test func aNegativeBatteryFloorIsRaisedSoBAT01StillBlocks() {
    let validation = Settings(batteryLowPercent: -1).validated()
    #expect(validation.settings.batteryLowPercent == 1)
    #expect(validation.adjustments == [SettingsAdjustment(key: "batteryLowPercent", from: "-1", to: "1")])
  }

  @Test func aResumeAtOrBelowTheFloorIsRaisedAboveIt() {
    let validation = Settings(batteryLowPercent: 80, batteryResumePercent: 30).validated()
    #expect(validation.settings.batteryLowPercent == 50)
    #expect(validation.settings.batteryResumePercent == 51)
    #expect(validation.settings.batteryLowPercent < validation.settings.batteryResumePercent)
  }

  @Test func hugeWindowsAreCappedSoTheStuckGuardStillWorks() {
    let validation = Settings(
      transcriptWindowSeconds: 1e12, releaseGraceSeconds: 1e9, stuckWindowSeconds: 999_999_999
    ).validated()
    #expect(validation.settings.transcriptWindowSeconds == 3600)
    #expect(validation.settings.releaseGraceSeconds == 3600)
    #expect(validation.settings.stuckWindowSeconds == 14_400)
    #expect(
      validation.adjustments.map(\.key) == ["transcriptWindowSeconds", "releaseGraceSeconds", "stuckWindowSeconds"])
    #expect(
      validation.adjustments.last?.decision
        == Decision(
          keyword: .warn, verb: "settingsClamped",
          fields: [
            DecisionField(key: "key", value: "stuckWindowSeconds"),
            DecisionField(key: "from", value: "999999999"),
            DecisionField(key: "to", value: "14400"),
          ]))
  }

  @Test func zeroOrNonFiniteWindowsBecomePositive() {
    let validation = Settings(
      transcriptWindowSeconds: .nan, releaseGraceSeconds: 0, stuckWindowSeconds: -.infinity
    ).validated()
    #expect(validation.settings.transcriptWindowSeconds == 120)
    #expect(validation.settings.releaseGraceSeconds == 1)
    #expect(validation.settings.stuckWindowSeconds == 1800)
  }

  @Test func theStuckWindowIsNeverShorterThanTheTranscriptWindow() {
    let validation = Settings(transcriptWindowSeconds: 900, stuckWindowSeconds: 300).validated()
    #expect(validation.settings.stuckWindowSeconds == 900)
  }

  @Test func theLongRunningDefaultsAreOnWithNoLimit() {
    let settings = Settings()
    #expect(settings.backgroundCommandsKeepAwake == true)
    #expect(settings.printRunsKeepAwake == true)
    #expect(settings.longRunningLimitEnabled == false)
    #expect(settings.longRunningLimitMinutes == 120)
    #expect(Settings.longRunningLimitRange == 15...720)
  }

  static let releasedFile = """
    {"batteryLowPercent":10,"batteryResumePercent":20,"transcriptWindowSeconds":120,"releaseGraceSeconds":60,
    "stuckWindowSeconds":1800,"ignoredEntrypoints":["sdk-*"],"keepDisplayOn":false,"hotspot":"",
    "hotspotAutoDetect":false,"batteryProtectionEnabled":true,"helperBatteryFloorPercent":10,
    "temperatureProtectionEnabled":false,"temperatureReleaseCelsius":45,"lidClosedKeepAwake":"always",
    "pauseFirstMinutes":15,"pauseSecondMinutes":60,"keepAwakeFirstMinutes":30,"keepAwakeSecondMinutes":120}
    """

  @Test func aFileWithoutTheLongRunningKeysGetsTheDefaults() throws {
    #expect(try decode("{}") == Settings())
    #expect(try decode(Self.releasedFile) == Settings())
  }

  @Test func theLongRunningKeysRoundTrip() throws {
    let settings = Settings(
      backgroundCommandsKeepAwake: false, printRunsKeepAwake: false, longRunningLimitEnabled: true,
      longRunningLimitMinutes: 45)
    let data = try JSONEncoder().encode(settings)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["backgroundCommandsKeepAwake"] as? Bool == false)
    #expect(object["printRunsKeepAwake"] as? Bool == false)
    #expect(object["longRunningLimitEnabled"] as? Bool == true)
    #expect(object["longRunningLimitMinutes"] as? Int == 45)
    #expect(try JSONDecoder().decode(Settings.self, from: data) == settings)
    #expect(throws: (any Error).self) { try decode(#"{"longRunningLimitMinutes":"two hours"}"#) }
    #expect(throws: (any Error).self) { try decode(#"{"backgroundCommandsKeepAwake":"yes"}"#) }
  }

  @Test(arguments: [(1, 15), (14, 15), (15, 15), (720, 720), (721, 720), (-5, 15)])
  func theLimitIsClampedToFifteenMinutesToTwelveHours(_ pair: (value: Int, expected: Int)) {
    let validation = Settings(longRunningLimitMinutes: pair.value).validated()
    #expect(validation.settings.longRunningLimitMinutes == pair.expected)
    let recorded = validation.adjustments.filter { $0.key == "longRunningLimitMinutes" }
    if pair.value == pair.expected {
      #expect(recorded.isEmpty)
    } else {
      #expect(
        recorded == [
          SettingsAdjustment(key: "longRunningLimitMinutes", from: String(pair.value), to: String(pair.expected))
        ])
    }
  }

  @Test func anEnabledLimitIsGivenInSeconds() {
    #expect(Settings(longRunningLimitEnabled: true, longRunningLimitMinutes: 120).longRunningLimitSeconds == 7200)
    #expect(Settings(longRunningLimitEnabled: false, longRunningLimitMinutes: 120).longRunningLimitSeconds == nil)
  }
}
