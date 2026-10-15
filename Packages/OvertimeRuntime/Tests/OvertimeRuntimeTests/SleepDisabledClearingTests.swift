import Foundation
import OvertimeAppSupport
import Testing
import os

struct SleepDisabledClearingTests {
  final class Reader: Sendable {
    private let state: OSAllocatedUnfairLock<(values: [Bool?], reads: Int)>

    init(_ values: [Bool?]) {
      state = OSAllocatedUnfairLock(initialState: (values, 0))
    }

    var reads: Int {
      state.withLock { $0.reads }
    }

    func read() -> Bool? {
      state.withLock { state in
        state.reads += 1
        guard state.values.count > 1 else { return state.values.first ?? nil }
        return state.values.removeFirst()
      }
    }
  }

  struct Scenario: Sendable, CustomTestStringConvertible {
    let name: String
    let readings: [Bool?]
    let prompt: AdminOutcome
    let expected: SleepDisabledClearOutcome
    let prompts: Int
    let reads: Int

    var testDescription: String { name }
  }

  static let cancelled = "You cancelled the administrator prompt. Sleep is still turned off system-wide."
  static let failed = "Couldn't turn sleep back on. Run this in Terminal: sudo pmset -a disablesleep 0"

  static let scenarios: [Scenario] = [
    Scenario(
      name: "reads 0", readings: [false], prompt: .succeeded, expected: .alreadyClear, prompts: 0, reads: 1),
    Scenario(
      name: "unreadable", readings: [nil], prompt: .succeeded, expected: .failed(.unreadable), prompts: 0, reads: 1),
    Scenario(
      name: "reads 1, prompt succeeds, reads 0", readings: [true, false], prompt: .succeeded, expected: .cleared,
      prompts: 1, reads: 2),
    Scenario(
      name: "reads 1, prompt succeeds, still 1", readings: [true, true], prompt: .succeeded,
      expected: .failed(.stillSet), prompts: 1, reads: 2),
    Scenario(
      name: "reads 1, prompt succeeds, unreadable", readings: [true, nil], prompt: .succeeded,
      expected: .failed(.unconfirmed), prompts: 1, reads: 2),
    Scenario(
      name: "reads 1, prompt cancelled", readings: [true, false], prompt: .cancelled, expected: .cancelled,
      prompts: 1, reads: 1),
    Scenario(
      name: "reads 1, prompt fails", readings: [true, false], prompt: .failed("The administrator command failed."),
      expected: .failed(.prompt("The administrator command failed.")), prompts: 1, reads: 1),
  ]

  @Test(arguments: scenarios)
  func theClearReadsFirstAndPromptsOnlyForAOne(_ scenario: Scenario) {
    let reader = Reader(scenario.readings)
    let prompt = FakeAdminPrompt(scenario.prompt)
    let outcome = SleepDisabledClearing.run(read: reader.read, prompt: prompt)
    #expect(outcome == scenario.expected)
    #expect(prompt.calls == scenario.prompts)
    #expect(reader.reads == scenario.reads)
  }

  @Test func aCancelledPromptIsOfferedAgainOnlyByRunningAgain() {
    let reader = Reader([true])
    let prompt = FakeAdminPrompt(.cancelled)
    #expect(SleepDisabledClearing.run(read: reader.read, prompt: prompt) == .cancelled)
    #expect(prompt.calls == 1)
    #expect(SleepDisabledClearing.run(read: reader.read, prompt: prompt) == .cancelled)
    #expect(prompt.calls == 2)
    #expect(reader.reads == 2)
  }

  @Test func theOutcomesCarryTheUISpecCopy() {
    #expect(SleepDisabledClearOutcome.alreadyClear.caption == nil)
    #expect(SleepDisabledClearOutcome.cleared.caption == nil)
    #expect(SleepDisabledClearOutcome.cancelled.caption == Self.cancelled)
    #expect(SleepDisabledClearOutcome.failed(.unreadable).caption == Self.failed)
    #expect(SleepDisabledClearOutcome.failed(.stillSet).caption == Self.failed)
    #expect(SleepDisabledClearOutcome.failed(.unconfirmed).caption == Self.failed)
    #expect(SleepDisabledClearOutcome.failed(.prompt("anything the prompt said")).caption == Self.failed)
    #expect(SleepDisabledClearing.cancelledCaption == Self.cancelled)
    #expect(SleepDisabledClearing.failedCaption == Self.failed)
  }

  @Test func theFailureCopyEndsWithTheOneCommandOfTheHints() {
    #expect(Hints.sleepDisabledCommand == "sudo pmset -a disablesleep 0")
    #expect(
      SleepDisabledClearing.failedCaption
        == "Couldn't turn sleep back on. Run this in Terminal: " + Hints.sleepDisabledCommand)
  }

  @Test func onlyAClearedOrAlreadyClearOutcomeHidesTheRow() {
    #expect(SleepDisabledClearOutcome.alreadyClear.isClear)
    #expect(SleepDisabledClearOutcome.cleared.isClear)
    #expect(!SleepDisabledClearOutcome.cancelled.isClear)
    #expect(!SleepDisabledClearOutcome.failed(.unreadable).isClear)
    #expect(!SleepDisabledClearOutcome.failed(.stillSet).isClear)
    #expect(!SleepDisabledClearOutcome.failed(.unconfirmed).isClear)
    #expect(!SleepDisabledClearOutcome.failed(.prompt("x")).isClear)
  }

  @Test func theRowCopyIsTheUISpecOne() {
    #expect(SleepDisabledClearing.rowTitle == "Sleep is turned off system-wide (SleepDisabled)")
    #expect(
      SleepDisabledClearing.rowCaption
        == "Overtime didn't set this. Until it's cleared, the Mac can't sleep at all, even with the lid closed and Claude idle."
    )
    #expect(SleepDisabledClearing.turnOnLabel == "Turn Sleep Back On…")
    #expect(SleepDisabledClearing.copyLabel == "Copy Command")
  }
}
