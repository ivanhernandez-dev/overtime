import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import Testing

struct AttentionModelTests {
  struct Row: Sendable {
    let item: AttentionItem
    let text: String
    let pane: SettingsPane
    let inputs: AttentionInputs
  }

  static let rows: [Row] = [
    Row(
      item: .selfTestFailed, text: "The keep-awake self-test failed.", pane: .diagnostics,
      inputs: AttentionInputs(selfTestFailed: true)),
    Row(
      item: .detectionHealth, text: "Overtime may be missing Claude activity.", pane: .diagnostics,
      inputs: AttentionInputs(detectionWarnings: [.rootMissing("/Users/someone/.claude/projects")])),
    Row(
      item: .helperReapprove, text: "Unplug protection needs your approval again.", pane: .unplugProtection,
      inputs: AttentionInputs(helperReapprove: true)),
    Row(
      item: .helperStale, text: "Unplug protection is out of date.", pane: .unplugProtection,
      inputs: AttentionInputs(helperStale: true)),
    Row(
      item: .loginApproval, text: "Launch at login needs your approval.", pane: .general,
      inputs: AttentionInputs(loginItem: .requiresApproval)),
    Row(
      item: .notificationsDenied, text: "Notifications are off for Overtime.", pane: .general,
      inputs: AttentionInputs(notifications: .denied)),
    Row(
      item: .locationMissing,
      text: "Location access is off. Failover still works, but with Location, Overtime can join the hotspot directly.",
      pane: .network, inputs: AttentionInputs(location: .denied, hotspotChoice: .autoDetect)),
    Row(
      item: .updateAvailable, text: "An update to Overtime is available.", pane: .about,
      inputs: AttentionInputs(updateWaiting: true)),
  ]

  static let everything = AttentionInputs(
    selfTestFailed: true, detectionWarnings: [.terminalSilence], helperReapprove: true, helperStale: true,
    loginItem: .requiresApproval, notifications: .denied, location: .notDetermined, hotspotChoice: .named("iPhone"),
    updateWaiting: true)

  @Test(arguments: rows)
  func eachConditionAloneYieldsItsItemWithItsTextAndPane(_ row: Row) {
    #expect(Attention.items(row.inputs, forPanel: false) == [row.item])
    #expect(Attention.items(row.inputs, forPanel: true) == [row.item])
    #expect(row.item.shortText == row.text)
    #expect(row.item.pane == row.pane)
    #expect(Attention.panelText([row.item]) == row.text)
    #expect(Attention.badges([row.item]) == [row.pane: [row.text]])
  }

  @Test func theEightItemsAreDeclaredInPriorityOrder() {
    #expect(AttentionItem.allCases == Self.rows.map(\.item))
    #expect(AttentionItem.allCases.map(\.priority) == [1, 2, 3, 4, 5, 6, 7, 8])
    #expect(AttentionItem.updateAvailable.priority == 8)
  }

  @Test func withNoConditionThereIsNoItemNoTextAndNoBadge() {
    let quiet = AttentionInputs(
      loginItem: .enabled, notifications: .authorized, location: .authorized, hotspotChoice: .autoDetect,
      updateWaiting: false)
    #expect(!AttentionInputs().updateWaiting)
    for inputs in [AttentionInputs(), quiet] {
      #expect(Attention.items(inputs, forPanel: true).isEmpty)
      #expect(Attention.items(inputs, forPanel: false).isEmpty)
    }
    #expect(Attention.panelText([]) == nil)
    #expect(Attention.badges([]).isEmpty)
  }

  @Test func allEightTogetherComeOutInPriorityOrder() {
    let items = Attention.items(Self.everything, forPanel: false)
    #expect(items == AttentionItem.allCases)
    #expect(Attention.items(Self.everything, forPanel: true) == AttentionItem.allCases)
    #expect(Attention.panelText(items) == "8 things need your attention.")
  }

  @Test(arguments: rows.dropLast())
  func aWaitingUpdateComesLastWhateverElseApplies(_ row: Row) {
    var inputs = row.inputs
    inputs.updateWaiting = true
    #expect(Attention.items(inputs, forPanel: true) == [row.item, .updateAvailable])
    #expect(Attention.items(inputs, forPanel: false) == [row.item, .updateAvailable])
    #expect(Attention.panelText(Attention.items(inputs, forPanel: true)) == "2 things need your attention.")
    #expect(Attention.items(inputs, forPanel: true).first?.pane != .about)
  }

  @Test func onlyTheUpdateWaitingInputRaisesTheUpdateItem() {
    var inputs = Self.everything
    inputs.updateWaiting = false
    #expect(!Attention.items(inputs, forPanel: false).contains(.updateAvailable))
    #expect(!Attention.items(inputs, forPanel: true).contains(.updateAvailable))
    #expect(Attention.items(AttentionInputs(updateWaiting: true), forPanel: true) == [.updateAvailable])
    #expect(
      Attention.items(AttentionInputs(panelInErrorState: true, updateWaiting: true), forPanel: true)
        == [.updateAvailable])
  }

  @Test func theSelfTestItemLeavesThePanelListInTheErrorStateButKeepsItsBadge() {
    var inputs = Self.everything
    inputs.panelInErrorState = true
    let panel = Attention.items(inputs, forPanel: true)
    #expect(panel == Array(AttentionItem.allCases.dropFirst()))
    #expect(panel.first == .detectionHealth)
    let badges = Attention.badges(Attention.items(inputs, forPanel: false))
    #expect(
      badges[.diagnostics] == ["The keep-awake self-test failed.", "Overtime may be missing Claude activity."])
    let onlySelfTest = AttentionInputs(selfTestFailed: true, panelInErrorState: true)
    #expect(Attention.items(onlySelfTest, forPanel: true).isEmpty)
    #expect(Attention.panelText(Attention.items(onlySelfTest, forPanel: true)) == nil)
    #expect(Attention.items(onlySelfTest, forPanel: false) == [.selfTestFailed])
  }

  static func inputs(from snapshot: EngineSnapshot) -> AttentionInputs {
    var panelInErrorState = false
    if case .error = StatusPresentation.derive(snapshot: snapshot, hostFailure: nil, engineUnresponsive: false).state {
      panelInErrorState = true
    }
    return AttentionInputs(
      selfTestFailed: snapshot.selfTestErrorActive, detectionWarnings: snapshot.detectionWarnings,
      panelInErrorState: panelInErrorState)
  }

  static func selfTest(_ status: SelfTestStatus, errorActive: Bool) -> EngineSnapshot {
    EngineSnapshot(
      busy: false, wanted: false, reason: "idle", detectionWarnings: [.terminalSilence], selfTest: status,
      selfTestErrorActive: errorActive, selfTestFailures: errorActive ? 1 : 0, selfTestRuns: 1)
  }

  @Test func aFailedSelfTestInTheSnapshotBadgesDiagnosticsFirstAndLeavesThePanelList() {
    let inputs = Self.inputs(from: Self.selfTest(.failed(.clamshellRefused(-3)), errorActive: true))
    #expect(inputs.selfTestFailed)
    #expect(inputs.panelInErrorState)
    let settings = Attention.items(inputs, forPanel: false)
    #expect(settings == [.selfTestFailed, .detectionHealth])
    #expect(
      Attention.badges(settings)
        == [.diagnostics: ["The keep-awake self-test failed.", "Overtime may be missing Claude activity."]])
    let panel = Attention.items(inputs, forPanel: true)
    #expect(panel == [.detectionHealth])
    #expect(Attention.panelText(panel) == "Overtime may be missing Claude activity.")
  }

  @Test(arguments: [
    SelfTestStatus.passed, .skipped(.sleepDisabled), .skipped(.otherTool("Keeper")), .skipped(.amphetamine),
    .failed(.timedOut),
  ])
  func aSelfTestWithNoActiveErrorAddsNoItemAndLeavesThePanelOutOfTheErrorState(_ status: SelfTestStatus) {
    let inputs = Self.inputs(from: Self.selfTest(status, errorActive: false))
    #expect(!inputs.selfTestFailed)
    #expect(!inputs.panelInErrorState)
    #expect(Attention.items(inputs, forPanel: false) == [.detectionHealth])
    #expect(Attention.items(inputs, forPanel: true) == [.detectionHealth])
  }

  @Test(arguments: [
    DetectionWarning.rootMissing("/a"), .rootUnreadable("/b"), .terminalSilence,
  ])
  func anyDetectionWarningIsTheDetectionHealthItem(_ warning: DetectionWarning) {
    #expect(Attention.items(AttentionInputs(detectionWarnings: [warning]), forPanel: true) == [.detectionHealth])
  }

  @Test func severalDetectionWarningsAreStillOneItem() {
    let inputs = AttentionInputs(detectionWarnings: [.rootMissing("/a"), .rootUnreadable("/b"), .terminalSilence])
    #expect(Attention.items(inputs, forPanel: true) == [.detectionHealth])
  }

  @Test(arguments: [
    (HotspotChoice.autoDetect, LocationAuthorization.notDetermined, true),
    (.autoDetect, .denied, true),
    (.autoDetect, .restricted, true),
    (.named("iPhone"), .denied, true),
    (.unknown("Old iPhone"), .notDetermined, true),
    (.autoDetect, .authorized, false),
    (.named("iPhone"), .authorized, false),
    (.none, .denied, false),
    (.none, .notDetermined, false),
    (.none, .authorized, false),
  ])
  func locationMissingNeedsAHotspotChoiceAndLocationNotAuthorized(
    _ choice: HotspotChoice, _ location: LocationAuthorization, _ expected: Bool
  ) {
    let inputs = AttentionInputs(location: location, hotspotChoice: choice)
    #expect(Attention.items(inputs, forPanel: true) == (expected ? [.locationMissing] : []))
  }

  @Test func anUnreadLocationStatusIsNotReportedAsMissing() {
    #expect(Attention.items(AttentionInputs(location: nil, hotspotChoice: .autoDetect), forPanel: true).isEmpty)
  }

  @Test(arguments: [
    (NotificationAuthorization.denied, true), (.notDetermined, false), (.authorized, false), (.provisional, false),
  ])
  func notificationsDeniedNeedsDeniedNotNotDetermined(_ authorization: NotificationAuthorization, _ expected: Bool) {
    let inputs = AttentionInputs(notifications: authorization)
    #expect(Attention.items(inputs, forPanel: true) == (expected ? [.notificationsDenied] : []))
  }

  @Test(arguments: [
    (LoginItemStatus.requiresApproval, true), (.enabled, false), (.notRegistered, false), (.notFound, false),
  ])
  func loginApprovalNeedsALoginItemThatRequiresApproval(_ status: LoginItemStatus, _ expected: Bool) {
    let inputs = AttentionInputs(loginItem: status)
    #expect(Attention.items(inputs, forPanel: true) == (expected ? [.loginApproval] : []))
  }

  @Test func thePanelTextIsNilForNoneTheItemsTextForOneAndACountForSeveral() {
    #expect(Attention.panelText([]) == nil)
    #expect(Attention.panelText([.loginApproval]) == "Launch at login needs your approval.")
    #expect(Attention.panelText([.detectionHealth, .loginApproval]) == "2 things need your attention.")
    #expect(
      Attention.panelText([.detectionHealth, .loginApproval, .notificationsDenied])
        == "3 things need your attention.")
  }

  @Test func badgesGroupTheShortTextsByPaneInPriorityOrder() {
    let badges = Attention.badges(Attention.items(Self.everything, forPanel: false))
    #expect(
      badges == [
        .diagnostics: ["The keep-awake self-test failed.", "Overtime may be missing Claude activity."],
        .unplugProtection: ["Unplug protection needs your approval again.", "Unplug protection is out of date."],
        .general: ["Launch at login needs your approval.", "Notifications are off for Overtime."],
        .network: [
          "Location access is off. Failover still works, but with Location, Overtime can join the hotspot directly."
        ],
        .about: ["An update to Overtime is available."],
      ])
    #expect(badges[.detection] == nil)
    #expect(badges[.battery] == nil)
  }

  static let helperRows: [(HelperUIState?, AttentionItem?)] = [
    (nil, nil), (.checking, nil), (.off, nil), (.installing, nil), (.waitingForApproval, nil), (.onStandingBy, nil),
    (.onHolding, nil), (.needsApprovalAgain, .helperReapprove), (.updating, nil), (.outOfDate, .helperStale),
    (.error, nil), (.removing, nil),
  ]

  @Test(arguments: helperRows)
  func onlyTheNeedsApprovalAgainAndOutOfDateRowsAreAttentionItems(_ shown: HelperUIState?, _ expected: AttentionItem?) {
    #expect(Attention.helperItem(for: shown) == expected)
  }

  @Test func everyRowOfTheUnplugProtectionPaneIsInTheHelperRows() {
    #expect(Set(Self.helperRows.compactMap(\.0)) == Set(HelperUIState.allCases))
    #expect(Self.helperRows.count == HelperUIState.allCases.count + 1)
  }

  struct HelperCase: Sendable, CustomTestStringConvertible {
    let name: String
    let state: HelperMonitorState
    let items: [AttentionItem]
    let text: String?

    var testDescription: String { name }
  }

  static let helperCases = [
    HelperCase(
      name: "needs approval again", state: HelperMonitorState(installer: .enabled, reachability: .unreachable),
      items: [.helperReapprove], text: "Unplug protection needs your approval again."),
    HelperCase(
      name: "out of date", state: HelperMonitorState(installer: .enabled, reachability: .reachable, staleAttempts: 2),
      items: [.helperStale], text: "Unplug protection is out of date."),
    HelperCase(
      name: "updating", state: HelperMonitorState(installer: .enabled, reachability: .reachable, staleAttempts: 1),
      items: [], text: nil),
    HelperCase(
      name: "on", state: HelperMonitorState(installer: .enabled, reachability: .reachable), items: [], text: nil),
    HelperCase(
      name: "waiting for approval", state: HelperMonitorState(installer: .requiresApproval), items: [], text: nil),
    HelperCase(name: "off", state: HelperMonitorState(installer: .notRegistered), items: [], text: nil),
    HelperCase(
      name: "error", state: HelperMonitorState(installer: .enabled, reachability: .reachable, lastError: "4097"),
      items: [], text: nil),
  ]

  @Test(arguments: helperCases, [false, true])
  func theMonitorStateYieldsTheHelperItemsOnTheUnplugProtectionPane(_ example: HelperCase, _ engaged: Bool) {
    let item = Attention.helperItem(for: HelperStatusPresentation.derive(example.state, engaged: engaged))
    let inputs = AttentionInputs(helperReapprove: item == .helperReapprove, helperStale: item == .helperStale)
    let items = Attention.items(inputs, forPanel: true)
    #expect(items == example.items)
    #expect(Attention.items(inputs, forPanel: false) == example.items)
    #expect(Attention.panelText(items) == example.text)
    #expect(Attention.badges(items) == (example.text.map { [.unplugProtection: [$0]] } ?? [:]))
    #expect(items.allSatisfy { $0.pane == .unplugProtection })
  }

  @Test func noAttentionCopyNamesAPathOrANetwork() {
    for item in AttentionItem.allCases {
      #expect(!item.shortText.contains("/"))
      #expect(!item.shortText.contains("iPhone"))
      #expect(!item.shortText.isEmpty)
    }
  }
}
