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
}
