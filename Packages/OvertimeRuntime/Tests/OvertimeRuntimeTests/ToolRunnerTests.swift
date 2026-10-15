import Foundation
import OvertimeCore
import OvertimeSystem
import Testing
import os

struct ToolRunnerTests {
  @Test func echoFinishesWithItsOutput() {
    #expect(
      ToolRunner(timeoutSeconds: 5).run("/bin/echo", ["hi"]) == .finished(exitCode: 0, stdout: "hi\n", stderr: ""))
  }

  @Test func stderrAndTheExitCodeAreCapturedSeparately() {
    let outcome = ToolRunner(timeoutSeconds: 5).run("/bin/sh", ["-c", "echo err 1>&2; exit 3"])
    #expect(outcome == .finished(exitCode: 3, stdout: "", stderr: "err\n"))
  }

  @Test func largeOutputIsDrainedWithoutAPipeDeadlock() {
    let outcome = ToolRunner(timeoutSeconds: 5).run("/bin/sh", ["-c", "head -c 300000 /dev/zero | tr '\\0' a"])
    guard case .finished(let code, let stdout, let stderr) = outcome else {
      Issue.record("expected finished, got \(outcome)")
      return
    }
    #expect(code == 0)
    #expect(stdout.utf8.count == 300_000)
    #expect(stdout.utf8.allSatisfy { $0 == UInt8(ascii: "a") })
    #expect(stderr.isEmpty)
  }

  static let ceilingSeconds: Double = 10
  static let mustFinishSeconds: Double = 60

  static func timed(_ work: @escaping @Sendable () -> ToolOutcome) async -> (ToolOutcome?, Duration) {
    let started = ContinuousClock.now
    let outcome = await OffPool.bounded(seconds: mustFinishSeconds, work)
    return (outcome, ContinuousClock.now - started)
  }

  @Test func aHungToolTimesOutQuicklyAndIsKilled() async throws {
    let temp = try TempDirectory()
    let pidFile = temp.url.appendingPathComponent("pid").path(percentEncoded: false)
    let (outcome, elapsed) = await Self.timed {
      ToolRunner(timeoutSeconds: 0.5).run("/bin/sh", ["-c", "echo $$ > '\(pidFile)'; exec /bin/sleep 30"])
    }
    #expect(outcome == .timedOut)
    #expect(elapsed < .seconds(Self.ceilingSeconds))
    let text = try String(contentsOfFile: pidFile, encoding: .utf8)
    let pid = try #require(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    #expect(kill(pid, 0) == -1 && errno == ESRCH)
  }

  @Test func aToolThatIgnoresSIGTERMIsKilled() async throws {
    let temp = try TempDirectory()
    let pidFile = temp.url.appendingPathComponent("pid").path(percentEncoded: false)
    let script = "trap '' TERM; echo $$ > '\(pidFile)'; while :; do /bin/sleep 0.05; done"
    let (outcome, elapsed) = await Self.timed { ToolRunner(timeoutSeconds: 0.5).run("/bin/sh", ["-c", script]) }
    #expect(outcome == .timedOut)
    #expect(elapsed < .seconds(Self.ceilingSeconds))
    let text = try String(contentsOfFile: pidFile, encoding: .utf8)
    let pid = try #require(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    #expect(kill(pid, 0) == -1 && errno == ESRCH)
  }

  @Test func aCancelledToolIsKilledAtOnceAndLaterRunsNeverOutliveTheCancellation() async throws {
    let temp = try TempDirectory()
    let pidFile = temp.url.appendingPathComponent("pid").path(percentEncoded: false)
    let cancellation = ToolCancellation()
    let runner = ToolRunner(timeoutSeconds: Self.mustFinishSeconds, cancellation: cancellation)
    let running = Task {
      await OffPool.bounded(seconds: Self.mustFinishSeconds) {
        runner.run("/bin/sh", ["-c", "trap '' TERM; echo $$ > '\(pidFile)'; exec /bin/sleep 60"])
      }
    }
    #expect(await OffPool.eventually(seconds: 10) { FileManager.default.fileExists(atPath: pidFile) })
    let text = try String(contentsOfFile: pidFile, encoding: .utf8)
    let pid = try #require(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    #expect(!cancellation.isCancelled)
    let cancelledAt = ContinuousClock.now
    cancellation.cancel()
    let result = await running.value
    #expect(ContinuousClock.now - cancelledAt < .seconds(Self.ceilingSeconds))
    guard case .finished(let code, _, _) = result else {
      Issue.record("expected finished")
      return
    }
    #expect(code == SIGKILL)
    #expect(kill(pid, 0) == -1 && errno == ESRCH)
    #expect(cancellation.isCancelled)

    let (later, elapsed) = await Self.timed { runner.run("/bin/sleep", ["60"]) }
    guard case .finished(let laterCode, _, _) = later else {
      Issue.record("expected finished")
      return
    }
    #expect(laterCode == SIGKILL)
    #expect(elapsed < .seconds(Self.ceilingSeconds))
  }

  @Test func aMissingExecutableFailsToLaunch() {
    guard case .launchFailed = ToolRunner(timeoutSeconds: 5).run("/nonexistent/overtime-tool", []) else {
      Issue.record("expected launchFailed")
      return
    }
  }

  @Test func theDefaultTimeoutIsTheSystemCallBound() {
    #expect(ToolRunner().timeoutSeconds == Timing.systemCallTimeoutSeconds)
  }
}
