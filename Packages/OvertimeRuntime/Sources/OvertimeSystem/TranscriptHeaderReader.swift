import Foundation
import OvertimeCore
import os

public final class TranscriptHeaderReader: @unchecked Sendable {
  private struct FileKey: Hashable, Sendable {
    var device: Int32
    var inode: UInt64
  }

  private struct Verdict: Sendable {
    var entrypoint: String?
    var bytesRead: Int
    var lastSeen: Instant
  }

  private struct Cache: Sendable {
    var verdicts: [FileKey: Verdict] = [:]
    var lastPrune: Instant?
  }

  public static let maxCachedFiles = 4096

  private let clock: any ClockPort
  private let retention: StuckWindowBox
  private let cache = OSAllocatedUnfairLock(initialState: Cache())

  public convenience init(clock: any ClockPort = SystemClock(), retentionSeconds: Double = 1800) {
    self.init(clock: clock, stuckWindow: StuckWindowBox(seconds: retentionSeconds))
  }

  public init(clock: any ClockPort = SystemClock(), stuckWindow: StuckWindowBox) {
    self.clock = clock
    self.retention = stuckWindow
  }

  public var cachedEntryCount: Int {
    cache.withLock { $0.verdicts.count }
  }

  public func entrypoint(forFileAt path: String) -> String? {
    var info = stat()
    guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
    let key = FileKey(device: info.st_dev, inode: info.st_ino)
    let size = Int(info.st_size)
    let now = clock.mono()
    let cached: String?? = cache.withLock { cache in
      prune(&cache, now: now)
      guard var verdict = cache.verdicts[key] else { return nil }
      let settled =
        verdict.entrypoint != nil || verdict.bytesRead >= TranscriptHeader.maxBytes || size == verdict.bytesRead
      guard settled else { return nil }
      verdict.lastSeen = now
      cache.verdicts[key] = verdict
      return .some(verdict.entrypoint)
    }
    if let cached {
      return cached
    }
    guard let bytes = TranscriptHeaderReader.readHeader(at: path, expecting: (info.st_dev, UInt64(info.st_ino))) else {
      return nil
    }
    let entrypoint = TranscriptHeader.entrypoint(in: bytes)
    cache.withLock { cache in
      if cache.verdicts[key] == nil && cache.verdicts.count >= TranscriptHeaderReader.maxCachedFiles {
        return
      }
      cache.verdicts[key] = Verdict(entrypoint: entrypoint, bytesRead: bytes.count, lastSeen: now)
    }
    return entrypoint
  }

  private func prune(_ cache: inout Cache, now: Instant) {
    if let lastPrune = cache.lastPrune, now.seconds(since: lastPrune) < 60 {
      return
    }
    cache.lastPrune = now
    let retention = Instant.nanoseconds(forSeconds: retention.seconds)
    cache.verdicts = cache.verdicts.filter { _, verdict in
      now.nanoseconds(since: verdict.lastSeen) < retention
    }
  }

  static func readHeader(at path: String, expecting identity: (device: Int32, inode: UInt64)? = nil) -> [UInt8]? {
    let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { return nil }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
    if let identity, identity.device != info.st_dev || identity.inode != UInt64(info.st_ino) {
      return nil
    }
    var bytes = [UInt8](repeating: 0, count: TranscriptHeader.maxBytes)
    var filled = 0
    while filled < bytes.count {
      let count = bytes.withUnsafeMutableBytes { raw in
        read(descriptor, raw.baseAddress! + filled, raw.count - filled)
      }
      if count < 0 && errno == EINTR { continue }
      guard count >= 0 else { return nil }
      if count == 0 { break }
      filled += count
    }
    return Array(bytes.prefix(filled))
  }
}
