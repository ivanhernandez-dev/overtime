import Foundation
import OvertimeClamshell
import OvertimeCore
import OvertimeEngine
import OvertimeSystem

func installStopHandlers(for engine: Engine) -> [any DispatchSourceSignal] {
  let queue = DispatchQueue(label: "io.github.ivanhernandez-dev.overtime.signals")
  return [SIGINT, SIGTERM].map { number in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
    source.setEventHandler {
      Task { await engine.stop() }
    }
    source.resume()
    return source
  }
}

let invocation: Invocation
do {
  invocation = try CommandLineOptions.parseInvocation(Array(CommandLine.arguments.dropFirst()))
} catch CommandLineError.usage(let message) {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(64)
} catch {
  FileHandle.standardError.write(Data((CommandLineOptions.usageMessage + "\n").utf8))
  exit(64)
}

let environment = ProcessInfo.processInfo.environment
let homeDirectory = NSHomeDirectory()
let paths = Paths.resolve(environment: environment, homeDirectory: homeDirectory)

func runCtl(_ ctl: CtlOptions) -> Int32 {
  do {
    let response = try ControlClient.send(
      ctl.request, socketPath: paths.controlSocket(ctl.mode).path(percentEncoded: false))
    FileHandle.standardOutput.write(ControlProtocol.encodeLine(response))
    return response.ok ? 0 : 1
  } catch ControlSocketError.notRunning {
    FileHandle.standardError.write(Data("overtimed (\(ctl.mode.rawValue)) is not running\n".utf8))
    return 69
  } catch {
    FileHandle.standardError.write(Data("overtimed: ctl failed: \(error)\n".utf8))
    return 1
  }
}

let options: CommandLineOptions
switch invocation {
case .ctl(let ctlOptions):
  exit(runCtl(ctlOptions))
case .status(let mode):
  print(StatusReport.json(StateStore.read(at: paths.stateFile(mode))))
  exit(0)
case .reset:
  let writer: ClamshellWriter
  do {
    writer = try ClamshellWriter.open()
  } catch {
    FileHandle.standardError.write(Data("overtimed: cannot open the clamshell writer: \(error)\n".utf8))
    exit(71)
  }
  let socketPath = paths.controlSocket(.live).path(percentEncoded: false)
  exit(
    ResetCommand.run(
      clamshell: ClamshellBackend(writer: writer), stateFile: paths.stateFile(.live),
      lockFile: paths.lockFile(.live), out: { print($0) },
      followUp: { (try? ControlClient.send(.releaseUntilIdle, socketPath: socketPath))?.ok == true }))
case .engine(let engineOptions):
  options = engineOptions
}

var fileSettings = Settings()
var settingsProblem: String?
switch SettingsStore.load(from: paths.settingsFile) {
case .missing:
  break
case .loaded(let loaded):
  fileSettings = loaded
case .invalid(let reason):
  settingsProblem = reason
}
let mergedSettings = options.overrides.applied(to: fileSettings)
if let problem = SettingsStore.validationProblem(mergedSettings) {
  FileHandle.standardError.write(
    Data("overtimed: invalid settings: \(problem)\n\(CommandLineOptions.usageMessage)\n".utf8))
  exit(64)
}
let (settings, settingsAdjustments) = mergedSettings.validated()
let roots = settings.resolvedTranscriptRoots(environment: environment, homeDirectory: homeDirectory)

let instance: RunningInstance
do {
  switch options.mode {
  case .shadow:
    instance = try Composition.launchShadow(
      paths: paths, settings: settings, environment: environment, homeDirectory: homeDirectory, once: options.once)
  case .live:
    instance = try Composition.launchLive(
      paths: paths, settings: settings, ports: try LivePorts.system(paths: paths), environment: environment,
      homeDirectory: homeDirectory, once: options.once)
  }
} catch CompositionError.sentinelUnavailable(let reason) {
  FileHandle.standardError.write(Data("overtimed: cannot start the sentinel: \(reason)\n".utf8))
  exit(70)
} catch CompositionError.alreadyRunning(let mode) {
  FileHandle.standardError.write(Data("overtimed (\(mode.rawValue)) is already running\n".utf8))
  exit(75)
} catch {
  FileHandle.standardError.write(Data("overtimed: cannot start: \(error)\n".utf8))
  exit(1)
}
let engine = instance.engine

await engine.logLine(
  Decision(
    keyword: .start,
    verb: options.mode.rawValue,
    fields: [
      DecisionField(key: "once", value: options.once ? "true" : "false"),
      DecisionField(key: "roots", value: String(roots.count)),
      DecisionField(key: "ignored", value: settings.ignoredEntrypoints.joined(separator: ",")),
    ]
  ))

for adjustment in settingsAdjustments {
  await engine.logLine(adjustment.decision)
}

if let settingsProblem {
  await engine.logLine(
    Decision(keyword: .error, verb: "settings invalid", fields: [DecisionField(key: "reason", value: settingsProblem)]))
}

if options.once {
  await instance.runOnceAndFinish()
  exit(0)
}

let stopHandlers = installStopHandlers(for: engine)
await engine.run()
instance.shutdown()
withExtendedLifetime(stopHandlers) {}
exit(0)
