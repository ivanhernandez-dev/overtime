import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing
import os

@Suite(.serialized)
struct AppHostRestartTests {
  final class Fixture: @unchecked Sendable {
    let temp: TempDirectory
    let paths: Paths
    let home: String
    let secondaryLockFile: URL
    let locks: HeldLocks
    private let events = OSAllocatedUnfairLock<[String]>(initialState: [])
    private let failing = OSAllocatedUnfairLock(initialState: false)
    private let gate = OSAllocatedUnfairLock<DispatchSemaphore?>(initialState: nil)

    init() throws {
      temp = try TempDirectory()
      paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path + "/root"], homeDirectory: temp.path)
      home = temp.path + "/home"
      try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
      try paths.createDirectories()
      secondaryLockFile = URL(fileURLWithPath: temp.path + "/secondary.lock")
      locks = HeldLocks(
        primary: try InstanceLock.acquire(at: paths.lockFile(.live)),
        secondary: try InstanceLock.acquire(at: secondaryLockFile))
    }

    var launches: [String] {
      events.withLock { $0 }
    }

    func failNextLaunches() {
      failing.withLock { $0 = true }
    }

    func holdNextLaunch(_ semaphore: DispatchSemaphore) {
      gate.withLock { $0 = semaphore }
    }

    var decisionLines: [String] {
      guard let text = try? String(contentsOf: paths.decisionLog(.shadow), encoding: .utf8) else { return [] }
      return text.split(separator: "\n").map(String.init)
    }

    var stopCount: Int {
      decisionLines.filter { $0.contains(" STOP shadow") }.count
    }

    var stampExists: Bool {
      FileManager.default.fileExists(atPath: paths.relaunchSuppression.path(percentEncoded: false))
    }

    func waitForLaunch() async throws {
      let deadline = ContinuousClock.now + .seconds(10)
      while !launches.contains("waiting"), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
    }

    func isFree(_ url: URL) -> Bool {
      guard let lock = try? InstanceLock.acquire(at: url) else { return false }
      lock.release()
      return true
    }

    func host() -> AppHost {
      AppHost(
        paths: paths, version: "0.1.0", environment: [:], homeDirectory: home,
        launcher: { [self] launch in
          if let semaphore = gate.withLock({ $0 }) {
            events.withLock { $0.append("waiting") }
            _ = semaphore.wait(timeout: .now() + 10)
          }
          let primaryFree = isFree(paths.lockFile(.live))
          events.withLock {
            $0.append(
              "launch lock=\(launch.lock == nil ? "nil" : "held") stops=\(stopCount) primaryFree=\(primaryFree)")
          }
          if failing.withLock({ $0 }) {
            throw CompositionError.alreadyRunning(.live)
          }
          return try Composition.launchShadow(
            paths: paths, settings: launch.settings, environment: [:], homeDirectory: home, once: true)
        })
    }
  }

  static let newSettings = Settings(batteryLowPercent: 15, batteryResumePercent: 30)

  static func running(_ start: AppHostStart) -> LiveEngineHost? {
    guard case .running(let host) = start else { return nil }
    return host
  }

  @Test func aRestartStopsTheOldEngineOnceBeforeRelaunchingWithTheNewSettings() async throws {
    let fixture = try Fixture()
    let host = fixture.host()
    let first = try #require(Self.running(await host.start(locks: fixture.locks)))
    #expect(await first.engine.currentSnapshot().batteryLowPercent == Settings().batteryLowPercent)

    let second = try #require(Self.running(await host.restart(with: Self.newSettings)))
    #expect(second.engine !== first.engine)
    #expect(
      fixture.launches == [
        "launch lock=held stops=0 primaryFree=false", "launch lock=held stops=1 primaryFree=false",
      ])
    #expect(!fixture.isFree(fixture.paths.lockFile(.live)))
    #expect(fixture.stopCount == 1)
    let snapshot = await second.engine.currentSnapshot()
    #expect(snapshot.batteryLowPercent == 15)
    #expect(snapshot.batteryResumePercent == 30)
    #expect(host.runningHost?.engine === second.engine)
    #expect(!fixture.isFree(fixture.secondaryLockFile))

    #expect(await host.terminate())
    #expect(fixture.stopCount == 2)
    #expect(fixture.isFree(fixture.secondaryLockFile))
    #expect(fixture.isFree(fixture.paths.lockFile(.shadow)))
  }

  @Test func aLauncherThatThrowsKeepsTheInstanceLocksUntilTheQuit() async throws {
    let fixture = try Fixture()
    let host = fixture.host()
    _ = try #require(Self.running(await host.start(locks: fixture.locks)))
    fixture.failNextLaunches()
    guard case .blocked(let failure) = await host.restart(with: Self.newSettings) else {
      Issue.record("expected blocked")
      return
    }
    #expect(failure == .lockHeldElsewhere)
    #expect(fixture.stopCount == 1)
    #expect(host.runningHost == nil)
    #expect(fixture.isFree(fixture.paths.lockFile(.shadow)))
    #expect(!fixture.isFree(fixture.paths.lockFile(.live)))
    #expect(!fixture.isFree(fixture.secondaryLockFile))
    #expect(await host.terminate())
    #expect(fixture.stopCount == 1)
    #expect(fixture.isFree(fixture.paths.lockFile(.live)))
    #expect(fixture.isFree(fixture.secondaryLockFile))
  }

  @Test func aRestartDuringARestartAwaitsTheFirst() async throws {
    let fixture = try Fixture()
    let host = fixture.host()
    _ = try #require(Self.running(await host.start(locks: fixture.locks)))
    let semaphore = DispatchSemaphore(value: 0)
    fixture.holdNextLaunch(semaphore)
    let firstRestart = Task { await host.restart(with: Self.newSettings) }
    let secondRestart = Task { await host.restart(with: Settings(batteryLowPercent: 5, batteryResumePercent: 50)) }
    let deadline = ContinuousClock.now + .seconds(10)
    while !fixture.launches.contains("waiting"), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try await Task.sleep(for: .milliseconds(200))
    semaphore.signal()
    let first = try #require(Self.running(await firstRestart.value))
    let second = try #require(Self.running(await secondRestart.value))
    #expect(first.engine === second.engine)
    #expect(fixture.launches.filter { $0.hasPrefix("launch") }.count == 2)
    #expect(fixture.stopCount == 1)
    #expect(await host.terminate())
  }

  @Test func aQuitDuringARestartLaunchStopsTheFreshEngineAndNeverInstallsIt() async throws {
    let fixture = try Fixture()
    let host = fixture.host()
    _ = try #require(Self.running(await host.start(locks: fixture.locks)))
    let semaphore = DispatchSemaphore(value: 0)
    fixture.holdNextLaunch(semaphore)
    let restart = Task { await host.restart(with: Self.newSettings) }
    let deadline = ContinuousClock.now + .seconds(10)
    while !fixture.launches.contains("waiting"), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(fixture.stopCount == 1)
    let quit = Task { await host.terminate() }
    try await Task.sleep(for: .milliseconds(200))
    semaphore.signal()
    guard case .blocked = await restart.value else {
      Issue.record("expected blocked")
      return
    }
    #expect(await quit.value)
    #expect(fixture.stopCount == 2)
    #expect(host.runningHost == nil)
    #expect(fixture.isFree(fixture.paths.lockFile(.shadow)))
    #expect(fixture.isFree(fixture.paths.lockFile(.live)))
    #expect(fixture.isFree(fixture.secondaryLockFile))
  }

  @Test func aQuitDuringASlowStartStopsTheFreshEngineAndKeepsTheSuppressionStamp() async throws {
    let fixture = try Fixture()
    let host = fixture.host()
    let semaphore = DispatchSemaphore(value: 0)
    fixture.holdNextLaunch(semaphore)
    let start = host.beginStart(locks: fixture.locks)
    try await fixture.waitForLaunch()
    let quit = Task { await host.terminate() }
    try await Task.sleep(for: .milliseconds(200))
    #expect(fixture.stampExists)
    semaphore.signal()
    guard case .blocked = await start.value else {
      Issue.record("expected blocked")
      return
    }
    #expect(await quit.value)
    #expect(fixture.stopCount == 1)
    #expect(host.runningHost == nil)
    #expect(fixture.stampExists)
    #expect(fixture.isFree(fixture.paths.lockFile(.shadow)))
    #expect(fixture.isFree(fixture.paths.lockFile(.live)))
    #expect(fixture.isFree(fixture.secondaryLockFile))
  }

  @Test func aQuitBeforeTheStartNeverLaunchesAndStillStampsSuppression() async throws {
    let fixture = try Fixture()
    let host = fixture.host()
    #expect(await host.terminate())
    #expect(fixture.stampExists)
    guard case .blocked = await host.start(locks: fixture.locks) else {
      Issue.record("expected blocked")
      return
    }
    #expect(fixture.launches.isEmpty)
    #expect(host.runningHost == nil)
    #expect(fixture.isFree(fixture.paths.lockFile(.live)))
    #expect(fixture.isFree(fixture.secondaryLockFile))
  }

  @Test func aRestartAfterAQuitNeverLaunches() async throws {
    let fixture = try Fixture()
    let host = fixture.host()
    _ = try #require(Self.running(await host.start(locks: fixture.locks)))
    #expect(await host.terminate())
    guard case .blocked = await host.restart(with: Self.newSettings) else {
      Issue.record("expected blocked")
      return
    }
    #expect(fixture.launches.filter { $0.hasPrefix("launch") }.count == 1)
  }

  @Test func aRestartWhoseOldEngineStopTimesOutKeepsBothLocksAndTheOldSentinel() async throws {
    let fixture = try Fixture()
    let recorder = HoldRecorder(stateFile: fixture.paths.stateFile(.live))
    let clamshell = FakeClamshellPort(recorder: recorder)
    let sentinels = SentinelFactory(recorder: recorder)
    let launches = OSAllocatedUnfairLock(initialState: 0)
    let paths = fixture.paths
    let home = fixture.home
    let host = AppHost(
      paths: paths, version: "0.1.0", environment: [:], homeDirectory: home, restartStopBoundSeconds: 0.3,
      launcher: { launch in
        launches.withLock { $0 += 1 }
        return try Composition.launchLive(
          paths: paths, settings: Settings(transcriptRoots: [home + "/projects"]),
          ports: LivePorts(
            assertions: IOPMAssertionBackend(syscalls: FakeAssertionSyscalls(), registry: AssertionRegistry()),
            tools: NoTools(), clamshell: clamshell, stateFile: paths.stateFile(.live),
            makeSentinel: { sentinels.make() }),
          environment: [:], homeDirectory: home, once: true, lock: launch.lock)
      })
    let first = try #require(Self.running(await host.start(locks: fixture.locks)))
    await first.engine.step(.tick(TickFacts(fullWake: true)))
    #expect(await first.engine.handle(.force(.indefinite)).ok)
    #expect(await EffectOrderTests.poll(within: 5) { await first.engine.state.hold.lidClose == .held })

    clamshell.blockNextWrite(seconds: 2)
    guard case .blocked(let failure) = await host.restart(with: Self.newSettings) else {
      Issue.record("expected blocked")
      return
    }
    #expect(failure == .sentinelUnavailable)
    #expect(launches.withLock { $0 } == 1)
    #expect(host.runningHost == nil)
    #expect(!fixture.isFree(fixture.paths.lockFile(.live)))
    #expect(!fixture.isFree(fixture.secondaryLockFile))
    #expect(!sentinels.first.closed)
    let entries = recorder.all
    let engaged = try #require(entries.lastIndex(of: .clamshell(on: true, fileOwnsHold: true)))
    let sinceEngage = entries[engaged...]
    #expect(!sinceEngage.contains { if case .sentinel("DISARM", _) = $0 { return true } else { return false } })
    #expect(!sinceEngage.contains(.sentinelClose))

    #expect(await host.terminate())
    #expect(fixture.isFree(fixture.paths.lockFile(.live)))
    #expect(fixture.isFree(fixture.secondaryLockFile))
  }

  @Test func aSuccessfulStartConsumesTheSuppressionStampAndAFailedOneLeavesIt() async throws {
    let fixture = try Fixture()
    let stamp = fixture.paths.relaunchSuppression
    #expect(RelaunchSuppression.stamp(at: stamp))
    fixture.failNextLaunches()
    guard case .blocked = await fixture.host().start(locks: fixture.locks) else {
      Issue.record("expected blocked")
      return
    }
    #expect(FileManager.default.fileExists(atPath: stamp.path(percentEncoded: false)))

    let second = try Fixture()
    let secondStamp = second.paths.relaunchSuppression
    #expect(RelaunchSuppression.stamp(at: secondStamp))
    let host = second.host()
    _ = try #require(Self.running(await host.start(locks: second.locks)))
    #expect(!FileManager.default.fileExists(atPath: secondStamp.path(percentEncoded: false)))
    #expect(await host.terminate())
    #expect(FileManager.default.fileExists(atPath: secondStamp.path(percentEncoded: false)))
  }

  @Test func aRestartWithoutARunningEngineIsBlocked() async throws {
    let fixture = try Fixture()
    let host = fixture.host()
    guard case .blocked = await host.restart(with: Self.newSettings) else {
      Issue.record("expected blocked")
      return
    }
    #expect(fixture.launches.isEmpty)
    fixture.locks.release()
  }
}
