import Foundation
import OvertimeAppSupport
import OvertimeClamshell
import OvertimeEngine
import OvertimeHelperClient
import OvertimeSystem
import os

enum AppMode: Equatable {
  case testHost
  case live(HeldLocks)
  case blocked(HostFailure)

  static var current: AppMode = .testHost

  var isTestHost: Bool {
    self == .testHost
  }
}

enum AppPaths {
  #if DEBUG
    static let appName = "Overtime Dev"
  #else
    static let appName = Paths.releaseAppName
  #endif

  static func primary(environment: [String: String], homeDirectory: String) -> Paths {
    Paths.resolve(environment: environment, homeDirectory: homeDirectory, appName: appName)
  }

  static func secondary(environment: [String: String], homeDirectory: String) -> Paths? {
    #if DEBUG
      Paths.resolve(environment: environment, homeDirectory: homeDirectory, appName: Paths.releaseAppName)
    #else
      nil
    #endif
  }
}

@main
enum Entry {
  static func main() {
    switch AppInvocation.parse(Array(CommandLine.arguments.dropFirst()), allowsRecordBackend: allowsRecordBackend) {
    case .usage(let message):
      FileHandle.standardError.write(Data((message + "\n").utf8))
      exit(AppInvocation.usageExitCode)
    case .reset(let choice):
      exit(reset(choice))
    case .uninstall(let purge):
      uninstall(purge: purge)
    case .app:
      break
    }
    let environment = ProcessInfo.processInfo.environment
    if environment["XCTestConfigurationFilePath"] != nil {
      AppMode.current = .testHost
      InertTestHostApp.main()
      return
    }
    guard let mode = gate(environment: environment, homeDirectory: NSHomeDirectory()) else {
      exit(0)
    }
    AppMode.current = mode
    OvertimeApp.main()
  }

  static var allowsRecordBackend: Bool {
    #if DEBUG
      true
    #else
      false
    #endif
  }

  static func reset(_ choice: ResetBackendChoice) -> Int32 {
    let paths = AppPaths.primary(environment: ProcessInfo.processInfo.environment, homeDirectory: NSHomeDirectory())
    let openClamshell: () throws -> any ClamshellPort
    var helperClear: (@Sendable () -> Bool)?
    switch choice {
    case .iokit:
      helperClear = resetHelperClear()
      openClamshell = { ClamshellBackend(writer: try ClamshellWriter.open()) }
    case .record(let path):
      #if DEBUG
        openClamshell = { RecordClamshell(path: path) }
      #else
        return AppInvocation.usageExitCode
      #endif
    }
    let socketPath = paths.controlSocket(.live).path(percentEncoded: false)
    return ResetCommand.run(
      openClamshell: openClamshell, stateFile: paths.stateFile(.live), lockFile: paths.lockFile(.live),
      out: { print($0) }, err: { FileHandle.standardError.write(Data("Overtime: \($0)\n".utf8)) },
      instanceName: Paths.releaseAppName,
      followUp: { (try? ControlClient.send(.releaseUntilIdle, socketPath: socketPath))?.ok == true },
      helperClear: helperClear)
  }

  static let uninstallQuitWaitSeconds: Double = 15

  static var uninstallTable: PurgeTable {
    #if DEBUG
      .dev
    #else
      .release
    #endif
  }

  static func uninstall(purge: Bool) -> Never {
    if let refusal = HeadlessUninstall.rootRefusal(effectiveUserID: geteuid()) {
      FileHandle.standardError.write(Data((refusal + "\n").utf8))
      exit(AppInvocation.usageExitCode)
    }
    let write: @Sendable (String) -> Void = { line in
      FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
    let table = uninstallTable
    let staging = LiveUninstallSystem.headless(table: table, identity: SMAppServiceDaemon.identity, instanceQuit: false)
    let quit = HeadlessUninstall.quitRunningInstance(
      removeStagedUpdate: { _ = staging.removeStagedUpdate(labels: table.sparkleJobLabels, cache: table.sparkleCache) },
      findInstance: { RunningInstanceLocator.otherInstance() },
      requestQuit: { target in _ = RunningInstanceLocator.requestQuit(target) },
      waitForExit: { target in ProcessWatch.waitForExit(pid: target.pid, seconds: uninstallQuitWaitSeconds) },
      write: write)
    guard quit != .stillRunning else {
      exit(ResetCommand.liveInstanceExitCode)
    }
    let system = staging.headless(instanceQuit: quit == .quit)
    let coordinator = UninstallCoordinator(system: system, table: table, mode: .headless)
    Task {
      let code = await HeadlessUninstall.run(coordinator: coordinator, system: system, purge: purge, write: write)
      exit(code)
    }
    dispatchMain()
  }

  static func resetHelperClear() -> @Sendable () -> Bool {
    let identity = SMAppServiceDaemon.identity
    return AppHost.emergencyHelperClear(installer: SMAppServiceDaemon(identity: identity)) {
      HelperXPCClient.privileged(identity: identity)
    }
  }

  nonisolated static let startupLogger = Logger(subsystem: FileLogger.logSubsystem, category: "startup")

  nonisolated static func logStartupError(_ message: String) {
    startupLogger.error("\(message, privacy: .public)")
  }

  static func gate(
    environment: [String: String], homeDirectory: String, logError: (String) -> Void = logStartupError
  ) -> AppMode? {
    let primary = AppPaths.primary(environment: environment, homeDirectory: homeDirectory)
    let secondary = AppPaths.secondary(environment: environment, homeDirectory: homeDirectory)
    do {
      try primary.createDirectories()
      try secondary?.createDirectories()
    } catch {
      logError("ERROR support directories failed reason=\(String(describing: error))")
      return .blocked(.storageUnavailable)
    }
    let resolution = InstanceGate.resolve(
      acquire: {
        InstanceGate.acquire(
          primaryLockFile: primary.lockFile(.live),
          secondaryLockFile: secondary?.lockFile(.live),
          otherInstance: RunningInstanceLocator.otherInstance
        )
      },
      open: { url in _ = ToolRunner().run("/usr/bin/open", [url.path(percentEncoded: false)]) },
      waitForExit: { pid, seconds in ProcessWatch.waitForExit(pid: pid, seconds: seconds) }
    )
    switch resolution {
    case .acquired(let locks):
      return .live(locks)
    case .blocked(let failure):
      return .blocked(failure)
    case .handedOff:
      return nil
    }
  }
}
