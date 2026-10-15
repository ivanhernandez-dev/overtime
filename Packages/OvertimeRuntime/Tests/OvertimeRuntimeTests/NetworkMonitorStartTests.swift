import Foundation
import OvertimeCore
import OvertimeEngine
import Testing

@testable import OvertimeSystem

struct NetworkMonitorStartTests {
  static let failure = Decision(
    keyword: .error, verb: "net failed",
    fields: [DecisionField(key: "action", value: "monitor"), DecisionField(key: "result", value: "timedOut")])
  static let refused = Decision(
    keyword: .error, verb: "net failed",
    fields: [DecisionField(key: "action", value: "monitor"), DecisionField(key: "result", value: "failed")])

  struct Fixture {
    let temp: TempDirectory
    let store: FakeNetworkStore
    let port: LiveNetworkPort
    let sink = NetworkCompositionTests.Sink()

    init(startTimeoutSeconds: Double = 30) throws {
      temp = try TempDirectory()
      let paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path], homeDirectory: temp.path)
      try paths.createDirectories()
      let fixture = try #require(try NetworkFixture.synthetic()[NetworkCompositionTests.deadNetworkCase])
      store = FakeNetworkStore(fixture)
      port = LiveNetworkPort.compose(
        paths: paths, location: LocationGrant(), source: store, knownNetworks: { [] },
        probe: StubbedProbe(primary: .fail, captive: .fail).probe, radio: FakeWiFiRadio(), clock: FakeClock(),
        makeTools: { _ in FakeToolPort() }, sleep: { _ in }, startTimeoutSeconds: startTimeoutSeconds)
    }
  }

  static func started(_ port: LiveNetworkPort) async -> Bool? {
    guard let task = await OffPool.bounded(seconds: 10, { port.start() }) else { return nil }
    guard await Engine.bounded(seconds: 40, { _ = await task.value }) else { return nil }
    return await task.value
  }

  static func seconds(_ body: () -> Void) -> Double {
    let start = ContinuousClock.now
    body()
    let elapsed = ContinuousClock.now - start
    return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
  }

  @Test func startReturnsAtOnceAndTheFactsStayUnknownUntilTheFirstReadLands() async throws {
    let fixture = try Fixture(startTimeoutSeconds: 5)
    let port = fixture.port
    fixture.store.holdStarts()
    defer { fixture.store.releaseStarts() }
    let returned = await OffPool.bounded(seconds: 30) { Self.seconds { _ = port.start() } }
    #expect(try #require(returned) < 3)
    #expect(await OffPool.eventually { fixture.store.startCount == 1 })
    #expect(port.facts(lidClosed: false) == nil)
    fixture.store.releaseStarts()
    #expect(await OffPool.eventually { port.facts(lidClosed: false) != nil })
  }

  @Test func aStartThatOutlivesItsBoundLogsOneLineOnceTheLogIsAttachedAndTheFactsStayUnknown() async throws {
    let fixture = try Fixture(startTimeoutSeconds: 0.3)
    let port = fixture.port
    fixture.store.holdStarts()
    defer { fixture.store.releaseStarts() }
    #expect(await Self.started(port) == false)
    #expect(port.facts(lidClosed: false) == nil)
    let sink = fixture.sink
    port.attachLog { sink.append($0) }
    #expect(sink.decisions == [Self.failure])
    let line = DecisionFormatter.line(Self.failure, wall: Date(), timeZone: .current)
    #expect(line.hasSuffix(" ERROR net failed action=monitor result=timedOut"))
  }

  @Test func aRefusedStartLogsOnceAndIsRetriedAtTheNextLidCloseAndSettingsChange() async throws {
    let fixture = try Fixture()
    let port = fixture.port
    let sink = fixture.sink
    port.attachLog { sink.append($0) }
    fixture.store.refuseStart()
    #expect(await Self.started(port) == false)
    #expect(fixture.sink.decisions == [Self.refused])
    #expect(port.facts(lidClosed: false) == nil)

    _ = port.facts(lidClosed: true)
    #expect(await OffPool.eventually { fixture.store.startCount == 2 })
    try await NetworkCompositionTests.settle()
    #expect(fixture.sink.decisions == [Self.refused])
    #expect(port.facts(lidClosed: true) == nil)
    _ = port.facts(lidClosed: true)
    try await NetworkCompositionTests.settle()
    #expect(fixture.store.startCount == 2)

    port.autoDetectInUse(false)
    #expect(await OffPool.eventually { fixture.store.startCount == 3 })
    try await NetworkCompositionTests.settle()
    #expect(fixture.sink.decisions == [Self.refused])

    fixture.store.refuseStart(false)
    _ = port.facts(lidClosed: false)
    _ = port.facts(lidClosed: true)
    #expect(await OffPool.eventually { port.facts(lidClosed: true) != nil })
    #expect(fixture.store.startCount == 4)

    fixture.store.refuseStart()
    _ = port.facts(lidClosed: false)
    _ = port.facts(lidClosed: true)
    try await NetworkCompositionTests.settle()
    #expect(fixture.store.startCount == 4)
  }
}
