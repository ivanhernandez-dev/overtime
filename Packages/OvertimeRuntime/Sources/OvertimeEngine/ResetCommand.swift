import Foundation
import OvertimeCore
import OvertimeSystem

public enum ResetCommand {
  public static let liveInstanceExitCode: Int32 = 75
  public static let clamshellUnavailableExitCode: Int32 = 71

  public static func run(
    clamshell: any ClamshellPort,
    stateFile: URL,
    lockFile: URL,
    timeoutSeconds: Double = Timing.systemCallTimeoutSeconds,
    out: (String) -> Void,
    instanceName: String = "overtimed",
    followUp: (@Sendable () -> Bool)? = nil,
    helperClear: (@Sendable () -> Bool)? = nil
  ) -> Int32 {
    run(
      openClamshell: { clamshell }, stateFile: stateFile, lockFile: lockFile, timeoutSeconds: timeoutSeconds,
      out: out, err: { _ in }, instanceName: instanceName, followUp: followUp, helperClear: helperClear)
  }

  public static func run(
    openClamshell: () throws -> any ClamshellPort,
    stateFile: URL,
    lockFile: URL,
    timeoutSeconds: Double = Timing.systemCallTimeoutSeconds,
    out: (String) -> Void,
    err: (String) -> Void,
    instanceName: String = "overtimed",
    followUp: (@Sendable () -> Bool)? = nil,
    helperClear: (@Sendable () -> Bool)? = nil
  ) -> Int32 {
    let helperCleared = clearHelper(helperClear, timeoutSeconds: timeoutSeconds)
    if !helperCleared {
      out(helperUnconfirmedMessage)
    }
    let clamshell: any ClamshellPort
    do {
      clamshell = try openClamshell()
    } catch {
      err("cannot open the clamshell writer: \(error)")
      return clamshellUnavailableExitCode
    }
    let lock: InstanceLock?
    var liveInstance = false
    do {
      lock = try InstanceLock.acquire(at: lockFile)
    } catch InstanceLockError.alreadyRunning {
      lock = nil
      liveInstance = true
    } catch {
      lock = nil
    }
    defer { lock?.release() }
    let outcome = DeadlineRunner().run(timeout: timeoutSeconds) { clamshell.write(on: false) }
    switch outcome {
    case .value(.succeeded):
      break
    case .value(.failed(let code)):
      out("reset: clear failed (code \(code))")
      return 1
    case .value(.timedOut), .timedOut:
      out("reset: clear failed (timed out)")
      return 1
    }
    out("reset: clamshell cleared")
    let success: Int32 = helperCleared ? 0 : 1
    guard !liveInstance else {
      out(liveInstanceMessage(instanceName: instanceName, released: followUp?() == true))
      return helperCleared ? liveInstanceExitCode : success
    }
    guard lock != nil else {
      out("reset: state file not updated: cannot take the instance lock")
      return success
    }
    guard case .state(var persisted) = StateStore.read(at: stateFile) else { return success }
    persisted.ownsHold = false
    persisted.sentinelArmed = false
    do {
      try StateStore.write(persisted, to: stateFile)
    } catch {
      out("reset: state file not updated: \(error)")
    }
    return success
  }

  static let helperUnconfirmedMessage =
    "reset: unplug protection didn't confirm that system sleep is back on. If the Mac won't sleep, run: "
    + "sudo pmset -a disablesleep 0"

  static func clearHelper(_ helperClear: (@Sendable () -> Bool)?, timeoutSeconds: Double) -> Bool {
    guard let helperClear else { return true }
    return DeadlineRunner().run(timeout: timeoutSeconds) { helperClear() } == .value(true)
  }

  static func liveInstanceMessage(instanceName: String, released: Bool) -> String {
    if released {
      return "reset: a live \(instanceName) is running; it was sent Release until idle, so it will not re-assert its "
        + "hold until Claude goes idle. The state file was left alone."
    }
    let advice =
      instanceName == "overtimed"
      ? "Run `overtimed ctl pause` or stop it first." : "Choose Pause in its menu or quit it first."
    return "reset: a live \(instanceName) is running and will re-assert its hold; the state file was left alone. "
      + advice
  }
}
