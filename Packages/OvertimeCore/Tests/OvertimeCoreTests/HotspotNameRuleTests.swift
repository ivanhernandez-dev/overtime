import Foundation
import Testing

@testable import OvertimeCore

struct SSIDCase: Sendable, CustomTestStringConvertible {
  var label: String
  var name: String
  var valid: Bool

  var testDescription: String { label }

  static func text(_ values: UInt32...) -> String {
    String(String.UnicodeScalarView(values.compactMap(Unicode.Scalar.init)))
  }

  static let apostrophe = text(0x2019)
  static let zoe = "Zo" + text(0xEB) + apostrophe + "s iPhone"

  static let all: [SSIDCase] = [
    SSIDCase(label: "empty", name: "", valid: false),
    SSIDCase(label: "one byte", name: "a", valid: true),
    SSIDCase(label: "32 ASCII bytes", name: String(repeating: "a", count: 32), valid: true),
    SSIDCase(label: "33 ASCII bytes", name: String(repeating: "a", count: 33), valid: false),
    SSIDCase(label: "a name with U+00EB and U+2019", name: zoe, valid: true),
    SSIDCase(label: "ten U+2019 (30 bytes)", name: String(repeating: apostrophe, count: 10), valid: true),
    SSIDCase(label: "eleven U+2019 (33 bytes)", name: String(repeating: apostrophe, count: 11), valid: false),
    SSIDCase(label: "NUL", name: "Test" + text(0x00) + "iPhone", valid: false),
    SSIDCase(label: "line feed", name: "Test" + text(0x0A) + "iPhone", valid: false),
    SSIDCase(label: "U+001F", name: "Test" + text(0x1F) + "iPhone", valid: false),
    SSIDCase(label: "U+007F", name: "Test" + text(0x7F) + "iPhone", valid: false),
    SSIDCase(label: "U+0085", name: "Test" + text(0x85) + "iPhone", valid: false),
    SSIDCase(label: "U+009F", name: "Test" + text(0x9F) + "iPhone", valid: false),
    SSIDCase(label: "U+00A0", name: "Test" + text(0xA0) + "iPhone", valid: true),
    SSIDCase(label: "a leading hyphen", name: "-Test iPhone", valid: true),
  ]

  static let invalidNames = all.filter { !$0.valid && !$0.name.isEmpty }
}

@Suite("Hotspot name rule")
struct HotspotNameRuleTests {
  @Test(arguments: SSIDCase.all)
  func anSSIDIsOneTo32BytesWithNoControlCharacter(_ example: SSIDCase) {
    #expect(Settings.isValidSSID(example.name) == example.valid)
  }

  @Test func theRuleUsesThe32ByteLimit() {
    #expect(Settings.maxSSIDBytes == 32)
  }

  static let distinctive = String(repeating: "Zo" + SSIDCase.text(0xEB), count: 40)

  @Test func anInvalidHotspotIsClearedAndRecordedWithoutItsName() {
    let validation = Settings(hotspot: Self.distinctive).validated()
    #expect(validation.settings.hotspot == "")
    #expect(validation.adjustments == [SettingsAdjustment(key: "hotspot", from: "invalid", to: "")])
    let values = validation.adjustments.flatMap { $0.decision.fields.map(\.value) }
    #expect(values == ["hotspot", "invalid", ""])
    #expect(values.allSatisfy { !$0.contains("Zo") && !$0.contains(SSIDCase.text(0xEB)) })
  }

  @Test(arguments: SSIDCase.invalidNames)
  func everyInvalidNameIsClearedTheSameWay(_ example: SSIDCase) {
    let validation = Settings(hotspot: example.name).validated()
    #expect(validation.settings.hotspot == "")
    #expect(validation.adjustments == [SettingsAdjustment(key: "hotspot", from: "invalid", to: "")])
  }

  @Test func aValidOrEmptyHotspotIsLeftAlone() {
    for name in ["", "Test iPhone", SSIDCase.zoe] {
      let validation = Settings(hotspot: name).validated()
      #expect(validation.settings.hotspot == name)
      #expect(validation.adjustments.isEmpty)
    }
  }

  @Test func autoDetectIsNeverChangedByTheRule() {
    for autoDetect in [false, true] {
      let validation = Settings(hotspot: Self.distinctive, hotspotAutoDetect: autoDetect).validated()
      #expect(validation.settings.hotspotAutoDetect == autoDetect)
      #expect(validation.settings.hotspot == "")
    }
  }

  @Test func settingsDecodedWithAnInvalidHotspotValidateToEmpty() throws {
    let bad = "Test" + SSIDCase.text(0x07) + "iPhone"
    let data = try JSONEncoder().encode(["hotspot": bad])
    let decoded = try JSONDecoder().decode(Settings.self, from: data)
    #expect(decoded.hotspot == bad)
    let validation = decoded.validated()
    #expect(validation.settings.hotspot == "")
    #expect(validation.adjustments == [SettingsAdjustment(key: "hotspot", from: "invalid", to: "")])
  }
}
