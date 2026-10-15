import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import OvertimeHelperClient
import OvertimeHelperCore
import OvertimeSystem
import Testing
import os

struct HelperAbsentTests {
  enum Known: String, Sendable, CaseIterable, CustomTestStringConvertible {
    case nothing
    case notInstalled
    case unreachable
    case outOfDate

    var testDescription: String { rawValue }

    var facts: HelperFacts? {
      switch self {
      case .nothing: nil
      case .notInstalled: HelperFacts(installed: false, reachable: false, current: false)
      case .unreachable: HelperFacts(installed: true, reachable: false, current: true)
      case .outOfDate: HelperFacts(installed: true, reachable: true, current: false)
      }
    }
  }

  final class Launches: Sendable {
    private let passed = OSAllocatedUnfairLock<[any HelperPort]>(initialState: [])

    var helpers: [any HelperPort] {
      passed.withLock { $0 }
    }

    func record(_ helper: any HelperPort) {
      passed.withLock { $0.append(helper) }
    }
  }

  struct HostFixture {
    let temp: TempDirectory
    let paths: Paths
    let home: String
    let locks: HeldLocks
    let launches = Launches()

    init() throws {
      temp = try TempDirectory()
      paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path + "/root"], homeDirectory: temp.path)
      home = temp.path + "/home"
      try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
      try paths.createDirectories()
      locks = HeldLocks(primary: try InstanceLock.acquire(at: paths.lockFile(.live)), secondary: nil)
    }

    func launcher() -> AppHostLauncher {
      let launches = launches
      let paths = paths
      let home = home
      return { launch in
        launches.record(launch.helper)
        return try Composition.launchShadow(
          paths: paths, settings: launch.settings, environment: [:], homeDirectory: home, once: true)
      }
    }
  }

  static func busyLidClosedRun(
    _ harness: EngineHelperTests.Harness, _ engine: Engine, facts: HelperFacts?
  ) async {
    if let facts {
      await engine.updateHelper(facts)
    }
    await harness.work(engine, lidClosed: true)
    await engine.step(EngineHelperTests.lidOpen)
    await engine.step(EngineHelperTests.lidClose)
    await engine.step(.command(.sleepNow))
    await engine.step(.systemHasPoweredOn)
    await harness.tick(engine, lidClosed: true)
    harness.clock.advance(seconds: 31)
    await harness.work(engine, lidClosed: true)
    await engine.step(.command(.pause(.indefinite)))
    await engine.step(.command(.resume))
    await harness.tick(engine, lidClosed: true)
    await engine.stop()
  }

  static func helperLines(_ harness: EngineHelperTests.Harness) -> [Substring] {
    let text = (try? String(contentsOf: harness.decisionLog, encoding: .utf8)) ?? ""
    return text.split(separator: "\n").filter { $0.contains(" helper ") }
  }

  @Test func portsBuiltWithoutAHelperAnswerEveryHelperCallAsUnavailable() throws {
    let harness = try EngineHelperTests.Harness()
    let recorder = harness.recorder
    let ports = LivePorts(
      assertions: FakeAssertionPort(), tools: harness.tools, clamshell: FakeClamshellPort(recorder: recorder),
      stateFile: harness.paths.stateFile(.live), makeSentinel: { FakeSentinelPort(recorder: recorder) })
    #expect(ports.helper is NoHelperPort)
    let unavailable = EffectOutcome.failed(code: LiveInterpreter.helperUnavailableCode)
    #expect(ports.helper.engage() == unavailable)
    #expect(ports.helper.heartbeat() == unavailable)
    #expect(ports.helper.release() == unavailable)
    #expect(recorder.all.isEmpty)
    #expect(harness.tools.calls.isEmpty)
  }

  @Test(arguments: Known.allCases)
  func withoutReadyFactsABusyLidClosedRunSendsNoHelperEffect(_ known: Known) async throws {
    let harness = try EngineHelperTests.Harness()
    let fake = FakeHelperPort()
    let engine = try harness.engine(helper: fake)
    await Self.busyLidClosedRun(harness, engine, facts: known.facts)
    #expect(fake.calls.isEmpty)
    #expect(Self.helperLines(harness).isEmpty)
    #expect(harness.order.all.contains(OrderedClamshellPort.onEntry))
    #expect(harness.order.all.contains(OrderedClamshellPort.offEntry))
    #expect(harness.order.all.contains(EngineHelperTests.sleepEntry))
  }

  @Test(arguments: Known.allCases)
  func withoutReadyFactsAnXPCPortMakesNoConnectionAcrossAWholeEngineRun(_ known: Known) async throws {
    let harness = try EngineHelperTests.Harness()
    let helper = InProcessHelper(order: harness.order)
    defer { helper.stop() }
    let port = XPCHelperPort(client: helper.client())
    let engine = try harness.engine(helper: port)
    await Self.busyLidClosedRun(harness, engine, facts: known.facts)
    #expect(helper.connectionsMade == 0)
    #expect(helper.fake.calls.isEmpty)
    #expect(port.observations.current == HelperObservation())
    #expect(!(await engine.currentSnapshot().helperEngaged))
    #expect(harness.order.all.contains(OrderedClamshellPort.onEntry))
  }

  @Test func withReadyFactsTheSameRunDoesReachTheHelper() async throws {
    let harness = try EngineHelperTests.Harness()
    let helper = InProcessHelper(order: harness.order)
    defer { helper.stop() }
    let port = XPCHelperPort(client: helper.client())
    let engine = try harness.engine(helper: port)
    await Self.busyLidClosedRun(harness, engine, facts: EngineHelperTests.ready)
    #expect(helper.connectionsMade >= 1)
    #expect(helper.fake.pmsetWrites.first == true)
    #expect(helper.fake.pmsetWrites.last == false)
    #expect(helper.fake.sleepDisabled == false)
    #expect(!Self.helperLines(harness).isEmpty)
  }

  static let closing = [EngineSnapshot(lidClosed: false), EngineSnapshot(lidClosed: true)]

  @Test(arguments: [HelperInstallerStatus.notRegistered, .notFound, .requiresApproval])
  func aRefreshAtLaunchAndAtALidCloseWhileTheHelperIsNotEnabledMakesNoConnectionAndRegistersNothing(
    _ status: HelperInstallerStatus
  ) async {
    let helper = InProcessHelper()
    defer { helper.stop() }
    let installer = FakeHelperInstaller(status: status)
    let host = ScriptedSnapshotHost()
    let port = XPCHelperPort(client: helper.client())
    let monitor = HelperMonitor(installer: installer, port: port)
    defer { monitor.stop() }
    monitor.start(host: host)
    #expect(await OffPool.eventually { !host.helperUpdates.isEmpty })
    for snapshot in Self.closing {
      host.yield(snapshot)
    }
    #expect(await OffPool.eventually { installer.statusReads == 2 })
    await monitor.refresh()
    #expect(installer.statusReads == 3)
    #expect(
      host.helperUpdates == [HelperFacts(installed: status == .requiresApproval, reachable: false, current: false)])
    #expect(host.helperUpdates.allSatisfy { !$0.ready })
    #expect(helper.connectionsMade == 0)
    #expect(helper.fake.calls.isEmpty)
    #expect(installer.calls.isEmpty)
    #expect(port.observations.current == HelperObservation())
    #expect(monitor.state.installer == status)
    #expect(monitor.state.reachability == .unknown)
    #expect(monitor.state.status == nil)
    #expect(HelperStatusPresentation.derive(monitor.state, engaged: false) != .onStandingBy)
  }

  @Test func withTheHelperEnabledTheSameRefreshesDoReachTheHelperAndStillRegisterNothing() async {
    let helper = InProcessHelper()
    defer { helper.stop() }
    let installer = FakeHelperInstaller(status: .enabled)
    let host = ScriptedSnapshotHost()
    let monitor = HelperMonitor(installer: installer, port: XPCHelperPort(client: helper.client()))
    defer { monitor.stop() }
    monitor.start(host: host)
    #expect(await OffPool.eventually { !host.helperUpdates.isEmpty })
    for snapshot in Self.closing {
      host.yield(snapshot)
    }
    #expect(await OffPool.eventually { helper.statusCalls == 2 })
    #expect(helper.connectionsMade == 1)
    #expect(host.helperUpdates.allSatisfy { $0.ready })
    #expect(installer.calls.isEmpty)
  }

  @Test(arguments: [HelperInstallerStatus.notRegistered, .notFound, .requiresApproval])
  func withTheMonitorFeedingTheEngineAHelperThatIsNotEnabledIsNeverReachedAcrossAWholeRun(
    _ status: HelperInstallerStatus
  ) async throws {
    let harness = try EngineHelperTests.Harness()
    let helper = InProcessHelper(order: harness.order)
    defer { helper.stop() }
    let port = XPCHelperPort(client: helper.client())
    let engine = try harness.engine(helper: port)
    let installer = FakeHelperInstaller(status: status)
    let monitor = HelperMonitor(installer: installer, port: port)
    defer { monitor.stop() }
    monitor.start(host: LiveEngineHost(engine: engine, clock: harness.clock))
    await monitor.refresh()
    #expect(await engine.currentSnapshot().helperFacts?.ready == false)
    await Self.busyLidClosedRun(harness, engine, facts: nil)
    await monitor.refresh()
    #expect(helper.connectionsMade == 0)
    #expect(helper.fake.calls.isEmpty)
    #expect(installer.calls.isEmpty)
    #expect(Self.helperLines(harness).isEmpty)
    #expect(port.observations.current == HelperObservation())
    #expect(harness.order.all.contains(OrderedClamshellPort.onEntry))
    #expect(harness.order.all.contains(OrderedClamshellPort.offEntry))
  }

  @Test func withTheMonitorFeedingTheEngineAnEnabledHelperIsEngagedInTheSameRun() async throws {
    let harness = try EngineHelperTests.Harness()
    let helper = InProcessHelper(order: harness.order)
    defer { helper.stop() }
    let port = XPCHelperPort(client: helper.client())
    let engine = try harness.engine(helper: port)
    let installer = FakeHelperInstaller(status: .enabled)
    let monitor = HelperMonitor(installer: installer, port: port)
    defer { monitor.stop() }
    monitor.start(host: LiveEngineHost(engine: engine, clock: harness.clock))
    await monitor.refresh()
    #expect(await engine.currentSnapshot().helperFacts?.ready == true)
    await Self.busyLidClosedRun(harness, engine, facts: nil)
    #expect(helper.fake.pmsetWrites.first == true)
    #expect(helper.fake.pmsetWrites.last == false)
    #expect(helper.fake.sleepDisabled == false)
    #expect(!Self.helperLines(harness).isEmpty)
    #expect(installer.calls.isEmpty)
  }

  @Test func anAppHostCreatedWithoutAHelperPassesTheNoHelperPortToItsLauncher() async throws {
    let fixture = try HostFixture()
    let host = AppHost(
      paths: fixture.paths, version: "0.1.0", environment: [:], homeDirectory: fixture.home,
      launcher: fixture.launcher())
    guard case .running = await host.start(locks: fixture.locks) else {
      Issue.record("the host did not start")
      return
    }
    guard case .running = await host.restart(with: Settings()) else {
      Issue.record("the host did not restart")
      return
    }
    #expect(fixture.launches.helpers.count == 2)
    #expect(fixture.launches.helpers.allSatisfy { $0 is NoHelperPort })
    #expect(await host.terminate())
  }

  @Test func anAppHostCreatedWithAHelperPassesThatPortAtStartAndAfterARestart() async throws {
    let fixture = try HostFixture()
    let fake = FakeHelperPort()
    let host = AppHost(
      paths: fixture.paths, version: "0.1.0", environment: [:], homeDirectory: fixture.home, helper: fake,
      launcher: fixture.launcher())
    guard case .running = await host.start(locks: fixture.locks) else {
      Issue.record("the host did not start")
      return
    }
    guard case .running = await host.restart(with: Settings()) else {
      Issue.record("the host did not restart")
      return
    }
    #expect(fixture.launches.helpers.count == 2)
    #expect(fixture.launches.helpers.allSatisfy { ($0 as? FakeHelperPort) === fake })
    #expect(fake.calls.isEmpty)
    #expect(await host.terminate())
  }
}
