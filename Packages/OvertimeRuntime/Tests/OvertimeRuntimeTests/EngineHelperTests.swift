import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import OvertimeHelperClient
import OvertimeHelperCore
import OvertimeSystem
import Testing
import os

final class HelperCallOrder: Sendable {
  private struct Entries: Sendable {
    var all: [String] = []
    var firstSeen: [String: ContinuousClock.Instant] = [:]
  }

  private let entries = OSAllocatedUnfairLock(initialState: Entries())

  var all: [String] {
    entries.withLock { $0.all }
  }

  func append(_ entry: String) {
    let now = ContinuousClock.now
    entries.withLock { entries in
      entries.all.append(entry)
      if entries.firstSeen[entry] == nil {
        entries.firstSeen[entry] = now
      }
    }
  }

  func firstSeen(_ entry: String) -> ContinuousClock.Instant? {
    entries.withLock { $0.firstSeen[entry] }
  }

  func count(_ entry: String) -> Int {
    all.filter { $0 == entry }.count
  }
}

final class OrderedHelperSystem: HelperSystemPort, Sendable {
  static let setEntry = "pmset 1"
  static let clearEntry = "pmset 0"
  static let edgeEntry = "helper edge"

  let fake: FakeHelperSystem
  private let order: HelperCallOrder
  private let delays = OSAllocatedUnfairLock(initialState: (set: 0.0, clear: 0.0))

  init(fake: FakeHelperSystem, order: HelperCallOrder) {
    self.fake = fake
    self.order = order
  }

  func delaySets(seconds: Double) {
    delays.withLock { $0.set = seconds }
  }

  func delayClears(seconds: Double) {
    delays.withLock { $0.clear = seconds }
  }

  func readSleepDisabled() -> Bool? {
    fake.readSleepDisabled()
  }

  func writeSleepDisabled(_ disabled: Bool) -> Bool {
    order.append(disabled ? Self.setEntry : Self.clearEntry)
    let delay = delays.withLock { disabled ? $0.set : $0.clear }
    if delay > 0 {
      Thread.sleep(forTimeInterval: delay)
    }
    return fake.writeSleepDisabled(disabled)
  }

  func lidClosed() -> Bool? {
    fake.lidClosed()
  }

  func clamshellEdge() -> Bool {
    order.append(Self.edgeEntry)
    return fake.clamshellEdge()
  }

  func power() -> HelperPowerFacts? {
    fake.power()
  }

  func thermal() -> HelperThermalFacts? {
    fake.thermal()
  }

  func pause(milliseconds: Int) {
    fake.pause(milliseconds: milliseconds)
  }
}

struct OrderedClamshellPort: ClamshellPort {
  static let onEntry = "clamshell on"
  static let offEntry = "clamshell off"

  let inner: FakeClamshellPort
  let order: HelperCallOrder

  func write(on: Bool) -> EffectOutcome {
    order.append(on ? Self.onEntry : Self.offEntry)
    return inner.write(on: on)
  }
}

enum HelperTestClient {
  struct Endpoint: @unchecked Sendable {
    let value: NSXPCListenerEndpoint
  }

  static func make(
    to listener: NSXPCListener, counting made: OSAllocatedUnfairLock<Int>, requirement: String, timeoutSeconds: Double
  ) -> HelperXPCClient {
    let endpoint = Endpoint(value: listener.endpoint)
    return HelperXPCClient(requirement: requirement, timeoutSeconds: timeoutSeconds) {
      made.withLock { $0 += 1 }
      return NSXPCConnection(listenerEndpoint: endpoint.value)
    }
  }
}

final class InProcessHelper {
  static let connectionRelease = "release reason=connection sleepDisabled=0 edge=done"

  let fake: FakeHelperSystem
  let system: OrderedHelperSystem
  let queue: DispatchQueue
  let machine: HelperMachine
  let service: HelperXPCService
  let listener: NSXPCListener
  private let made = OSAllocatedUnfairLock(initialState: 0)

  init(
    order: HelperCallOrder = HelperCallOrder(), sleepDisabled: Bool? = false, lid: Bool? = true,
    version: Int = HelperIdentity.version
  ) {
    let fake = FakeHelperSystem(sleepDisabled: sleepDisabled, lid: lid)
    let system = OrderedHelperSystem(fake: fake, order: order)
    let queue = DispatchQueue(label: "InProcessHelper.machine")
    let machine = HelperMachine(system: system, record: fake, log: fake, clock: fake, version: version)
    let service = HelperXPCService(machine: machine, log: fake, queue: queue, onExit: {})
    let listener = NSXPCListener.anonymous()
    service.configure(listener, requirement: OwnRequirement.string())
    listener.resume()
    self.fake = fake
    self.system = system
    self.queue = queue
    self.machine = machine
    self.service = service
    self.listener = listener
  }

  var connectionsMade: Int {
    made.withLock { $0 }
  }

  var connections: Int {
    queue.sync { machine.connections }
  }

  var statusCalls: Int {
    fake.calls.filter { $0 == .thermal }.count
  }

  func watch() {
    queue.sync { machine.watch() }
  }

  func client(
    requirement: String = OwnRequirement.string(), timeoutSeconds: Double = HelperXPCClient.defaultTimeoutSeconds
  ) -> HelperXPCClient {
    HelperTestClient.make(to: listener, counting: made, requirement: requirement, timeoutSeconds: timeoutSeconds)
  }

  func stop() {
    listener.invalidate()
  }
}

final class SilentHelper: NSObject, NSXPCListenerDelegate, HelperXPCProtocol, @unchecked Sendable {
  private struct Counts: Sendable {
    var sets: [Bool] = []
    var statuses = 0
    var ended = 0
  }

  let listener = NSXPCListener.anonymous()
  private let held = OSAllocatedUnfairLock<[Any]>(uncheckedState: [])
  private let counts = OSAllocatedUnfairLock(initialState: Counts())
  private let made = OSAllocatedUnfairLock(initialState: 0)
  private let answered: Int
  private let garbage: Bool

  init(answeringStatuses answered: Int = 0, thenGarbage garbage: Bool = false) {
    self.answered = answered
    self.garbage = garbage
    super.init()
    listener.setConnectionCodeSigningRequirement(OwnRequirement.string())
    listener.delegate = self
    listener.resume()
  }

  var sets: [Bool] { counts.withLock { $0.sets } }
  var statuses: Int { counts.withLock { $0.statuses } }
  var ended: Int { counts.withLock { $0.ended } }
  var connectionsMade: Int { made.withLock { $0 } }

  func client(timeoutSeconds: Double) -> HelperXPCClient {
    HelperTestClient.make(
      to: listener, counting: made, requirement: OwnRequirement.string(), timeoutSeconds: timeoutSeconds)
  }

  func stop() {
    listener.invalidate()
  }

  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
    let counts = counts
    connection.exportedInterface = NSXPCInterface(with: HelperXPCProtocol.self)
    connection.exportedObject = self
    connection.invalidationHandler = {
      counts.withLock { $0.ended += 1 }
    }
    connection.resume()
    return true
  }

  func setSleepDisabled(
    _ enabled: Bool, batteryFloorPercent: Int, temperatureCeilingCelsius: Int,
    reply: @escaping @Sendable (Int32, String) -> Void
  ) {
    counts.withLock { $0.sets.append(enabled) }
    held.withLockUnchecked { $0.append(reply) }
  }

  func status(appHelperVersion: Int, reply: @escaping @Sendable (Data) -> Void) {
    let seen = counts.withLock { counts -> Int in
      counts.statuses += 1
      return counts.statuses
    }
    guard seen > answered else {
      return reply(HelperStatus(helperVersion: appHelperVersion).encoded())
    }
    guard !garbage else {
      return reply(Data("not a status".utf8))
    }
    held.withLockUnchecked { $0.append(reply) }
  }
}

final class ClearSwallowingHelper: NSObject, NSXPCListenerDelegate, HelperXPCProtocol, @unchecked Sendable {
  private let inner: HelperXPCService
  private let held = OSAllocatedUnfairLock<[Any]>(uncheckedState: [])
  private let swallowed = OSAllocatedUnfairLock(initialState: 0)

  init(inner: HelperXPCService) {
    self.inner = inner
  }

  var clearsSwallowed: Int {
    swallowed.withLock { $0 }
  }

  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
    let accepted = inner.listener(listener, shouldAcceptNewConnection: connection)
    connection.exportedObject = self
    return accepted
  }

  func setSleepDisabled(
    _ enabled: Bool, batteryFloorPercent: Int, temperatureCeilingCelsius: Int,
    reply: @escaping @Sendable (Int32, String) -> Void
  ) {
    guard enabled else {
      swallowed.withLock { $0 += 1 }
      held.withLockUnchecked { $0.append(reply) }
      return
    }
    inner.setSleepDisabled(
      enabled, batteryFloorPercent: batteryFloorPercent, temperatureCeilingCelsius: temperatureCeilingCelsius,
      reply: reply)
  }

  func status(appHelperVersion: Int, reply: @escaping @Sendable (Data) -> Void) {
    inner.status(appHelperVersion: appHelperVersion, reply: reply)
  }
}

struct EngineHelperTests {
  static let ready = HelperFacts(installed: true, reachable: true, current: true)
  static let lidClose = Event.lidChanged(closed: true, sleepBit: false, externalDisplays: 0)
  static let lidOpen = Event.lidChanged(closed: false, sleepBit: false, externalDisplays: nil)
  static let sleepEntry = "sleepnow"
  static let appHold = [OrderedClamshellPort.onEntry]
  static let engaged = [OrderedClamshellPort.onEntry, OrderedHelperSystem.setEntry]
  static let engageTimedOut = " ERROR helper engage failed reason=timedOut retryIn=30"
  static let releaseTimedOut = " ERROR helper release failed reason=timedOut"
  static let shortCallSeconds: Double = 2
  static let outlivesTheStopSeconds: Double = 30
  static let onlyTheEnginesBound: Comment =
    "R2T-WR-02: the client's own timeout outlives the stop bound, so only the engine's helper-call bound can end the release in time"

  enum End: String, Sendable, CaseIterable, CustomTestStringConvertible {
    case releaseUntilIdle
    case pause
    case stop

    var testDescription: String { rawValue }
  }

  struct Harness {
    let temp: TempDirectory
    let paths: Paths
    let clock = FakeClock()
    let tools = FakeToolPort()
    let recorder: HoldRecorder
    let order = HelperCallOrder()

    init() throws {
      temp = try TempDirectory()
      paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path], homeDirectory: temp.path)
      recorder = HoldRecorder(stateFile: paths.stateFile(.live))
      let order = order
      tools.setResponder { _, arguments in
        if arguments == ["sleepnow"] {
          order.append(EngineHelperTests.sleepEntry)
        }
        return nil
      }
    }

    func engine(
      helper: any HelperPort, callTimeoutSeconds: Double = Timing.systemCallTimeoutSeconds,
      stopWaitSeconds: Double = Engine.stopWaitSeconds, settings: Settings = Settings()
    ) throws -> Engine {
      let clamshell = OrderedClamshellPort(inner: FakeClamshellPort(recorder: recorder), order: order)
      var configured = settings
      configured.transcriptRoots = [temp.path + "/projects"]
      return try Composition.makeLiveEngine(
        paths: paths,
        settings: configured,
        ports: LivePorts(
          assertions: FakeAssertionPort(), tools: tools, clamshell: clamshell, stateFile: paths.stateFile(.live),
          makeSentinel: { [recorder] in FakeSentinelPort(recorder: recorder) }, helper: helper),
        environment: [:],
        homeDirectory: temp.path,
        once: true,
        clock: clock,
        callTimeoutSeconds: callTimeoutSeconds,
        externalDisplays: { 0 },
        stopWaitSeconds: stopWaitSeconds
      )
    }

    func work(_ engine: Engine, lidClosed: Bool) async {
      await engine.step(.transcriptActivity(TranscriptActivity(at: clock.mono())))
      await tick(engine, lidClosed: lidClosed)
    }

    func tick(_ engine: Engine, lidClosed: Bool) async {
      await engine.step(.tick(TickFacts(lidClosed: lidClosed, externalDisplays: lidClosed ? 0 : nil, fullWake: true)))
    }

    func engage(_ engine: Engine) async {
      await engine.updateHelper(EngineHelperTests.ready)
      await work(engine, lidClosed: true)
    }

    func end(_ end: End, _ engine: Engine) async {
      switch end {
      case .releaseUntilIdle:
        await engine.step(.command(.releaseUntilIdle))
      case .pause:
        await engine.step(.command(.pause(.indefinite)))
      case .stop:
        await engine.stop()
      }
    }

    func logged(_ suffix: String, in mode: KeyPath<Harness, URL> = \.decisionLog) -> Bool {
      guard let text = try? String(contentsOf: self[keyPath: mode], encoding: .utf8) else { return false }
      return text.split(separator: "\n").contains { $0.hasSuffix(suffix) }
    }

    var decisionLog: URL { paths.decisionLog(.live) }
    var errorLog: URL { paths.errorLog(.live) }
  }

  static func run(_ call: @escaping @Sendable () -> EffectOutcome) async -> EffectOutcome {
    await OffPool.run(call)
  }

  static func probe(_ port: XPCHelperPort) async -> HelperProbe {
    await OffPool.run { port.probe() }
  }

  @Test func theAppsHelperLimitsMatchTheHelpersCompiledLimits() {
    let rule: Comment =
      "the app's intent mirrors the helper's floor and ceiling and its editor offers the helper's ranges, so they must match"
    #expect(Settings.helperBatteryFloorRange == HelperSafetyLimits.batteryFloorRange, rule)
    #expect(Settings().helperBatteryFloorPercent == HelperSafetyLimits.defaultBatteryFloorPercent, rule)
    #expect(Settings.temperatureReleaseRange == HelperSafetyLimits.temperatureCeilingRange, rule)
    #expect(HelperIntent.helperTemperatureCeilingCelsius == HelperSafetyLimits.defaultTemperatureCeilingCelsius, rule)
  }

  @Test func theEngineSendsTheConfiguredLimitsToTheHelper() async throws {
    let harness = try Harness()
    let helper = InProcessHelper(order: harness.order)
    defer { helper.stop() }
    let port = XPCHelperPort(client: helper.client())
    let engine = try harness.engine(
      helper: port, settings: Settings(helperBatteryFloorPercent: 25, temperatureReleaseCelsius: 45))
    await harness.engage(engine)
    #expect(await engine.state.helper.phase == .engaged)
    #expect(helper.fake.logLines.contains("set owned prior=0 floor=25 ceiling=45"))
  }

  @Test func withTheLidOpenTheEngineHoldsOnItsOwnAndALidCloseEngagesTheHelperAfterIt() async throws {
    let harness = try Harness()
    let helper = InProcessHelper(order: harness.order)
    defer { helper.stop() }
    let port = XPCHelperPort(client: helper.client())
    let engine = try harness.engine(helper: port)
    await engine.updateHelper(Self.ready)
    await harness.work(engine, lidClosed: false)
    #expect(harness.order.all == Self.appHold)
    #expect(helper.connectionsMade == 0)
    #expect(helper.fake.calls.isEmpty)
    let open = await engine.currentSnapshot()
    #expect(!open.helperEngaged)
    #expect(open.helperFacts == Self.ready)

    await engine.step(Self.lidClose)
    #expect(harness.order.all == Self.engaged)
    #expect(helper.fake.pmsetWrites == [true])
    #expect(helper.fake.sleepDisabled == true)
    #expect(helper.fake.storedRecord?.owns == true)
    #expect(await engine.state.helper.phase == .engaged)
    let closed = await engine.currentSnapshot()
    #expect(closed.helperEngaged)
    #expect(closed.helperFacts == Self.ready)
    #expect(port.observations.owns)
    #expect(helper.connectionsMade == 1)
    #expect(helper.connections == 1)
    #expect(harness.logged(" HOLD helper engage"))
  }

  @Test func whenTheLidOpensTheHelperClearsSleepDisabledBeforeTheAppsOwnClear() async throws {
    let harness = try Harness()
    let helper = InProcessHelper(order: harness.order)
    defer { helper.stop() }
    let port = XPCHelperPort(client: helper.client())
    let engine = try harness.engine(helper: port)
    await harness.engage(engine)
    #expect(harness.order.all == Self.engaged)

    helper.fake.setLid(false)
    await engine.step(Self.lidOpen)
    #expect(harness.order.all == Self.engaged + [OrderedHelperSystem.clearEntry])
    #expect(helper.fake.sleepDisabled == false)
    #expect(helper.fake.storedRecord?.owns == false)
    #expect(await engine.state.hold.lidClose == .held)
    #expect(await engine.state.helper.phase == .idle)
    #expect(!(await engine.currentSnapshot().helperEngaged))
    #expect(!port.observations.owns)
    #expect(harness.logged(" HOLD helper release reason=lidOpen"))
    #expect(await OffPool.eventually { helper.connections == 0 })

    await engine.step(.command(.releaseUntilIdle))
    #expect(
      harness.order.all == Self.engaged + [OrderedHelperSystem.clearEntry, OrderedClamshellPort.offEntry])
    #expect(helper.connectionsMade == 1)
  }

  @Test(arguments: End.allCases)
  func everyEndOfTheHoldReleasesTheHelperBeforeTheAppsOwnClearInTheSameBatch(_ end: End) async throws {
    let harness = try Harness()
    let helper = InProcessHelper(order: harness.order)
    defer { helper.stop() }
    let port = XPCHelperPort(client: helper.client())
    let engine = try harness.engine(helper: port)
    await harness.engage(engine)
    await harness.end(end, engine)
    let released = [
      OrderedHelperSystem.clearEntry, OrderedHelperSystem.edgeEntry, OrderedClamshellPort.offEntry,
    ]
    #expect(Array(harness.order.all.prefix(5)) == Self.engaged + released)
    #expect(harness.order.count(OrderedHelperSystem.setEntry) == 1)
    #expect(helper.fake.sleepDisabled == false)
    #expect(!(await engine.currentSnapshot().helperEngaged))
    #expect(await OffPool.eventually { helper.connections == 0 })
    #expect(helper.connectionsMade == 1)
  }

  @Test func sleepNowReleasesTheHelperBeforeTheSleepRequestAndKeepsTheAppsOwnHold() async throws {
    let harness = try Harness()
    let helper = InProcessHelper(order: harness.order)
    defer { helper.stop() }
    let port = XPCHelperPort(client: helper.client())
    let engine = try harness.engine(helper: port)
    await harness.engage(engine)
    await engine.step(.command(.sleepNow))
    #expect(
      harness.order.all
        == Self.engaged + [OrderedHelperSystem.clearEntry, OrderedHelperSystem.edgeEntry, Self.sleepEntry])
    #expect(await engine.state.hold.lidClose == .held)
    #expect(!(await engine.currentSnapshot().helperEngaged))
    #expect(harness.logged(" HOLD helper release reason=sleepNow"))
  }

  @Test func theHeartbeatIsAStatusCallOnTheSameConnectionTwentySecondsAfterTheLastContact() async throws {
    let harness = try Harness()
    let helper = InProcessHelper(order: harness.order)
    defer { helper.stop() }
    let port = XPCHelperPort(client: helper.client())
    let engine = try harness.engine(helper: port)
    await harness.engage(engine)
    #expect(port.observations.status == nil)
    helper.fake.forget()

    harness.clock.advance(seconds: 19)
    await harness.tick(engine, lidClosed: true)
    #expect(helper.statusCalls == 0)
    let before = await engine.currentSnapshot()

    harness.clock.advance(seconds: 1)
    await harness.tick(engine, lidClosed: true)
    #expect(helper.statusCalls == 1)
    #expect(helper.fake.pmsetWrites.isEmpty)
    #expect(helper.connectionsMade == 1)
    #expect(helper.connections == 1)
    #expect(port.observations.status?.engaged == true)
    #expect(port.observations.status?.helperVersion == HelperIdentity.version)
    #expect(port.observations.owns)
    #expect(await engine.currentSnapshot() == before)
    #expect(await engine.state.helper.phase == .engaged)
    #expect(!helper.fake.logLines.contains { $0.hasPrefix("status stale") })

    await harness.tick(engine, lidClosed: true)
    #expect(helper.statusCalls == 1)
  }

  @Test func anEngineThatStopsTickingLosesTheHelperAfterFiftyFiveSecondsWhateverElseAsksForStatus() async throws {
    let harness = try Harness()
    let helper = InProcessHelper(order: harness.order)
    defer { helper.stop() }
    let port = XPCHelperPort(client: helper.client())
    let engine = try harness.engine(helper: port)
    await harness.engage(engine)
    helper.fake.forget()

    helper.fake.advance(seconds: 30)
    #expect(await Self.probe(port) == .engaged(nil))
    #expect(await Self.probe(port) == .engaged(nil))
    #expect(helper.fake.calls.isEmpty)
    helper.fake.advance(seconds: 24)
    helper.watch()
    #expect(helper.fake.pmsetWrites.isEmpty)
    helper.fake.advance(seconds: 1)
    helper.watch()
    #expect(helper.fake.logLines.contains("release reason=heartbeat sleepDisabled=0 edge=done"))
    #expect(helper.fake.sleepDisabled == false)
    #expect(helper.connectionsMade == 1)
  }

  static let holderRule: Comment =
    "03-REVIEW.md H-WR-02: only the connection that engaged refreshes the heartbeat, and the end of that connection releases"
  static let clearRule: Comment =
    "03-REVIEW.md H-WR-02: a clear is still accepted from any connection that passes the requirement"
  static let heartbeatRelease = "release reason=heartbeat sleepDisabled=0 edge=done"
  static let clearRelease = "release reason=clear sleepDisabled=0 edge=done"

  static func engaged(_ client: HelperXPCClient) async -> Bool? {
    guard case .success(let status) = await OffPool.run({ client.status(appVersion: HelperIdentity.version) })
    else { return nil }
    return status.engaged
  }

  @Test func aSecondClientAskingForStatusNeverKeepsTheHoldOfAnEngineThatStoppedTicking() async throws {
    let harness = try Harness()
    let helper = InProcessHelper(order: harness.order)
    defer { helper.stop() }
    let port = XPCHelperPort(client: helper.client())
    let engine = try harness.engine(helper: port)
    await harness.engage(engine)
    let second = helper.client()
    defer { second.invalidate() }
    helper.fake.forget()

    helper.fake.advance(seconds: 30)
    #expect(await Self.engaged(second) == true, Self.holderRule)
    helper.fake.advance(seconds: 24)
    #expect(await Self.engaged(second) == true, Self.holderRule)
    #expect(helper.connections == 2)
    helper.watch()
    #expect(helper.fake.pmsetWrites.isEmpty)
    helper.fake.advance(seconds: 1)
    #expect(await Self.engaged(second) == true, Self.holderRule)
    helper.watch()
    #expect(helper.fake.logLines.contains(Self.heartbeatRelease), Self.holderRule)
    #expect(helper.fake.pmsetWrites == [false], Self.holderRule)
    #expect(helper.fake.sleepDisabled == false, Self.holderRule)
    #expect(await Self.engaged(second) == false, Self.holderRule)
  }

  @Test func thePortsHeartbeatKeepsTheHoldBecauseItGoesOverTheConnectionThatEngaged() async {
    let helper = InProcessHelper()
    defer { helper.stop() }
    let port = XPCHelperPort(client: helper.client())
    guard case .answered = await Self.probe(port) else {
      Issue.record("an idle port asks the helper")
      return
    }
    #expect(await Self.run { port.engage() } == .succeeded)
    helper.fake.advance(seconds: 54)
    #expect(await Self.run { port.heartbeat() } == .succeeded)
    helper.fake.advance(seconds: 54)
    helper.watch()
    #expect(helper.fake.pmsetWrites == [true], Self.holderRule)
    #expect(helper.fake.sleepDisabled == true, Self.holderRule)
    #expect(helper.connectionsMade == 1, Self.holderRule)
    helper.fake.advance(seconds: 1)
    helper.watch()
    #expect(helper.fake.logLines.contains(Self.heartbeatRelease))
  }

  @Test func aPortThatDropsItsConnectionReleasesTheHelperWhileASecondClientStaysConnected() async {
    let helper = InProcessHelper()
    defer { helper.stop() }
    helper.system.delaySets(seconds: 0.8)
    let port = XPCHelperPort(client: helper.client(), boundSeconds: 0.3)
    let second = helper.client()
    defer { second.invalidate() }
    #expect(await Self.engaged(second) == false)
    #expect(helper.connections == 1)

    #expect(await Self.run { port.engage() } == .timedOut)
    #expect(
      await OffPool.eventually { helper.fake.logLines.contains(InProcessHelper.connectionRelease) }, Self.holderRule)
    #expect(helper.fake.logLines.contains("set owned prior=0 floor=10 ceiling=45"))
    #expect(helper.fake.pmsetWrites == [true, false], Self.holderRule)
    #expect(helper.fake.sleepDisabled == false, Self.holderRule)
    #expect(helper.connectionsMade == 2)
    #expect(await OffPool.eventually { helper.connections == 1 })
    #expect(await Self.engaged(second) == false, Self.holderRule)
  }

  @Test func theClearOnlyClientReleasesAHoldItDidNotEngageAndItsOwnEndReleasesNothingMore() async {
    let helper = InProcessHelper()
    defer { helper.stop() }
    let port = XPCHelperPort(client: helper.client())
    #expect(await Self.run { port.engage() } == .succeeded)
    let short = helper.client()
    let clear = AppHost.emergencyHelperClear(installer: FakeHelperInstaller(status: .enabled)) { short }
    helper.fake.forget()

    #expect(await OffPool.run { clear() }, Self.clearRule)
    #expect(helper.fake.logLines == [Self.clearRelease], Self.clearRule)
    #expect(helper.fake.pmsetWrites == [false], Self.clearRule)
    #expect(helper.fake.sleepDisabled == false, Self.clearRule)
    #expect(helper.statusCalls == 0, "The emergency client must only send a clear and never call status (T-03-19)")
    #expect(helper.connectionsMade == 2)
    #expect(await OffPool.eventually { helper.connections == 1 })

    #expect(await Self.run { port.heartbeat() } == .failed(code: XPCHelperPort.notEngagedCode))
    #expect(await OffPool.eventually { helper.connections == 0 })
    #expect(helper.fake.logLines == [Self.clearRelease])
    #expect(helper.fake.pmsetWrites == [false])
  }

  @Test func aClearOnlyClientWhoseClearNeverArrivesLeavesThePortsHoldWhenItsConnectionEnds() async {
    let helper = InProcessHelper()
    defer { helper.stop() }
    let swallowing = ClearSwallowingHelper(inner: helper.service)
    helper.listener.delegate = swallowing
    let port = XPCHelperPort(client: helper.client())
    #expect(await Self.run { port.engage() } == .succeeded)
    let short = helper.client(timeoutSeconds: 0.5)
    let clear = AppHost.emergencyHelperClear(installer: FakeHelperInstaller(status: .enabled)) { short }

    #expect(await OffPool.run { clear() } == false)
    #expect(swallowing.clearsSwallowed == 1)
    #expect(helper.connectionsMade == 2)
    #expect(await OffPool.eventually { helper.connections == 1 })
    helper.queue.sync {}
    #expect(helper.fake.pmsetWrites == [true], Self.holderRule)
    #expect(helper.fake.sleepDisabled == true, Self.holderRule)
    helper.fake.advance(seconds: 54)
    #expect(await Self.run { port.heartbeat() } == .succeeded, Self.holderRule)
    helper.fake.advance(seconds: 54)
    helper.watch()
    #expect(helper.fake.sleepDisabled == true, Self.holderRule)
    #expect(helper.connectionsMade == 2)
    helper.fake.advance(seconds: 1)
    helper.watch()
    #expect(helper.fake.logLines.contains(Self.heartbeatRelease))
    #expect(helper.fake.sleepDisabled == false)
  }

  @Test func aHelperThatNeverAnswersTimesOutAndTheAppsOwnHoldAndClearStillRun() async throws {
    let harness = try Harness()
    let silent = SilentHelper()
    defer { silent.stop() }
    let port = XPCHelperPort(client: silent.client(timeoutSeconds: 1))
    let engine = try harness.engine(helper: port)
    await harness.engage(engine)
    #expect(harness.order.all == Self.appHold)
    #expect(await engine.state.hold.lidClose == .held)
    #expect(!(await engine.currentSnapshot().helperEngaged))
    #expect(harness.logged(Self.engageTimedOut))
    #expect(harness.logged(Self.engageTimedOut, in: \.errorLog))
    #expect(silent.sets == [true])
    #expect(await OffPool.eventually { silent.ended == 1 })

    await engine.step(.command(.releaseUntilIdle))
    #expect(harness.order.all == Self.appHold + [OrderedClamshellPort.offEntry])
    #expect(harness.logged(Self.releaseTimedOut))
    #expect(harness.logged(Self.releaseTimedOut, in: \.errorLog))
    #expect(silent.sets == [true, false])
    #expect(silent.connectionsMade == 2)
    #expect(await OffPool.eventually { silent.ended == 2 })
  }

  @Test func whileAHelperCallThatOutlivedItsBoundStillRunsTheAppsOwnClearRunsAndNoReleaseReachesTheHelper()
    async throws
  {
    let harness = try Harness()
    let silent = SilentHelper()
    defer { silent.stop() }
    let port = XPCHelperPort(client: silent.client(timeoutSeconds: 12), boundSeconds: 0.3)
    let engine = try harness.engine(helper: port)
    await harness.engage(engine)
    #expect(harness.logged(Self.engageTimedOut))
    #expect(harness.order.all == Self.appHold)

    await engine.step(.command(.releaseUntilIdle))
    #expect(harness.order.all == Self.appHold + [OrderedClamshellPort.offEntry])
    #expect(silent.ended == 0)
    #expect(harness.logged(Self.releaseTimedOut))

    #expect(await OffPool.eventually(seconds: 20) { silent.ended == 1 })
    try? await Task.sleep(for: .milliseconds(300))
    #expect(silent.sets == [true])
    #expect(silent.connectionsMade == 1)
  }

  @Test func aReleaseThatNeverReachesTheHelperIsNotRetriedAndTheHelperReleasesWhenTheConnectionEnds() async throws {
    let harness = try Harness()
    let helper = InProcessHelper(order: harness.order)
    defer { helper.stop() }
    let swallowing = ClearSwallowingHelper(inner: helper.service)
    helper.listener.delegate = swallowing
    let port = XPCHelperPort(client: helper.client())
    let engine = try harness.engine(helper: port)
    await harness.engage(engine)
    #expect(harness.order.all == Self.engaged)

    await engine.step(.command(.releaseUntilIdle))
    #expect(swallowing.clearsSwallowed == 1)
    #expect(harness.order.all.contains(OrderedClamshellPort.offEntry))
    #expect(harness.logged(Self.releaseTimedOut))
    #expect(await engine.state.helper.phase == .idle)
    #expect(await OffPool.eventually { helper.fake.logLines.contains(InProcessHelper.connectionRelease) })
    #expect(helper.fake.pmsetWrites == [true, false])
    #expect(helper.fake.sleepDisabled == false)

    harness.clock.advance(seconds: 31)
    await harness.tick(engine, lidClosed: true)
    #expect(swallowing.clearsSwallowed == 1)
    #expect(helper.connectionsMade == 1)
    #expect(helper.fake.pmsetWrites == [true, false])
  }

  @Test func aStopWhoseHelperReleaseUsesItsWholeBoundStillClearsTheAppsOwnBitInsideTheStopBound() async throws {
    let harness = try Harness()
    let helper = InProcessHelper(order: harness.order)
    defer { helper.stop() }
    let swallowing = ClearSwallowingHelper(inner: helper.service)
    helper.listener.delegate = swallowing
    let client = helper.client(timeoutSeconds: Self.outlivesTheStopSeconds)
    let port = XPCHelperPort(client: client)
    let engine = try harness.engine(helper: port, callTimeoutSeconds: Self.shortCallSeconds)
    await harness.engage(engine)
    #expect(harness.order.all == Self.engaged)
    #expect(Self.outlivesTheStopSeconds > Engine.stopWaitSeconds, Self.onlyTheEnginesBound)
    #expect(Engine.stopWaitSeconds - Timing.systemCallTimeoutSeconds == 1)
    #expect(Engine.stopWaitSeconds - Self.shortCallSeconds >= 2)

    let started = ContinuousClock.now
    await engine.stop()
    let stopped = ContinuousClock.now - started
    let cleared = try #require(harness.order.firstSeen(OrderedClamshellPort.offEntry)) - started
    #expect(swallowing.clearsSwallowed == 1)
    #expect(cleared >= .seconds(Self.shortCallSeconds))
    #expect(cleared < .seconds(Engine.stopWaitSeconds))
    #expect(stopped < .seconds(Engine.stopWaitSeconds))
    let entries = harness.recorder.all
    let bye = entries.firstIndex { if case .sentinel("BYE", _) = $0 { return true } else { return false } }
    let closed = entries.firstIndex(of: .sentinelClose)
    #expect(bye != nil)
    #expect(closed != nil)
    if let bye, let closed {
      #expect(bye < closed)
    }
    #expect(harness.logged(Self.releaseTimedOut))
    #expect(!helper.fake.logLines.contains(InProcessHelper.connectionRelease))
    client.invalidate()
    #expect(await OffPool.eventually { helper.fake.logLines.contains(InProcessHelper.connectionRelease) })
    #expect(helper.fake.sleepDisabled == false)
  }

  @Test func aHelperWhoseReplyTheClientRejectsReadsAsNotEngagedAndReleasesWhenTheConnectionIsDropped() async throws {
    let harness = try Harness()
    let helper = InProcessHelper(order: harness.order)
    defer { helper.stop() }
    let port = XPCHelperPort(client: helper.client(requirement: HelperIdentity.release.helperRequirement))
    let engine = try harness.engine(helper: port)
    await harness.engage(engine)
    #expect(harness.logged(" ERROR helper engage failed code=4102 retryIn=30"))
    #expect(!(await engine.currentSnapshot().helperEngaged))
    #expect(await engine.state.hold.lidClose == .held)
    #expect(!port.observations.owns)
    #expect(await OffPool.eventually { helper.fake.logLines.contains(InProcessHelper.connectionRelease) })
    #expect(helper.fake.pmsetWrites == [true, false])
    #expect(helper.fake.sleepDisabled == false)
  }

  @Test func thePortMakesNoConnectionBeforeItsFirstCall() {
    let helper = InProcessHelper()
    defer { helper.stop() }
    let port = XPCHelperPort(client: helper.client())
    #expect(port.observations.current == HelperObservation())
    #expect(helper.connectionsMade == 0)
    #expect(helper.fake.calls.isEmpty)
  }

  @Test func anOwnedSetAndASetOverAValueThatWasAlreadyOnBothEngage() async {
    let owned = InProcessHelper()
    defer { owned.stop() }
    let first = XPCHelperPort(client: owned.client())
    #expect(await Self.run { first.engage() } == .succeeded)
    #expect(first.observations.owns)
    #expect(owned.fake.pmsetWrites == [true])

    let alreadyOn = InProcessHelper(sleepDisabled: true)
    defer { alreadyOn.stop() }
    let second = XPCHelperPort(client: alreadyOn.client())
    #expect(await Self.run { second.engage() } == .succeeded)
    #expect(!second.observations.owns)
    #expect(alreadyOn.fake.pmsetWrites.isEmpty)
    #expect(await Self.probe(second) == .engaged(nil))
    #expect(alreadyOn.connections == 1)
  }

  @Test func aRefusedSetIsAFailureWithTheRefusedCodeAndDropsTheConnection() async {
    let helper = InProcessHelper(lid: false)
    defer { helper.stop() }
    let port = XPCHelperPort(client: helper.client())
    #expect(await Self.run { port.engage() } == .failed(code: LiveInterpreter.helperRefusedCode))
    #expect(helper.fake.holdCalls.isEmpty)
    #expect(!port.observations.owns)
    #expect(await OffPool.eventually { helper.connections == 0 })
    guard case .answered(let status) = await Self.probe(port) else {
      Issue.record("a port that is not engaged asks the helper")
      return
    }
    #expect(!status.engaged)
    #expect(helper.connectionsMade == 2)
  }

  @Test func aHeartbeatToAHelperThatReleasedOnItsOwnFailsAndDropsTheConnection() async {
    let helper = InProcessHelper()
    defer { helper.stop() }
    let port = XPCHelperPort(client: helper.client())
    #expect(await Self.run { port.engage() } == .succeeded)
    #expect(await Self.run { port.heartbeat() } == .succeeded)
    #expect(port.observations.status?.engaged == true)
    #expect(port.observations.owns)
    #expect(helper.connectionsMade == 1)

    helper.fake.setPower(HelperPowerFacts(onBattery: true, percent: 10, warningLevel: HelperPowerFacts.warningNone))
    helper.watch()
    #expect(helper.fake.sleepDisabled == false)
    #expect(await Self.run { port.heartbeat() } == .failed(code: XPCHelperPort.notEngagedCode))
    #expect(port.observations.current == HelperObservation())
    #expect(await OffPool.eventually { helper.connections == 0 })
    guard case .answered = await Self.probe(port) else {
      Issue.record("a port whose heartbeat failed is no longer engaged")
      return
    }
  }

  @Test func aReleaseAlwaysDropsTheConnectionAlsoWhenTheClearDidNotComplete() async {
    let helper = InProcessHelper()
    defer { helper.stop() }
    let port = XPCHelperPort(client: helper.client())
    #expect(await Self.run { port.engage() } == .succeeded)
    #expect(await Self.run { port.release() } == .succeeded)
    #expect(await OffPool.eventually { helper.connections == 0 })
    #expect(helper.fake.pmsetWrites == [true, false])
    #expect(port.observations.current == HelperObservation())

    #expect(await Self.run { port.engage() } == .succeeded)
    helper.fake.setWriteSucceeds(false)
    #expect(await Self.run { port.release() } == .failed(code: LiveInterpreter.helperRefusedCode))
    #expect(await OffPool.eventually { helper.connections == 0 })
    #expect(!port.observations.owns)
    #expect(helper.fake.sleepDisabled == true)
    helper.fake.setWriteSucceeds(true)
    helper.fake.advance(seconds: HelperMachine.retrySeconds)
    helper.watch()
    #expect(helper.fake.sleepDisabled == false)
    #expect(helper.connectionsMade == 2)
  }

  @Test func anAnswerThatArrivesAfterThePortsBoundCountsAsTimedOutAndTheHelperReleases() async {
    let helper = InProcessHelper()
    defer { helper.stop() }
    helper.system.delaySets(seconds: 0.8)
    let port = XPCHelperPort(client: helper.client(), boundSeconds: 0.3)
    #expect(await Self.run { port.engage() } == .timedOut)
    #expect(!port.observations.owns)
    #expect(await OffPool.eventually { helper.fake.logLines.contains(InProcessHelper.connectionRelease) })
    #expect(helper.fake.pmsetWrites == [true, false])
    guard case .answered(let status) = await Self.probe(port) else {
      Issue.record("a port whose engage came too late is not engaged")
      return
    }
    #expect(!status.engaged)
  }

  @Test func anEngageThatWaitedPastItsBoundBehindAnotherCallNeverReachesTheHelper() async {
    let silent = SilentHelper()
    defer { silent.stop() }
    let port = XPCHelperPort(client: silent.client(timeoutSeconds: 10), boundSeconds: 0.3)
    async let probing = Self.probe(port)
    #expect(await OffPool.eventually(seconds: 5) { silent.statuses == 1 })
    #expect(await Self.run { port.engage() } == .timedOut)
    #expect(await probing == .unreachable(XPCHelperPort.timedOutReason))
    #expect(silent.sets.isEmpty)
    #expect(silent.statuses == 1)
  }

  @Test func aProbeAsksTheHelperOnlyWhileThePortIsNotEngagedAndSharesItsOneConnection() async {
    let helper = InProcessHelper()
    defer { helper.stop() }
    let port = XPCHelperPort(client: helper.client())
    guard case .answered(let idle) = await Self.probe(port) else {
      Issue.record("an idle port asks the helper")
      return
    }
    #expect(!idle.engaged)
    #expect(!idle.exiting)
    #expect(idle.helperVersion == HelperIdentity.version)
    #expect(port.observations.status == idle)
    #expect(helper.statusCalls == 1)

    #expect(await Self.run { port.engage() } == .succeeded)
    #expect(helper.connectionsMade == 1)
    helper.fake.forget()
    #expect(await Self.probe(port) == .engaged(idle))
    #expect(helper.fake.calls.isEmpty)

    #expect(await Self.run { port.release() } == .succeeded)
    helper.fake.forget()
    guard case .answered(let after) = await Self.probe(port) else {
      Issue.record("a released port asks the helper again")
      return
    }
    #expect(!after.engaged)
    #expect(helper.statusCalls == 1)
    #expect(helper.connectionsMade == 2)
  }

  @Test func aProbeMadeWhileAReleaseIsInFlightWaitsForItAndStillGetsTheHelpersAnswer() async {
    let order = HelperCallOrder()
    let helper = InProcessHelper(order: order)
    defer { helper.stop() }
    let port = XPCHelperPort(client: helper.client())
    #expect(await Self.run { port.engage() } == .succeeded)
    helper.system.delayClears(seconds: 0.5)
    async let releasing = Self.run { port.release() }
    #expect(await OffPool.eventually { order.all.contains(OrderedHelperSystem.clearEntry) })
    guard case .answered(let status) = await Self.probe(port) else {
      Issue.record("a probe made during a release gets the helper's answer once the release is done")
      _ = await releasing
      return
    }
    #expect(!status.engaged)
    #expect(!status.owns)
    #expect(await releasing == .succeeded)
    #expect(port.observations.status == status)
    #expect(helper.connectionsMade == 2)
  }

  @Test func aProbeOfAHelperThatDoesNotAnswerIsUnreachableAndForgetsTheLastAnswer() async {
    let silent = SilentHelper(answeringStatuses: 1)
    defer { silent.stop() }
    let port = XPCHelperPort(client: silent.client(timeoutSeconds: HelperXPCClient.defaultTimeoutSeconds))
    let first = HelperStatus(helperVersion: HelperIdentity.version)
    #expect(await Self.probe(port) == .answered(first))
    #expect(port.observations.status == first)
    #expect(await Self.probe(port) == .unreachable(XPCHelperPort.timedOutReason))
    #expect(port.observations.current == HelperObservation())
    #expect(await OffPool.eventually { silent.ended == 1 })
    #expect(silent.connectionsMade == 1)

    let refusing = InProcessHelper()
    defer { refusing.stop() }
    let rejected = XPCHelperPort(client: refusing.client(requirement: HelperIdentity.dev.helperRequirement))
    #expect(await Self.probe(rejected) == .unreachable("NSCocoaErrorDomain 4102"))

    let broken = SilentHelper(answeringStatuses: 1, thenGarbage: true)
    defer { broken.stop() }
    let failing = XPCHelperPort(client: broken.client(timeoutSeconds: 5))
    #expect(await Self.probe(failing) == .answered(first))
    #expect(failing.observations.status == first)
    #expect(await Self.probe(failing) == .unreachable(HelperXPCClient.undecodableStatusReason))
    #expect(failing.observations.current == HelperObservation())
  }

  @Test func aFailureReasonBecomesItsErrorCodeAndAnythingElseTheUnavailableCode() {
    #expect(XPCHelperPort.code(forFailure: "NSCocoaErrorDomain 4097") == 4097)
    #expect(XPCHelperPort.code(forFailure: "NSCocoaErrorDomain 4102") == 4102)
    #expect(XPCHelperPort.code(forFailure: "NSPOSIXErrorDomain -3") == -3)
    let unavailable = LiveInterpreter.helperUnavailableCode
    for reason in [
      "replyCode 9", HelperXPCClient.undecodableStatusReason, HelperXPCClient.noProxyReason, "", "A B 7",
      "Domain x", "Domain 99999999999", "Domain 5 extra",
    ] {
      #expect(XPCHelperPort.code(forFailure: reason) == unavailable)
    }
  }

  @Test func thePortsOwnCodeAndBoundAreTheDocumentedOnes() {
    #expect(XPCHelperPort.notEngagedCode == -6)
    let codes = [
      LiveInterpreter.unwatchedWriteCode, LiveInterpreter.toolLaunchFailedCode, LiveInterpreter.unpersistedWriteCode,
      LiveInterpreter.helperUnavailableCode, LiveInterpreter.helperRefusedCode, XPCHelperPort.notEngagedCode,
    ]
    #expect(Set(codes).count == codes.count)
    #expect(XPCHelperPort.defaultBoundSeconds == 4.75)
    #expect(XPCHelperPort.defaultBoundSeconds < Timing.systemCallTimeoutSeconds)
    #expect(XPCHelperPort.defaultBoundSeconds < HelperXPCClient.defaultTimeoutSeconds)
    #expect(XPCHelperPort.timedOutReason == "timedOut")
  }

  @Test func theSnapshotReadsEngagedOnlyWhileTheHelperIsEngagingOrEngaged() {
    let id = EffectID(value: 7)
    #expect(EngineSnapshot.helperEngaged(.engaging(id)))
    #expect(EngineSnapshot.helperEngaged(.engaged))
    #expect(!EngineSnapshot.helperEngaged(.idle))
    #expect(!EngineSnapshot.helperEngaged(.releasing(id)))
    #expect(!EngineSnapshot.helperEngaged(.failed(retryAt: Instant(nanoseconds: 1))))
    var state = AppState(mode: .live)
    #expect(EngineSnapshot(state: state).helperFacts == nil)
    #expect(!EngineSnapshot(state: state).helperEngaged)
    state.helper.facts = Self.ready
    state.helper.phase = .engaged
    #expect(EngineSnapshot(state: state).helperFacts == Self.ready)
    #expect(EngineSnapshot(state: state).helperEngaged)
    #expect(EngineSnapshot() == EngineSnapshot(helperEngaged: false, helperFacts: nil))
  }

  @Test func theHostPassesHelperFactsToTheEngineInsideItsBound() async throws {
    let harness = try Harness()
    let fake = FakeHelperPort()
    let engine = try harness.engine(helper: fake)
    let host = LiveEngineHost(engine: engine, clock: harness.clock)
    let quick = LiveEngineHost(engine: engine, clock: harness.clock, boundSeconds: 0.2)
    let facts = HelperFacts(installed: true, reachable: false, current: true, owns: false, sleepDisabled: true)
    await host.updateHelper(facts)
    #expect(await engine.state.helper.facts == facts)
    #expect(await host.probe()?.helperFacts == facts)
    #expect(fake.calls.isEmpty)

    await harness.work(engine, lidClosed: true)
    fake.holdNext(.engage)
    defer { fake.releaseHeld() }
    await quick.updateHelper(Self.ready)
    #expect(fake.heldReturned == 0, "the host returned inside its bound while the engage it caused is still blocked")
    fake.releaseHeld()
    #expect(await EffectOrderTests.poll(within: 5) { await engine.state.helper.phase == .engaged })
    #expect(fake.calls == [.engage])
  }
}
