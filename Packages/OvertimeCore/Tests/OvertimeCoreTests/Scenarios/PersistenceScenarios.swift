import Foundation
import Testing

@testable import OvertimeCore

@Suite("Persistence scenarios #16-#17")
struct PersistenceScenarios {
  static let garbage = #"{"ownsHold": true, "switchedToHotspot": "x", "evil": "$(touch /tmp/pwned)"}"#

  @Test("#16 loads valid values and ignores garbage")
  func scenario16LoadsValidValuesAndIgnoresGarbage() {
    guard case .state(let state) = StateCodec.decode(Data(Self.garbage.utf8)) else {
      Issue.record("scenario 16 did not decode to a state")
      return
    }
    #expect(state.ownsHold == true)
    #expect(state.switchedToHotspot == false)
    #expect(state == PersistedState(ownsHold: true))
  }

  @Test("#17 save and load round trip")
  func scenario17SaveAndLoadRoundTrip() {
    let state = PersistedState(
      version: 1,
      bootSessionUUID: "11111111-2222-3333-4444-555555555555",
      ownsHold: true,
      sentinelArmed: true,
      switchedToHotspot: true,
      pause: PersistedPause(
        kind: PersistedPause.timed, monoDeadlineNanoseconds: 229_171_670_000_000,
        wallDeadline: Date(timeIntervalSince1970: 1_800_000_000)),
      releaseUntilIdle: true,
      forceActive: true
    )
    #expect((try? StateCodec.encode(state)).map(StateCodec.decode) == .state(state))
  }
}

@Suite("State codec leniency")
struct StateCodecLeniencyTests {
  @Test(arguments: [
    "[1,2]", "\"text\"", "42", "{\"ownsHold\": tr", "", "\u{00}\u{01}\u{02}garbage",
  ])
  func nonObjectsAndTruncatedFilesAreCorrupt(_ text: String) {
    #expect(StateCodec.decode(Data(text.utf8)) == .corrupt)
  }

  @Test func wrongTypesFallBackToEachFieldsDefault() {
    let text = """
      {"version": "one", "bootSessionUUID": 7, "ownsHold": false, "sentinelArmed": "true",
       "releaseUntilIdle": null, "forceActive": [true], "pause": {"kind": "forever"}}
      """
    #expect(StateCodec.decode(Data(text.utf8)) == .state(PersistedState()))
  }

  @Test(arguments: [
    "{}", #"{"ownsHold": 1}"#, #"{"ownsHold": "true"}"#, #"{"ownsHold": null}"#, #"{"ownsHold": [true]}"#,
    #"{"sentinelArmed": true}"#,
  ])
  func aMissingOrMistypedOwnsHoldIsCorruptAndClears(_ text: String) {
    let snapshot = StateCodec.decode(Data(text.utf8))
    #expect(snapshot == .corrupt)
    #expect(LidCloseHold.launchAction(LaunchFacts(persisted: snapshot, bootSessionUUID: "boot")) == .clearIfUnwanted)
  }

  @Test func ownershipDisagreeingWithTheArmedSentinelIsAmbiguousAndClears() {
    let text = #"{"ownsHold": false, "sentinelArmed": true, "bootSessionUUID": "boot"}"#
    let snapshot = StateCodec.decode(Data(text.utf8))
    #expect(LidCloseHold.launchAction(LaunchFacts(persisted: snapshot, bootSessionUUID: "boot")) == .clearIfUnwanted)
  }

  @Test func encodedStatesAlwaysCarryOwnershipSoTheyNeverDecodeAsAmbiguous() throws {
    let data = try StateCodec.encode(PersistedState())
    #expect(String(decoding: data, as: UTF8.self).contains(#""ownsHold":false"#))
    #expect(StateCodec.decode(data) == .state(PersistedState()))
  }

  @Test func aPauseMissingTheDeadlineItsKindNeedsIsDropped() {
    let timed = #"{"ownsHold": false, "pause": {"kind": "timed", "monoDeadlineNanoseconds": 5}}"#
    let until = #"{"ownsHold": false, "pause": {"kind": "until"}}"#
    let negative =
      #"{"ownsHold": false, "pause": {"kind": "timed", "monoDeadlineNanoseconds": -5, "wallDeadline": "2027-01-15T08:00:00Z"}}"#
    for text in [timed, until, negative] {
      #expect(StateCodec.decode(Data(text.utf8)) == .state(PersistedState()), "\(text)")
    }
    let valid = #"{"ownsHold": false, "pause": {"kind": "until", "wallDeadline": "2027-01-15T08:00:00Z"}}"#
    #expect(
      StateCodec.decode(Data(valid.utf8))
        == .state(
          PersistedState(
            pause: PersistedPause(kind: PersistedPause.until, wallDeadline: Date(timeIntervalSince1970: 1_800_000_000)))
        ))
  }

  @Test func anOverlongBootSessionIsIgnored() {
    let text = "{\"ownsHold\": false, \"bootSessionUUID\": \"" + String(repeating: "a", count: 300) + "\"}"
    #expect(StateCodec.decode(Data(text.utf8)) == .state(PersistedState()))
  }
}
