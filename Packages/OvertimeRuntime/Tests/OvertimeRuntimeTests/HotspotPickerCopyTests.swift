import OvertimeAppSupport
import OvertimeCore
import Testing

struct HotspotPickerCopyTests {
  static let caption =
    "If the network stops working while the lid is closed and Claude is working, Overtime switches the Mac to this hotspot, and back to your usual network when you open the lid."
  static let locationMissing =
    "Location access is off. Failover still works, but with Location, Overtime can join the hotspot directly."
  static let notDetermined = "Location access lets Overtime join your iPhone hotspot directly."
  static let stalePhrases = ["later version", "will need", "is needed"]

  static let controlName = "Bell\u{0007}phone"
  static let tooLongName = String(repeating: "a", count: 33)
  static let longestName = String(repeating: "b", count: 32)
  static let invalidNames = [controlName, tooLongName, ""]

  @Test func thePickerCaptionDescribesWhatFailoverDoesNow() {
    #expect(HotspotPicker.sectionCaption == Self.caption)
  }

  @Test func theLocationMissingItemSaysFailoverWorksWithoutLocation() {
    #expect(AttentionItem.locationMissing.shortText == Self.locationMissing)
    #expect(AttentionItem.locationMissing.pane == .network)
  }

  @Test func theNotDeterminedLocationRowSaysWhatLocationAddsForTheHotspot() {
    #expect(LocationRow.notDeterminedTitle == Self.notDetermined)
    #expect(LocationRow.for(.notDetermined).title == Self.notDetermined)
    #expect(LocationRow.for(.notDetermined).action == .allowLocation)
  }

  @Test func noCopyPromisesFailoverLaterOrSaysLocationIsNeeded() {
    let texts =
      [
        HotspotPicker.sectionCaption, LocationRow.notDeterminedTitle, LocationRow.authorizedTitle,
        LocationRow.deniedTitle, LocationRow.caption,
      ] + AttentionItem.allCases.map(\.shortText)
    for text in texts {
      for phrase in Self.stalePhrases {
        #expect(!text.contains(phrase), "\(text)")
      }
    }
  }

  @Test func theInvalidNamesFailTheSSIDRuleAndTheLongestNameKeepsIt() {
    for name in Self.invalidNames {
      #expect(!Settings.isValidSSID(name))
    }
    #expect(Settings.isValidSSID(Self.longestName))
  }

  @Test func thePickerNeverOffersAKnownNameThatFailsTheSSIDRule() {
    let known = [
      "gamma", Self.controlName, "Zoë’s iPhone", Self.tooLongName, "alpha", "", Self.longestName,
    ]
    #expect(
      HotspotPicker.entries(knownNetworks: known, stored: .none) == [
        .choice(.none), .choice(.autoDetect), .divider, .choice(.named("alpha")), .choice(.named(Self.longestName)),
        .choice(.named("gamma")), .choice(.named("Zoë’s iPhone")),
      ])
    #expect(HotspotPicker.sortedNames(known) == ["alpha", Self.longestName, "gamma", "Zoë’s iPhone"])
  }

  @Test func onlyInvalidKnownNamesLeaveNoneAndAutoDetectWithoutADivider() {
    #expect(
      HotspotPicker.entries(knownNetworks: Self.invalidNames, stored: .none) == [
        .choice(.none), .choice(.autoDetect),
      ])
    #expect(
      HotspotPicker.entries(knownNetworks: Self.invalidNames, stored: .autoDetect) == [
        .choice(.none), .choice(.autoDetect),
      ])
  }
}
