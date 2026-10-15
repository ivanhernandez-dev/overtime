import Foundation
import OvertimeClamshell
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing

@Suite(.serialized)
struct ClamshellRunnerKeyTests {
  @Test func onAndOffWritesShareOneRunnerKey() {
    #expect(LiveInterpreter.runnerKey(forClamshellWrite: true) == LiveInterpreter.runnerKey(forClamshellWrite: false))
    #expect(LiveInterpreter.runnerKey(forClamshellWrite: false) == LiveInterpreter.clamshellRunnerKey)
  }

  static func outcome(_ events: [Event], _ id: EffectID) -> EffectOutcome? {
    events.compactMap { event -> EffectOutcome? in
      guard case .effectResult(let result, let outcome) = event, result == id else { return nil }
      return outcome
    }.first
  }

  @Test func noClearCanSucceedWhileAnAbandonedOnWriteIsStillRunning() async throws {
    let temp = try TempDirectory()
    let paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path], homeDirectory: temp.path)
    try paths.createDirectories()
    let recorder = HoldRecorder(stateFile: paths.stateFile(.live))
    let port = GatedClamshellPort(recorder: recorder)
    let logger = try FileLogger(decisionLog: paths.decisionLog(.live), errorLog: paths.errorLog(.live))
    let interpreter = LiveInterpreter(
      ports: LivePorts(
        assertions: FakeAssertionPort(), tools: NoTools(), clamshell: port, stateFile: paths.stateFile(.live),
        makeSentinel: { FakeSentinelPort(recorder: recorder) }),
      logger: logger, sentinel: FakeSentinelPort(recorder: recorder))
    port.holdNextWrite()
    defer { port.release() }
    let engage = EffectID(value: 1)
    let engaged = await interpreter.enqueue(
      [.sentinel(.arm), .clamshell(on: true, id: engage, why: .engage)], wall: Date()
    ).value
    #expect(Self.outcome(engaged, engage) == .timedOut)
    #expect(port.waiting)
    let clear = EffectID(value: 2)
    let refused = await interpreter.enqueue([.clamshell(on: false, id: clear, why: .release)], wall: Date()).value
    #expect(Self.outcome(refused, clear) == .timedOut)
    #expect(EffectOrderTests.clamshellWrites(recorder.all) == [true])
    port.release()
    #expect(await EffectOrderTests.poll(within: 10) { !port.waiting })
    let deadline = ContinuousClock.now + .seconds(10)
    var retried: EffectOutcome?
    var attempt: UInt64 = 3
    while retried != .succeeded, ContinuousClock.now < deadline {
      let retry = EffectID(value: attempt)
      let cleared = await interpreter.enqueue([.clamshell(on: false, id: retry, why: .release)], wall: Date()).value
      retried = Self.outcome(cleared, retry)
      attempt += 1
      if retried != .succeeded { try await Task.sleep(for: .milliseconds(20)) }
    }
    #expect(retried == .succeeded)
    #expect(EffectOrderTests.clamshellWrites(recorder.all) == [true, false])
  }
}
