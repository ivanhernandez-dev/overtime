import Foundation
import OvertimeAppSupport
import OvertimeCore
import Testing

struct HotspotChoiceTests {
  static let phone = "Ivan’s iPhone"
  static let known = ["gamma", "Ivan’s iPhone", "alpha", "Beta"]

  @Test func anEmptyHotspotWithAutoDetectOffIsNone() {
    let choice = HotspotChoice(settings: Settings(hotspot: "", hotspotAutoDetect: false), knownNetworks: Self.known)
    #expect(choice == .none)
    #expect(choice.label == "None")
    #expect(choice.isNone)
  }

  @Test func anEmptyHotspotWithAutoDetectOnIsAutoDetect() {
    let choice = HotspotChoice(settings: Settings(hotspot: "", hotspotAutoDetect: true), knownNetworks: Self.known)
    #expect(choice == .autoDetect)
    #expect(choice.label == "Auto-detect iPhone hotspot")
    #expect(!choice.isNone)
  }

  @Test func aKnownStoredNameIsNamed() {
    let choice = HotspotChoice(settings: Settings(hotspot: Self.phone), knownNetworks: Self.known)
    #expect(choice == .named(Self.phone))
    #expect(choice.label == "Ivan’s iPhone")
  }

  @Test func aStoredNameNoLongerKnownIsUnknownWithItsLabel() {
    let choice = HotspotChoice(settings: Settings(hotspot: Self.phone), knownNetworks: ["alpha"])
    #expect(choice == .unknown(Self.phone))
    #expect(choice.label == "Ivan’s iPhone (not in known networks)")
  }

  @Test func aStoredNameWithUnreadableNetworksIsNotClaimedUnknown() {
    let choice = HotspotChoice(settings: Settings(hotspot: Self.phone), knownNetworks: nil)
    #expect(choice == .named(Self.phone))
  }

  @Test func aHandEditedFileWithANameAndAutoDetectIsTheNamedNetwork() {
    let choice = HotspotChoice(
      settings: Settings(hotspot: Self.phone, hotspotAutoDetect: true), knownNetworks: Self.known)
    #expect(choice == .named(Self.phone))
    let applied = choice.apply(to: Settings(hotspot: Self.phone, hotspotAutoDetect: true))
    #expect(applied.hotspot == Self.phone)
    #expect(applied.hotspotAutoDetect == false)
  }

  @Test func applyingAutoDetectStoresAnEmptyHotspotAndTheFlag() {
    let applied = HotspotChoice.autoDetect.apply(to: Settings(hotspot: Self.phone))
    #expect(applied.hotspot == "")
    #expect(applied.hotspotAutoDetect == true)
  }

  @Test func applyingNoneClearsBoth() {
    let applied = HotspotChoice.none.apply(to: Settings(hotspot: Self.phone, hotspotAutoDetect: true))
    #expect(applied.hotspot == "")
    #expect(applied.hotspotAutoDetect == false)
  }

  @Test func applyingANamedOrUnknownNetworkStoresThatSSIDOnly() {
    for choice in [HotspotChoice.named(Self.phone), .unknown(Self.phone)] {
      let applied = choice.apply(to: Settings(hotspotAutoDetect: true))
      #expect(applied.hotspot == Self.phone)
      #expect(applied.hotspotAutoDetect == false)
    }
  }

  @Test func applyingKeepsEveryOtherSetting() {
    let base = Settings(
      batteryLowPercent: 15, batteryResumePercent: 30, transcriptWindowSeconds: 90, releaseGraceSeconds: 20,
      stuckWindowSeconds: 600, transcriptRoots: ["/a"], ignoredEntrypoints: ["x"], keepDisplayOn: true)
    var expected = base
    expected.hotspotAutoDetect = true
    #expect(HotspotChoice.autoDetect.apply(to: base) == expected)
  }

  @Test(arguments: [
    HotspotChoice.none, .autoDetect, .named("Ivan’s iPhone"), .unknown("Old phone"),
  ])
  func everyChoiceRoundTripsThroughSettingsAndThePicker(_ choice: HotspotChoice) throws {
    let known = Self.known
    let applied = choice.apply(to: Settings())
    #expect(applied.validated().adjustments.isEmpty)
    let data = try JSONEncoder().encode(applied)
    let reloaded = try JSONDecoder().decode(Settings.self, from: data)
    let restored = HotspotChoice(settings: reloaded, knownNetworks: known)
    #expect(restored == choice)
    #expect(HotspotPicker.entries(knownNetworks: known, stored: restored).contains(.choice(restored)))
    if let name = restored.networkName {
      #expect(reloaded.hotspot == name)
    } else {
      #expect(reloaded.hotspot.isEmpty)
    }
  }

  @Test func autoDetectNeverWritesANonSSIDIntoHotspot() {
    for start in [Settings(), Settings(hotspot: Self.phone), Settings(hotspotAutoDetect: true)] {
      let applied = HotspotChoice.autoDetect.apply(to: start)
      #expect(applied.hotspot.isEmpty)
      #expect(!applied.hotspot.contains(StartupChecks.autodetectMarker))
    }
  }

  @Test func theEntriesAreNoneAutoDetectADividerThenKnownNamesCaseInsensitively() {
    let entries = HotspotPicker.entries(knownNetworks: ["gamma", "Beta", "alpha"], stored: .none)
    #expect(
      entries == [
        .choice(.none), .choice(.autoDetect), .divider, .choice(.named("alpha")), .choice(.named("Beta")),
        .choice(.named("gamma")),
      ])
    #expect(HotspotPicker.caption(knownNetworks: ["gamma", "Beta", "alpha"]) == nil)
  }

  @Test func unreadableKnownNetworksGiveOnlyTheFirstTwoEntriesAndTheCaption() {
    #expect(HotspotPicker.entries(knownNetworks: nil, stored: .none) == [.choice(.none), .choice(.autoDetect)])
    #expect(HotspotPicker.entries(knownNetworks: nil, stored: .autoDetect) == [.choice(.none), .choice(.autoDetect)])
    #expect(HotspotPicker.caption(knownNetworks: nil) == "Couldn't read your known Wi-Fi networks.")
  }

  @Test func anEmptyKnownListGivesTheFirstTwoEntriesWithoutACaption() {
    #expect(HotspotPicker.entries(knownNetworks: [], stored: .none) == [.choice(.none), .choice(.autoDetect)])
    #expect(HotspotPicker.caption(knownNetworks: []) == nil)
  }

  @Test func aStoredNameStaysSelectableWhenTheNetworksAreUnreadable() {
    #expect(
      HotspotPicker.entries(knownNetworks: nil, stored: .named(Self.phone)) == [
        .choice(.none), .choice(.autoDetect), .divider, .choice(.named(Self.phone)),
      ])
  }

  @Test func anUnknownStoredNameStaysSelectableAfterTheKnownNetworks() {
    #expect(
      HotspotPicker.entries(knownNetworks: ["alpha"], stored: .unknown(Self.phone)) == [
        .choice(.none), .choice(.autoDetect), .divider, .choice(.named("alpha")), .choice(.unknown(Self.phone)),
      ])
  }

  @Test func emptyAndDuplicateNetworkNamesAreDropped() {
    #expect(
      HotspotPicker.entries(knownNetworks: ["", "alpha", "alpha"], stored: .none) == [
        .choice(.none), .choice(.autoDetect), .divider, .choice(.named("alpha")),
      ])
  }

  @Test func namesThatDifferOnlyInCaseKeepAStableOrder() {
    #expect(HotspotPicker.sortedNames(["b", "B", "a"]) == ["a", "B", "b"])
  }

  @Test func theCopyMatchesTheUISpec() {
    #expect(HotspotChoice.pickerLabel == "iPhone hotspot")
    #expect(HotspotChoice.noneLabel == "None")
    #expect(HotspotChoice.autoDetectLabel == "Auto-detect iPhone hotspot")
    #expect(
      HotspotPicker.sectionCaption
        == "If the network stops working while the lid is closed and Claude is working, Overtime switches the Mac to this hotspot, and back to your usual network when you open the lid."
    )
  }
}
