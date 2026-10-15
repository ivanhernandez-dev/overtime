import AppKit
import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing

@testable import Overtime

@MainActor
@Suite(.serialized)
struct TerminationLifecycleTests {
  @MainActor final class Fixture {
    let folder: TestFolder
    let paths: Paths
    let locks: HeldLocks
    let host: AppHost
    let center = NotificationCenter()

    init() throws {
      folder = try TestFolder()
      let paths = Paths.resolve(environment: ["OVERTIME_HOME": folder.path + "/root"], homeDirectory: folder.path)
      try paths.createDirectories()
      self.paths = paths
      locks = HeldLocks(primary: try InstanceLock.acquire(at: paths.lockFile(.live)), secondary: nil)
      let home = folder.path
      host = AppHost(
        paths: paths, version: "0.1.0", environment: [:], homeDirectory: home,
        launcher: { launch in
          try Composition.launchShadow(
            paths: paths, settings: launch.settings, environment: [:], homeDirectory: home, once: true)
        })
    }

    func lifecycle(logoutResetSeconds: Double = TerminationLifecycle.logoutResetSeconds) -> TerminationLifecycle {
      let lifecycle = TerminationLifecycle(host: host, center: center, logoutResetSeconds: logoutResetSeconds)
      lifecycle.observePowerOff()
      return lifecycle
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

    var lockIsFree: Bool {
      guard let lock = try? InstanceLock.acquire(at: paths.lockFile(.live)) else { return false }
      lock.release()
      return true
    }

    func postPowerOff() {
      center.post(name: NSWorkspace.willPowerOffNotification, object: nil)
    }
  }

  static func running(_ start: AppHostStart) -> LiveEngineHost? {
    guard case .running(let host) = start else { return nil }
    return host
  }

  @Test func aCancelledLogoutLeavesTheEngineRunningAndTheControlsEffective() async throws {
    let fixture = try Fixture()
    let lifecycle = fixture.lifecycle()
    let engineHost = try #require(Self.running(await fixture.host.start(locks: fixture.locks)))
    let model = PanelModel()
    model.amphetamineLocator = .absent
    model.bind(to: engineHost)

    fixture.postPowerOff()
    #expect(await waitUntil { lifecycle.logoutPending })
    try await Task.sleep(for: .milliseconds(300))

    #expect(fixture.stopCount == 0)
    #expect(!fixture.stampExists)
    #expect(!fixture.lockIsFree)
    #expect(fixture.host.runningHost?.engine === engineHost.engine)
    #expect(fixture.decisionLines.contains { $0.contains(" CHECK logout pending") })
    #expect(await model.perform(.keepAwake(.untilStopped))?.ok == true)
    #expect(await waitUntil { model.presentation.state == .override })

    await lifecycle.begin().value
    #expect(fixture.stopCount == 1)
  }

  @Test func aLogoutThatNoQuitFollowsIsForgottenSoTheNextOneIsLoggedAgain() async throws {
    let fixture = try Fixture()
    let lifecycle = fixture.lifecycle(logoutResetSeconds: 0.2)
    _ = try #require(Self.running(await fixture.host.start(locks: fixture.locks)))
    let pendingLines = { fixture.decisionLines.filter { $0.contains(" CHECK logout pending") }.count }

    fixture.postPowerOff()
    #expect(await waitUntil { lifecycle.logoutPending })
    fixture.postPowerOff()
    #expect(await waitUntil { !lifecycle.logoutPending })
    #expect(pendingLines() == 1)

    fixture.postPowerOff()
    #expect(await waitUntil { lifecycle.logoutPending })
    #expect(await waitUntil { pendingLines() == 2 })

    await lifecycle.begin().value
  }

  @Test func aLogoutFollowedByTheQuitStaysPending() async throws {
    let fixture = try Fixture()
    let lifecycle = fixture.lifecycle(logoutResetSeconds: 0.2)
    _ = try #require(Self.running(await fixture.host.start(locks: fixture.locks)))

    fixture.postPowerOff()
    #expect(await waitUntil { lifecycle.logoutPending })
    let quit = lifecycle.begin()
    try await Task.sleep(for: .milliseconds(500))
    #expect(lifecycle.logoutPending)
    await quit.value
    #expect(fixture.stopCount == 1)
  }

  @Test func aLogoutThatArrivesWhileTheQuitIsPreparingIsStillRecordedAsPending() async throws {
    let fixture = try Fixture()
    _ = try #require(Self.running(await fixture.host.start(locks: fixture.locks)))
    let release = Box(false)
    let preparing = Box(false)
    let lifecycle = TerminationLifecycle(
      host: fixture.host, center: fixture.center, logoutResetSeconds: 0.2,
      prepare: {
        preparing.value = true
        let deadline = ContinuousClock.now + .seconds(30)
        while !release.value, ContinuousClock.now < deadline {
          try? await Task.sleep(for: .milliseconds(20))
        }
      })
    lifecycle.observePowerOff()

    let quit = lifecycle.begin()
    #expect(await waitUntil(timeout: 10) { preparing.value })
    #expect(!lifecycle.logoutPending)
    fixture.postPowerOff()
    #expect(await waitUntil(timeout: 10) { lifecycle.logoutPending })
    release.value = true
    await quit.value
    #expect(lifecycle.logoutPending)
    #expect(fixture.stopCount == 1)
  }

  @MainActor final class Box<Value> {
    var value: Value

    init(_ value: Value) {
      self.value = value
    }
  }

  @Test func theQuitWaitsForThePreparationBeforeItFinishes() async throws {
    let fixture = try Fixture()
    _ = try #require(Self.running(await fixture.host.start(locks: fixture.locks)))
    var events: [String] = []
    let lifecycle = TerminationLifecycle(
      host: fixture.host, center: fixture.center,
      prepare: {
        events.append("prepare began")
        try? await Task.sleep(for: .milliseconds(300))
        events.append("prepare ended")
      },
      onFinished: { events.append("finished") })

    await lifecycle.begin().value
    await lifecycle.begin().value

    #expect(events == ["prepare began", "prepare ended", "finished"])
    #expect(fixture.stopCount == 1)
    #expect(fixture.lockIsFree)
  }

  @Test func theLifecycleReportsTerminatingOnlyOnceTheQuitBegan() async throws {
    let fixture = try Fixture()
    let lifecycle = fixture.lifecycle()
    _ = try #require(Self.running(await fixture.host.start(locks: fixture.locks)))

    #expect(!lifecycle.isTerminating)
    fixture.postPowerOff()
    #expect(await waitUntil { lifecycle.logoutPending })
    #expect(!lifecycle.isTerminating)

    let quit = lifecycle.begin()
    #expect(lifecycle.isTerminating)
    await quit.value
    #expect(lifecycle.isTerminating)
    #expect(fixture.stopCount == 1)
  }

  @Test func aLogoutThatGoesAheadStopsTheEngineExactlyOnceFromTheQuit() async throws {
    let fixture = try Fixture()
    let lifecycle = fixture.lifecycle()
    _ = try #require(Self.running(await fixture.host.start(locks: fixture.locks)))

    fixture.postPowerOff()
    #expect(await waitUntil { lifecycle.logoutPending })
    #expect(fixture.stopCount == 0)

    let quit = lifecycle.begin()
    let repeated = lifecycle.begin()
    fixture.postPowerOff()
    await quit.value
    await repeated.value
    await lifecycle.begin().value

    #expect(fixture.stopCount == 1)
    #expect(fixture.stampExists)
    #expect(fixture.lockIsFree)
    #expect(fixture.host.runningHost == nil)
  }
}
