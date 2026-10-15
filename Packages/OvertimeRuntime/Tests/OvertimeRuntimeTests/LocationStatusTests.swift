import Foundation
import OvertimeAppSupport
import Testing

struct LocationStatusTests {
  @Test func authorizedIsTheGreenRowWithNoAction() {
    let row = LocationRow.for(.authorized)
    #expect(row.symbol == "checkmark.circle.fill")
    #expect(row.tone == .success)
    #expect(row.title == "Location access is on.")
    #expect(row.action == nil)
    #expect(row.actionLabel == nil)
  }

  @Test func notDeterminedIsTheInfoRowWithAllowLocationAccess() {
    let row = LocationRow.for(.notDetermined)
    #expect(row.symbol == "info.circle")
    #expect(row.tone == .info)
    #expect(row.title == "Location access lets Overtime join your iPhone hotspot directly.")
    #expect(row.action == .allowLocation)
    #expect(row.actionLabel == "Allow Location Access")
  }

  @Test(arguments: [LocationAuthorization.denied, .restricted])
  func deniedAndRestrictedAreTheOrangeRowWithOpenLocationServices(_ status: LocationAuthorization) {
    let row = LocationRow.for(status)
    #expect(row.symbol == "exclamationmark.triangle.fill")
    #expect(row.tone == .warning)
    #expect(row.title == "Location access is off for Overtime.")
    #expect(row.action == .openLocationServices)
    #expect(row.actionLabel == "Open Location Services")
  }

  @Test(arguments: [
    LocationAuthorization.notDetermined, .denied, .restricted, .authorized,
  ])
  func theRowIsHiddenForNone(_ status: LocationAuthorization) {
    #expect(LocationRow.for(status, choice: .none) == nil)
  }

  @Test(arguments: [HotspotChoice.autoDetect, .named("Ivan’s iPhone"), .unknown("Old phone")])
  func theRowShowsForEveryOtherChoice(_ choice: HotspotChoice) {
    #expect(LocationRow.for(.denied, choice: choice) == LocationRow.for(.denied))
  }

  @Test func theCaptionMatchesTheUISpec() {
    #expect(LocationRow.caption == "Overtime never stores or sends your location.")
  }

  @Test func theSystemSettingsLinksArePinned() {
    #expect(
      SystemSettingsLinks.locationServices.absoluteString
        == "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")
    #expect(SystemSettingsLinks.wifi.absoluteString == "x-apple.systempreferences:com.apple.wifi-settings-extension")
    #expect(
      SystemSettingsLinks.notifications.absoluteString
        == "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
    #expect(
      SystemSettingsLinks.lockScreen.absoluteString
        == "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension")
  }
}
