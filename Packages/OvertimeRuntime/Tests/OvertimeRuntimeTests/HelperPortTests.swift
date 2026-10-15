import Foundation
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing
import os

struct HelperPortTests {
  final class Order: Sendable {
    private let entries = OSAllocatedUnfairLock<[String]>(initialState: [])

    var all: [String] {
      entries.withLock { $0 }
    }

    func append(_ entry: String) {
      entries.withLock { $0.append(entry) }
    }
  }

  struct OrderedClamshell: ClamshellPort {
    let order: Order

    func write(on: Bool) -> EffectOutcome {
      order.append(on ? "clamshell on" : "clamshell off")
      return .succeeded
    }
  }

  struct Harness {
    let temp: TempDirectory
    let paths: Paths
    let logger: FileLogger
    let order = Order()
    let helper: FakeHelperPort

    init() throws {
      temp = try TempDirectory()
      paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path], homeDirectory: temp.path)
      try paths.createDirectories()
      logger = try FileLogger(decisionLog: paths.decisionLog(.live), errorLog: paths.errorLog(.live))
      let order = order
      helper = FakeHelperPort { order.append("helper " + $0.rawValue) }
    }

    func ports(helper: (any HelperPort)?) -> LivePorts {
      let recorder = HoldRecorder(stateFile: paths.stateFile(.live))
      let makeSentinel: @Sendable () -> any SentinelPort = { FakeSentinelPort(recorder: recorder) }
      guard let helper else {
        return LivePorts(
          assertions: FakeAssertionPort(), tools: NoTools(), clamshell: OrderedClamshell(order: order),
          stateFile: paths.stateFile(.live), makeSentinel: makeSentinel)
      }
      return LivePorts(
        assertions: FakeAssertionPort(), tools: NoTools(), clamshell: OrderedClamshell(order: order),
        stateFile: paths.stateFile(.live), makeSentinel: makeSentinel, helper: helper)
    }

    func interpreter(
      helper: (any HelperPort)?, callTimeoutSeconds: Double = Timing.systemCallTimeoutSeconds
    ) -> LiveInterpreter {
      LiveInterpreter(
        ports: ports(helper: helper), logger: logger, timeZone: TimeZone(secondsFromGMT: 0) ?? .gmt,
        callTimeoutSeconds: callTimeoutSeconds)
    }
  }

  static let releaseThenClear: [Effect] = [
    .helper(.release, id: EffectID(value: 1)), .clamshell(on: false, id: EffectID(value: 2), why: .release),
  ]

  static func perform(
    _ interpreter: LiveInterpreter, _ effects: [Effect], within seconds: Double = 10
  ) async -> [Event]? {
    let results = OSAllocatedUnfairLock<[Event]?>(initialState: nil)
    let finished = await Engine.bounded(seconds: seconds) {
      let events = await interpreter.perform(effects, wall: Date())
      results.withLock { $0 = events }
    }
    return finished ? results.withLock { $0 } : nil
  }

  @Test func theNoHelperPortAnswersEveryCallAsUnavailable() {
    let port = NoHelperPort()
    #expect(port.engage() == .failed(code: LiveInterpreter.helperUnavailableCode))
    #expect(port.release() == .failed(code: LiveInterpreter.helperUnavailableCode))
    #expect(port.heartbeat() == .failed(code: LiveInterpreter.helperUnavailableCode))
  }

  @Test func theHelperCodesAreTheirOwn() {
    #expect(LiveInterpreter.helperUnavailableCode == -4)
    #expect(LiveInterpreter.helperRefusedCode == -5)
    let codes = [
      LiveInterpreter.unwatchedWriteCode, LiveInterpreter.toolLaunchFailedCode, LiveInterpreter.unpersistedWriteCode,
      LiveInterpreter.helperUnavailableCode, LiveInterpreter.helperRefusedCode,
    ]
    #expect(Set(codes).count == codes.count)
    #expect(LiveInterpreter.helperRunnerKey == "helper")
    #expect(LiveInterpreter.helperRunnerKey != LiveInterpreter.clamshellRunnerKey)
  }

  @Test func portsBuiltWithoutAHelperUseTheNoHelperPort() async throws {
    let harness = try Harness()
    #expect(harness.ports(helper: nil).helper is NoHelperPort)
    let effects: [Effect] = HelperAction.allCases.enumerated().map { index, action in
      .helper(action, id: EffectID(value: UInt64(index + 1)))
    }
    let results = await Self.perform(harness.interpreter(helper: nil), effects)
    let unavailable = EffectOutcome.failed(code: LiveInterpreter.helperUnavailableCode)
    #expect(
      results == [
        .effectResult(EffectID(value: 1), unavailable), .effectResult(EffectID(value: 2), unavailable),
        .effectResult(EffectID(value: 3), unavailable),
      ])
    #expect(harness.helper.calls.isEmpty)
  }

  @Test func eachHelperActionReachesItsOwnPortCallInBatchOrder() async throws {
    let harness = try Harness()
    let effects: [Effect] = [
      .helper(.engage, id: EffectID(value: 1)), .helper(.heartbeat, id: EffectID(value: 2)),
      .helper(.release, id: EffectID(value: 3)),
    ]
    let results = await Self.perform(harness.interpreter(helper: harness.helper), effects)
    #expect(harness.helper.calls == [.engage, .heartbeat, .release])
    #expect(
      results == [
        .effectResult(EffectID(value: 1), .succeeded), .effectResult(EffectID(value: 2), .succeeded),
        .effectResult(EffectID(value: 3), .succeeded),
      ])
  }

  @Test func aHelperReleaseRunsBeforeTheClamshellClearThatFollowsIt() async throws {
    let harness = try Harness()
    let results = await Self.perform(harness.interpreter(helper: harness.helper), Self.releaseThenClear)
    #expect(harness.order.all == ["helper release", "clamshell off"])
    #expect(results == [.effectResult(EffectID(value: 1), .succeeded), .effectResult(EffectID(value: 2), .succeeded)])
  }

  @Test(arguments: [EffectOutcome.failed(code: LiveInterpreter.helperRefusedCode), .failed(code: 4097), .timedOut])
  func aHelperCallThatDidNotSucceedNeverSkipsTheNextEffect(_ outcome: EffectOutcome) async throws {
    let harness = try Harness()
    harness.helper.queue(outcome, for: .release)
    let results = await Self.perform(harness.interpreter(helper: harness.helper), Self.releaseThenClear)
    #expect(harness.order.all == ["helper release", "clamshell off"])
    #expect(results == [.effectResult(EffectID(value: 1), outcome), .effectResult(EffectID(value: 2), .succeeded)])
  }

  @Test func aHelperCallThatOutlivesItsBoundTimesOutAndTheNextEffectStillRuns() async throws {
    let harness = try Harness()
    harness.helper.holdNext(.release)
    defer { harness.helper.releaseHeld() }
    let interpreter = harness.interpreter(helper: harness.helper)
    let results = await Self.perform(interpreter, Self.releaseThenClear)
    #expect(harness.helper.heldReturned == 0, "the clamshell clear ran while the helper release is still blocked")
    #expect(results == [.effectResult(EffectID(value: 1), .timedOut), .effectResult(EffectID(value: 2), .succeeded)])
    #expect(harness.order.all == ["helper release", "clamshell off"])
  }

  @Test func whileAnAbandonedHelperCallStillRunsTheNextOneTimesOutWithoutReachingThePort() async throws {
    let harness = try Harness()
    harness.helper.holdNext(.engage)
    defer { harness.helper.releaseHeld() }
    let interpreter = harness.interpreter(helper: harness.helper)
    let engage = await Self.perform(interpreter, [.helper(.engage, id: EffectID(value: 1))])
    #expect(engage == [.effectResult(EffectID(value: 1), .timedOut)])
    let release = await Self.perform(interpreter, Self.releaseThenClear)
    #expect(harness.helper.heldReturned == 0, "the abandoned engage is still running")
    #expect(release == [.effectResult(EffectID(value: 1), .timedOut), .effectResult(EffectID(value: 2), .succeeded)])
    #expect(harness.helper.calls == [.engage])
    #expect(harness.order.all == ["helper engage", "clamshell off"])
  }

  @Test func theShadowInterpreterAnswersHelperEffectsWithSuccess() async throws {
    let harness = try Harness()
    let interpreter = RecordingInterpreter(logger: harness.logger, timeZone: TimeZone(secondsFromGMT: 0) ?? .gmt)
    let effects: [Effect] = HelperAction.allCases.enumerated().map { index, action in
      .helper(action, id: EffectID(value: UInt64(index + 1)))
    }
    let results = await interpreter.perform(effects, wall: Date())
    #expect(
      results == [
        .effectResult(EffectID(value: 1), .succeeded), .effectResult(EffectID(value: 2), .succeeded),
        .effectResult(EffectID(value: 3), .succeeded),
      ])
    #expect(harness.helper.calls.isEmpty)
  }
}
