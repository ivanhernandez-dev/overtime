import Foundation
import OvertimeClamshell
import OvertimeCore
import OvertimeSystem
import os

public protocol SentinelPort: Sendable {
  func start() throws
  func send(_ line: SentinelLine) -> SentinelSendResult
  func close()
  func retire() async -> SentinelRetirement
}

extension SentinelLink: SentinelPort {}

public protocol HelperPort: Sendable {
  func engage(limits: HelperLimits) -> EffectOutcome
  func release() -> EffectOutcome
  func heartbeat() -> EffectOutcome
}

public struct NoHelperPort: HelperPort {
  public init() {}

  public func engage(limits: HelperLimits) -> EffectOutcome {
    .failed(code: LiveInterpreter.helperUnavailableCode)
  }

  public func release() -> EffectOutcome {
    .failed(code: LiveInterpreter.helperUnavailableCode)
  }

  public func heartbeat() -> EffectOutcome {
    .failed(code: LiveInterpreter.helperUnavailableCode)
  }
}

public struct LivePorts: Sendable {
  public var assertions: any AssertionPort
  public var tools: any ToolPort
  public var clamshell: any ClamshellPort
  public var stateFile: URL
  public var makeSentinel: @Sendable () -> any SentinelPort
  public var network: any NetworkPort
  public var helper: any HelperPort

  public init(
    assertions: any AssertionPort,
    tools: any ToolPort,
    clamshell: any ClamshellPort,
    stateFile: URL,
    makeSentinel: @escaping @Sendable () -> any SentinelPort,
    network: any NetworkPort = NoNetworkPort(),
    helper: any HelperPort = NoHelperPort()
  ) {
    self.helper = helper
    self.network = network
    self.assertions = assertions
    self.tools = tools
    self.clamshell = clamshell
    self.stateFile = stateFile
    self.makeSentinel = makeSentinel
  }

  public static func sentinelArguments(relaunch: RelaunchConfiguration?) -> [String] {
    relaunch?.arguments ?? []
  }

  public static func system(
    paths: Paths, relaunch: RelaunchConfiguration? = nil, helper: any HelperPort = NoHelperPort(),
    network: any NetworkPort = NoNetworkPort()
  ) throws -> LivePorts {
    let sentinelLog = paths.sentinelLog
    let extraArguments = sentinelArguments(relaunch: relaunch)
    return LivePorts(
      assertions: IOPMAssertionBackend(syscalls: RealAssertionSyscalls(), registry: .shared),
      tools: ToolRunner(timeoutSeconds: Timing.systemCallTimeoutSeconds),
      clamshell: ClamshellBackend(writer: try ClamshellWriter.open()),
      stateFile: paths.stateFile(.live),
      makeSentinel: {
        SentinelLink(
          executableURL: SentinelLink.siblingExecutable(named: "overtime-sentinel"),
          timeoutSeconds: Int(Timing.sentinelTimeoutSeconds),
          logURL: sentinelLog,
          extraArguments: extraArguments
        )
      },
      network: network,
      helper: helper
    )
  }
}

public final class LiveInterpreter: EffectInterpreter {
  public struct NetworkBounds: Sendable, Equatable {
    public var probe: Double
    public var join: Double
    public var cycle: Double

    public init(probe: Double, join: Double, cycle: Double) {
      self.probe = probe
      self.join = join
      self.cycle = cycle
    }

    public static let standard = NetworkBounds(probe: 5, join: 15, cycle: 25)
  }

  public static let networkRunnerKey = "net"
  public static let unwatchedWriteCode: Int32 = -1
  public static let toolLaunchFailedCode: Int32 = -2
  public static let unpersistedWriteCode: Int32 = -3
  public static let helperUnavailableCode: Int32 = -4
  public static let helperRefusedCode: Int32 = -5
  public static let helperRunnerKey = "helper"
  public static let pmsetPath = "/usr/bin/pmset"
  /// The holder's on and off clamshell writes must share this one runner key. While an abandoned
  /// on-write is still running, every clear by the holder then fails fast as timedOut, so a successful
  /// clear by the holder proves that no earlier holder on-write can land after it. Giving clears their
  /// own key would reopen the late-landing hole (CR-03). The sentinel's clears use their own IOKit
  /// connection and are not ordered after a hung holder write.
  public static let clamshellRunnerKey = "clamshell"
  static let displaySleepArguments = ["displaysleepnow"]
  static let sleepArguments = ["sleepnow"]

  private struct SentinelSlot: Sendable {
    var current: (any SentinelPort)?
    var closed = false
  }

  enum RespawnOutcome {
    case installed
    case failed
    case closed
  }

  private let ports: LivePorts
  private let sentinel: OSAllocatedUnfairLock<SentinelSlot>
  private let logger: FileLogger
  private let timeZone: TimeZone
  private let callTimeoutSeconds: Double
  private let networkBounds: NetworkBounds
  private let runner = DeadlineRunner()
  private let tail = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
  private let networkTail = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
  private let networkClosed = OSAllocatedUnfairLock(initialState: false)
  private let networkStream: AsyncStream<Event>
  private let networkContinuation: AsyncStream<Event>.Continuation
  static let finishedBatch = Task<[Event], Never> { [] }

  public init(
    ports: LivePorts,
    logger: FileLogger,
    sentinel: (any SentinelPort)? = nil,
    timeZone: TimeZone = .current,
    callTimeoutSeconds: Double = Timing.systemCallTimeoutSeconds,
    networkBounds: NetworkBounds = .standard
  ) {
    self.ports = ports
    self.sentinel = OSAllocatedUnfairLock(initialState: SentinelSlot(current: sentinel))
    self.logger = logger
    self.timeZone = timeZone
    self.callTimeoutSeconds = callTimeoutSeconds
    self.networkBounds = networkBounds
    (networkStream, networkContinuation) = AsyncStream.makeStream(of: Event.self)
  }

  deinit {
    networkContinuation.finish()
  }

  public var networkEvents: AsyncStream<Event>? {
    networkStream
  }

  public func closeNetwork() {
    networkClosed.withLock { $0 = true }
  }

  private var isNetworkClosed: Bool {
    networkClosed.withLock { $0 }
  }

  public func drainNetwork() async {
    await networkTail.withLock { $0 }?.value
  }

  public func enqueue(_ effects: [Effect], wall: Date) -> Task<[Event], Never> {
    let network = effects.compactMap(Self.networkEffect)
    guard !network.isEmpty else {
      return serialized { [self] in await performInOrder(effects, wall: wall) }
    }
    let continuation = networkContinuation
    if !isNetworkClosed {
      enqueueNetwork(network, wall: wall, continuation: continuation)
    }
    let rest = effects.filter { Self.networkEffect($0) == nil }
    guard !rest.isEmpty else { return Self.finishedBatch }
    return serialized { [self] in await performInOrder(rest, wall: wall) }
  }

  private func enqueueNetwork(_ network: [NetEffect], wall: Date, continuation: AsyncStream<Event>.Continuation) {
    _ = networkSerialized { [self] in
      for effect in network {
        guard !isNetworkClosed else { return }
        if let event = await self.network(effect, wall: wall) {
          continuation.yield(event)
        }
      }
    }
  }

  static func networkEffect(_ effect: Effect) -> NetEffect? {
    guard case .net(let net) = effect else { return nil }
    return net
  }

  public func heartbeat() async -> SentinelSendResult {
    await serialized { [self] in send(.heartbeat) }.value
  }

  public func logNow(_ decision: Decision, wall: Date) {
    logger.log(decision, wall: wall, timeZone: timeZone)
  }

  private func serialized<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> Task<T, Never> {
    tail.withLock { tail -> Task<T, Never> in
      let previous = tail
      let task = Task {
        await previous?.value
        return await body()
      }
      tail = Task { _ = await task.value }
      return task
    }
  }

  private func networkSerialized(_ body: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
    networkTail.withLock { tail -> Task<Void, Never> in
      let previous = tail
      let task = Task {
        await previous?.value
        await body()
      }
      tail = task
      return task
    }
  }

  private func performInOrder(_ effects: [Effect], wall: Date) async -> [Event] {
    var results: [Event] = []
    var armDelivered = false
    var unwatched = false
    var respawnFailed = false
    var ownershipUnpersisted = false
    var index = effects.startIndex
    while index < effects.endIndex {
      let effect = effects[index]
      index += 1
      switch effect {
      case .log(let decision):
        logger.log(decision, wall: wall, timeZone: timeZone)
      case .persist(let state):
        do {
          try StateStore.write(state, to: ports.stateFile)
        } catch {
          ownershipUnpersisted = ownershipUnpersisted || state.ownsHold
          logger.log(Decision(keyword: .error, verb: "state write failed"), wall: wall, timeZone: timeZone)
        }
      case .idleAssertion(let action, let id):
        results.append(.effectResult(id, await assertion(.preventUserIdleSystemSleep, action)))
      case .displayAssertion(let action, let id):
        results.append(.effectResult(id, await assertion(.preventUserIdleDisplaySleep, action)))
      case .sentinel(.respawn):
        let arm = index < effects.endIndex && effects[index] == .sentinel(.arm)
        if arm { index += 1 }
        let outcome = await respawn(wall: wall, arm: arm)
        armDelivered = arm && outcome == .installed
        unwatched = outcome != .installed
        respawnFailed = outcome != .installed
        if outcome == .failed {
          logger.log(Decision(keyword: .error, verb: "sentinel respawn failed"), wall: wall, timeZone: timeZone)
        }
      case .sentinel(let command):
        guard let line = Self.line(for: command) else { continue }
        if send(line) == .sent {
          armDelivered = armDelivered || line == .arm
        } else if !unwatched {
          unwatched = true
          if !respawnFailed && !isClosed {
            results.append(.sentinelLost)
          }
        }
      case .clamshell(let on, let id, _):
        guard !on || !ownershipUnpersisted else {
          results.append(.effectResult(id, .failed(code: Self.unpersistedWriteCode)))
          continue
        }
        guard !on || (armDelivered && !unwatched) else {
          results.append(.effectResult(id, .failed(code: Self.unwatchedWriteCode)))
          continue
        }
        results.append(.effectResult(id, await clamshell(on: on)))
      case .displaySleepNow(let id):
        results.append(.effectResult(id, await pmset(Self.displaySleepArguments, wall: wall)))
      case .requestSleep(let id):
        results.append(.effectResult(id, await pmset(Self.sleepArguments, wall: wall)))
      case .net:
        continue
      case .helper(let action, let id, let limits):
        results.append(.effectResult(id, await helper(action, limits: limits)))
      }
    }
    return results
  }

  private func helper(_ action: HelperAction, limits: HelperLimits?) async -> EffectOutcome {
    let port = ports.helper
    let engageLimits = limits ?? HelperLimits(settings: Settings())
    let outcome = await runner.perform(timeout: callTimeoutSeconds, key: Self.helperRunnerKey) { () -> EffectOutcome in
      switch action {
      case .engage: port.engage(limits: engageLimits)
      case .release: port.release()
      case .heartbeat: port.heartbeat()
      }
    }
    switch outcome {
    case .value(let result):
      return result
    case .timedOut:
      return .timedOut
    }
  }

  static func line(for command: SentinelCommand) -> SentinelLine? {
    switch command {
    case .arm: .arm
    case .disarm: .disarm
    case .bye: .bye
    case .respawn: nil
    }
  }

  private func send(_ line: SentinelLine) -> SentinelSendResult {
    guard let current = sentinel.withLock({ $0.current }) else { return .notRunning }
    return current.send(line)
  }

  private var isClosed: Bool {
    sentinel.withLock { $0.closed }
  }

  /// Make-before-break: the replacement is started, and armed when the batch arms it, before the
  /// old sentinel is retired, so an armed sentinel exists at every point of a respawn. A close that
  /// lands mid-respawn applies to whichever sentinel ends up installed.
  private func respawn(wall: Date, arm: Bool) async -> RespawnOutcome {
    guard !isClosed else { return .closed }
    let fresh = ports.makeSentinel()
    guard await Self.startOffTheCooperativePool(fresh) else { return .failed }
    guard !arm || fresh.send(.arm) == .sent else {
      _ = await fresh.retire()
      return .failed
    }
    let replaced = sentinel.withLock { slot -> (old: (any SentinelPort)?, installed: Bool) in
      guard !slot.closed else { return (nil, false) }
      defer { slot.current = fresh }
      return (slot.current, true)
    }
    guard replaced.installed else {
      fresh.close()
      return .closed
    }
    if let old = replaced.old {
      let retired = await old.retire()
      if retired != .notRunning {
        let fields = [DecisionField(key: "signal", value: retired.rawValue)]
        logger.log(Decision(keyword: .sentinel, verb: "retired", fields: fields), wall: wall, timeZone: timeZone)
      }
    }
    return .installed
  }

  public static let sentinelStartQueueLabel = "io.github.ivanhernandez-dev.overtime.sentinel-start"
  static let sentinelStartQueue = DispatchQueue(label: sentinelStartQueueLabel)

  static func startOffTheCooperativePool(_ fresh: any SentinelPort) async -> Bool {
    await withCheckedContinuation { continuation in
      sentinelStartQueue.async {
        continuation.resume(returning: (try? fresh.start()) != nil)
      }
    }
  }

  public func closeSentinel() {
    let current = sentinel.withLock { slot -> (any SentinelPort)? in
      slot.closed = true
      defer { slot.current = nil }
      return slot.current
    }
    current?.close()
  }

  public func runTool(_ executable: String, _ arguments: [String]) async -> ToolOutcome {
    let tools = ports.tools
    let bound = callTimeoutSeconds + ToolRunner.terminateGraceSeconds + ToolRunner.reapWaitSeconds
    switch await runner.perform(timeout: bound, key: "tool", { tools.run(executable, arguments) }) {
    case .value(let outcome):
      return outcome
    case .timedOut:
      return .timedOut
    }
  }

  private func pmset(_ arguments: [String], wall: Date) async -> EffectOutcome {
    let outcome: EffectOutcome
    switch await runTool(Self.pmsetPath, arguments) {
    case .finished(let exitCode, _, _):
      outcome = exitCode == 0 ? .succeeded : .failed(code: exitCode)
    case .timedOut:
      outcome = .timedOut
    case .launchFailed:
      outcome = .failed(code: Self.toolLaunchFailedCode)
    }
    if outcome != .succeeded {
      let fields = [DecisionField(key: "command", value: arguments.joined(separator: " "))]
      logger.log(Decision(keyword: .error, verb: "pmset failed", fields: fields), wall: wall, timeZone: timeZone)
    }
    return outcome
  }

  private func network(_ effect: NetEffect, wall: Date) async -> Event? {
    let port = ports.network
    switch effect {
    case .probe:
      switch await runner.performIfAdmitted(
        timeout: networkBounds.probe, key: Self.networkRunnerKey, { port.probe() })
      {
      case .notAdmitted:
        return nil
      case .timedOut:
        return .netProbeResult(online: false)
      case .value(let online):
        return .netProbeResult(online: online)
      }
    case .joinHotspot(let name):
      _ = await networkAction("joinHotspot", bound: networkBounds.join, wall: wall) { port.joinHotspot(name) }
      return nil
    case .cycleWifi:
      let admission = await networkAction("cycleWifi", bound: networkBounds.cycle, wall: wall) { port.cycleWifi() }
      return .netCycleDone(Self.cycleOutcome(admission))
    }
  }

  static let cycleRanCodes: Set<Int32> = [
    WiFiController.Code.offFailed.rawValue, WiFiController.Code.stillOff.rawValue,
  ]

  static func cycleOutcome(_ admission: DeadlineRunner.Admission<EffectOutcome>) -> NetCycleOutcome {
    switch admission {
    case .value(.succeeded):
      .succeeded
    case .value(.failed(let code)) where code == WiFiController.Code.adminRequired.rawValue:
      .adminRequired
    case .value(.failed(let code)) where code == WiFiController.Code.powerUnknown.rawValue:
      .powerUnknown
    case .value(.failed(let code)) where cycleRanCodes.contains(code):
      .failed
    case .value(.timedOut), .timedOut:
      .failed
    case .value(.failed), .notAdmitted:
      .refused
    }
  }

  private func networkAction(
    _ action: String, bound: Double, wall: Date, _ body: @escaping @Sendable () -> EffectOutcome
  ) async -> DeadlineRunner.Admission<EffectOutcome> {
    let admission = await runner.performIfAdmitted(timeout: bound, key: Self.networkRunnerKey, body)
    let result: String
    switch admission {
    case .value(.succeeded):
      return admission
    case .value(.failed(let code)):
      result = String(code)
    case .value(.timedOut), .timedOut:
      result = "timedOut"
    case .notAdmitted:
      result = "busy"
    }
    let fields = [DecisionField(key: "action", value: action), DecisionField(key: "result", value: result)]
    logger.log(Decision(keyword: .error, verb: "net failed", fields: fields), wall: wall, timeZone: timeZone)
    return admission
  }

  private func clamshell(on: Bool) async -> EffectOutcome {
    let port = ports.clamshell
    let key = Self.runnerKey(forClamshellWrite: on)
    switch await runner.perform(timeout: callTimeoutSeconds, key: key, { port.write(on: on) }) {
    case .value(let result):
      return result
    case .timedOut:
      return .timedOut
    }
  }

  public static func runnerKey(forClamshellWrite on: Bool) -> String {
    clamshellRunnerKey
  }

  private func assertion(_ kind: AssertionKind, _ action: AssertionAction) async -> EffectOutcome {
    let port = ports.assertions
    let outcome = await runner.perform(timeout: callTimeoutSeconds, key: "assertion.\(kind)") { () -> EffectOutcome in
      switch action {
      case .acquireOrRenew(let timeoutSeconds):
        return port.acquireOrRenew(kind, timeoutSeconds: timeoutSeconds)
      case .release:
        return port.release(kind)
      }
    }
    switch outcome {
    case .value(let result):
      return result
    case .timedOut:
      return .timedOut
    }
  }
}
