import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing
import os

struct TerminationCoordinatorTests {
  static let mustFinishSeconds: Double = 30
  final class Recorder: Sendable {
    private let entries = OSAllocatedUnfairLock<[String]>(initialState: [])

    func record(_ entry: String) {
      entries.withLock { $0.append(entry) }
    }

    var all: [String] {
      entries.withLock { $0 }
    }
  }

  @Test func beforeStopThenStopThenShutdown() async {
    let recorder = Recorder()
    let coordinator = TerminationCoordinator(
      beforeStop: { recorder.record("beforeStop") },
      stop: { recorder.record("stop") },
      shutdown: { recorder.record("shutdown") },
      outerBoundSeconds: Self.mustFinishSeconds
    )
    #expect(await coordinator.terminate())
    #expect(recorder.all == ["beforeStop", "stop", "shutdown"])
  }

  @Test func aHungStopStillShutsDownAfterTheBound() async {
    let recorder = Recorder()
    let coordinator = TerminationCoordinator(
      beforeStop: {},
      stop: { try? await Task.sleep(for: .seconds(60)) },
      shutdown: { recorder.record("shutdown") },
      outerBoundSeconds: 0.2
    )
    let started = ContinuousClock.now
    #expect(await coordinator.terminate() == false)
    #expect(ContinuousClock.now - started < .seconds(10))
    #expect(recorder.all == ["shutdown"])
  }

  @Test func concurrentCallsStopOnce() async {
    let recorder = Recorder()
    let coordinator = TerminationCoordinator(
      beforeStop: {},
      stop: {
        recorder.record("stop")
        try? await Task.sleep(for: .milliseconds(100))
      },
      shutdown: { recorder.record("shutdown") },
      outerBoundSeconds: Self.mustFinishSeconds
    )
    async let first = coordinator.terminate()
    async let second = coordinator.terminate()
    let results = await [first, second]
    #expect(results == [true, true])
    #expect(recorder.all == ["stop", "shutdown"])
  }

  static func stampAge(_ url: URL) -> TimeInterval? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)),
      let modified = attributes[.modificationDate] as? Date
    else { return nil }
    return abs(Date().timeIntervalSince(modified))
  }

  static func mode(_ url: URL) -> Int? {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
    return (attributes?[.posixPermissions] as? NSNumber)?.intValue
  }

  @Test func theSuppressionStampIsWrittenBeforeTheStopRuns() async throws {
    let temp = try TempDirectory()
    let stamp = temp.url.appendingPathComponent("relaunch-suppressed")
    let seenAge = OSAllocatedUnfairLock<TimeInterval?>(initialState: nil)
    let coordinator = TerminationCoordinator(
      beforeStop: { RelaunchSuppression.stamp(at: stamp) },
      stop: { seenAge.withLock { $0 = Self.stampAge(stamp) } },
      shutdown: {},
      outerBoundSeconds: Self.mustFinishSeconds
    )
    #expect(await coordinator.terminate())
    let age = try #require(seenAge.withLock { $0 })
    #expect(age < Self.mustFinishSeconds)
    #expect(Self.mode(stamp) == 0o600)
  }

  @Test func anOldStampIsRefreshedToNow() async throws {
    let temp = try TempDirectory()
    let stamp = temp.url.appendingPathComponent("relaunch-suppressed")
    try Data("old".utf8).write(to: stamp)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSinceNow: -3_600), .posixPermissions: 0o644],
      ofItemAtPath: stamp.path(percentEncoded: false))
    #expect(RelaunchSuppression.stamp(at: stamp))
    #expect(try #require(Self.stampAge(stamp)) < 2)
    #expect(Self.mode(stamp) == 0o600)
  }

  @Test func aStampPlantedAsASymlinkIsReplacedAndItsTargetIsNotTruncatedOrTouched() throws {
    let temp = try TempDirectory()
    let target = temp.url.appendingPathComponent("elsewhere")
    try Data("keep".utf8).write(to: target)
    let past = Date(timeIntervalSinceNow: -3_600)
    try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: target.path(percentEncoded: false))
    let stamp = temp.url.appendingPathComponent("relaunch-suppressed")
    try FileManager.default.createSymbolicLink(at: stamp, withDestinationURL: target)
    let recorder = Recorder()
    #expect(RelaunchSuppression.stamp(at: stamp) { recorder.record($0.verb) })
    #expect(recorder.all.isEmpty)
    var info = stat()
    #expect(lstat(stamp.path(percentEncoded: false), &info) == 0)
    #expect(info.st_mode & S_IFMT == S_IFREG)
    #expect(Self.mode(stamp) == 0o600)
    #expect(FileManager.default.contents(atPath: target.path(percentEncoded: false)) == Data("keep".utf8))
    #expect(try #require(Self.stampAge(target)) > 3_000)
    #expect(RelaunchSuppression.consume(at: stamp))
    #expect(FileManager.default.contents(atPath: target.path(percentEncoded: false)) == Data("keep".utf8))
  }

  @Test func aStampPathThatIsADirectoryIsRefused() throws {
    let temp = try TempDirectory()
    let stamp = temp.url.appendingPathComponent("relaunch-suppressed")
    try FileManager.default.createDirectory(at: stamp, withIntermediateDirectories: false)
    #expect(!RelaunchSuppression.stamp(at: stamp))
  }

  @Test func aPowerOffTerminateThenAQuitTerminateStopsOnceAndBothComplete() async {
    let recorder = Recorder()
    let coordinator = TerminationCoordinator(
      beforeStop: { recorder.record("beforeStop") },
      stop: {
        recorder.record("stop")
        try? await Task.sleep(for: .milliseconds(200))
      },
      shutdown: { recorder.record("shutdown") },
      outerBoundSeconds: Self.mustFinishSeconds
    )
    let powerOff = Task { await coordinator.terminate() }
    try? await Task.sleep(for: .milliseconds(20))
    let quit = await coordinator.terminate()
    #expect(await powerOff.value)
    #expect(quit)
    #expect(recorder.all == ["beforeStop", "stop", "shutdown"])
  }

  @Test func aFailedStampWriteStillStopsAndShutsDown() async throws {
    let temp = try TempDirectory()
    let folder = temp.url.appendingPathComponent("readonly", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path(percentEncoded: false))
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: folder.path(percentEncoded: false))
    }
    let stamp = folder.appendingPathComponent("relaunch-suppressed")
    let recorder = Recorder()
    let coordinator = TerminationCoordinator(
      beforeStop: {
        let written = RelaunchSuppression.stamp(at: stamp) { decision in recorder.record(decision.verb) }
        recorder.record(written ? "stamped" : "stampFailed")
      },
      stop: { recorder.record("stop") },
      shutdown: { recorder.record("shutdown") },
      outerBoundSeconds: Self.mustFinishSeconds
    )
    #expect(await coordinator.terminate())
    #expect(recorder.all == ["relaunch stamp failed", "stampFailed", "stop", "shutdown"])
    #expect(!FileManager.default.fileExists(atPath: stamp.path(percentEncoded: false)))
  }

  @Test func theAppHostStampsTheSuppressionFileBeforeItsStop() async throws {
    let temp = try TempDirectory()
    let paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path + "/root"], homeDirectory: temp.path)
    try paths.createDirectories()
    let locks = HeldLocks(primary: try InstanceLock.acquire(at: paths.lockFile(.live)), secondary: nil)
    let home = temp.path
    let host = AppHost(
      paths: paths, version: "0.1.0", environment: [:], homeDirectory: home,
      launcher: { launch in
        try Composition.launchShadow(
          paths: paths, settings: launch.settings, environment: [:], homeDirectory: home, once: true)
      })
    guard case .running = await host.start(locks: locks) else {
      Issue.record("expected running")
      return
    }
    #expect(!FileManager.default.fileExists(atPath: paths.relaunchSuppression.path(percentEncoded: false)))
    #expect(await host.terminate())
    #expect(try #require(Self.stampAge(paths.relaunchSuppression)) < 5)
    #expect(Self.mode(paths.relaunchSuppression) == 0o600)
  }
}
