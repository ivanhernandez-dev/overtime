import Foundation
import Testing

@testable import OvertimeCore

struct EffectiveHotspotCase: Sendable, CustomTestStringConvertible {
  var label: String
  var hotspot: String
  var autoDetect: Bool
  var candidate: String?
  var factsKnown: Bool
  var expected: EffectiveHotspot?

  var testDescription: String { label }

  static func text(_ values: UInt32...) -> String {
    String(String.UnicodeScalarView(values.compactMap(Unicode.Scalar.init)))
  }

  static let configured = "Test iPhone"
  static let candidate = "Zo" + text(0xEB, 0x2019) + "s iPhone"
  static let bell = "Test" + text(0x07) + "iPhone"

  static let all: [EffectiveHotspotCase] = [
    EffectiveHotspotCase(
      label: "configured, auto off, no candidate", hotspot: configured, autoDetect: false, candidate: nil,
      factsKnown: true, expected: EffectiveHotspot(name: configured, source: .configured)),
    EffectiveHotspotCase(
      label: "configured wins over the candidate", hotspot: configured, autoDetect: true, candidate: candidate,
      factsKnown: true, expected: EffectiveHotspot(name: configured, source: .configured)),
    EffectiveHotspotCase(
      label: "empty, auto on, candidate", hotspot: "", autoDetect: true, candidate: candidate, factsKnown: true,
      expected: EffectiveHotspot(name: candidate, source: .auto)),
    EffectiveHotspotCase(
      label: "empty, auto on, no candidate", hotspot: "", autoDetect: true, candidate: nil, factsKnown: true,
      expected: nil),
    EffectiveHotspotCase(
      label: "empty, auto off, candidate present", hotspot: "", autoDetect: false, candidate: candidate,
      factsKnown: true, expected: nil),
    EffectiveHotspotCase(
      label: "empty, auto on, empty candidate", hotspot: "", autoDetect: true, candidate: "", factsKnown: true,
      expected: nil),
    EffectiveHotspotCase(
      label: "empty, auto on, candidate with a control character", hotspot: "", autoDetect: true, candidate: bell,
      factsKnown: true, expected: nil),
    EffectiveHotspotCase(
      label: "configured, facts unknown", hotspot: configured, autoDetect: false, candidate: nil, factsKnown: false,
      expected: EffectiveHotspot(name: configured, source: .configured)),
    EffectiveHotspotCase(
      label: "empty, auto on, facts unknown", hotspot: "", autoDetect: true, candidate: nil, factsKnown: false,
      expected: nil),
  ]
}

@Suite("Effective hotspot")
struct EffectiveHotspotTests {
  @Test(arguments: EffectiveHotspotCase.all)
  func theEffectiveHotspotComesFromTheConfiguredNameOrTheCandidate(_ example: EffectiveHotspotCase) {
    let settings = Settings(hotspot: example.hotspot, hotspotAutoDetect: example.autoDetect)
    let facts = example.factsKnown ? NetworkFacts(wifiInterface: "en0", autoHotspot: example.candidate) : nil
    #expect(NetworkFailover.effectiveHotspot(settings, facts) == example.expected)
  }

  static func allDecisions(_ driver: NetDriver) -> [Decision] {
    driver.batches.flatMap { ScenarioHarness.decisions($0.effects) }
  }

  @Test func anAutoDetectedHotspotIsJoinedByNameAndLoggedOnlyByItsSource() {
    var driver = NetworkScenarios.stableDriver(
      settings: Settings(hotspot: "", hotspotAutoDetect: true), autoHotspot: EffectiveHotspotCase.candidate)
    NetworkScenarios.offlineThreeTimes(&driver)
    #expect(driver.actions.map(\.effect) == [.joinHotspot(EffectiveHotspotCase.candidate)])
    #expect(driver.netLines == [NetDriver.joinLine(.auto)])
    let values = Self.allDecisions(driver).flatMap { $0.fields.map(\.value) }
    #expect(!values.isEmpty)
    #expect(values.allSatisfy { !$0.contains("Zo") && !$0.contains("iPhone") })
  }

  @Test func theConfiguredNameWinsOverTheCandidateOnTheSameFailoverPath() {
    var driver = NetworkScenarios.stableDriver(
      settings: Settings(hotspot: EffectiveHotspotCase.configured, hotspotAutoDetect: true),
      autoHotspot: EffectiveHotspotCase.candidate)
    NetworkScenarios.offlineThreeTimes(&driver)
    #expect(driver.actions.map(\.effect) == [.joinHotspot(EffectiveHotspotCase.configured)])
    #expect(driver.netLines == [NetDriver.joinLine(.configured)])
    let values = Self.allDecisions(driver).flatMap { $0.fields.map(\.value) }
    #expect(values.allSatisfy { !$0.contains("iPhone") })
  }

  @Test func withAutoDetectOnAndNoCandidateNothingTouchesTheNetwork() {
    var driver = NetworkScenarios.stableDriver(
      settings: Settings(hotspot: "", hotspotAutoDetect: true), autoHotspot: nil)
    driver.run(from: 2, to: 60, answering: false)
    for second in stride(from: 61.0, through: 63.0, by: 1.0) {
      driver.probeResult(online: false, at: second)
    }
    #expect(driver.netEffects.isEmpty)
    #expect(driver.netLines.isEmpty)
  }
}
