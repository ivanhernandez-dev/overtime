import Foundation
import OvertimeCore

public enum ScreenLockReader {
  public static let executable = "/usr/sbin/sysadminctl"
  public static let arguments = ["-screenLock", "status"]

  public static func read(tools: any ToolPort) -> ScreenLockStatus {
    switch tools.run(executable, arguments) {
    case .finished(let exitCode, let stdout, let stderr):
      return ScreenLockStatus.parse(output: stdout + "\n" + stderr, exitCode: exitCode, timedOut: false)
    case .timedOut:
      return ScreenLockStatus.parse(output: "", exitCode: nil, timedOut: true)
    case .launchFailed:
      return ScreenLockStatus.parse(output: "", exitCode: nil, timedOut: false)
    }
  }
}
