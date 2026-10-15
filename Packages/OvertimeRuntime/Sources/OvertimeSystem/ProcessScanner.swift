import Darwin
import Foundation
import OvertimeCore
import os

public struct ProcessScanner: Sendable {
  private struct Identity: Hashable, Sendable {
    var pid: Int32
    var startSeconds: UInt64
    var startMicroseconds: UInt64
  }

  private struct Details: Sendable {
    var args: ProcArgs?
    var pidPath: String?
  }

  private final class DetailsCache: Sendable {
    let entries = OSAllocatedUnfairLock(initialState: [Identity: Details]())
  }

  private static let pathBufferSize = 4 * 1024
  static let amphetamineComm = "Amphetamine"

  private let userID: UInt32
  private let cache = DetailsCache()
  private let readArgs: @Sendable (Int32) -> [UInt8]?
  private let readPath: @Sendable (Int32) -> String?

  public init(userID: UInt32) {
    self.init(userID: userID, readArgs: ProcessScanner.procArgs, readPath: ProcessScanner.pidPath)
  }

  init(
    userID: UInt32, readArgs: @escaping @Sendable (Int32) -> [UInt8]?,
    readPath: @escaping @Sendable (Int32) -> String?
  ) {
    self.userID = userID
    self.readArgs = readArgs
    self.readPath = readPath
  }

  public func sample(clock: any ClockPort = SystemClock(), extraCandidates: Set<Int32> = []) -> [ProcessRecord] {
    let monoNow = clock.mono()
    let wallNow = clock.wall().timeIntervalSince1970
    var infos: [(pid: Int32, info: proc_bsdinfo)] = []
    for pid in ProcessScanner.allPIDs() {
      guard let info = ProcessScanner.bsdInfo(pid), info.pbi_uid == userID else { continue }
      infos.append((pid, info))
    }
    var candidates = extraCandidates
    for (pid, info) in infos {
      let comm = ProcessScanner.comm(info)
      if comm == "caffeinate" {
        candidates.insert(pid)
        candidates.insert(Int32(bitPattern: info.pbi_ppid))
      }
      if comm == ProcessScanner.amphetamineComm {
        candidates.insert(pid)
      }
      if info.e_tdev != ProcessRecord.noDevice {
        candidates.insert(pid)
      }
    }
    var seen: Set<Identity> = []
    var records: [ProcessRecord] = []
    records.reserveCapacity(infos.count)
    for (pid, info) in infos {
      let identity = Identity(pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
      let startWall = Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
      var record = ProcessRecord(
        pid: pid,
        ppid: Int32(bitPattern: info.pbi_ppid),
        uid: info.pbi_uid,
        comm: ProcessScanner.comm(info),
        ttyDevice: info.e_tdev,
        startMono: monoNow.adding(seconds: -max(0, wallNow - startWall))
      )
      if candidates.contains(pid) {
        seen.insert(identity)
        let details = details(for: identity)
        record.argv0 = details.args?.argv0
        record.argv1 = details.args?.argv1
        record.execPath = details.args?.execPath
        record.pidPath = details.pidPath
        record.claudeConfigDirectory = details.args?.claudeConfigDirectory
      }
      records.append(record)
    }
    let current = seen
    cache.entries.withLock { entries in
      entries = entries.filter { current.contains($0.key) }
    }
    return records
  }

  private func details(for identity: Identity) -> Details {
    if let cached = cache.entries.withLock({ $0[identity] }) {
      return cached
    }
    let fresh = Details(
      args: readArgs(identity.pid).flatMap(ProcArgsParser.parse),
      pidPath: readPath(identity.pid)
    )
    cache.entries.withLock { $0[identity] = fresh }
    return fresh
  }

  private static func allPIDs() -> [Int32] {
    let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
    guard needed > 0 else { return [] }
    var pids = [Int32](repeating: 0, count: Int(needed) / MemoryLayout<Int32>.size + 64)
    let filled = pids.withUnsafeMutableBytes { buffer in
      proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress, Int32(buffer.count))
    }
    guard filled > 0 else { return [] }
    return pids.prefix(Int(filled) / MemoryLayout<Int32>.size).filter { $0 > 0 }
  }

  private static func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    let filled = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
    return filled == size ? info : nil
  }

  private static func comm(_ info: proc_bsdinfo) -> String {
    withUnsafeBytes(of: info.pbi_comm) { buffer in
      String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }
  }

  static func procArgs(_ pid: Int32) -> [UInt8]? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    let status = buffer.withUnsafeMutableBytes { bytes in
      sysctl(&mib, 3, bytes.baseAddress, &size, nil, 0)
    }
    guard status == 0 else { return nil }
    return Array(buffer.prefix(size))
  }

  static func pidPath(_ pid: Int32) -> String? {
    var buffer = [UInt8](repeating: 0, count: pathBufferSize)
    let length = buffer.withUnsafeMutableBytes { bytes in
      proc_pidpath(pid, bytes.baseAddress, UInt32(bytes.count))
    }
    guard length > 0 else { return nil }
    return String(decoding: buffer.prefix(Int(length)).prefix { $0 != 0 }, as: UTF8.self)
  }
}
