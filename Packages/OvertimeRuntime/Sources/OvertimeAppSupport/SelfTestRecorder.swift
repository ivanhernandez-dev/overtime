import Foundation
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import os

struct SelfTestRecording: Sendable, Equatable {
  struct Result: Sendable, Equatable {
    let outcome: SelfTestOutcome
    let reason: String?
  }

  var recordedRuns: UInt64 = 0
  var lastStatus: SelfTestStatus?

  mutating func result(for snapshot: EngineSnapshot) -> Result? {
    defer { lastStatus = snapshot.selfTest }
    switch snapshot.selfTest {
    case .passed:
      return finishedRun(snapshot) ? Result(outcome: .passed, reason: nil) : nil
    case .failed(let failure):
      return finishedRun(snapshot) ? Result(outcome: .failed, reason: SelfTestPresentation.reason(for: failure)) : nil
    case .skipped(let skip):
      guard lastStatus != snapshot.selfTest else { return nil }
      return Result(outcome: .skipped, reason: SelfTestPresentation.reason(for: skip))
    case .notRun, .waiting, .running:
      return nil
    }
  }

  private mutating func finishedRun(_ snapshot: EngineSnapshot) -> Bool {
    guard snapshot.selfTestRuns > recordedRuns else { return false }
    recordedRuns = snapshot.selfTestRuns
    return true
  }
}

public final class SelfTestRecorder: Sendable {
  public static let writeFailedDecision = Decision(keyword: .error, verb: "preferences write failed")
  public static let unknownBuild = "unknown"

  private let writer: Writer
  private let consumer = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

  public init(
    preferencesFile: URL,
    osVersion: @escaping @Sendable () -> String = { SystemInfo.osVersion() },
    log: @escaping @Sendable (Decision) -> Void,
    onRecord: @escaping @Sendable (SelfTestRecord) -> Void = { _ in }
  ) {
    writer = Writer(preferencesFile: preferencesFile, osVersion: osVersion, log: log, onRecord: onRecord)
  }

  public var lastRecord: SelfTestRecord? {
    AppPreferencesStore.read(at: writer.preferencesFile).preferences.selfTest
  }

  public var isRunning: Bool {
    consumer.withLock { $0 != nil }
  }

  public func start(host: any EngineHosting) {
    let writer = writer
    let task = Task {
      var recording = SelfTestRecording()
      let stream = await host.snapshots()
      for await snapshot in stream {
        guard !Task.isCancelled else { break }
        guard let result = recording.result(for: snapshot) else { continue }
        writer.store(result, osBuild: snapshot.osBuild, at: host.clock.wall())
      }
    }
    let previous = consumer.withLock { current -> Task<Void, Never>? in
      defer { current = task }
      return current
    }
    previous?.cancel()
  }

  public func stop() {
    consumer.withLock { current -> Task<Void, Never>? in
      defer { current = nil }
      return current
    }?.cancel()
  }

  deinit {
    consumer.withLock { $0 }?.cancel()
  }

  struct Writer: Sendable {
    let preferencesFile: URL
    let osVersion: @Sendable () -> String
    let log: @Sendable (Decision) -> Void
    let onRecord: @Sendable (SelfTestRecord) -> Void

    func store(_ result: SelfTestRecording.Result, osBuild: String?, at wall: Date) {
      let record = SelfTestRecord(
        outcome: result.outcome, reason: result.reason, at: wall, osBuild: osBuild ?? SelfTestRecorder.unknownBuild,
        osVersion: osVersion())
      do {
        try AppPreferencesStore.update(at: preferencesFile) { $0.selfTest = record }
      } catch {
        log(SelfTestRecorder.writeFailedDecision)
        return
      }
      onRecord(record)
    }
  }
}
