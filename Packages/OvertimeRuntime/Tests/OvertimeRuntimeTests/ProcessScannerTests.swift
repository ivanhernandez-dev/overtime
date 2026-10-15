import Darwin
import Foundation
import OvertimeCore
import Testing
import os

@testable import OvertimeSystem

struct ProcessScannerTests {
  @Test func samplesTheTestProcessReadOnly() throws {
    let scanner = ProcessScanner(userID: getuid())
    let records = scanner.sample(clock: SystemClock(), extraCandidates: [getpid()])
    let own = try #require(records.first { $0.pid == getpid() })
    #expect(own.uid == getuid())
    #expect(own.ppid == getppid())
    #expect(!own.comm.isEmpty)
    #expect(own.argv0 != nil)
    #expect(own.pidPath != nil)
    #expect(own.startMono != nil)
    #expect(records.allSatisfy { $0.uid == getuid() })
  }

  @Test func repeatedSamplesAgreeThroughTheCache() throws {
    let scanner = ProcessScanner(userID: getuid())
    let first = try #require(scanner.sample(extraCandidates: [getpid()]).first { $0.pid == getpid() })
    let second = try #require(scanner.sample(extraCandidates: [getpid()]).first { $0.pid == getpid() })
    #expect(first.argv0 == second.argv0)
    #expect(first.execPath == second.execPath)
    #expect(first.pidPath == second.pidPath)
  }

  @Test func anotherUsersIdentityYieldsNoRecords() {
    let scanner = ProcessScanner(userID: UInt32.max - 7)
    #expect(scanner.sample(extraCandidates: [getpid()]).isEmpty)
  }

  final class ReadLog: Sendable {
    private let reads = OSAllocatedUnfairLock(initialState: (args: [Int32](), paths: [Int32]()))

    func noteArgs(_ pid: Int32) {
      reads.withLock { $0.args.append(pid) }
    }

    func notePath(_ pid: Int32) {
      reads.withLock { $0.paths.append(pid) }
    }

    var args: [Int32] {
      reads.withLock { $0.args }
    }

    var paths: [Int32] {
      reads.withLock { $0.paths }
    }
  }

  static func countingScanner(_ log: ReadLog) -> ProcessScanner {
    ProcessScanner(
      userID: getuid(),
      readArgs: { pid in
        log.noteArgs(pid)
        return ProcessScanner.procArgs(pid)
      },
      readPath: { pid in
        log.notePath(pid)
        return ProcessScanner.pidPath(pid)
      })
  }

  static func candidates(of records: [ProcessRecord], extra: Set<Int32>) -> Set<Int32> {
    var candidates = extra
    for record in records {
      if record.ttyDevice != ProcessRecord.noDevice || record.comm == ProcessScanner.amphetamineComm {
        candidates.insert(record.pid)
      }
      if record.comm == "caffeinate" {
        candidates.insert(record.pid)
        candidates.insert(record.ppid)
      }
    }
    return candidates.intersection(records.map(\.pid))
  }

  @Test func argvIsReadOnlyForCandidatePids() {
    let log = ReadLog()
    let scanner = Self.countingScanner(log)
    let records = scanner.sample(clock: SystemClock(), extraCandidates: [getpid()])
    let pids = Set(records.map(\.pid))
    let candidates = Self.candidates(of: records, extra: [getpid()])
    #expect(pids.count == records.count)
    #expect(candidates.contains(getpid()))
    #expect(candidates.isStrictSubset(of: pids))
    #expect(log.args.count == Set(log.args).count)
    #expect(log.paths.count == Set(log.paths).count)
    #expect(Set(log.args) == candidates)
    #expect(Set(log.paths) == candidates)
    #expect(log.args.count < records.count)
    let others = records.filter { !candidates.contains($0.pid) }
    #expect(!others.isEmpty)
    for record in others {
      #expect(record.argv0 == nil, "\(record.pid) \(record.comm)")
      #expect(record.argv1 == nil, "\(record.pid) \(record.comm)")
      #expect(record.execPath == nil, "\(record.pid) \(record.comm)")
      #expect(record.pidPath == nil, "\(record.pid) \(record.comm)")
      #expect(record.claudeConfigDirectory == nil, "\(record.pid) \(record.comm)")
    }
  }

  static func ownClaudeBuffer(configDirectory: String) -> [UInt8] {
    let argc = withUnsafeBytes(of: Int32(1).littleEndian) { Array($0) }
    let strings = ["/Users/dev/.local/bin/claude", "", "claude", "CLAUDE_CONFIG_DIR=" + configDirectory, "", "pfz=0"]
    return argc + strings.flatMap { Array($0.utf8) + [0] }
  }

  @Test func aCandidateCarriesTheConfigDirectoryOfItsOwnBuffer() throws {
    let log = ReadLog()
    let own = getpid()
    let configDirectory = "/tmp/ot-sr6-scanner-config"
    let scanner = ProcessScanner(
      userID: getuid(),
      readArgs: { pid in
        log.noteArgs(pid)
        return pid == own ? Self.ownClaudeBuffer(configDirectory: configDirectory) : nil
      },
      readPath: ProcessScanner.pidPath)
    let records = scanner.sample(clock: SystemClock(), extraCandidates: [own])
    let record = try #require(records.first { $0.pid == own })
    #expect(record.argv0 == "claude")
    #expect(record.claudeConfigDirectory == configDirectory)
    #expect(ClaudeCodeDetector(userID: getuid()).signals(from: records).claudeConfigDirectories == [configDirectory])
    #expect(log.args.filter { $0 == own }.count == 1)
  }

  @Test func theOwnBufferYieldsTheConfigDirectoryItWasStartedWith() throws {
    let buffer = ProcessScanner.procArgs(getpid())
    let read = buffer.flatMap(ProcArgsParser.parse)
    let parsed = try #require(read)
    #expect(parsed.argv0 == CommandLine.arguments.first)
    let inherited = ProcessInfo.processInfo.environment[ProcArgsParser.configDirectoryVariable]
    let expected = inherited.flatMap { value in
      (1...ProcArgsParser.maxConfigDirectoryBytes).contains(value.utf8.count) ? value : nil
    }
    #expect(parsed.claudeConfigDirectory == expected)
  }

  @Test func aSecondSampleReadsNothingAgainForUnchangedProcesses() {
    let log = ReadLog()
    let scanner = Self.countingScanner(log)
    _ = scanner.sample(clock: SystemClock(), extraCandidates: [getpid()])
    let firstArgs = log.args
    let firstPaths = log.paths
    #expect(firstArgs.contains(getpid()))
    let records = scanner.sample(clock: SystemClock(), extraCandidates: [getpid()])
    let againArgs = Set(log.args.dropFirst(firstArgs.count))
    let againPaths = Set(log.paths.dropFirst(firstPaths.count))
    #expect(!againArgs.contains(getpid()))
    #expect(!againPaths.contains(getpid()))
    #expect(againArgs.isDisjoint(with: firstArgs))
    #expect(againPaths.isDisjoint(with: firstPaths))
    #expect(againArgs.isSubset(of: Self.candidates(of: records, extra: [getpid()])))
    let own = records.first { $0.pid == getpid() }
    #expect(own?.argv0 != nil)
    #expect(own?.pidPath != nil)
  }
}
