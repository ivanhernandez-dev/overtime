import Foundation
import OvertimeAppSupport
import OvertimeHelperCore
import Testing

struct HelperStatusPresentationTests {
  struct Row: Sendable, CustomTestStringConvertible {
    let state: HelperUIState
    let icon: HelperStatusIcon
    let title: String
    let caption: String?
    let actions: [HelperStatusAction]

    var testDescription: String { title }
  }

  static let warningSymbol = "exclamationmark.triangle.fill"
  static let onSymbol = "checkmark.shield.fill"

  static let rows: [Row] = [
    Row(state: .checking, icon: .progress, title: "Checking unplug protection…", caption: nil, actions: []),
    Row(
      state: .off, icon: .symbol("shield", .secondary), title: "Off",
      caption: "With the lid closed, unplugging power or a display can still let the Mac sleep.",
      actions: [.install]),
    Row(state: .installing, icon: .progress, title: "Installing…", caption: nil, actions: []),
    Row(
      state: .waitingForApproval, icon: .symbol("clock", .warning), title: "Waiting for your approval",
      caption:
        "Turn on Overtime under Allow in the Background in System Settings > General > Login Items & Extensions.",
      actions: [.openLoginItems, .remove]),
    Row(
      state: .onStandingBy, icon: .symbol(onSymbol, .success), title: "On",
      caption: "It turns system sleep off only while Claude works with the lid closed.", actions: [.remove]),
    Row(
      state: .onHolding, icon: .symbol(onSymbol, .success), title: "On, holding now",
      caption: "System sleep is off until the lid opens or Claude finishes.", actions: [.remove]),
    Row(
      state: .needsApprovalAgain, icon: .symbol(warningSymbol, .warning), title: "Needs your approval again",
      caption:
        "macOS stopped the helper, usually after an update. In System Settings > General > Login Items & Extensions, turn Overtime off and on again under Allow in the Background.",
      actions: [.openLoginItems, .remove]),
    Row(state: .updating, icon: .progress, title: "Updating the helper…", caption: nil, actions: []),
    Row(
      state: .outOfDate, icon: .symbol(warningSymbol, .warning), title: "Out of date",
      caption:
        "The installed helper is older than this version of Overtime. Remove unplug protection, then install it again.",
      actions: [.remove]),
    Row(
      state: .error, icon: .symbol(warningSymbol, .error), title: "Unplug protection isn't working",
      caption:
        "Overtime couldn't talk to the helper. Keep-awake still works without it. Try again, or remove and reinstall it.",
      actions: [.reconnect, .remove]),
    Row(state: .removing, icon: .progress, title: "Removing…", caption: nil, actions: []),
  ]

  struct Condition: Sendable, CustomTestStringConvertible {
    let name: String
    var installer: HelperInstallerStatus?
    var reachability: HelperReachability = .unknown
    var inFlight: HelperInFlight?
    var engaged = false
    var staleAttempts = 0
    var lastError: String?
    let expected: HelperUIState

    var testDescription: String { name }
  }

  static let conditions: [Condition] = [
    Condition(name: "no read yet", installer: nil, expected: .checking),
    Condition(name: "no read yet, engaged", installer: nil, engaged: true, expected: .checking),
    Condition(name: "enabled, not probed yet", installer: .enabled, expected: .checking),
    Condition(name: "not registered", installer: .notRegistered, expected: .off),
    Condition(name: "not found", installer: .notFound, expected: .off),
    Condition(
      name: "not registered ignores the probe fields", installer: .notRegistered, reachability: .reachable,
      engaged: true, staleAttempts: 3, expected: .off),
    Condition(name: "register in flight", installer: .notRegistered, inFlight: .installing, expected: .installing),
    Condition(name: "register in flight before any read", installer: nil, inFlight: .installing, expected: .installing),
    Condition(
      name: "register in flight over an earlier error", installer: .notRegistered, inFlight: .installing,
      lastError: "Operation not permitted", expected: .installing),
    Condition(name: "requires approval", installer: .requiresApproval, expected: .waitingForApproval),
    Condition(
      name: "requires approval ignores the probe fields", installer: .requiresApproval, reachability: .unreachable,
      engaged: true, staleAttempts: 2, expected: .waitingForApproval),
    Condition(
      name: "enabled, reachable, current", installer: .enabled, reachability: .reachable, expected: .onStandingBy),
    Condition(
      name: "enabled, reachable, current, engaged", installer: .enabled, reachability: .reachable, engaged: true,
      expected: .onHolding),
    Condition(
      name: "enabled and unreachable", installer: .enabled, reachability: .unreachable, expected: .needsApprovalAgain),
    Condition(
      name: "enabled and unreachable, engaged", installer: .enabled, reachability: .unreachable, engaged: true,
      expected: .needsApprovalAgain),
    Condition(
      name: "enabled and unreachable after a stale answer", installer: .enabled, reachability: .unreachable,
      staleAttempts: 1, expected: .needsApprovalAgain),
    Condition(
      name: "an older version on the first read", installer: .enabled, reachability: .reachable, staleAttempts: 1,
      expected: .updating),
    Condition(
      name: "an older version on the first read, engaged", installer: .enabled, reachability: .reachable,
      engaged: true, staleAttempts: 1, expected: .updating),
    Condition(
      name: "still older on the next read", installer: .enabled, reachability: .reachable, staleAttempts: 2,
      expected: .outOfDate),
    Condition(
      name: "still older many reads later", installer: .enabled, reachability: .reachable, staleAttempts: 7,
      expected: .outOfDate),
    Condition(
      name: "register failed", installer: .notRegistered, lastError: "Operation not permitted", expected: .error),
    Condition(
      name: "status failed while enabled and reachable", installer: .enabled, reachability: .reachable,
      lastError: "undecodableStatus", expected: .error),
    Condition(
      name: "status failed while enabled, reachable and engaged", installer: .enabled, reachability: .reachable,
      engaged: true, lastError: "NSCocoaErrorDomain 4102", expected: .error),
    Condition(
      name: "unregister failed while waiting for approval", installer: .requiresApproval,
      lastError: "Operation not permitted", expected: .error),
    Condition(
      name: "unregister in flight", installer: .enabled, reachability: .reachable, inFlight: .removing,
      engaged: true, expected: .removing),
    Condition(
      name: "unregister in flight over an earlier error", installer: .enabled, reachability: .unreachable,
      inFlight: .removing, lastError: "Operation not permitted", expected: .removing),
  ]

  @Test(arguments: rows)
  func eachStateShowsItsRowOfTheUISpec(_ row: Row) {
    #expect(row.state.icon == row.icon)
    #expect(row.state.title == row.title)
    #expect(row.state.caption == row.caption)
    #expect(row.state.actions == row.actions)
  }

  @Test func thereAreExactlyElevenStatesAndEachHasARow() {
    #expect(HelperUIState.allCases.count == 11)
    #expect(Set(Self.rows.map(\.state)) == Set(HelperUIState.allCases))
    #expect(Set(Self.rows.map(\.title)).count == 11)
  }

  @Test(arguments: conditions)
  func eachStateComesFromItsCondition(_ condition: Condition) {
    let derived = HelperStatusPresentation.derive(
      installer: condition.installer, reachability: condition.reachability, inFlight: condition.inFlight,
      engaged: condition.engaged, staleAttempts: condition.staleAttempts, lastError: condition.lastError)
    #expect(derived == condition.expected)
  }

  @Test func everyStateIsReachedByAtLeastOneCondition() {
    #expect(Set(Self.conditions.map(\.expected)) == Set(HelperUIState.allCases))
  }

  @Test func aMonitorStateIsDerivedFromItsOwnFields() {
    let waiting = HelperMonitorState(installer: .requiresApproval)
    #expect(HelperStatusPresentation.derive(waiting, engaged: false) == .waitingForApproval)
    let holding = HelperMonitorState(installer: .enabled, reachability: .reachable)
    #expect(HelperStatusPresentation.derive(holding, engaged: true) == .onHolding)
    let stale = HelperMonitorState(installer: .enabled, reachability: .reachable, staleAttempts: 2)
    #expect(HelperStatusPresentation.derive(stale, engaged: false) == .outOfDate)
    let failed = HelperMonitorState(installer: .notRegistered, lastError: "Operation not permitted")
    #expect(HelperStatusPresentation.derive(failed, engaged: false) == .error)
    let removing = HelperMonitorState(installer: .enabled, reachability: .reachable, inFlight: .removing)
    #expect(HelperStatusPresentation.derive(removing, engaged: false) == .removing)
  }

  @Test func theActionsCarryTheirLabelsAndStyles() {
    #expect(HelperStatusAction.install.label == "Install Unplug Protection…")
    #expect(HelperStatusAction.install.style == .bordered)
    #expect(!HelperStatusAction.install.isDestructive)
    #expect(HelperStatusAction.openLoginItems.label == "Open Login Items")
    #expect(HelperStatusAction.openLoginItems.style == .link)
    #expect(!HelperStatusAction.openLoginItems.isDestructive)
    #expect(HelperStatusAction.remove.label == "Remove Unplug Protection…")
    #expect(HelperStatusAction.remove.style == .bordered)
    #expect(HelperStatusAction.remove.isDestructive)
    #expect(HelperStatusAction.reconnect.label == "Reconnect Helper")
    #expect(HelperStatusAction.reconnect.style == .bordered)
    #expect(!HelperStatusAction.reconnect.isDestructive)
  }

  @Test func theDetailLineNamesTheHelperVersionAndWhetherSystemSleepIsOn() {
    let sleepOn = HelperStatus(helperVersion: 1, sleepDisabled: false)
    let sleepOff = HelperStatus(helperVersion: 1, sleepDisabled: true)
    #expect(HelperStatusPresentation.detail(status: sleepOn) == "Helper version 1. System sleep: on.")
    #expect(HelperStatusPresentation.detail(status: sleepOff) == "Helper version 1. System sleep: off.")
    #expect(
      HelperStatusPresentation.detail(status: HelperStatus(helperVersion: 3, sleepDisabled: false))
        == "Helper version 3. System sleep: on.")
    #expect(HelperStatusPresentation.detail(status: HelperStatus(helperVersion: 12)) == "Helper version 12.")
    #expect(HelperStatusPresentation.detail(status: nil) == nil)
  }

  @Test func theDetailLineShowsOnlyWhileTheHelperIsReachable() {
    let status = HelperStatus(helperVersion: 1, sleepDisabled: true)
    let reachable = HelperMonitorState(installer: .enabled, reachability: .reachable, status: status)
    #expect(HelperStatusPresentation.detail(for: reachable) == "Helper version 1. System sleep: off.")
    let unreachable = HelperMonitorState(installer: .enabled, reachability: .unreachable, status: status)
    #expect(HelperStatusPresentation.detail(for: unreachable) == nil)
    let unknown = HelperMonitorState(installer: .enabled, reachability: .unknown, status: status)
    #expect(HelperStatusPresentation.detail(for: unknown) == nil)
    let removed = HelperMonitorState(installer: .notRegistered, reachability: .reachable, status: status)
    #expect(HelperStatusPresentation.detail(for: removed) == nil)
    let noStatus = HelperMonitorState(installer: .enabled, reachability: .reachable)
    #expect(HelperStatusPresentation.detail(for: noStatus) == nil)
  }

  @Test func theFourAboutNotesAreTheUISpecOnes() {
    #expect(
      HelperStatusPresentation.aboutNotes == [
        "Installing it needs one approval in System Settings. While you approve it, Overtime's login item may briefly show that it needs approval too.",
        "It runs as an administrator and does one thing: it turns system sleep off while Claude works with the lid closed, and back on afterwards.",
        "While it holds the Mac on battery, macOS can't put the Mac to sleep in an emergency. The helper lets go at its battery floor or temperature limit, both in Settings > Battery, or if the Mac gets too hot.",
        "Turning it off in System Settings also quits Overtime. Open Overtime again afterwards.",
      ])
  }

  @Test func theRemoveConfirmationCopyIsTheUISpecOne() {
    #expect(HelperStatusPresentation.removeConfirmationTitle == "Remove unplug protection?")
    #expect(
      HelperStatusPresentation.removeConfirmationMessage
        == "With the lid closed, unplugging power or a display can let the Mac sleep again.")
    #expect(HelperStatusPresentation.removeConfirmationConfirm == "Remove Unplug Protection")
    #expect(HelperStatusPresentation.removeConfirmationKeep == "Keep Unplug Protection")
  }
}
