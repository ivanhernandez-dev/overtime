import Dispatch
import Foundation
import OvertimeClamshell
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing
import os

final class GatedClamshellPort: ClamshellPort {
  private struct Gate: Sendable {
    var armed = false
    var waiting = false
  }

  private let recorder: HoldRecorder
  private let gate = OSAllocatedUnfairLock(initialState: Gate())
  private let semaphore = DispatchSemaphore(value: 0)

  init(recorder: HoldRecorder) {
    self.recorder = recorder
  }

  func holdNextWrite() {
    gate.withLock { $0.armed = true }
  }

  var waiting: Bool {
    gate.withLock { $0.waiting }
  }

  func release() {
    semaphore.signal()
  }

  func write(on: Bool) -> EffectOutcome {
    recorder.append(.clamshell(on: on, fileOwnsHold: recorder.fileOwnsHold()))
    let blocks = gate.withLock { gate -> Bool in
      guard gate.armed else { return false }
      gate.armed = false
      gate.waiting = true
      return true
    }
    if blocks {
      semaphore.wait()
      gate.withLock { $0.waiting = false }
    }
    return .succeeded
  }
}

@Suite(.serialized)
struct EffectOrderTests {
  static func poll(within seconds: Double, _ condition: () async -> Bool) async -> Bool {
    let deadline = ProcessProbe.uptime() + seconds
    while ProcessProbe.uptime() < deadline {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
  }

  static func clamshellWrites(_ entries: [HoldRecorder.Entry]) -> [Bool] {
    entries.compactMap {
      if case .clamshell(let on, _) = $0 { return on }
      return nil
    }
  }

  @Test func batchesRunInEnqueueOrderWhileTheFirstIsBlocked() async throws {
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
      logger: logger, sentinel: FakeSentinelPort(recorder: recorder), callTimeoutSeconds: 30)
    port.holdNextWrite()
    let first = interpreter.enqueue(
      [.sentinel(.arm), .clamshell(on: true, id: EffectID(value: 1), why: .reassert)], wall: Date())
    let second = interpreter.enqueue(
      [.clamshell(on: false, id: EffectID(value: 2), why: .release), .sentinel(.disarm)], wall: Date())
    try #require(await Self.poll(within: 5) { port.waiting })
    try await Task.sleep(for: .milliseconds(200))
    #expect(Self.clamshellWrites(recorder.all) == [true])
    port.release()
    #expect(await first.value == [.effectResult(EffectID(value: 1), .succeeded)])
    #expect(await second.value == [.effectResult(EffectID(value: 2), .succeeded)])
    #expect(
      recorder.all == [
        .sentinel("ARM", fileOwnsHold: nil),
        .clamshell(on: true, fileOwnsHold: nil),
        .clamshell(on: false, fileOwnsHold: nil),
        .sentinel("DISARM", fileOwnsHold: nil),
      ])
  }

  @Test func aReleaseReducedWhileAReassertIsInFlightRunsAfterIt() async throws {
    let temp = try TempDirectory()
    let paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path], homeDirectory: temp.path)
    let recorder = HoldRecorder(stateFile: paths.stateFile(.live))
    let port = GatedClamshellPort(recorder: recorder)
    let clock = FakeClock()
    let engine = try Composition.makeLiveEngine(
      paths: paths,
      settings: Settings(transcriptRoots: [temp.path + "/projects"]),
      ports: LivePorts(
        assertions: FakeAssertionPort(), tools: NoTools(), clamshell: port, stateFile: paths.stateFile(.live),
        makeSentinel: { FakeSentinelPort(recorder: recorder) }),
      environment: [:], homeDirectory: temp.path, once: true, clock: clock, callTimeoutSeconds: 30)
    await engine.step(.tick(TickFacts(fullWake: true)))
    await engine.step(.transcriptActivity(TranscriptActivity(at: clock.mono())))
    try #require(await engine.state.hold.lidClose == .held)
    recorder.reset()
    clock.advance(seconds: Timing.reassertEverySeconds + 1)
    port.holdNextWrite()
    let reassert = Task { await engine.step(.tick(TickFacts(fullWake: true))) }
    try #require(await Self.poll(within: 5) { port.waiting })
    let pause = Task { await engine.step(.command(.pause(.indefinite))) }
    let releasing = await Self.poll(within: 5) {
      if case .releasing = await engine.state.hold.lidClose { return true }
      return false
    }
    port.release()
    await reassert.value
    await pause.value
    try #require(releasing)
    let entries = recorder.all
    #expect(Self.clamshellWrites(entries) == [true, false])
    let lastOn = try #require(entries.lastIndex(of: .clamshell(on: true, fileOwnsHold: true)))
    let disarm = try #require(
      entries.firstIndex {
        if case .sentinel("DISARM", _) = $0 { return true }
        return false
      })
    #expect(lastOn < disarm)
    #expect(await engine.state.hold.lidClose == .released)
    guard case .state(let stored) = StateStore.read(at: paths.stateFile(.live)) else {
      Issue.record("no state file")
      return
    }
    #expect(stored.ownsHold == false)
  }
}
