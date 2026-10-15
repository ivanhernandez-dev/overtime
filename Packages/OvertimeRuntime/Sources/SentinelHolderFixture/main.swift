import Darwin
import Foundation
import OvertimeClamshell
import OvertimeSystem

struct FixtureOptions {
  var sentinelPath = ""
  var recordPath = ""
  var logPath = ""
  var timeoutSeconds = 45
  var arm = false
  var heartbeat = true
  var disarmAfter: Int?
  var byeAfter: Int?
  var spawnChild = false
  var rearmOnTerm = false
  var closeAfter: Int?
  var stampOnTerm: String?
  var exitAfterStamp = false
  var byeOnTerm = false
  var relaunchArguments: [String] = []
}

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("SentinelHolderFixture: \(message)\n".utf8))
  exit(64)
}

func parseOptions(_ arguments: [String]) -> FixtureOptions {
  var options = FixtureOptions()
  var iterator = arguments.dropFirst().makeIterator()
  func value(_ flag: String) -> String {
    guard let next = iterator.next() else { fail("\(flag) needs a value") }
    return next
  }
  while let flag = iterator.next() {
    switch flag {
    case "--sentinel": options.sentinelPath = value(flag)
    case "--record": options.recordPath = value(flag)
    case "--log": options.logPath = value(flag)
    case "--timeout":
      guard let seconds = Int(value(flag)), seconds > 0 else { fail("invalid --timeout") }
      options.timeoutSeconds = seconds
    case "--arm": options.arm = true
    case "--no-heartbeat": options.heartbeat = false
    case "--disarm-after":
      guard let seconds = Int(value(flag)), seconds > 0 else { fail("invalid --disarm-after") }
      options.disarmAfter = seconds
    case "--bye-after":
      guard let seconds = Int(value(flag)), seconds > 0 else { fail("invalid --bye-after") }
      options.byeAfter = seconds
    case "--spawn-child": options.spawnChild = true
    case "--rearm-on-term": options.rearmOnTerm = true
    case "--close-after":
      guard let seconds = Int(value(flag)), seconds > 0 else { fail("invalid --close-after") }
      options.closeAfter = seconds
    case "--stamp-on-term": options.stampOnTerm = value(flag)
    case "--exit-after-stamp": options.exitAfterStamp = true
    case "--bye-on-term": options.byeOnTerm = true
    case RelaunchFlags.app, RelaunchFlags.history, RelaunchFlags.suppress:
      options.relaunchArguments += [flag, value(flag)]
    case "--relaunch-record":
      options.relaunchArguments += [RelaunchFlags.spawner, "record:\(value(flag))"]
    default: fail("unknown argument \(flag)")
    }
  }
  guard !options.sentinelPath.isEmpty, !options.recordPath.isEmpty, !options.logPath.isEmpty else {
    fail("--sentinel, --record and --log are required")
  }
  return options
}

func emit(_ line: String) {
  print(line)
  fflush(stdout)
}

func report(_ result: SentinelSendResult) {
  if case .lost(let code) = result { emit("LOST \(code)") }
}

func handlesTerm(_ options: FixtureOptions) -> Bool {
  options.rearmOnTerm || options.stampOnTerm != nil || options.byeOnTerm
}

func installTermHandler(_ options: FixtureOptions, link: SentinelLink) -> (any DispatchSourceSignal)? {
  guard handlesTerm(options) else { return nil }
  signal(SIGTERM, SIG_IGN)
  let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: DispatchQueue(label: "fixture.term"))
  source.setEventHandler { handleTerm(options, link: link) }
  source.resume()
  return source
}

func handleTerm(_ options: FixtureOptions, link: SentinelLink) {
  if options.rearmOnTerm {
    report(link.send(.arm))
    emit("REARMED")
  }
  if let stampPath = options.stampOnTerm {
    let descriptor = open(stampPath, O_WRONLY | O_CREAT | O_CLOEXEC, 0o600)
    if descriptor >= 0 {
      futimes(descriptor, nil)
      close(descriptor)
    }
    emit("STAMPED")
  }
  if options.byeOnTerm {
    report(link.send(.bye))
    link.close()
    emit("BYE SENT")
    usleep(500_000)
    exit(0)
  }
  if options.stampOnTerm != nil && options.exitAfterStamp { exit(0) }
}

if CommandLine.arguments.dropFirst().first == RespawnScenario.command {
  RespawnScenario.run(CommandLine.arguments)
}
let options = parseOptions(CommandLine.arguments)
let link = SentinelLink(
  executableURL: URL(fileURLWithPath: options.sentinelPath),
  timeoutSeconds: options.timeoutSeconds,
  logURL: URL(fileURLWithPath: options.logPath),
  extraArguments: ["--clear-backend", "record:\(options.recordPath)"] + options.relaunchArguments)
do {
  try link.start()
} catch {
  fail("cannot start the sentinel: \(error)")
}
let termSource = installTermHandler(options, link: link)
if options.arm { report(link.send(.arm)) }
if options.spawnChild {
  let child = Process()
  child.executableURL = URL(fileURLWithPath: "/bin/sleep")
  child.arguments = ["60"]
  do {
    try child.run()
  } catch {
    fail("cannot start the child: \(error)")
  }
  emit("CHILD \(child.processIdentifier)")
}
emit("READY parent=\(getpid()) sentinel=\(link.processIdentifier ?? 0)")

var elapsed = 0
while true {
  sleep(1)
  elapsed += 1
  if elapsed == options.disarmAfter { report(link.send(.disarm)) }
  if elapsed == options.byeAfter { report(link.send(.bye)) }
  if elapsed == options.closeAfter {
    link.close()
    emit("CLOSED")
  }
  if options.heartbeat { report(link.send(.heartbeat)) }
}
