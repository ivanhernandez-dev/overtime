import Dispatch
import Foundation
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing
import os

@Suite(.serialized)
struct SampleAdmissionTests {
  static let mustFinishSeconds: Double = 30

  static func poll(within seconds: Double, _ condition: () -> Bool) async -> Bool {
    let deadline = ProcessProbe.uptime() + seconds
    while ProcessProbe.uptime() < deadline {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
  }

  @Test func aSampleRefusedByTheThreadCapDoesNotStopLaterSamples() async throws {
    let runner = DeadlineRunner(maxOutstanding: 1)
    let samples = OSAllocatedUnfairLock(initialState: 0)
    let engine = Engine(
      mode: .shadow, settings: Settings(), clock: FakeClock(), interpreter: CapturingInterpreter(),
      sources: EngineSources(
        transcriptSeed: { [] },
        sampleTick: {
          samples.withLock { $0 += 1 }
          return TickFacts()
        }),
      sampleTimeoutSeconds: Self.mustFinishSeconds, deadlineRunner: runner)
    let gate = DispatchSemaphore(value: 0)
    let occupant = Task { await runner.perform(timeout: Self.mustFinishSeconds, key: "occupant") { gate.wait() } }
    #expect(await Self.poll(within: Self.mustFinishSeconds) { runner.outstandingCount == 1 })
    await engine.tick()
    #expect(samples.withLock { $0 } == 0)
    gate.signal()
    _ = await occupant.value
    #expect(await Self.poll(within: Self.mustFinishSeconds) { runner.outstandingCount == 0 })
    await engine.tick()
    await engine.tick()
    #expect(samples.withLock { $0 } == 2)
  }

  @Test func aHungSampleIsNotStackedAndLaterSamplesResumeOnceItReturns() async throws {
    let runner = DeadlineRunner()
    let samples = OSAllocatedUnfairLock(initialState: 0)
    let gate = DispatchSemaphore(value: 0)
    let engine = Engine(
      mode: .shadow, settings: Settings(), clock: FakeClock(), interpreter: CapturingInterpreter(),
      sources: EngineSources(
        transcriptSeed: { [] },
        sampleTick: {
          let count = samples.withLock { count -> Int in
            count += 1
            return count
          }
          if count == 1 { gate.wait() }
          return TickFacts()
        }),
      sampleTimeoutSeconds: 0.1, deadlineRunner: runner)
    await engine.tick()
    #expect(await Self.poll(within: Self.mustFinishSeconds) { samples.withLock { $0 } == 1 })
    await engine.tick()
    #expect(samples.withLock { $0 } == 1)
    gate.signal()
    #expect(await Self.poll(within: Self.mustFinishSeconds) { runner.outstandingCount == 0 })
    await engine.tick()
    #expect(await Self.poll(within: Self.mustFinishSeconds) { samples.withLock { $0 } == 2 })
  }
}
