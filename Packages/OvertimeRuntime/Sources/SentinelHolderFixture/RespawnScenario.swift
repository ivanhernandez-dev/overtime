import Darwin
import Foundation
import OvertimeClamshell
import OvertimeCore
import OvertimeEngine
import OvertimeSystem

enum RespawnScenario {
  enum Pause: String {
    case starting, ready, armed, retiring, done
  }

  struct Options {
    var sentinelPath = ""
    var directory = ""
    var pause = Pause.done
    var oldClearFails = false
  }

  static let command = "respawn"

  static func run(_ arguments: [String]) -> Never {
    let options = parse(arguments)
    Task.detached { await perform(options) }
    dispatchMain()
  }

  static func parse(_ arguments: [String]) -> Options {
    var options = Options()
    var iterator = arguments.dropFirst(2).makeIterator()
    func value(_ flag: String) -> String {
      guard let next = iterator.next() else { fail("\(flag) needs a value") }
      return next
    }
    while let flag = iterator.next() {
      switch flag {
      case "--sentinel": options.sentinelPath = value(flag)
      case "--dir": options.directory = value(flag)
      case "--pause":
        guard let pause = Pause(rawValue: value(flag)) else { fail("invalid --pause") }
        options.pause = pause
      case "--old-clear-fails": options.oldClearFails = true
      default: fail("unknown argument \(flag)")
      }
    }
    guard !options.sentinelPath.isEmpty, !options.directory.isEmpty else { fail("--sentinel and --dir are required") }
    return options
  }

  static func link(_ options: Options, role: String, record: String, extra: [String] = []) -> SentinelLink {
    SentinelLink(
      executableURL: URL(fileURLWithPath: options.sentinelPath),
      timeoutSeconds: 3_600,
      logURL: URL(fileURLWithPath: options.directory + "/\(role).log"),
      extraArguments: ["--clear-backend", "record:\(record)"] + extra)
  }

  static func perform(_ options: Options) async {
    let directory = options.directory
    let oldRecord = options.oldClearFails ? directory + "/missing/old.record" : directory + "/old.record"
    let old = ObservedSentinel(
      link: link(options, role: "old", record: oldRecord, extra: ["--clear-budget", "5"]), role: "old",
      pause: options.pause)
    do {
      try old.start()
    } catch {
      fail("cannot start the old sentinel: \(error)")
    }
    report(old.send(.arm))
    let logger: FileLogger
    do {
      logger = try FileLogger(
        decisionLog: URL(fileURLWithPath: directory + "/decisions.log"),
        errorLog: URL(fileURLWithPath: directory + "/errors.log"))
    } catch {
      fail("cannot open the fixture log: \(error)")
    }
    let fresh = link(options, role: "fresh", record: directory + "/fresh.record")
    let ports = LivePorts(
      assertions: InertAssertions(), tools: InertTools(), clamshell: InertClamshell(),
      stateFile: URL(fileURLWithPath: directory + "/state.json"),
      makeSentinel: { ObservedSentinel(link: fresh, role: "fresh", pause: options.pause) })
    let interpreter = LiveInterpreter(ports: ports, logger: logger, sentinel: old)
    _ = await interpreter.enqueue([.sentinel(.respawn), .sentinel(.arm)], wall: Date()).value
    pauseForever(.done, options.pause)
  }

  static func pauseForever(_ phase: Pause, _ chosen: Pause) {
    guard phase == chosen else { return }
    emit("PAUSED \(phase.rawValue)")
    while true { sleep(60) }
  }
}

final class ObservedSentinel: SentinelPort {
  let link: SentinelLink
  let role: String
  let pause: RespawnScenario.Pause

  init(link: SentinelLink, role: String, pause: RespawnScenario.Pause) {
    self.link = link
    self.role = role
    self.pause = pause
  }

  var isFresh: Bool { role == "fresh" }

  func start() throws {
    if isFresh { RespawnScenario.pauseForever(.starting, pause) }
    try link.start()
    emit("SENTINEL \(role) \(link.processIdentifier ?? 0)")
    if isFresh { RespawnScenario.pauseForever(.ready, pause) }
  }

  func send(_ line: SentinelLine) -> SentinelSendResult {
    let result = link.send(line)
    if isFresh && line == .arm { RespawnScenario.pauseForever(.armed, pause) }
    return result
  }

  func close() {
    link.close()
  }

  func retire() async -> SentinelRetirement {
    if !isFresh && pause == .retiring { emit("PAUSED retiring") }
    return await link.retire()
  }
}

struct InertAssertions: AssertionPort {
  func acquireOrRenew(_ kind: AssertionKind, timeoutSeconds: Int) -> EffectOutcome { .failed(code: -1) }
  func release(_ kind: AssertionKind) -> EffectOutcome { .succeeded }
}

struct InertTools: ToolPort {
  func run(_ executable: String, _ arguments: [String]) -> ToolOutcome { .launchFailed("inert") }
}

struct InertClamshell: ClamshellPort {
  func write(on: Bool) -> EffectOutcome { .failed(code: -1) }
}
