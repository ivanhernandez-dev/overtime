import Foundation
import OvertimeAppSupport
import OvertimeHelperCore
import OvertimeSystem

nonisolated struct AppleScriptAdminPrompt: AdminPrompt {
  static let osascript = "/usr/bin/osascript"
  static let clearCommand = "/usr/bin/pmset -a disablesleep 0"
  static let source = script(clearCommand)
  static let userCancelledErrorNumber = -128
  static let promptTimeoutSeconds: Double = 600
  static let genericFailure = "The administrator command failed."
  static let quitFailure = "Overtime quit before the administrator prompt was answered."

  let tools: any ToolPort
  let cancellation: ToolCancellation
  let identity: HelperIdentity

  init(cancellation: ToolCancellation = ToolCancellation(), identity: HelperIdentity = SMAppServiceDaemon.identity) {
    self.init(
      tools: ToolRunner(timeoutSeconds: Self.promptTimeoutSeconds, cancellation: cancellation),
      cancellation: cancellation, identity: identity)
  }

  init(
    tools: any ToolPort, cancellation: ToolCancellation = ToolCancellation(),
    identity: HelperIdentity = SMAppServiceDaemon.identity
  ) {
    self.tools = tools
    self.cancellation = cancellation
    self.identity = identity
  }

  static func purgeSource(for identity: HelperIdentity) -> String {
    script(purgeCommand(for: identity))
  }

  static func clearAndPurgeSource(for identity: HelperIdentity) -> String {
    script(clearCommand + " && " + purgeCommand(for: identity))
  }

  static func source(for command: UninstallAdminCommand, identity: HelperIdentity) -> String {
    switch command {
    case .clearSleepDisabled: source
    case .purgeRootFolders: purgeSource(for: identity)
    case .clearAndPurge: clearAndPurgeSource(for: identity)
    }
  }

  private static func purgeCommand(for identity: HelperIdentity) -> String {
    "/bin/rm -rf '" + identity.supportDirectory + "' '" + identity.logDirectory + "'"
  }

  private static func script(_ command: String) -> String {
    "do shell script \"" + command + "\" with administrator privileges"
  }

  func clearSleepDisabled() -> AdminOutcome {
    run(.clearSleepDisabled)
  }

  func run(_ command: UninstallAdminCommand) -> AdminOutcome {
    guard !cancellation.isCancelled else { return .failed(Self.quitFailure) }
    let outcome = Self.outcome(tools.run(Self.osascript, ["-e", Self.source(for: command, identity: identity)]))
    guard outcome != .succeeded, cancellation.isCancelled else { return outcome }
    return .failed(Self.quitFailure)
  }

  static func outcome(_ result: ToolOutcome) -> AdminOutcome {
    switch result {
    case .finished(exitCode: 0, _, _):
      return .succeeded
    case .finished(_, _, let stderr):
      if stderr.contains("(\(userCancelledErrorNumber))") {
        return .cancelled
      }
      return .failed(message(fromStandardError: stderr))
    case .timedOut:
      return .failed("The administrator prompt timed out.")
    case .launchFailed:
      return .failed("The administrator command couldn't be started.")
    }
  }

  static func message(fromStandardError stderr: String) -> String {
    var text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    if let marker = text.range(of: "execution error: ") {
      text = String(text[marker.upperBound...])
    }
    if let code = text.range(of: #" \(-?\d+\)$"#, options: .regularExpression) {
      text.removeSubrange(code)
    }
    return text.isEmpty ? genericFailure : text
  }
}
