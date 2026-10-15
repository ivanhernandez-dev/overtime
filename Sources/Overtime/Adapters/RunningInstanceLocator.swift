import AppKit
import OvertimeAppSupport

enum RunningInstanceLocator {
  static func otherInstance() -> HandoffTarget? {
    guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
    let candidates = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).compactMap { app in
      app.bundleURL.map { url in
        HandoffCandidate(
          target: HandoffTarget(url: url, pid: app.processIdentifier), finishedLaunching: app.isFinishedLaunching,
          terminated: app.isTerminated)
      }
    }
    return InstanceGate.handoffTarget(from: candidates, ownPID: ProcessInfo.processInfo.processIdentifier)
  }

  static func requestQuit(_ target: HandoffTarget) -> Bool {
    guard let bundleID = Bundle.main.bundleIdentifier,
      let app = NSRunningApplication(processIdentifier: target.pid),
      app.bundleIdentifier == bundleID
    else { return false }
    return app.terminate()
  }
}
