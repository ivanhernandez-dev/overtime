import Foundation
import OvertimeAppSupport
import OvertimeCore
import Testing

struct LidClosedCopyTests {
  static let options = ["Always", "Only on power adapter", "Never"]
  static let captions = [
    "While Claude works, closing the lid doesn't put the Mac to sleep, on battery or on power.",
    "While Claude works on power, closing the lid doesn't put the Mac to sleep. On battery, and when you unplug the charger with the lid closed, the Mac sleeps as usual.",
    "Closing the lid puts the Mac to sleep as usual, even while Claude works. With the lid open, Overtime still keeps it from idle sleep.",
  ]
  static let onPowerAdapterNote =
    "In Settings > General, Keep awake with the lid closed is set to Only on power adapter, so unplugging the charger with the lid closed lets the Mac sleep. Unplug protection still keeps it awake when you connect or disconnect a display."
  static let neverNote =
    "In Settings > General, Keep awake with the lid closed is set to Never, so unplug protection isn't used. It stays installed until you remove it."

  @Test func theLidClosedCopyIsTheContractCopy() {
    #expect(LidClosedCopy.sectionTitle == "Lid")
    #expect(LidClosedCopy.label == "Keep awake with the lid closed")
    #expect(LidClosedKeepAwake.allCases == [.always, .onPowerAdapter, .never])
    #expect(LidClosedKeepAwake.allCases.map(LidClosedCopy.optionLabel) == Self.options)
    #expect(LidClosedKeepAwake.allCases.map(LidClosedCopy.caption) == Self.captions)
  }

  @Test func theSettingNoteFollowsTheLidClosedSetting() throws {
    #expect(LidClosedCopy.settingNote(.always) == nil)
    let onPowerAdapter = try #require(LidClosedCopy.settingNote(.onPowerAdapter))
    #expect(onPowerAdapter == Self.onPowerAdapterNote)
    let never = try #require(LidClosedCopy.settingNote(.never))
    #expect(never == Self.neverNote)
    for (value, note) in [(LidClosedKeepAwake.onPowerAdapter, onPowerAdapter), (.never, never)] {
      #expect(note.contains(LidClosedCopy.label))
      #expect(note.contains(LidClosedCopy.optionLabel(value)))
    }
  }
}
