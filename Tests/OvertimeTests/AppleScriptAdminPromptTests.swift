import Foundation
import OvertimeAppSupport
import OvertimeHelperCore
import OvertimeSystem
import Testing
import os

@testable import Overtime

@MainActor
struct AppleScriptAdminPromptTests {
  struct Call: Equatable {
    let executable: String
    let arguments: [String]
    let onMainThread: Bool
  }

  final class HeldTools: ToolPort {
    private let gate: DispatchSemaphore?
    private let result: ToolOutcome
    private let recorded = OSAllocatedUnfairLock<[Call]>(initialState: [])

    init(result: ToolOutcome, gate: DispatchSemaphore? = nil) {
      self.result = result
      self.gate = gate
    }

    var calls: [Call] {
      recorded.withLock { $0 }
    }

    func run(_ executable: String, _ arguments: [String]) -> ToolOutcome {
      recorded.withLock {
        $0.append(Call(executable: executable, arguments: arguments, onMainThread: Thread.isMainThread))
      }
      _ = gate?.wait(timeout: .now() + 10)
      return result
    }
  }

  @Test func theCommandIsTheFixedSourcePassedToOsascriptAsOneArgument() {
    #expect(
      AppleScriptAdminPrompt.source
        == "do shell script \"/usr/bin/pmset -a disablesleep 0\" with administrator privileges")
    let tools = HeldTools(result: .finished(exitCode: 0, stdout: "", stderr: ""))
    #expect(AppleScriptAdminPrompt(tools: tools).clearSleepDisabled() == .succeeded)
    #expect(tools.calls.map(\.executable) == ["/usr/bin/osascript"])
    #expect(tools.calls.map(\.arguments) == [["-e", AppleScriptAdminPrompt.source]])
  }

  @Test func anOpenPasswordDialogLeavesTheMainThreadResponsive() async {
    let gate = DispatchSemaphore(value: 0)
    let tools = HeldTools(result: .finished(exitCode: 0, stdout: "", stderr: ""), gate: gate)
    let prompt = AppleScriptAdminPrompt(tools: tools)
    let outcome = Task.detached { prompt.clearSleepDisabled() }
    #expect(await waitUntil { tools.calls.count == 1 })
    try? await Task.sleep(for: .milliseconds(100))
    #expect(tools.calls.count == 1)
    gate.signal()
    #expect(await outcome.value == .succeeded)
    #expect(tools.calls.map(\.onMainThread) == [false])
  }

  final class DialogUntilQuit: ToolPort {
    let cancellation: ToolCancellation
    let result: ToolOutcome
    private let recorded = OSAllocatedUnfairLock(initialState: 0)

    init(cancellation: ToolCancellation, result: ToolOutcome = .finished(exitCode: SIGKILL, stdout: "", stderr: "")) {
      self.cancellation = cancellation
      self.result = result
    }

    var calls: Int {
      recorded.withLock { $0 }
    }

    func run(_ executable: String, _ arguments: [String]) -> ToolOutcome {
      recorded.withLock { $0 += 1 }
      let deadline = Date(timeIntervalSinceNow: 10)
      while !cancellation.isCancelled && Date() < deadline {
        usleep(10_000)
      }
      return result
    }
  }

  @Test func aQuitWhileTheDialogIsOpenEndsThePromptAsAFailureNamingTheQuit() async {
    let cancellation = ToolCancellation()
    let tools = DialogUntilQuit(cancellation: cancellation)
    let prompt = AppleScriptAdminPrompt(tools: tools, cancellation: cancellation)
    let outcome = Task.detached { prompt.clearSleepDisabled() }
    #expect(await waitUntil { tools.calls == 1 })
    cancellation.cancel()
    #expect(await outcome.value == .failed(AppleScriptAdminPrompt.quitFailure))
    #expect(prompt.clearSleepDisabled() == .failed(AppleScriptAdminPrompt.quitFailure))
    #expect(tools.calls == 1)
  }

  @Test func aPromptThatSucceededJustBeforeTheQuitStillCountsAsSucceeded() {
    let cancellation = ToolCancellation()
    let tools = HeldTools(result: .finished(exitCode: 0, stdout: "", stderr: ""))
    let prompt = AppleScriptAdminPrompt(tools: tools, cancellation: cancellation)
    #expect(prompt.clearSleepDisabled() == .succeeded)
    cancellation.cancel()
    #expect(AppleScriptAdminPrompt(tools: tools).clearSleepDisabled() == .succeeded)
  }

  nonisolated static let releasePurge =
    "do shell script \"/bin/rm -rf '/Library/Application Support/Overtime' '/Library/Logs/Overtime'\""
    + " with administrator privileges"
  nonisolated static let releaseClearAndPurge =
    "do shell script \"/usr/bin/pmset -a disablesleep 0 && "
    + "/bin/rm -rf '/Library/Application Support/Overtime' '/Library/Logs/Overtime'\""
    + " with administrator privileges"
  nonisolated static let devPurge =
    "do shell script \"/bin/rm -rf '/Library/Application Support/Overtime Dev' '/Library/Logs/Overtime Dev'\""
    + " with administrator privileges"
  nonisolated static let devClearAndPurge =
    "do shell script \"/usr/bin/pmset -a disablesleep 0 && "
    + "/bin/rm -rf '/Library/Application Support/Overtime Dev' '/Library/Logs/Overtime Dev'\""
    + " with administrator privileges"
  nonisolated static let clear = "do shell script \"/usr/bin/pmset -a disablesleep 0\" with administrator privileges"

  @Test func thePurgeAndTheClearAndPurgeAreFixedForTheReleaseIdentity() {
    #expect(AppleScriptAdminPrompt.purgeSource(for: .release) == Self.releasePurge)
    #expect(AppleScriptAdminPrompt.clearAndPurgeSource(for: .release) == Self.releaseClearAndPurge)
  }

  @Test func thePurgeAndTheClearAndPurgeAreFixedForTheDevIdentity() {
    #expect(AppleScriptAdminPrompt.purgeSource(for: .dev) == Self.devPurge)
    #expect(AppleScriptAdminPrompt.clearAndPurgeSource(for: .dev) == Self.devClearAndPurge)
  }

  @Test(arguments: [
    (UninstallAdminCommand.clearSleepDisabled, HelperIdentity.release, clear),
    (.purgeRootFolders, .release, releasePurge),
    (.clearAndPurge, .release, releaseClearAndPurge),
    (.clearSleepDisabled, .dev, clear),
    (.purgeRootFolders, .dev, devPurge),
    (.clearAndPurge, .dev, devClearAndPurge),
  ])
  func eachUninstallCommandMapsToItsFixedSource(
    command: UninstallAdminCommand, identity: HelperIdentity, expected: String
  ) {
    #expect(AppleScriptAdminPrompt.source(for: command, identity: identity) == expected)
  }

  @Test func theCommandListCoversEveryUninstallCommandWithDistinctSources() {
    for identity in [HelperIdentity.release, .dev] {
      let sources = UninstallAdminCommand.allCases.map { AppleScriptAdminPrompt.source(for: $0, identity: identity) }
      #expect(Set(sources).count == UninstallAdminCommand.allCases.count)
    }
    #expect(UninstallAdminCommand.allCases.count == 3)
  }

  @Test func thePromptActsOnTheConfigurationsIdentityByDefault() {
    let tools = HeldTools(result: .finished(exitCode: 0, stdout: "", stderr: ""))
    #expect(AppleScriptAdminPrompt(tools: tools).identity == SMAppServiceDaemon.identity)
    #expect(AppleScriptAdminPrompt().identity == SMAppServiceDaemon.identity)
    #expect(SMAppServiceDaemon.identity == .dev)
    #expect(tools.calls.isEmpty)
  }

  @Test(arguments: [HelperIdentity.release, .dev])
  func runPassesTheFixedPurgeSourceToOsascriptAsOneArgument(identity: HelperIdentity) {
    let tools = HeldTools(result: .finished(exitCode: 0, stdout: "", stderr: ""))
    let prompt = AppleScriptAdminPrompt(tools: tools, identity: identity)
    #expect(prompt.run(.purgeRootFolders) == .succeeded)
    #expect(prompt.run(.clearAndPurge) == .succeeded)
    #expect(prompt.run(.clearSleepDisabled) == .succeeded)
    #expect(tools.calls.map(\.executable) == Array(repeating: "/usr/bin/osascript", count: 3))
    #expect(
      tools.calls.map(\.arguments) == [
        ["-e", AppleScriptAdminPrompt.purgeSource(for: identity)],
        ["-e", AppleScriptAdminPrompt.clearAndPurgeSource(for: identity)],
        ["-e", Self.clear],
      ])
  }

  @Test(arguments: [
    (ToolOutcome.finished(exitCode: 0, stdout: "", stderr: ""), AdminOutcome.succeeded),
    (.finished(exitCode: 1, stdout: "", stderr: "0:120: execution error: User canceled. (-128)\n"), .cancelled),
    (
      .finished(exitCode: 1, stdout: "", stderr: "0:120: execution error: rm: Operation not permitted (1)\n"),
      .failed("rm: Operation not permitted")
    ),
    (.timedOut, .failed("The administrator prompt timed out.")),
  ])
  func runMapsThePurgeResult(result: ToolOutcome, expected: AdminOutcome) {
    let prompt = AppleScriptAdminPrompt(tools: HeldTools(result: result), identity: .release)
    #expect(prompt.run(.purgeRootFolders) == expected)
  }

  @Test(arguments: UninstallAdminCommand.allCases)
  func aCancelledPromptFailsWithoutRunningTheTool(command: UninstallAdminCommand) {
    let cancellation = ToolCancellation()
    cancellation.cancel()
    let tools = HeldTools(result: .finished(exitCode: 0, stdout: "", stderr: ""))
    let prompt = AppleScriptAdminPrompt(tools: tools, cancellation: cancellation, identity: .release)
    #expect(prompt.run(command) == .failed(AppleScriptAdminPrompt.quitFailure))
    #expect(tools.calls.isEmpty)
  }

  @Test(arguments: [
    (ToolOutcome.finished(exitCode: 0, stdout: "", stderr: ""), AdminOutcome.succeeded),
    (.finished(exitCode: 1, stdout: "", stderr: "0:93: execution error: User canceled. (-128)\n"), .cancelled),
    (
      .finished(
        exitCode: 1, stdout: "",
        stderr: "0:93: execution error: The administrator user name or password was incorrect. (-60007)\n"),
      .failed("The administrator user name or password was incorrect.")
    ),
    (.finished(exitCode: 1, stdout: "", stderr: ""), .failed(AppleScriptAdminPrompt.genericFailure)),
    (.timedOut, .failed("The administrator prompt timed out.")),
    (.launchFailed("no such file"), .failed("The administrator command couldn't be started.")),
  ])
  func osascriptResultsMapToAdminOutcomes(result: ToolOutcome, expected: AdminOutcome) {
    #expect(AppleScriptAdminPrompt.outcome(result) == expected)
  }
}
