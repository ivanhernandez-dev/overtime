import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import Testing

struct NetworkStatusLineTests {
  static let candidate = ["Zo", "\u{EB}", "\u{2019}", "s iPhone"].joined()

  static func summary(
    switched: Bool = false, onHotspot: Bool? = nil, readiness: NetReadiness?
  ) -> NetworkSummary {
    NetworkSummary(
      wired: false, wifiFound: true, onHotspot: onHotspot ?? switched, switched: switched, readiness: readiness,
      phase: .idle)
  }

  @Test(arguments: [nil, false, true] as [Bool?])
  func noSummaryReadsFailoverOff(_ lidClosed: Bool?) {
    let line = StatusLines.network(nil, lidClosed: lidClosed)
    #expect(line.value == "Failover off")
    #expect(line.detail == nil)
  }

  @Test func aSwitchWithTheLidClosedOnTheHotspotReadsOnTheHotspotWithTheReturnDetail() {
    let line = StatusLines.network(Self.summary(switched: true, readiness: .armed(.configured)), lidClosed: true)
    #expect(line.value == "On your iPhone hotspot")
    #expect(line.detail == "Returns to your usual network when you open the lid.")
  }

  @Test(arguments: [true, false, nil] as [Bool?])
  func aSwitchWithTheLidOpenReadsReturningUntilTheReturnCompletes(_ onHotspot: Bool?) {
    var summary = Self.summary(switched: true, readiness: .armed(.configured))
    summary.onHotspot = onHotspot
    let line = StatusLines.network(summary, lidClosed: false)
    #expect(line.value == "Returning to your usual network…")
    #expect(line.detail == nil)
    #expect(line.value == StatusLines.returning)
  }

  static let stillOffAndOn: [(Bool?, ReturnStop)] = [
    (true, .adminRequired), (nil, .adminRequired), (true, .powerUnknown), (nil, .powerUnknown),
  ]

  @Test(arguments: stillOffAndOn)
  func aReturnStoppedBeforeACycleRanReadsStillOnTheHotspotWithWhatToDo(_ onHotspot: Bool?, _ stop: ReturnStop) {
    var summary = Self.summary(switched: true, readiness: .armed(.configured))
    summary.onHotspot = onHotspot
    summary.returnStop = stop
    let line = StatusLines.network(summary, lidClosed: false)
    #expect(line.value == "Still on your iPhone hotspot")
    #expect(line.detail == "Turn Wi-Fi off and on to return to your usual network.")
    #expect(line.value == StatusLines.stillOnHotspot)
    #expect(line.detail == StatusLines.stillOnHotspotDetail)
  }

  @Test(arguments: [true, nil] as [Bool?])
  func aReturnThatMacOSUndidReadsStillOnTheHotspotAndPointsToTheWiFiMenu(_ onHotspot: Bool?) {
    var summary = Self.summary(switched: true, readiness: .armed(.configured))
    summary.onHotspot = onHotspot
    summary.returnStop = .backOnHotspot
    let line = StatusLines.network(summary, lidClosed: false)
    #expect(line.value == "Still on your iPhone hotspot")
    #expect(line.detail == "macOS rejoined it. Choose your usual network in the Wi-Fi menu.")
    #expect(line.detail == StatusLines.rejoinedHotspotDetail)
    let row = StatusLines.rows(for: EngineSnapshot(lidClosed: false, network: summary)).last
    #expect(
      row?.accessibilityText
        == "Network, still on your iPhone hotspot. macOS rejoined it. Choose your usual network in the Wi-Fi menu.")
  }

  @Test(arguments: [ReturnStop.adminRequired, .powerUnknown, .backOnHotspot])
  func aStoppedReturnReadsTheHotspotDetailOnceTheLidClosesAgain(_ stop: ReturnStop) {
    var summary = Self.summary(switched: true, readiness: .armed(.configured))
    summary.returnStop = stop
    #expect(StatusLines.network(summary, lidClosed: true) == (StatusLines.onHotspot, StatusLines.onHotspotDetail))
  }

  @Test func theStoppedReturnRowIsSpokenWithItsDetail() {
    var summary = Self.summary(switched: true, readiness: .armed(.auto))
    summary.returnStop = .adminRequired
    let row = StatusLines.rows(for: EngineSnapshot(lidClosed: false, network: summary)).last
    #expect(row?.value == "Still on your iPhone hotspot")
    #expect(
      row?.accessibilityText
        == "Network, still on your iPhone hotspot. Turn Wi-Fi off and on to return to your usual network.")
  }

  @Test func theSummaryCarriesTheStopReasonOnlyOnceTheReturnStopped() {
    var state = AppState(mode: .live)
    state.persisted.switchedToHotspot = true
    state.network.facts = NetworkFacts(wifiInterface: "en0", onHotspot: true, wired: false, wifiPowered: true)
    let cycles: [(ReturnCycle, ReturnStop?)] = [
      (.idle, nil), (.inFlight, nil), (.retryAt(Instant(nanoseconds: 9)), nil), (.done, nil),
      (.stopped(.adminRequired), .adminRequired), (.stopped(.powerUnknown), .powerUnknown),
      (.stopped(.backOnHotspot), .backOnHotspot),
    ]
    for (cycle, stop) in cycles {
      state.network.returnCycle = cycle
      let summary = NetworkSummary.summary(state: state, settings: Settings())
      #expect(summary?.returnStop == stop)
      #expect(summary?.returnStalled == (stop != nil))
    }
  }

  static let switchedReadiness: [NetReadiness?] = [
    .armed(.auto), .armed(.configured), .off(.wired), .off(.noHotspot), nil,
  ]

  @Test(arguments: [true, nil] as [Bool?], switchedReadiness)
  func aSwitchWithTheLidClosedOrUnknownNeverFallsBackToTheReadiness(_ lidClosed: Bool?, _ readiness: NetReadiness?) {
    var summary = Self.summary(switched: true, readiness: readiness)
    for onHotspot in [true, nil] as [Bool?] {
      summary.onHotspot = onHotspot
      let line = StatusLines.network(summary, lidClosed: lidClosed)
      #expect(line.value == "On your iPhone hotspot")
      #expect(line.detail == "Returns to your usual network when you open the lid.")
    }
    summary.onHotspot = false
    let off = StatusLines.network(summary, lidClosed: lidClosed)
    #expect(off.value == "Switching networks…")
    #expect(off.detail == nil)
    #expect(off.value == StatusLines.switchingNetworks)
    for onHotspot in [true, false, nil] as [Bool?] {
      summary.onHotspot = onHotspot
      let value = StatusLines.network(summary, lidClosed: lidClosed).value
      #expect(value != "Failover on")
      #expect(value != "Failover off")
    }
  }

  @Test func theNetworkGlyphShowsTheHotspotWhileTheValueSaysTheMacIsOnIt() {
    #expect(StatusLines.hotspotIcon == "personalhotspot")
    #expect(StatusLines.wifiIcon == "wifi")
    func icon(_ summary: NetworkSummary?, lidClosed: Bool?) -> String? {
      StatusLines.rows(for: EngineSnapshot(lidClosed: lidClosed, network: summary)).last?.icon
    }
    var switched = Self.summary(switched: true, onHotspot: true, readiness: .armed(.auto))
    #expect(icon(switched, lidClosed: true) == "personalhotspot")
    switched.returnStop = .adminRequired
    #expect(icon(switched, lidClosed: false) == "personalhotspot")
    switched.returnStop = .backOnHotspot
    #expect(icon(switched, lidClosed: false) == "personalhotspot")
    switched.returnStop = nil
    #expect(icon(switched, lidClosed: false) == "wifi")
    switched.onHotspot = false
    #expect(icon(switched, lidClosed: true) == "wifi")
    #expect(icon(Self.summary(readiness: .armed(.auto)), lidClosed: true) == "wifi")
    #expect(icon(Self.summary(readiness: .off(.wifiOff)), lidClosed: true) == "wifi")
    #expect(StatusLines.rows(for: nil).last?.icon == "wifi")
  }

  @Test func noNetworkRowSpeaksALowercasedIPhone() {
    var summary = Self.summary(switched: true, onHotspot: true, readiness: .armed(.auto))
    var rows = [StatusLines.rows(for: EngineSnapshot(lidClosed: true, network: summary)).last]
    summary.returnStop = .adminRequired
    rows.append(StatusLines.rows(for: EngineSnapshot(lidClosed: false, network: summary)).last)
    summary.returnStop = .backOnHotspot
    rows.append(StatusLines.rows(for: EngineSnapshot(lidClosed: false, network: summary)).last)
    for row in rows {
      let spoken = row?.accessibilityText ?? ""
      #expect(spoken.contains("iPhone"))
      #expect(!spoken.contains("iphone"))
    }
  }

  @Test(arguments: [true, false] as [Bool])
  func aHotspotOvertimeDidNotSwitchToReadsTheReadiness(_ lidClosed: Bool) {
    let summary = Self.summary(switched: false, onHotspot: true, readiness: .off(.noHotspot))
    #expect(StatusLines.network(summary, lidClosed: lidClosed) == ("Failover off", nil))
  }

  @Test(arguments: [HotspotSource.configured, .auto])
  func anArmedFailoverReadsOn(_ source: HotspotSource) {
    let line = StatusLines.network(Self.summary(readiness: .armed(source)), lidClosed: true)
    #expect(line.value == "Failover on")
    #expect(line.detail == nil)
  }

  @Test(arguments: NetOffReason.allCases)
  func everyOffReasonReadsOff(_ reason: NetOffReason) {
    let line = StatusLines.network(Self.summary(readiness: .off(reason)), lidClosed: true)
    #expect(line.value == "Failover off")
    #expect((line.detail == nil) == (reason == .noHotspot || reason == .noWifi))
  }

  static let actionableReasons: [(NetOffReason, String)] = [
    (.wifiOff, "Wi-Fi is off. Failover resumes when it's back on."),
    (.wired, "The Mac has a wired connection."),
  ]

  @Test(arguments: actionableReasons)
  func anOffReasonTheUserCanActOnGetsItsDetail(_ reason: NetOffReason, _ detail: String) {
    let summary = Self.summary(readiness: .off(reason))
    for lidClosed in [true, false, nil] as [Bool?] {
      let line = StatusLines.network(summary, lidClosed: lidClosed)
      #expect(line.value == "Failover off")
      #expect(line.detail == detail)
      let row = StatusLines.rows(for: EngineSnapshot(lidClosed: lidClosed, network: summary)).last
      #expect(row?.accessibilityText == "Network, failover off. \(detail)")
    }
  }

  @Test func noHotspotGetsItsDetailOnlyWhenAutoDetectIsChosen() {
    var summary = Self.summary(readiness: .off(.noHotspot))
    let none = StatusLines.network(summary, lidClosed: true)
    #expect(none.value == "Failover off")
    #expect(none.detail == nil)
    summary.autoDetect = true
    let auto = StatusLines.network(summary, lidClosed: true)
    #expect(auto.value == "Failover off")
    #expect(auto.detail == "Overtime can't find an iPhone hotspot among your known networks.")
  }

  @Test(arguments: [false, true])
  func aMissingWiFiInterfaceReadsOffWithoutADetail(_ autoDetect: Bool) {
    var summary = Self.summary(readiness: .off(.noWifi))
    summary.autoDetect = autoDetect
    let line = StatusLines.network(summary, lidClosed: true)
    #expect(line.value == "Failover off")
    #expect(line.detail == nil)
  }

  @Test func theSummaryCarriesTheAutoDetectChoiceAsABoolean() throws {
    var state = AppState(mode: .live)
    state.network.facts = NetworkFacts(wifiInterface: "en0", onHotspot: false, wired: false, wifiPowered: true)
    let none = try #require(NetworkSummary.summary(state: state, settings: Settings()))
    #expect(none.autoDetect == false)
    #expect(none.readiness == .off(.noHotspot))
    let auto = try #require(NetworkSummary.summary(state: state, settings: Settings(hotspotAutoDetect: true)))
    #expect(auto.autoDetect == true)
    #expect(auto.readiness == .off(.noHotspot))
    #expect(StatusLines.network(auto, lidClosed: true).detail == StatusLines.noHotspotDetail)
    let named = try #require(
      NetworkSummary.summary(state: state, settings: Settings(hotspot: "Test iPhone", hotspotAutoDetect: true)))
    #expect(named.autoDetect == false)
    #expect(named.readiness == .armed(.configured))
  }

  @Test func aSummaryWithoutReadinessReadsOff() {
    let line = StatusLines.network(Self.summary(readiness: nil), lidClosed: true)
    #expect(line.value == "Failover off")
    #expect(line.detail == nil)
  }

  @Test func aSwitchWinsOverAWiredOff() {
    let line = StatusLines.network(Self.summary(switched: true, readiness: .off(.wired)), lidClosed: true)
    #expect(line.value == "On your iPhone hotspot")
    #expect(line.detail == "Returns to your usual network when you open the lid.")
  }

  @Test func theRowReadsTheLidFromTheSnapshot() {
    let summary = Self.summary(switched: true, readiness: .armed(.auto))
    let open = StatusLines.rows(for: EngineSnapshot(lidClosed: false, network: summary)).last
    #expect(open?.value == "Returning to your usual network…")
    #expect(open?.detail == nil)
    #expect(open?.accessibilityText == "Network, returning to your usual network…")
    let unknown = StatusLines.rows(for: EngineSnapshot(network: summary)).last
    #expect(unknown?.value == "On your iPhone hotspot")
  }

  @Test func theRowReadsTheDetailAfterTheValue() {
    let snapshot = EngineSnapshot(lidClosed: true, network: Self.summary(switched: true, readiness: .armed(.auto)))
    let row = StatusLines.rows(for: snapshot).last
    #expect(row?.label == "Network")
    #expect(row?.value == "On your iPhone hotspot")
    #expect(row?.detail == "Returns to your usual network when you open the lid.")
    #expect(
      row?.accessibilityText == "Network, on your iPhone hotspot. Returns to your usual network when you open the lid.")
  }

  @Test func aRowWithoutDetailReadsAsBefore() {
    let row = StatusLines.rows(for: EngineSnapshot(network: Self.summary(readiness: .armed(.auto)))).last
    #expect(row?.detail == nil)
    #expect(row?.accessibilityText == "Network, failover on")
  }

  @Test func noFactsAndNoSwitchGiveNoSummary() {
    #expect(NetworkSummary.summary(state: AppState(mode: .live), settings: Settings()) == nil)
  }

  @Test func aSwitchWithoutFactsStillGivesASummary() {
    var state = AppState(mode: .live)
    state.persisted.switchedToHotspot = true
    let summary = NetworkSummary.summary(state: state, settings: Settings())
    #expect(summary == NetworkSummary(switched: true))
    #expect(StatusLines.network(summary, lidClosed: false).value == "Returning to your usual network…")
    #expect(StatusLines.network(summary, lidClosed: true).value == "On your iPhone hotspot")
  }

  @Test func theSummaryCopiesTheFactsAsBooleansAndThePhase() {
    var state = AppState(mode: .live)
    state.network.facts = NetworkFacts(wifiInterface: "en0", onHotspot: false, wired: true, wifiPowered: true)
    state.network.phase = .joining(until: Instant(nanoseconds: 9))
    let summary = NetworkSummary.summary(state: state, settings: Settings(hotspot: "Test iPhone"))
    #expect(
      summary
        == NetworkSummary(
          wired: true, wifiFound: true, onHotspot: false, switched: false, readiness: .off(.wired), phase: .joining))
    state.network.phase = .waitingAfterCycle(until: Instant(nanoseconds: 9))
    #expect(NetworkSummary.summary(state: state, settings: Settings())?.phase == .waitingAfterCycle)
    state.network.facts = NetworkFacts()
    #expect(NetworkSummary.summary(state: state, settings: Settings())?.wifiFound == false)
  }

  @Test func anAutoCandidateArmsTheSummaryWithoutItsName() throws {
    var state = AppState(mode: .live)
    state.network.facts = NetworkFacts(
      wifiInterface: "en0", onHotspot: false, wired: false, wifiPowered: true, autoHotspot: Self.candidate)
    let summary = NetworkSummary.summary(state: state, settings: Settings(hotspotAutoDetect: true))
    #expect(summary?.readiness == .armed(.auto))
    let stored = Mirror(reflecting: try #require(summary)).children.map(\.value)
    #expect(stored.count == 8)
    #expect(!stored.contains { $0 is String })
    let described = String(reflecting: summary)
    #expect(!described.contains(Self.candidate))
    #expect(!described.contains(["Zo", "\u{EB}"].joined()))
    #expect(!described.contains("iPhone"))
  }
}
