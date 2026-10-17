import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeSystem
import Testing

struct HintsTests {
  static let sleepDisabledCopy =
    "Sleep is turned off system-wide (SleepDisabled). The Mac can't sleep until you run: sudo pmset -a disablesleep 0"
  static let amphetamineRunningCopy =
    "Amphetamine is running. Quit it so the two apps don't fight over lid-close sleep."
  static let amphetamineInstalledCopy = "Amphetamine is installed. Keep it quit while Overtime runs."
  static let rootlessCopy = "With the lid closed, unplugging power or a display can still let the Mac sleep."
  static let protectedCopy =
    "Unplug protection is on. Unplugging power or a display with the lid closed won't let the Mac sleep."

  struct Variant: Sendable, CustomTestStringConvertible {
    let helper: HelperHintState
    let icon: String
    let text: String
    let action: HintAction?
    let label: String?

    var testDescription: String { String(describing: helper) }
  }

  static let variants = [
    Variant(
      helper: .notInstalled, icon: "info.circle", text: rootlessCopy, action: .setUpUnplugProtection,
      label: "Set Up Unplug Protection…"),
    Variant(
      helper: .installedNotReady, icon: "info.circle", text: rootlessCopy, action: .reviewUnplugProtection,
      label: "Review Unplug Protection…"),
    Variant(helper: .ready, icon: "checkmark.shield", text: protectedCopy, action: nil, label: nil),
  ]

  static let shownStates: [(HelperUIState?, HelperHintState)] = [
    (nil, .notInstalled), (.off, .notInstalled), (.checking, .installedNotReady), (.installing, .installedNotReady),
    (.waitingForApproval, .installedNotReady), (.needsApprovalAgain, .installedNotReady),
    (.updating, .installedNotReady), (.outOfDate, .installedNotReady), (.error, .installedNotReady),
    (.removing, .installedNotReady), (.onStandingBy, .ready), (.onHolding, .ready),
  ]

  @Test func theCommandAtTheEndOfASentenceIsSplitOff() throws {
    let hint = try #require(Hints.visible(HintInputs(sleepDisabledLeftover: true)).first)
    #expect(hint.text == Self.sleepDisabledCopy)
    for text in [hint.text, SleepDisabledClearing.failedCaption] {
      let parts = CommandText.split(text)
      let command = try #require(parts.command, "no command split off: \(text)")
      #expect(command == Hints.sleepDisabledCommand)
      #expect(parts.sentence.hasSuffix(": "))
      #expect(!parts.sentence.contains(Hints.sleepDisabledCommand))
      #expect(parts.sentence + command == text)
    }
    let inside = "Run \(Hints.sleepDisabledCommand) in Terminal."
    for text in [Self.amphetamineInstalledCopy, SleepDisabledClearing.cancelledCaption, inside, ""] {
      #expect(CommandText.split(text) == CommandText(sentence: text, command: nil), "\(text)")
    }
  }

  @Test func theCopyConfirmationCopyIsFixed() {
    #expect(CopyConfirmation.copiedLabel == "Copied")
    #expect(CopyConfirmation.copiedSymbol == "checkmark")
    #expect(CopyConfirmation.announcement == "Command copied.")
    #expect(CopyConfirmation.seconds == 2)
  }

  @Test func withEveryConditionTrueTheFirstThreeShow() {
    let hints = Hints.visible(
      HintInputs(
        sleepDisabledLeftover: true, amphetamineRunning: true, otherTools: ["Lungo"], amphetamineInstalled: true,
        keepAwakeWanted: true))
    #expect(hints.count == 3)
    #expect(hints.map(\.priority) == [1, 3, 5])
    #expect(hints.map(\.text) == [Self.sleepDisabledCopy, Self.amphetamineRunningCopy, Self.rootlessCopy])
    #expect(hints.map(\.action) == [.copyCommand, nil, .setUpUnplugProtection])
    #expect(hints.map(\.tint) == [.warning, .warning, .info])
  }

  @Test func anotherToolNamesTheFirstSortedName() {
    let hints = Hints.visible(HintInputs(otherTools: ["Lungo", "KeepingYouAwake"]))
    #expect(hints.map(\.text) == ["KeepingYouAwake is also managing sleep. Running both is unsupported."])
    #expect(hints.first?.icon == "exclamationmark.triangle.fill")
  }

  @Test func amphetamineInstalledButNotRunningIsInformational() {
    let hints = Hints.visible(HintInputs(amphetamineInstalled: true))
    #expect(hints.map(\.text) == [Self.amphetamineInstalledCopy])
    #expect(hints.first?.tint == .info)
    #expect(hints.first?.icon == "info.circle")
    #expect(hints.first?.priority == 4)
  }

  @Test func runningAmphetamineReplacesTheInstalledHint() {
    let hints = Hints.visible(HintInputs(amphetamineRunning: true, amphetamineInstalled: true))
    #expect(hints.map(\.priority) == [3])
  }

  @Test(arguments: variants)
  func theUnplugProtectionHintShowsOnlyWhileKeepAwakeIsWantedAndFollowsTheHelper(_ variant: Variant) {
    let hints = Hints.visible(HintInputs(keepAwakeWanted: true, helper: variant.helper))
    #expect(
      hints == [Hint(priority: 5, icon: variant.icon, tint: .info, text: variant.text, action: variant.action)])
    #expect(hints.first?.action?.label == variant.label)
    #expect(Hints.visible(HintInputs(keepAwakeWanted: false, helper: variant.helper)).isEmpty)
  }

  @Test func withNoHelperStateTheHintOffersToSetUpUnplugProtection() {
    #expect(HintInputs().helper == .notInstalled)
    #expect(!HintInputs().helperOwnsSleepDisabled)
    #expect(Hints.visible(HintInputs(keepAwakeWanted: true)).map(\.action) == [.setUpUnplugProtection])
  }

  @Test func theThreeUnplugProtectionVariantsAreTheUISpecOnes() {
    #expect(Hints.rootlessLimitation == Self.rootlessCopy)
    #expect(Hints.unplugProtectionOn == Self.protectedCopy)
    #expect(Self.variants.map(\.helper) == [.notInstalled, .installedNotReady, .ready])
  }

  static let displayCopy = "With the lid closed, connecting or disconnecting a display can still let the Mac sleep."
  static let protectedForDisplaysCopy =
    "Unplug protection is on. Connecting or disconnecting a display with the lid closed won't let the Mac sleep."

  @Test func theUnplugHintIsHiddenWhileTheLidClosedHoldIsOff() {
    let helperStates: [HelperHintState] = [.notInstalled, .installedNotReady, .ready]
    for setting in LidClosedKeepAwake.allCases {
      for helper in helperStates {
        let hints = Hints.visible(
          HintInputs(
            keepAwakeWanted: true, helper: helper, lidClosedKeepAwake: setting, lidClosedHoldAllowed: false))
        #expect(!hints.contains { $0.priority == 5 }, "\(setting) \(helper)")
      }
    }
  }

  @Test func withOnPowerAdapterTheUnplugHintNamesOnlyTheDisplay() {
    let cases: [(HelperHintState, String, String, HintAction?)] = [
      (.notInstalled, "info.circle", Self.displayCopy, .setUpUnplugProtection),
      (.installedNotReady, "info.circle", Self.displayCopy, .reviewUnplugProtection),
      (.ready, "checkmark.shield", Self.protectedForDisplaysCopy, nil),
    ]
    for (helper, icon, text, action) in cases {
      let hints = Hints.visible(
        HintInputs(
          keepAwakeWanted: true, helper: helper, lidClosedKeepAwake: .onPowerAdapter, lidClosedHoldAllowed: true))
      #expect(hints == [Hint(priority: 5, icon: icon, tint: .info, text: text, action: action)])
    }
    #expect(Hints.displayLimitation == Self.displayCopy)
    #expect(Hints.unplugProtectionOnForDisplays == Self.protectedForDisplaysCopy)
  }

  @Test(arguments: shownStates)
  func theHintStateFollowsTheRowTheUnplugProtectionPaneShows(_ shown: HelperUIState?, _ expected: HelperHintState) {
    #expect(HelperHintState.derive(shown) == expected)
  }

  @Test func everyRowOfThePaneHasAHintState() {
    #expect(Set(Self.shownStates.compactMap(\.0)) == Set(HelperUIState.allCases))
    #expect(Self.shownStates.count == HelperUIState.allCases.count + 1)
  }

  @Test func theSleepDisabledHintIsHiddenWhileTheHelperOwnsTheValue() {
    let owned = Hints.visible(HintInputs(sleepDisabledLeftover: true, helperOwnsSleepDisabled: true))
    #expect(owned.isEmpty)
    let foreign = Hints.visible(HintInputs(sleepDisabledLeftover: true, helperOwnsSleepDisabled: false))
    #expect(foreign.map(\.priority) == [1])
    #expect(foreign.first?.text == Self.sleepDisabledCopy)
    #expect(foreign.first?.action == .copyCommand)
    #expect(Hints.visible(HintInputs(sleepDisabledLeftover: false, helperOwnsSleepDisabled: true)).isEmpty)
  }

  @Test func whileTheHelperOwnsSleepDisabledTheOtherHintsKeepTheirOrderAndTheCap() {
    let hints = Hints.visible(
      HintInputs(
        sleepDisabledLeftover: true, amphetamineRunning: false, otherTools: ["Lungo"], amphetamineInstalled: true,
        keepAwakeWanted: true, helper: .ready, helperOwnsSleepDisabled: true))
    #expect(hints.map(\.priority) == [3, 4, 5])
    let withoutAmphetamine = Hints.visible(
      HintInputs(
        sleepDisabledLeftover: true, otherTools: ["Lungo"], keepAwakeWanted: true, helper: .ready,
        helperOwnsSleepDisabled: true))
    #expect(withoutAmphetamine.map(\.priority) == [3, 5])
    #expect(withoutAmphetamine.last?.text == Self.protectedCopy)
    #expect(withoutAmphetamine.last?.icon == "checkmark.shield")
  }

  @Test(arguments: variants)
  func aForeignSleepDisabledValueStaysFirstWhateverTheHelperState(_ variant: Variant) {
    let hints = Hints.visible(
      HintInputs(sleepDisabledLeftover: true, keepAwakeWanted: true, helper: variant.helper))
    #expect(hints.map(\.priority) == [1, 5])
    #expect(hints.last?.text == variant.text)
  }

  @Test(arguments: [
    (PanelState.holding, true), (.lidClosedHolding, true), (.grace, true), (.override, true), (.idle, false),
    (.paused, false), (.releasedUntilIdle, false), (.batteryFloor, false), (.starting, false),
    (.error(.holdFailed), false), (.error(.selfTestFailed), false),
  ])
  func keepAwakeIsWantedOnlyInTheHoldingStates(_ state: PanelState, _ wanted: Bool) {
    #expect(Hints.keepAwakeWanted(state) == wanted)
  }

  @Test func nothingTrueMeansNoHint() {
    #expect(Hints.visible(HintInputs()).isEmpty)
  }

  @Test func theCopyCommandIsTheFixedString() {
    #expect(Hints.sleepDisabledCommand == "sudo pmset -a disablesleep 0")
    #expect(HintAction.copyCommand.label == "Copy Command")
    #expect(HintAction.setUpUnplugProtection.label == "Set Up Unplug Protection…")
    #expect(HintAction.reviewUnplugProtection.label == "Review Unplug Protection…")
  }

  @Test func aLiveSleepDisabledReadShowsHintOneWithCopyCommand() {
    let hints = Hints.visible(HintInputs(sleepDisabledLeftover: true))
    #expect(hints.map(\.priority) == [1])
    #expect(hints.first?.text == Self.sleepDisabledCopy)
    #expect(hints.first?.action == .copyCommand)
    #expect(Hints.sleepDisabledCommand == "sudo pmset -a disablesleep 0")
  }
}
