import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing
import os

struct AutoHotspotTests {
  final class KnownNetworksReader: Sendable {
    private struct State {
      var names: [String]?
      var blocking = false
      var held: Set<Int> = []
      var started = 0
      var finished = 0
    }

    static let heldCalls = 8

    private let state: OSAllocatedUnfairLock<State>
    private let gate = DispatchSemaphore(value: 0)
    private let callGates = (0...KnownNetworksReader.heldCalls).map { _ in DispatchSemaphore(value: 0) }

    init(_ names: [String]?) {
      state = OSAllocatedUnfairLock(initialState: State(names: names))
    }

    var reads: Int { state.withLock { $0.started } }
    var finished: Int { state.withLock { $0.finished } }

    func serve(_ names: [String]?) {
      state.withLock { $0.names = names }
    }

    func block() {
      state.withLock { $0.blocking = true }
    }

    func hold(call: Int) {
      state.withLock { _ = $0.held.insert(call) }
    }

    func release(call: Int) {
      state.withLock { _ = $0.held.remove(call) }
      callGates[call].signal()
    }

    func release() {
      let (waiting, held) = state.withLock { state -> (Int, Set<Int>) in
        state.blocking = false
        defer { state.held = [] }
        return (state.started - state.finished, state.held)
      }
      for _ in 0..<max(waiting, 1) {
        gate.signal()
      }
      for call in held {
        callGates[call].signal()
      }
    }

    func read() -> [String]? {
      let (call, blocking, held) = state.withLock { state -> (Int, Bool, Bool) in
        state.started += 1
        return (state.started, state.blocking, state.held.contains(state.started))
      }
      if held, call <= Self.heldCalls {
        _ = callGates[call].wait(timeout: .now() + 30)
      } else if blocking {
        _ = gate.wait(timeout: .now() + 30)
      }
      return state.withLock { state -> [String]? in
        state.finished += 1
        return state.names
      }
    }
  }

  final class Calls<Value: Sendable>: Sendable {
    private let values = OSAllocatedUnfairLock<[Value]>(initialState: [])

    func append(_ value: Value) {
      values.withLock { $0.append(value) }
    }

    var all: [Value] { values.withLock { $0 } }
  }

  static let names = ["Office", "Test iPhone", "Spare iPhone"]
  static let settleSeconds: Double = 0.15

  static func monitor(
    _ reader: KnownNetworksReader, timeout: Double = 5
  ) async throws -> NetworkMonitor {
    let monitor = NetworkMonitor(
      source: FakeNetworkStore(try NetworkFixture.capture()), knownNetworks: { reader.read() },
      readTimeoutSeconds: timeout)
    _ = await OffPool.run { monitor.start() }
    return monitor
  }

  static func settle() async {
    try? await Task.sleep(for: .seconds(settleSeconds))
  }

  @Test func theCandidateIsTheFirstKnownNetworkNamingAnIPhoneInListOrder() {
    #expect(KnownNetworks.autoHotspot(in: Self.names) == "Test iPhone")
    #expect(KnownNetworks.autoHotspot(in: ["Spare iPhone", "Test iPhone"]) == "Spare iPhone")
    #expect(KnownNetworks.autoHotspot(in: ["Office", "Cafe"]) == nil)
    #expect(KnownNetworks.autoHotspot(in: ["office iphone"]) == nil)
    #expect(KnownNetworks.autoHotspot(in: []) == nil)
    #expect(KnownNetworks.autoHotspot(in: nil) == nil)
  }

  @Test func theMarkerIsTheOneStartupChecksAndOnboardingUse() {
    #expect(KnownNetworks.autodetectMarker == StartupChecks.autodetectMarker)
  }

  @Test func autoDetectInUseReadsOnceAndTheCandidateAppearsInALaterFactsRead() async throws {
    let reader = KnownNetworksReader(Self.names)
    let monitor = try await Self.monitor(reader)
    #expect(monitor.facts(lidClosed: false)?.autoHotspot == nil)
    monitor.autoDetectInUse(true)
    #expect(await OffPool.eventually { monitor.facts(lidClosed: false)?.autoHotspot == "Test iPhone" })
    #expect(reader.reads == 1)
  }

  @Test func eachLidCloseEdgeReadsTheKnownNetworksOnceAndLaterClosedReadsDoNot() async throws {
    let reader = KnownNetworksReader(Self.names)
    let monitor = try await Self.monitor(reader)
    monitor.autoDetectInUse(true)
    #expect(await OffPool.eventually { monitor.facts(lidClosed: false)?.autoHotspot == "Test iPhone" })
    reader.serve(["Spare iPhone"])
    #expect(monitor.facts(lidClosed: true)?.autoHotspot == "Test iPhone")
    #expect(await OffPool.eventually { monitor.facts(lidClosed: true)?.autoHotspot == "Spare iPhone" })
    #expect(reader.reads == 2)
    for _ in 0..<20 {
      _ = monitor.facts(lidClosed: true)
    }
    reader.serve(["Test iPhone"])
    _ = monitor.facts(lidClosed: false)
    _ = monitor.facts(lidClosed: true)
    #expect(await OffPool.eventually { monitor.facts(lidClosed: true)?.autoHotspot == "Test iPhone" })
    #expect(reader.reads == 3)
    reader.serve(["Spare iPhone"])
    _ = monitor.facts(lidClosed: nil)
    _ = monitor.facts(lidClosed: true)
    #expect(await OffPool.eventually { monitor.facts(lidClosed: true)?.autoHotspot == "Spare iPhone" })
    #expect(reader.reads == 4)
    reader.serve(["Test iPhone"])
    monitor.autoDetectInUse(true)
    #expect(await OffPool.eventually { monitor.facts(lidClosed: true)?.autoHotspot == "Test iPhone" })
    #expect(reader.reads == 5)
  }

  @Test func theFirstClosedReadAfterAnUnknownLidIsAnEdge() async throws {
    let reader = KnownNetworksReader(Self.names)
    let monitor = try await Self.monitor(reader)
    monitor.autoDetectInUse(true)
    #expect(await OffPool.eventually { reader.finished == 1 })
    _ = monitor.facts(lidClosed: true)
    #expect(await OffPool.eventually { reader.reads == 2 })
  }

  @Test func turningAutoDetectOffClearsTheCandidateWithoutARead() async throws {
    let reader = KnownNetworksReader(Self.names)
    let monitor = try await Self.monitor(reader)
    monitor.autoDetectInUse(true)
    #expect(await OffPool.eventually { monitor.facts(lidClosed: false)?.autoHotspot == "Test iPhone" })
    monitor.autoDetectInUse(false)
    #expect(monitor.facts(lidClosed: false)?.autoHotspot == nil)
    await Self.settle()
    #expect(reader.reads == 1)
    monitor.autoDetectInUse(true)
    #expect(await OffPool.eventually { reader.reads == 2 })
  }

  @Test func withoutAutoDetectALidCloseReadsNothing() async throws {
    let reader = KnownNetworksReader(Self.names)
    let monitor = try await Self.monitor(reader)
    _ = monitor.facts(lidClosed: false)
    _ = monitor.facts(lidClosed: true)
    monitor.autoDetectInUse(false)
    _ = monitor.facts(lidClosed: false)
    _ = monitor.facts(lidClosed: true)
    await Self.settle()
    #expect(reader.reads == 0)
    #expect(monitor.facts(lidClosed: true)?.autoHotspot == nil)
  }

  @Test func anUnreadableListOrOneWithoutAnIPhoneGivesNoCandidate() async throws {
    let reader = KnownNetworksReader(Self.names)
    let monitor = try await Self.monitor(reader)
    monitor.autoDetectInUse(true)
    #expect(await OffPool.eventually { monitor.facts(lidClosed: false)?.autoHotspot == "Test iPhone" })
    reader.serve(nil)
    _ = monitor.facts(lidClosed: true)
    #expect(await OffPool.eventually { monitor.facts(lidClosed: true)?.autoHotspot == nil })
    reader.serve(["Office"])
    monitor.autoDetectInUse(true)
    #expect(await OffPool.eventually { reader.finished == 3 })
    await Self.settle()
    #expect(monitor.facts(lidClosed: true)?.autoHotspot == nil)
  }

  @Test func aReadThatOutlivesItsBoundGivesNoCandidateWhileFactsReturnAtOnce() async throws {
    let reader = KnownNetworksReader(Self.names)
    defer { reader.release() }
    let monitor = try await Self.monitor(reader, timeout: 6)
    monitor.autoDetectInUse(true)
    #expect(await OffPool.eventually(seconds: 10) { monitor.facts(lidClosed: false)?.autoHotspot == "Test iPhone" })
    reader.block()
    let clock = ContinuousClock()
    let start = clock.now
    let facts = monitor.facts(lidClosed: true)
    let elapsed = clock.now - start
    #expect(elapsed < .seconds(3))
    #expect(facts?.autoHotspot == "Test iPhone")
    #expect(await OffPool.eventually(seconds: 10) { reader.reads == 2 })
    #expect(await OffPool.eventually(seconds: 15) { monitor.facts(lidClosed: true)?.autoHotspot == nil })
    #expect(reader.finished == 1)
  }

  @Test func aResultThatArrivesAfterAutoDetectWasTurnedOffIsDiscarded() async throws {
    let reader = KnownNetworksReader(Self.names)
    defer { reader.release() }
    let monitor = try await Self.monitor(reader)
    reader.block()
    monitor.autoDetectInUse(true)
    #expect(await OffPool.eventually { reader.reads == 1 })
    monitor.autoDetectInUse(false)
    reader.release()
    #expect(await OffPool.eventually { reader.finished == 1 })
    await Self.settle()
    #expect(monitor.facts(lidClosed: false)?.autoHotspot == nil)
  }

  @Test func aSupersededReadNeverShowsEvenWhenAutoDetectIsBackOn() async throws {
    let reader = KnownNetworksReader(["Test iPhone"])
    defer { reader.release() }
    let monitor = try await Self.monitor(reader)
    reader.hold(call: 1)
    reader.hold(call: 2)
    monitor.autoDetectInUse(true)
    #expect(await OffPool.eventually { reader.reads == 1 })
    monitor.autoDetectInUse(false)
    monitor.autoDetectInUse(true)
    reader.release(call: 1)
    #expect(await OffPool.eventually { reader.reads == 2 })
    #expect(reader.finished == 1)
    #expect(monitor.facts(lidClosed: false)?.autoHotspot == nil)
    reader.serve(["Spare iPhone"])
    reader.release(call: 2)
    #expect(await OffPool.eventually { monitor.facts(lidClosed: false)?.autoHotspot == "Spare iPhone" })
  }

  static func engine(
    _ temp: TempDirectory, hook: @escaping @Sendable (Settings) -> Void
  ) throws -> (Engine, Settings) {
    let paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path], homeDirectory: temp.path)
    try paths.createDirectories()
    let logger = try FileLogger(decisionLog: paths.decisionLog(.shadow), errorLog: paths.errorLog(.shadow))
    let settings = Settings(transcriptRoots: [temp.path + "/projects"])
    let engine = Engine(
      mode: .shadow,
      settings: settings,
      clock: FakeClock(),
      interpreter: RecordingInterpreter(logger: logger, timeZone: TimeZone(secondsFromGMT: 0)!),
      sources: EngineSources(transcriptSeed: { [] }, sampleTick: { TickFacts() }, networkSettings: hook)
    )
    return (engine, settings)
  }

  @Test func applyingAHotspotChangeCallsTheNetworkSettingsHookOnceWithTheNewSettings() async throws {
    let temp = try TempDirectory()
    let calls = Calls<Settings>()
    let (engine, base) = try Self.engine(temp) { calls.append($0) }
    var named = base
    named.hotspot = "Test iPhone"
    #expect(await engine.apply(settings: named))
    #expect(calls.all == [named])
    var auto = named
    auto.hotspotAutoDetect = true
    #expect(await engine.apply(settings: auto))
    #expect(calls.all == [named, auto])
    var other = auto
    other.keepDisplayOn = true
    other.batteryLowPercent = 15
    other.releaseGraceSeconds = 90
    #expect(await engine.apply(settings: other))
    #expect(calls.all == [named, auto])
    #expect(await engine.apply(settings: other))
    #expect(calls.all == [named, auto])
  }

  @Test func theLiveEngineTellsThePortWhetherAutoDetectIsInUseAtBuildAndOnEachHotspotChange() async throws {
    let temp = try TempDirectory()
    let paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path], homeDirectory: temp.path)
    let recorder = HoldRecorder(stateFile: paths.stateFile(.live))
    let calls = Calls<Bool>()
    let base = Settings(transcriptRoots: [temp.path + "/projects"], hotspotAutoDetect: true)
    let engine = try Composition.makeLiveEngine(
      paths: paths,
      settings: base,
      ports: LivePorts(
        assertions: FakeAssertionPort(), tools: FakeToolPort(), clamshell: FakeClamshellPort(recorder: recorder),
        stateFile: paths.stateFile(.live), makeSentinel: { [recorder] in FakeSentinelPort(recorder: recorder) },
        network: ClosureNetworkPort(onAutoDetect: { calls.append($0) })),
      environment: [:],
      homeDirectory: temp.path,
      once: true,
      clock: FakeClock(),
      externalDisplays: { 0 }
    )
    #expect(calls.all == [true])
    var named = base
    named.hotspot = "Test iPhone"
    #expect(await engine.apply(settings: named))
    #expect(calls.all == [true, false])
    var display = named
    display.keepDisplayOn = true
    #expect(await engine.apply(settings: display))
    #expect(calls.all == [true, false])
    #expect(await engine.apply(settings: base))
    #expect(calls.all == [true, false, true])
    var off = base
    off.hotspotAutoDetect = false
    #expect(await engine.apply(settings: off))
    #expect(calls.all == [true, false, true, false])
  }
}
