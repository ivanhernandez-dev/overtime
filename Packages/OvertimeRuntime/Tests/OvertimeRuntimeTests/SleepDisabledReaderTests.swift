import Foundation
import OvertimeAppSupport
import OvertimeSystem
import Testing

struct SleepDisabledReaderTests {
  @Test(arguments: [
    (ToolOutcome.finished(exitCode: 0, stdout: " SleepDisabled\t\t1\n", stderr: ""), Optional(true)),
    (ToolOutcome.finished(exitCode: 0, stdout: " SleepDisabled\t\t0\n", stderr: ""), Optional(false)),
    (ToolOutcome.finished(exitCode: 0, stdout: "SleepDisabled 1", stderr: ""), Optional(true)),
    (ToolOutcome.finished(exitCode: 0, stdout: " hibernatemode 3\n", stderr: ""), Optional(false)),
    (ToolOutcome.finished(exitCode: 1, stdout: "SleepDisabled 1", stderr: ""), nil),
    (ToolOutcome.timedOut, nil),
    (ToolOutcome.launchFailed("missing"), nil),
  ])
  func theParserReadsOnlyTheSleepDisabledLineOfASuccessfulRead(_ outcome: ToolOutcome, _ expected: Bool?) {
    #expect(SleepDisabledReader.parse(outcome) == expected)
    #expect(SleepDisabledReader.pmset == "/usr/bin/pmset")
  }

  @Test(arguments: [
    (ToolOutcome.finished(exitCode: 0, stdout: " SleepDisabled\t\t1\n", stderr: ""), Optional(true)),
    (ToolOutcome.finished(exitCode: 0, stdout: " SleepDisabled\t\t0\n", stderr: ""), Optional(false)),
    (ToolOutcome.finished(exitCode: 0, stdout: " hibernatemode 3\n", stderr: ""), Optional(false)),
    (ToolOutcome.finished(exitCode: 1, stdout: "", stderr: "denied"), nil),
    (ToolOutcome.timedOut, nil),
  ])
  func theReaderRunsAReadOnlyPmsetGet(_ outcome: ToolOutcome, _ expected: Bool?) {
    let tools = FakeToolPort(outcome: outcome)
    #expect(SleepDisabledReader.read(tools: tools) == expected)
    #expect(tools.calls == [FakeToolPort.Call(executable: "/usr/bin/pmset", arguments: ["-g"])])
  }
}
