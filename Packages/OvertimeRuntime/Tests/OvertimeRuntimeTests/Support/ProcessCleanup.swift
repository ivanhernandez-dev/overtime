import Darwin
import Foundation
import Testing
import os

protocol SpawnedProcesses: AnyObject, Sendable {
  func signalEnd()
  var survivors: [String] { get }
}

final class TrackedProcess: SpawnedProcesses, @unchecked Sendable {
  let process: Process

  init(_ process: Process) {
    self.process = process
  }

  func signalEnd() {
    guard process.isRunning else { return }
    kill(process.processIdentifier, SIGCONT)
    kill(process.processIdentifier, SIGKILL)
  }

  var survivors: [String] {
    process.isRunning ? ["process \(process.processIdentifier)"] : []
  }
}

final class ProcessCleanup: Sendable {
  @TaskLocal static var current: ProcessCleanup?

  static let boundSeconds: Double = 5

  private let tracked = OSAllocatedUnfairLock<[any SpawnedProcesses]>(initialState: [])

  static func track(_ processes: any SpawnedProcesses, sourceLocation: SourceLocation = #_sourceLocation) {
    guard let current else {
      processes.signalEnd()
      Issue.record("A spawned process needs the .processCleanup trait on its suite", sourceLocation: sourceLocation)
      return
    }
    current.tracked.withLock { $0.append(processes) }
  }

  static func track(_ process: Process, sourceLocation: SourceLocation = #_sourceLocation) {
    track(TrackedProcess(process), sourceLocation: sourceLocation)
  }

  func endAll(within seconds: Double = ProcessCleanup.boundSeconds) async {
    let all = tracked.withLock { list in
      defer { list.removeAll() }
      return list
    }
    guard !all.isEmpty else { return }
    for processes in all { processes.signalEnd() }
    let ended = await OffPool.eventually(seconds: seconds) { all.allSatisfy { $0.survivors.isEmpty } }
    if !ended {
      let survivors = all.flatMap(\.survivors).joined(separator: ", ")
      Issue.record("Still running \(seconds) s after SIGKILL: \(survivors)")
    }
  }
}

struct ProcessCleanupTrait: SuiteTrait, TestTrait, TestScoping {
  var isRecursive: Bool { true }

  func provideScope(
    for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
  ) async throws {
    let cleanup = ProcessCleanup()
    do {
      try await ProcessCleanup.$current.withValue(cleanup) { try await function() }
    } catch {
      await cleanup.endAll()
      throw error
    }
    await cleanup.endAll()
  }
}

extension Trait where Self == ProcessCleanupTrait {
  static var processCleanup: Self { Self() }
}
