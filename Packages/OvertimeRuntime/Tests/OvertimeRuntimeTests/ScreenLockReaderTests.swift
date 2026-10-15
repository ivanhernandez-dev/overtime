import Foundation
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing

struct ScreenLockReaderTests {
  static let stderrLine = "2026-09-27 01:00:16.163 sysadminctl[53534:12172306] screenLock delay is 5 seconds\n"

  @Test func theReaderRunsExactlyTheStatusQueryWithoutAPassword() {
    let tools = FakeToolPort(outcome: .finished(exitCode: 0, stdout: "", stderr: Self.stderrLine))
    #expect(ScreenLockReader.read(tools: tools) == .delayed(seconds: 5))
    #expect(
      tools.calls == [FakeToolPort.Call(executable: "/usr/sbin/sysadminctl", arguments: ["-screenLock", "status"])])
    #expect(tools.calls.allSatisfy { !$0.arguments.contains("-password") })
  }

  @Test func stdoutAndStderrAreBothRead() {
    let tools = FakeToolPort(outcome: .finished(exitCode: 0, stdout: "screenLock is off\n", stderr: ""))
    #expect(ScreenLockReader.read(tools: tools) == .off)
  }

  @Test func aTimeoutALaunchFailureOrANonZeroExitIsUnknown() {
    #expect(ScreenLockReader.read(tools: FakeToolPort(outcome: .timedOut)) == .unknown)
    #expect(ScreenLockReader.read(tools: FakeToolPort(outcome: .launchFailed("no"))) == .unknown)
    let failed = FakeToolPort(outcome: .finished(exitCode: 1, stdout: "", stderr: "screenLock delay is immediate"))
    #expect(ScreenLockReader.read(tools: failed) == .unknown)
  }

  @Test func theLiveEngineStepsTheStatusRightAfterLaunch() async throws {
    let temp = try TempDirectory()
    let paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path], homeDirectory: temp.path)
    let recorder = HoldRecorder(stateFile: paths.stateFile(.live))
    let tools = FakeToolPort(outcome: .finished(exitCode: 0, stdout: "", stderr: "screenLock is off\n"))
    let engine = try Composition.makeLiveEngine(
      paths: paths,
      settings: Settings(transcriptRoots: [temp.path + "/projects"]),
      ports: LivePorts(
        assertions: FakeAssertionPort(), tools: tools, clamshell: FakeClamshellPort(recorder: recorder),
        stateFile: paths.stateFile(.live), makeSentinel: { [recorder] in FakeSentinelPort(recorder: recorder) }),
      environment: [:],
      homeDirectory: temp.path,
      once: true,
      clock: FakeClock()
    )
    await engine.runOnce()
    #expect(
      tools.calls.first == FakeToolPort.Call(executable: "/usr/sbin/sysadminctl", arguments: ["-screenLock", "status"]))
    let text = try String(contentsOf: paths.decisionLog(.live), encoding: .utf8)
    #expect(text.components(separatedBy: " WARN screenLock reason=off").count == 2)
    #expect(await engine.state.screenLockWarned)
  }
}
