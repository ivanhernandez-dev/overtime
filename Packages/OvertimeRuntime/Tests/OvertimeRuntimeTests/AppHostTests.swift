import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing
import os

struct AppHostTests {
  struct Fixture {
    let temp: TempDirectory
    let paths: Paths
    let locks: HeldLocks

    init() throws {
      temp = try TempDirectory()
      paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path], homeDirectory: "/Users/dev")
      try paths.createDirectories()
      locks = HeldLocks(primary: try InstanceLock.acquire(at: paths.lockFile(.live)), secondary: nil)
    }

    func host(_ launcher: @escaping AppHostLauncher) -> AppHost {
      AppHost(paths: paths, version: "0.1.0", environment: [:], homeDirectory: "/Users/dev", launcher: launcher)
    }

    var lockIsFree: Bool {
      guard let lock = try? InstanceLock.acquire(at: paths.lockFile(.live)) else { return false }
      lock.release()
      return true
    }
  }

  @Test func anUnavailableSentinelBlocksAndKeepsTheLocksUntilTheQuit() async throws {
    let fixture = try Fixture()
    let passedLock = OSAllocatedUnfairLock<InstanceLock?>(initialState: nil)
    let host = fixture.host { launch in
      passedLock.withLock { $0 = launch.lock }
      throw CompositionError.sentinelUnavailable("spawn failed")
    }
    guard case .blocked(let failure) = await host.start(locks: fixture.locks) else {
      Issue.record("expected blocked")
      return
    }
    #expect(failure == .sentinelUnavailable)
    #expect(passedLock.withLock { $0 } === fixture.locks.primary)
    #expect(!fixture.lockIsFree)
    #expect(await host.terminate())
    #expect(fixture.lockIsFree)
  }

  final class NetworkLaunches: Sendable {
    private let ports = OSAllocatedUnfairLock<[any NetworkPort]>(initialState: [])
    private let sinks = OSAllocatedUnfairLock<[@Sendable (Decision) -> Void]>(initialState: [])

    var received: [any NetworkPort] {
      ports.withLock { $0 }
    }

    var attached: [@Sendable (Decision) -> Void] {
      sinks.withLock { $0 }
    }

    func record(_ port: any NetworkPort) {
      ports.withLock { $0.append(port) }
    }

    func attach(_ sink: @escaping @Sendable (Decision) -> Void) {
      sinks.withLock { $0.append(sink) }
    }

    func launcher(paths: Paths) -> AppHostLauncher {
      { launch in
        self.record(launch.network)
        return try Composition.launchShadow(
          paths: paths, settings: launch.settings, environment: [:],
          homeDirectory: paths.supportDirectory.path(percentEncoded: false), once: true)
      }
    }
  }

  static let marker = Decision(
    keyword: .error, verb: "net failed",
    fields: [DecisionField(key: "action", value: "wifiOn"), DecisionField(key: "result", value: "-29")])

  @Test func theNetworkPortReachesTheLauncherRecoversAtStartAndStopAndLogsIntoTheEngine() async throws {
    let fixture = try Fixture()
    let launches = NetworkLaunches()
    let port = ClosureNetworkPort(onAttach: { launches.attach($0) })
    let host = AppHost(
      paths: fixture.paths, version: "0.1.0", environment: [:], homeDirectory: "/Users/dev", network: port,
      launcher: launches.launcher(paths: fixture.paths))
    guard case .running = await host.start(locks: fixture.locks) else {
      Issue.record("the host did not start")
      return
    }
    #expect(launches.received.count == 1)
    #expect(launches.received.first is ClosureNetworkPort)
    #expect(await OffPool.eventually(seconds: 5) { port.recoverCount == 1 })
    let sink = try #require(launches.attached.last)
    sink(Self.marker)
    let log = fixture.paths.decisionLog(.shadow)
    #expect(
      await OffPool.eventually(seconds: 5) {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains(" ERROR net failed action=wifiOn result=-29")
      })
    #expect(port.recoverCount == 1)
    #expect(await host.terminate())
    #expect(port.recoverCount == 2)
  }

  @Test func anAppHostBuiltWithoutANetworkPortPassesTheNoNetworkPortAtStartAndAfterARestart() async throws {
    let fixture = try Fixture()
    let launches = NetworkLaunches()
    let host = AppHost(
      paths: fixture.paths, version: "0.1.0", environment: [:], homeDirectory: "/Users/dev",
      launcher: launches.launcher(paths: fixture.paths))
    guard case .running = await host.start(locks: fixture.locks) else {
      Issue.record("the host did not start")
      return
    }
    guard case .running = await host.restart(with: Settings()) else {
      Issue.record("the host did not restart")
      return
    }
    #expect(launches.received.count == 2)
    #expect(launches.received.allSatisfy { $0 is NoNetworkPort })
    #expect(await host.terminate())
  }

  @Test func aRestartPassesTheSamePortAndAttachesTheLogToTheNewEngine() async throws {
    let fixture = try Fixture()
    let launches = NetworkLaunches()
    let port = ClosureNetworkPort(onAttach: { launches.attach($0) })
    let host = AppHost(
      paths: fixture.paths, version: "0.1.0", environment: [:], homeDirectory: "/Users/dev", network: port,
      launcher: launches.launcher(paths: fixture.paths))
    guard case .running = await host.start(locks: fixture.locks) else {
      Issue.record("the host did not start")
      return
    }
    #expect(await OffPool.eventually(seconds: 5) { port.recoverCount == 1 })
    guard case .running = await host.restart(with: Settings()) else {
      Issue.record("the host did not restart")
      return
    }
    #expect(launches.received.count == 2)
    #expect(launches.received.allSatisfy { $0 is ClosureNetworkPort })
    #expect(launches.attached.count == 2)
    let recoveries = port.recoverCount
    #expect(recoveries == 1)
    for received in launches.received {
      _ = received.recoverIfLeftOff()
    }
    #expect(port.recoverCount == recoveries + 2)
    #expect(await host.terminate())
  }

  @Test func aBlockedStartStillRecoversWiFiLeftOffOnce() async throws {
    let fixture = try Fixture()
    let port = ClosureNetworkPort()
    let host = AppHost(
      paths: fixture.paths, version: "0.1.0", environment: [:], homeDirectory: "/Users/dev", network: port,
      launcher: { _ in throw CompositionError.sentinelUnavailable("spawn failed") })
    guard case .blocked = await host.start(locks: fixture.locks) else {
      Issue.record("expected blocked")
      return
    }
    #expect(await OffPool.eventually(seconds: 5) { port.recoverCount == 1 })
    #expect(await host.terminate())
    #expect(port.recoverCount == 2)
  }

  @Test func aBlockedStartLogsAWiFiRecoveryFailureThroughTheFallbackAtStartAndAtStop() async throws {
    let fixture = try Fixture()
    let launches = NetworkLaunches()
    let logged = OSAllocatedUnfairLock<[Decision]>(initialState: [])
    let port = ClosureNetworkPort(
      onRecover: {
        for sink in launches.attached { sink(Self.marker) }
        return .failed(code: -29)
      },
      onAttach: { launches.attach($0) })
    let host = AppHost(
      paths: fixture.paths, version: "0.1.0", environment: [:], homeDirectory: "/Users/dev", network: port,
      fallbackLog: { decision in logged.withLock { $0.append(decision) } },
      launcher: { _ in throw CompositionError.sentinelUnavailable("spawn failed") })
    guard case .blocked = await host.start(locks: fixture.locks) else {
      Issue.record("expected blocked")
      return
    }
    #expect(await OffPool.eventually(seconds: 5) { logged.withLock { $0 } == [Self.marker] })
    #expect(launches.attached.count == 1)
    #expect(await host.terminate())
    #expect(port.recoverCount == 2)
    #expect(logged.withLock { $0 } == [Self.marker, Self.marker])
  }

  @Test func aStopRecoveryThatHangsIsCutAtItsBoundInsideTheTermination() async throws {
    let fixture = try Fixture()
    let gate = DispatchSemaphore(value: 0)
    let calls = OSAllocatedUnfairLock(initialState: 0)
    let port = ClosureNetworkPort(onRecover: {
      let call = calls.withLock { calls -> Int in
        calls += 1
        return calls
      }
      if call == 2 { gate.wait() }
      return .succeeded
    })
    defer { gate.signal() }
    let launches = NetworkLaunches()
    let host = AppHost(
      paths: fixture.paths, version: "0.1.0", environment: [:], homeDirectory: "/Users/dev", network: port,
      launcher: launches.launcher(paths: fixture.paths))
    guard case .running = await host.start(locks: fixture.locks) else {
      Issue.record("the host did not start")
      return
    }
    #expect(await OffPool.eventually(seconds: 5) { port.recoverCount == 1 })
    let start = ContinuousClock.now
    #expect(await host.terminate())
    let elapsed = ContinuousClock.now - start
    #expect(port.recoverCount == 2)
    #expect(elapsed >= .seconds(AppHost.stopRecoverySeconds) - .milliseconds(100))
    #expect(elapsed < .seconds(TerminationCoordinator.defaultOuterBoundSeconds))
  }

  @Test func aLockHeldElsewhereMapsToCouldNotStart() async throws {
    let fixture = try Fixture()
    let host = fixture.host { _ in throw CompositionError.alreadyRunning(.live) }
    guard case .blocked(let failure) = await host.start(locks: fixture.locks) else {
      Issue.record("expected blocked")
      return
    }
    #expect(failure == .lockHeldElsewhere)
    #expect(!fixture.lockIsFree)
    #expect(await host.terminate())
    #expect(fixture.lockIsFree)
  }
}
