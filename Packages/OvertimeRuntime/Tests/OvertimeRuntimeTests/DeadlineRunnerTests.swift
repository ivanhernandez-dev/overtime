import Foundation
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing
import os

struct DeadlineRunnerTests {
  actor Probe {
    let runner = DeadlineRunner()
    let gate = DispatchSemaphore(value: 0)
    let entered = OSAllocatedUnfairLock(initialState: false)

    func slow() async -> DeadlineRunner.Outcome<Int> {
      let gate = gate
      let entered = entered
      return await runner.perform(timeout: 60) {
        entered.withLock { $0 = true }
        _ = gate.wait(timeout: .now() + 120)
        return 7
      }
    }

    func ping() -> Bool {
      true
    }
  }

  static let mustFinishSeconds: Double = 30
  static let ceilingSeconds: Double = 5
  static let hangSeconds: Double = 15

  @Test func hangingBodyTimesOutWithinTheDeadline() async {
    let runner = DeadlineRunner()
    let start = ContinuousClock.now
    let outcome = await OffPool.run {
      runner.run(timeout: 0.5) { () -> Int in
        Thread.sleep(forTimeInterval: Self.hangSeconds)
        return 1
      }
    }
    #expect(outcome == .timedOut)
    #expect(ContinuousClock.now - start < .seconds(Self.ceilingSeconds))
  }

  @Test func aKeyStaysOutstandingWhileItsAbandonedBodyRunsAndClearsWhenItReturns() async {
    let runner = DeadlineRunner()
    let gate = DispatchSemaphore(value: 0)
    #expect(!runner.isOutstanding(key: "wifi.power"))
    let outcome = await OffPool.run {
      runner.run(timeout: 0.1, key: "wifi.power") { () -> Int in
        gate.wait()
        return 1
      }
    }
    #expect(outcome == .timedOut)
    #expect(runner.isOutstanding(key: "wifi.power"))
    #expect(!runner.isOutstanding(key: "wifi.read"))
    gate.signal()
    #expect(await OffPool.eventually { !runner.isOutstanding(key: "wifi.power") })
  }

  @Test func quickBodyReturnsItsValue() {
    #expect(DeadlineRunner().run(timeout: Self.mustFinishSeconds) { 42 } == .value(42))
  }

  @Test func performReturnsTheValueAndTimesOut() async {
    let runner = DeadlineRunner()
    #expect(await runner.perform(timeout: Self.mustFinishSeconds) { 42 } == .value(42))
    let start = ContinuousClock.now
    let outcome = await runner.perform(timeout: 0.3) { () -> Int in
      Thread.sleep(forTimeInterval: Self.hangSeconds)
      return 0
    }
    #expect(outcome == .timedOut)
    #expect(ContinuousClock.now - start < .seconds(Self.ceilingSeconds))
  }

  @Test func performDoesNotBlockTheCallingActor() async throws {
    let probe = Probe()
    defer { probe.gate.signal() }
    let slow = Task { await probe.slow() }
    #expect(await OffPool.eventually(seconds: 10) { probe.entered.withLock { $0 } })
    #expect(await Engine.bounded(seconds: 30) { _ = await probe.ping() })
    probe.gate.signal()
    #expect(await slow.value == .value(7))
  }

  @Test func aKeyStillInFlightFailsFastWithoutRunningTheBody() async throws {
    let runner = DeadlineRunner()
    let release = DispatchSemaphore(value: 0)
    let ran = OSAllocatedUnfairLock(initialState: 0)
    let first = runner.run(timeout: 0.1, key: "clamshell") { () -> Int in
      release.wait()
      return 1
    }
    #expect(first == .timedOut)
    #expect(runner.outstandingCount == 1)
    let start = ContinuousClock.now
    let second = await OffPool.run {
      runner.run(timeout: Self.hangSeconds, key: "clamshell") { () -> Int in
        ran.withLock { $0 += 1 }
        return 2
      }
    }
    #expect(second == .timedOut)
    #expect(ContinuousClock.now - start < .seconds(Self.ceilingSeconds))
    #expect(ran.withLock { $0 } == 0)
    #expect(runner.run(timeout: Self.mustFinishSeconds, key: "other") { 3 } == .value(3))
    release.signal()
    #expect(await Self.settles(runner))
    #expect(runner.run(timeout: Self.mustFinishSeconds, key: "clamshell") { 4 } == .value(4))
  }

  @Test func theOutstandingCapBoundsAbandonedThreads() async throws {
    let runner = DeadlineRunner(maxOutstanding: 2)
    let release = DispatchSemaphore(value: 0)
    for _ in 0..<2 {
      #expect(
        runner.run(timeout: 0.05) { () -> Int in
          release.wait()
          return 0
        } == .timedOut)
    }
    #expect(runner.outstandingCount == 2)
    let ran = OSAllocatedUnfairLock(initialState: false)
    #expect(
      runner.run(timeout: 1) { () -> Int in
        ran.withLock { $0 = true }
        return 1
      } == .timedOut)
    #expect(!ran.withLock { $0 })
    release.signal()
    release.signal()
    #expect(await Self.settles(runner))
    #expect(runner.run(timeout: 1) { 5 } == .value(5))
  }

  @Test func admissionTellsAKeyInUseApartFromATimeoutWhileRunStillAnswersTimedOut() async {
    let runner = DeadlineRunner()
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let ran = OSAllocatedUnfairLock(initialState: 0)
    let first = await OffPool.run {
      runner.run(timeout: 0.05, key: "net") { () -> Int in
        release.wait()
        return 1
      }
    }
    #expect(first == .timedOut)
    let admitted = await OffPool.run {
      runner.runIfAdmitted(timeout: 1, key: "net") { () -> Int in
        ran.withLock { $0 += 1 }
        return 2
      }
    }
    #expect(admitted == .notAdmitted)
    let performed = await runner.performIfAdmitted(timeout: 1, key: "net") { () -> Int in
      ran.withLock { $0 += 1 }
      return 3
    }
    #expect(performed == .notAdmitted)
    #expect(await OffPool.run { runner.run(timeout: 1, key: "net") { 4 } } == .timedOut)
    #expect(ran.withLock { $0 } == 0)
    release.signal()
    #expect(await Self.settles(runner))
    #expect(await runner.performIfAdmitted(timeout: 1, key: "net") { 5 } == .value(5))
  }

  @Test func admissionAnswersAValueOnAFreeKeyAndTimedOutForASlowBody() async {
    let runner = DeadlineRunner()
    #expect(await OffPool.run { runner.runIfAdmitted(timeout: 1, key: "net") { 6 } } == .value(6))
    #expect(await runner.performIfAdmitted(timeout: 1, key: "net") { 7 } == .value(7))
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let slow = await OffPool.run {
      runner.runIfAdmitted(timeout: 0.05, key: "net") { () -> Int in
        release.wait()
        return 8
      }
    }
    #expect(slow == .timedOut)
    let other = DispatchSemaphore(value: 0)
    defer { other.signal() }
    let performedSlow = await runner.performIfAdmitted(timeout: 0.05, key: "other") { () -> Int in
      other.wait()
      return 9
    }
    #expect(performedSlow == .timedOut)
  }

  @Test func admissionReportsTheOutstandingCapAsNotAdmitted() async {
    let runner = DeadlineRunner(maxOutstanding: 1)
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let first = await OffPool.run {
      runner.run(timeout: 0.05) { () -> Int in
        release.wait()
        return 0
      }
    }
    #expect(first == .timedOut)
    #expect(await OffPool.run { runner.runIfAdmitted(timeout: 1) { 1 } } == .notAdmitted)
    #expect(await runner.performIfAdmitted(timeout: 1, key: "net") { 2 } == .notAdmitted)
    #expect(await OffPool.run { runner.run(timeout: 1) { 3 } } == .timedOut)
    release.signal()
    #expect(await Self.settles(runner))
    #expect(await runner.performIfAdmitted(timeout: 1) { 4 } == .value(4))
  }

  static func settles(_ runner: DeadlineRunner) async -> Bool {
    for _ in 0..<200 {
      if runner.outstandingCount == 0 { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return false
  }
}
