import Foundation
import Testing

@testable import OvertimeCore

@Suite("Busy scenarios #1-#8")
struct BusyScenarios {
  typealias H = ScenarioHarness

  static let automationLine = #"{"type":"user","entrypoint":"sdk-cli"}"#
  static let interactiveLine =
    #"{"type":"user","entrypoint":"cli","message":"text with \"entrypoint\":\"sdk-cli\" inside"}"#
  static let subagentLine = #"{"type":"user","entrypoint":"cli"}"#
  static let summaryLine = #"{"type":"summary"}"#

  @Test("#1 claude -p automation does not count")
  func scenario01AutomationDoesNotCount() {
    var harness = H()
    let entrypoint = H.header(Self.automationLine)
    #expect(entrypoint == "sdk-cli")
    #expect(
      harness.activity(writtenAt: 0, entrypoint: entrypoint, seenAt: 0) == [H.entrypoint("sdk-cli", ignored: true)])
    #expect(harness.tick(at: 0) == [H.busy(false, source: "transcript"), H.want(false)])
    #expect(harness.state.busy.busy == false)
  }

  @Test("#2 interactive session counts even if its text mentions sdk-cli")
  func scenario02InteractiveMentionCounts() {
    var harness = H()
    let entrypoint = H.header(Self.interactiveLine)
    #expect(entrypoint == "cli")
    #expect(harness.activity(writtenAt: 0, entrypoint: entrypoint, seenAt: 0) == [H.entrypoint("cli", ignored: false)])
    #expect(harness.tick(at: 0) == [H.busy(true, source: "transcript"), H.want(true)])
    #expect(harness.state.busy.busy == true)
  }

  @Test("#3 transcript from 10 min ago does not count")
  func scenario03TenMinuteOldTranscriptDoesNotCount() {
    var harness = H()
    let entrypoint = H.header(Self.interactiveLine)
    #expect(
      harness.activity(writtenAt: -600, entrypoint: entrypoint, seenAt: 0) == [H.entrypoint("cli", ignored: false)])
    #expect(harness.tick(at: 0) == [H.busy(false, source: "transcript"), H.want(false)])
    #expect(harness.state.busy.busy == false)
  }

  @Test("#4 recent subagent transcript counts")
  func scenario04RecentSubagentTranscriptCounts() {
    var harness = H()
    let entrypoint = H.header(Self.subagentLine)
    #expect(harness.activity(writtenAt: 0, entrypoint: entrypoint, seenAt: 0) == [H.entrypoint("cli", ignored: false)])
    #expect(harness.tick(at: 0) == [H.busy(true, source: "transcript"), H.want(true)])
    #expect(harness.state.busy.busy == true)
  }

  @Test("#5 transcript without entrypoint counts (conservative)")
  func scenario05MissingEntrypointCounts() {
    var harness = H()
    let entrypoint = H.header(Self.summaryLine)
    #expect(entrypoint == nil)
    #expect(harness.activity(writtenAt: 0, entrypoint: entrypoint, seenAt: 0) == [])
    #expect(harness.tick(at: 0) == [H.busy(true, source: "transcript"), H.want(true)])
    #expect(harness.state.busy.busy == true)
  }

  @Test("#6 Claude caffeinate + long silent command stays busy")
  func scenario06CaffeinateWithSilentCommandStaysBusy() {
    var harness = H()
    #expect(harness.activity(writtenAt: -600, seenAt: 0) == [])
    #expect(harness.tick(at: 0, caffeinate: true) == [H.busy(true, source: "caffeinate"), H.want(true)])
    #expect(harness.state.busy.busy == true)
  }

  @Test("#7 Claude caffeinate with no writes for 40 min is treated as stuck")
  func scenario07CaffeinateWithoutWritesIsStuck() {
    var harness = H()
    #expect(harness.activity(writtenAt: -2400, seenAt: 0) == [])
    let first = harness.tick(at: 0, caffeinate: true)
    #expect(first == [H.busy(false, source: "caffeinate"), H.want(false)])
    #expect(harness.state.busy.busy == false)
    let second = harness.tick(at: 2, caffeinate: true)
    #expect(second == [H.stuck])
    #expect(harness.state.busy.busy == false)
    #expect((first + second).filter { $0 == H.stuck }.count == 1)
  }

  @Test("#8 no caffeinate and no recent transcripts is idle")
  func scenario08NoCaffeinateNoRecentTranscriptIsIdle() {
    var harness = H()
    #expect(harness.activity(writtenAt: -2400, seenAt: 0) == [])
    #expect(harness.tick(at: 0) == [H.busy(false, source: "transcript"), H.want(false)])
    #expect(harness.tick(at: 2) == [])
    #expect(harness.state.busy.busy == false)
  }
}
