import Foundation
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing
import os

final class CapturingInterpreter: EffectInterpreter {
  private let batches = OSAllocatedUnfairLock<[[Effect]]>(initialState: [])

  var recorded: [[Effect]] {
    batches.withLock { $0 }
  }

  func reset() {
    batches.withLock { $0.removeAll() }
  }

  func enqueue(_ effects: [Effect], wall: Date) -> Task<[Event], Never> {
    batches.withLock { $0.append(effects) }
    let results: [Event] = effects.compactMap { effect in
      switch effect {
      case .idleAssertion(_, let id), .displayAssertion(_, let id), .clamshell(_, let id, _),
        .displaySleepNow(let id), .requestSleep(let id), .helper(_, let id):
        .effectResult(id, .succeeded)
      case .log, .persist, .sentinel, .net:
        nil
      }
    }
    return Task { results }
  }
}

struct EngineTimingTests {
  static func engine(clock: FakeClock, interpreter: CapturingInterpreter) -> Engine {
    Engine(
      mode: .live,
      settings: Settings(),
      clock: clock,
      interpreter: interpreter,
      sources: EngineSources(transcriptSeed: { [] }, sampleTick: { TickFacts(fullWake: true) })
    )
  }

  static func engages(_ effects: [Effect]) -> Bool {
    effects.contains { effect in
      if case .clamshell(on: true, _, .engage) = effect { return true }
      return false
    }
  }

  @Test func theTickIsTwoSeconds() {
    #expect(Timing.tickSeconds == 2)
  }

  @Test func aTranscriptEventEngagesInItsOwnStepAfterAFullWakeTick() async {
    let clock = FakeClock()
    let interpreter = CapturingInterpreter()
    let engine = Self.engine(clock: clock, interpreter: interpreter)
    await engine.step(.tick(TickFacts(fullWake: true)))
    interpreter.reset()
    clock.advance(seconds: 0.3)
    let before = clock.mono()
    await engine.step(.transcriptActivity(TranscriptActivity(at: clock.mono())))
    #expect(clock.mono() == before)
    guard let batch = interpreter.recorded.first else {
      Issue.record("the transcript step performed nothing")
      return
    }
    #expect(Self.engages(batch))
    #expect(batch.contains(.sentinel(.arm)))
    #expect(await engine.state.hold.lidClose == .held)
  }

  @Test func withoutAFullWakeTheTranscriptStepDoesNotEngage() async {
    let clock = FakeClock()
    let interpreter = CapturingInterpreter()
    let engine = Self.engine(clock: clock, interpreter: interpreter)
    await engine.step(.tick(TickFacts(fullWake: false)))
    interpreter.reset()
    await engine.step(.transcriptActivity(TranscriptActivity(at: clock.mono())))
    #expect(!interpreter.recorded.contains(where: Self.engages))
    clock.advance(seconds: Timing.tickSeconds)
    await engine.step(.tick(TickFacts(fullWake: true)))
    #expect(interpreter.recorded.contains(where: Self.engages))
  }
}
