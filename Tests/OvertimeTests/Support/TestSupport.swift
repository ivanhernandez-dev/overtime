import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import os

final class TestFolder {
  let url: URL

  init() throws {
    url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "overtime-app-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  var path: String {
    url.path(percentEncoded: false)
  }

  deinit {
    try? FileManager.default.removeItem(at: url)
  }
}

@MainActor
func waitUntil(timeout: Double = 3, _ condition: @MainActor () -> Bool) async -> Bool {
  let deadline = ContinuousClock.now + .milliseconds(Int(timeout * 1000))
  while ContinuousClock.now < deadline {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(20))
  }
  return condition()
}

final class TestClock: ClockPort {
  private let reading: OSAllocatedUnfairLock<(mono: Instant, wall: Date)>

  init(
    mono: Instant = Instant(nanoseconds: 1_000_000_000_000_000), wall: Date = Date(timeIntervalSince1970: 1_800_000_000)
  ) {
    reading = OSAllocatedUnfairLock(initialState: (mono, wall))
  }

  func mono() -> Instant {
    reading.withLock { $0.mono }
  }

  func wall() -> Date {
    reading.withLock { $0.wall }
  }

  func advance(seconds: Double) {
    reading.withLock { $0 = ($0.mono.adding(seconds: seconds), $0.wall.addingTimeInterval(seconds)) }
  }
}

final class FakeEngineHost: EngineHosting {
  let clock: any ClockPort
  let engineToken = UUID()
  private let stream: AsyncStream<EngineSnapshot>
  private let continuation: AsyncStream<EngineSnapshot>.Continuation
  private let state = OSAllocatedUnfairLock<(requests: [CtlRequest], response: CtlResponse?)>(
    initialState: ([], CtlResponse(ok: true)))

  init(clock: any ClockPort = TestClock()) {
    self.clock = clock
    (stream, continuation) = AsyncStream.makeStream(of: EngineSnapshot.self, bufferingPolicy: .bufferingNewest(1))
  }

  var requests: [CtlRequest] {
    state.withLock { $0.requests }
  }

  func respond(with response: CtlResponse?) {
    state.withLock { $0.response = response }
  }

  func publish(_ snapshot: EngineSnapshot) {
    continuation.yield(snapshot)
  }

  func snapshots() async -> AsyncStream<EngineSnapshot> {
    stream
  }

  func send(_ request: CtlRequest) async -> CtlResponse? {
    state.withLock { state in
      state.requests.append(request)
      return state.response
    }
  }

  private let probing = OSAllocatedUnfairLock<(result: EngineSnapshot?, count: Int)>(
    initialState: (EngineSnapshot(), 0))

  var probes: Int {
    probing.withLock { $0.count }
  }

  func scriptProbe(_ result: EngineSnapshot?) {
    probing.withLock { $0.result = result }
  }

  func probe() async -> EngineSnapshot? {
    probing.withLock { probing in
      probing.count += 1
      return probing.result
    }
  }

  private let applying = OSAllocatedUnfairLock<(applied: [Settings], result: Bool)>(initialState: ([], true))

  var appliedSettings: [Settings] {
    applying.withLock { $0.applied }
  }

  func scriptApply(_ result: Bool) {
    applying.withLock { $0.result = result }
  }

  func apply(settings: Settings) async -> Bool {
    applying.withLock { applying in
      applying.applied.append(settings)
      return applying.result
    }
  }

  private let selfTesting = OSAllocatedUnfairLock(initialState: 0)

  var selfTestRequests: Int {
    selfTesting.withLock { $0 }
  }

  func requestSelfTest() async {
    selfTesting.withLock { $0 += 1 }
  }

  private let helperUpdating = OSAllocatedUnfairLock<[HelperFacts]>(initialState: [])

  var helperUpdates: [HelperFacts] {
    helperUpdating.withLock { $0 }
  }

  func updateHelper(_ facts: HelperFacts) async {
    helperUpdating.withLock { $0.append(facts) }
  }
}

struct StructEngineHost: EngineHosting {
  let fake: FakeEngineHost

  var clock: any ClockPort {
    fake.clock
  }

  var engineToken: UUID {
    fake.engineToken
  }

  func snapshots() async -> AsyncStream<EngineSnapshot> {
    await fake.snapshots()
  }

  func send(_ request: CtlRequest) async -> CtlResponse? {
    await fake.send(request)
  }

  func probe() async -> EngineSnapshot? {
    await fake.probe()
  }

  func apply(settings: Settings) async -> Bool {
    await fake.apply(settings: settings)
  }

  func requestSelfTest() async {
    await fake.requestSelfTest()
  }

  func updateHelper(_ facts: HelperFacts) async {
    await fake.updateHelper(facts)
  }
}

final class FakeEmergencyReset: EmergencyResetting {
  private let state = OSAllocatedUnfairLock<(outcomes: [EmergencyOutcome], runs: Int)>(initialState: ([], 0))

  init(_ outcomes: [EmergencyOutcome] = []) {
    state.withLock { $0.outcomes = outcomes }
  }

  var runs: Int {
    state.withLock { $0.runs }
  }

  func script(_ outcomes: [EmergencyOutcome]) {
    state.withLock { $0.outcomes += outcomes }
  }

  func run() async -> EmergencyOutcome {
    state.withLock { state in
      state.runs += 1
      return state.outcomes.isEmpty ? .restored(released: 0, helperCleared: true) : state.outcomes.removeFirst()
    }
  }
}
