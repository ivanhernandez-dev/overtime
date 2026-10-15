import Foundation
import OvertimeCore
import OvertimeSystem
import Testing

struct WiFiEvilTwinTests {
  static let hotspot = WiFiControllerJoinTests.hotspot
  static let wpa2Personal = 4
  static let wpa3Personal = 12
  static let open = 0
  static let owe = 14
  static let oweTransition = 15

  struct Scanned: Sendable, Equatable {
    var ssid: String?
    var securities: Set<Int>
    var rssi: Int
  }

  static func choose(_ networks: [Scanned], saved: Int = wpa2Personal) -> CoreWLANRadio.ScanChoice<Scanned> {
    CoreWLANRadio.scanChoice(
      networks, ssid: hotspot, saved: saved, ssidOf: \.ssid, supports: { $0.securities.contains($1) },
      rssi: \.rssi)
  }

  static func isInsecureOnly(_ choice: CoreWLANRadio.ScanChoice<Scanned>) -> Bool {
    if case .insecureOnly = choice { return true }
    return false
  }

  static func matched(_ choice: CoreWLANRadio.ScanChoice<Scanned>) -> Scanned? {
    if case .match(let network) = choice { return network }
    return nil
  }

  @Test func withLocationAScanThatSawOnlyInsecureTwinsRefusesAndNeverFallsBackToTheTool() async {
    let fixture = WiFiControllerJoinTests.Fixture(
      FakeWiFiRadio.Script(joinResult: .failure(.insecureOnly)), location: true)
    #expect(await fixture.join(Self.hotspot) == WiFiController.Code.insecureProfile.outcome)
    #expect(fixture.radio.calls.contains(.joinSaved(interface: "en0", ssid: Self.hotspot)))
    #expect(fixture.toolCalls.isEmpty)
  }

  @Test func aScanThatFoundNoSameNameNetworkStillFallsBackToTheTool() async {
    let fixture = WiFiControllerJoinTests.Fixture(
      FakeWiFiRadio.Script(joinResult: .failure(.notFound)), location: true)
    #expect(await fixture.join(Self.hotspot) == .succeeded)
    #expect(fixture.toolCalls == [WiFiControllerJoinTests.joinCall("en0", Self.hotspot)])
  }

  @Test(arguments: [open, owe, oweTransition, Int.max])
  func onlyInsecureSameNameNetworksInTheScanMeanInsecureOnly(_ security: Int) {
    let twin = Scanned(ssid: Self.hotspot, securities: [security], rssi: -40)
    let other = Scanned(ssid: "Office", securities: [Self.wpa2Personal], rssi: -30)
    #expect(Self.isInsecureOnly(Self.choose([twin, other])))
    let mixed = Scanned(ssid: Self.hotspot, securities: [Self.wpa2Personal, security], rssi: -45)
    #expect(Self.isInsecureOnly(Self.choose([twin, mixed])))
  }

  @Test func aSecureSameNameNetworkIsChosenOverAStrongerInsecureTwin() {
    let twin = Scanned(ssid: Self.hotspot, securities: [Self.open], rssi: -30)
    let real = Scanned(ssid: Self.hotspot, securities: [Self.wpa2Personal], rssi: -60)
    let weaker = Scanned(ssid: Self.hotspot, securities: [Self.wpa2Personal], rssi: -70)
    #expect(Self.matched(Self.choose([twin, weaker, real])) == real)
  }

  @Test func noSameNameNetworkOrOnlySecureOnesOfAnotherKindAreNotInsecureOnly() {
    #expect(Self.matched(Self.choose([])) == nil)
    #expect(!Self.isInsecureOnly(Self.choose([])))
    let other = Scanned(ssid: "Office", securities: [Self.open], rssi: -30)
    #expect(!Self.isInsecureOnly(Self.choose([other])))
    let wpa3 = Scanned(ssid: Self.hotspot, securities: [Self.wpa3Personal], rssi: -50)
    #expect(!Self.isInsecureOnly(Self.choose([wpa3])))
    #expect(Self.matched(Self.choose([wpa3])) == nil)
  }

  @Test func aNameSavedTwiceIsRefusedWhenEitherProfileIsInsecure() {
    #expect(CoreWLANRadio.savedProfileSecurity([]) == .absent)
    #expect(CoreWLANRadio.savedProfileSecurity([Self.wpa2Personal]) == .security(rawValue: Self.wpa2Personal))
    for insecure in [Self.open, Self.owe, Self.oweTransition, Int.max] {
      for order in [[Self.wpa2Personal, insecure], [insecure, Self.wpa2Personal]] {
        #expect(!CoreWLANRadio.acceptsSaved(CoreWLANRadio.savedProfileSecurity(order)), "\(order)")
      }
    }
    #expect(CoreWLANRadio.acceptsSaved(CoreWLANRadio.savedProfileSecurity([Self.wpa2Personal, Self.wpa3Personal])))
  }
}
