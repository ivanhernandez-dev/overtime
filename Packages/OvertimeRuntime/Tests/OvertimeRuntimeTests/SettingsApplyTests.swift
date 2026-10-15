import Darwin
import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing
import os

final class RecordingSettingsHost: EngineHosting {
  let clock: any ClockPort = FakeClock()
  let engineToken = UUID()
  let settingsURL: URL
  private let state = OSAllocatedUnfairLock<(applied: [Settings], fileAtApply: [Data?], result: Bool)>(
    initialState: ([], [], true))

  init(settingsURL: URL) {
    self.settingsURL = settingsURL
  }

  var applied: [Settings] {
    state.withLock { $0.applied }
  }

  var fileAtApply: [Data?] {
    state.withLock { $0.fileAtApply }
  }

  func scriptApply(_ result: Bool) {
    state.withLock { $0.result = result }
  }

  func snapshots() async -> AsyncStream<EngineSnapshot> {
    AsyncStream { $0.finish() }
  }

  func send(_ request: CtlRequest) async -> CtlResponse? {
    nil
  }

  func probe() async -> EngineSnapshot? {
    nil
  }

  func apply(settings: Settings) async -> Bool {
    let onDisk = try? Data(contentsOf: settingsURL)
    return state.withLock { state in
      state.applied.append(settings)
      state.fileAtApply.append(onDisk)
      return state.result
    }
  }

  func requestSelfTest() async {}

  func updateHelper(_ facts: HelperFacts) async {}
}

@Suite(.serialized)
struct SettingsApplyTests {
  static func mode(_ url: URL) -> mode_t? {
    var info = stat()
    guard stat(url.path(percentEncoded: false), &info) == 0 else { return nil }
    return info.st_mode & 0o777
  }

  static func candidate() -> Settings {
    Settings(batteryLowPercent: 20, batteryResumePercent: 30)
  }

  @Test func commitSavesWithModeSixHundredThenAppliesOnce() async throws {
    let temp = try TempDirectory()
    let url = temp.url.appendingPathComponent("settings.json")
    let host = RecordingSettingsHost(settingsURL: url)
    let result = await SettingsCommitter.commit(Self.candidate(), to: url, host: host)
    #expect(result == .applied)
    #expect(Self.mode(url) == 0o600)
    #expect(SettingsStore.load(from: url) == .loaded(Self.candidate()))
    #expect(host.applied == [Self.candidate()])
    let seen = try #require(host.fileAtApply.first ?? nil)
    #expect(seen == (try Data(contentsOf: url)))
  }

  @Test func aFailedSaveNeverAppliesAndLeavesTheFileUnchanged() async throws {
    let temp = try TempDirectory()
    let folder = temp.url.appendingPathComponent("locked", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("settings.json")
    try SettingsStore.save(Settings(), to: url)
    let before = try Data(contentsOf: url)
    #expect(chmod(folder.path(percentEncoded: false), 0o500) == 0)
    defer { _ = chmod(folder.path(percentEncoded: false), 0o700) }
    let host = RecordingSettingsHost(settingsURL: url)
    let result = await SettingsCommitter.commit(Self.candidate(), to: url, host: host)
    #expect(result == .saveFailed)
    #expect(host.applied.isEmpty)
    #expect(try Data(contentsOf: url) == before)
  }

  @Test func anInvalidCandidateIsNeverSavedOrApplied() async throws {
    let temp = try TempDirectory()
    let url = temp.url.appendingPathComponent("settings.json")
    let host = RecordingSettingsHost(settingsURL: url)
    let invalid = Settings(batteryLowPercent: 20, batteryResumePercent: 20)
    let result = await SettingsCommitter.commit(invalid, to: url, host: host)
    #expect(result == .invalid(SettingsValidationError(message: "Must be lower than the resume level (20%).")))
    #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    #expect(host.applied.isEmpty)
  }

  @Test func anInvalidCandidateLeavesAnExistingFileUntouched() async throws {
    let temp = try TempDirectory()
    let url = temp.url.appendingPathComponent("settings.json")
    try SettingsStore.save(Settings(), to: url)
    let before = try Data(contentsOf: url)
    let host = RecordingSettingsHost(settingsURL: url)
    let clamped = Settings(batteryLowPercent: 60, batteryResumePercent: 70)
    let result = await SettingsCommitter.commit(clamped, to: url, host: host)
    #expect(result == .invalid(SettingsValidationError(message: "Enter a whole percentage from 1 to 50.")))
    #expect(try Data(contentsOf: url) == before)
    #expect(host.applied.isEmpty)
  }

  @Test func aHostThatCannotApplyYieldsApplyTimedOutWithTheFileSaved() async throws {
    let temp = try TempDirectory()
    let url = temp.url.appendingPathComponent("settings.json")
    let host = RecordingSettingsHost(settingsURL: url)
    host.scriptApply(false)
    let result = await SettingsCommitter.commit(Self.candidate(), to: url, host: host)
    #expect(result == .applyTimedOut)
    #expect(SettingsStore.load(from: url) == .loaded(Self.candidate()))
    #expect(host.applied == [Self.candidate()])
  }
}
