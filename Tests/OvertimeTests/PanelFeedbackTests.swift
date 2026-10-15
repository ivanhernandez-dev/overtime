import Foundation
import OvertimeAppSupport
import SwiftUI
import Testing

@testable import Overtime

@MainActor
struct PanelFeedbackTests {
  @MainActor final class Spoken {
    private(set) var texts: [String] = []

    func record(_ text: String) {
      texts.append(text)
    }
  }

  @Test func aCopyShowsCopiedAnnouncesOnceAndRevertsAfterItsWindow() async {
    let spoken = Spoken()
    let feedback = CopyFeedback(seconds: 0.05) { spoken.record($0) }
    #expect(!feedback.isShowing)
    #expect(spoken.texts.isEmpty)
    feedback.copied()
    #expect(feedback.isShowing)
    #expect(spoken.texts == ["Command copied."])
    #expect(await waitUntil { !feedback.isShowing })
    #expect(spoken.texts == ["Command copied."])
  }

  @Test func aSecondCopyRestartsTheWindowAndAStaleExpiryChangesNothing() {
    let spoken = Spoken()
    let feedback = CopyFeedback(seconds: 600) { spoken.record($0) }
    let start = feedback.generation
    feedback.copied()
    let first = feedback.generation
    feedback.copied()
    let second = feedback.generation
    #expect(first == start + 1)
    #expect(second == first + 1)
    #expect(spoken.texts == ["Command copied.", "Command copied."])
    feedback.expire(first)
    #expect(feedback.isShowing)
    feedback.expire(second)
    #expect(!feedback.isShowing)
    #expect(feedback.generation == second)
  }

  @Test func theFeedbackWindowDefaultsToTheSharedTwoSeconds() {
    let feedback = CopyFeedback()
    #expect(feedback.seconds == CopyConfirmation.seconds)
    #expect(!feedback.isShowing)
  }

  @Test func theRowHighlightRadiusIsSixPoints() {
    #expect(CornerGeometry.rowRadius == 6)
  }

  @Test func thePanelHairlineIsHalfAPoint() {
    #expect(MenuBarPanelController.hairlineWidth == 0.5)
    #expect(MenuBarPanelController.cornerRadius == 24)
  }

  static let keyEquivalents: [(shortcut: PanelShortcut, key: Character, modifiers: EventModifiers)] = [
    (.pause, "p", [.control, .command]),
    (.keepAwake, "k", [.control, .command]),
    (.releaseUntilIdle, "i", [.control, .command]),
    (.sleepNow, "s", [.control, .command]),
    (.restore, "r", [.control, .command]),
    (.settings, ",", [.command]),
    (.quit, "q", [.command]),
  ]

  @Test func everyPanelShortcutMapsToItsKeyEquivalent() {
    #expect(Self.keyEquivalents.map(\.shortcut) == PanelShortcut.allCases)
    for expected in Self.keyEquivalents {
      let equivalent = expected.shortcut.keyboardShortcut
      #expect(equivalent.key.character == expected.key, "\(expected.shortcut)")
      #expect(equivalent.modifiers == expected.modifiers, "\(expected.shortcut)")
      #expect(equivalent.key.character == expected.shortcut.key, "\(expected.shortcut)")
      let mapped = EventModifiers(expected.shortcut.modifiers.map { $0.eventModifier })
      #expect(equivalent.modifiers == mapped, "\(expected.shortcut)")
    }
  }

  static let transitionSeconds: [(transition: MotionTransition, seconds: Double)] = [
    (.rowHighlight, 0.15), (.statusGlyph, 0.2), (.onboardingStep, 0.25), (.panelClose, 0.15),
  ]

  @Test func aTransitionAnimatesOnlyWithoutReduceMotion() {
    #expect(Self.transitionSeconds.map(\.transition) == MotionTransition.allCases)
    for expected in Self.transitionSeconds {
      #expect(Motion.animation(expected.transition, reduceMotion: true) == nil, "\(expected.transition)")
      #expect(
        Motion.animation(expected.transition, reduceMotion: false) == Animation.easeOut(duration: expected.seconds),
        "\(expected.transition)")
    }
    #expect(Animation.easeOut(duration: 0.15) != Animation.easeOut(duration: 0.25))
    #expect(Animation.easeOut(duration: 0.15) != Animation.linear(duration: 0.15))
  }
}
