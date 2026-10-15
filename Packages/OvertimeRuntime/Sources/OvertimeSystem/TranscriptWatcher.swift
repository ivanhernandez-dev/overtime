import CoreServices
import Foundation
import OvertimeCore

public final class TranscriptWatcher: @unchecked Sendable {
  private struct Root {
    var configured: String
    var origin: RootOrigin
    var canonical: String
    var status: RootStatus?
    var stream: FSEventStreamRef?
  }

  private let clock: any ClockPort
  private let seedWindow: StuckWindowBox
  private let healthCheckSeconds: Double
  private let headers: TranscriptHeaderReader
  private let statusOfRoot: @Sendable (String) -> RootStatus
  private let queue = DispatchQueue(label: "io.github.ivanhernandez-dev.overtime.transcript-watcher")
  private var roots: [Root]
  private var healthTimer: (any DispatchSourceTimer)?
  private var continuation: AsyncStream<Event>.Continuation?
  private var retainedSelf: TranscriptWatcher?
  private var generation = 0

  public convenience init(
    roots: [String],
    clock: any ClockPort,
    seedWindowSeconds: Double,
    headers: TranscriptHeaderReader,
    healthCheckSeconds: Double = Timing.healthCheckSeconds,
    statusOfRoot: @escaping @Sendable (String) -> RootStatus = TranscriptWatcher.status(ofRootAt:)
  ) {
    self.init(
      roots: roots, clock: clock, stuckWindow: StuckWindowBox(seconds: seedWindowSeconds), headers: headers,
      healthCheckSeconds: healthCheckSeconds, statusOfRoot: statusOfRoot)
  }

  public convenience init(
    roots: [String],
    clock: any ClockPort,
    stuckWindow: StuckWindowBox,
    headers: TranscriptHeaderReader,
    healthCheckSeconds: Double = Timing.healthCheckSeconds,
    statusOfRoot: @escaping @Sendable (String) -> RootStatus = TranscriptWatcher.status(ofRootAt:)
  ) {
    self.init(
      roots: roots.map { TranscriptRoot(path: $0, origin: .configured) }, clock: clock, stuckWindow: stuckWindow,
      headers: headers, healthCheckSeconds: healthCheckSeconds, statusOfRoot: statusOfRoot)
  }

  public init(
    roots: [TranscriptRoot],
    clock: any ClockPort,
    stuckWindow: StuckWindowBox,
    headers: TranscriptHeaderReader,
    healthCheckSeconds: Double = Timing.healthCheckSeconds,
    statusOfRoot: @escaping @Sendable (String) -> RootStatus = TranscriptWatcher.status(ofRootAt:)
  ) {
    self.roots = roots.map {
      Root(configured: $0.path, origin: $0.origin, canonical: TranscriptWatcher.canonicalPath($0.path))
    }
    self.clock = clock
    self.seedWindow = stuckWindow
    self.healthCheckSeconds = healthCheckSeconds
    self.headers = headers
    self.statusOfRoot = statusOfRoot
  }

  deinit {
    for root in roots {
      if let stream = root.stream {
        TranscriptWatcher.release(stream)
      }
    }
    healthTimer?.cancel()
    continuation?.finish()
  }

  public var canonicalRoots: [String] {
    queue.sync { roots.map(\.canonical) }
  }

  public static func canonicalPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  public static func status(ofRootAt path: String) -> RootStatus {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
      return .missing
    }
    return access(path, R_OK | X_OK) == 0 ? .ok : .unreadable
  }

  public static func health(ofRoots roots: [String]) -> [RootHealth] {
    roots.map { RootHealth(path: $0, status: status(ofRootAt: $0)) }
  }

  public static func health(ofRoots roots: [TranscriptRoot]) -> [RootHealth] {
    roots.map { RootHealth(path: $0.path, status: status(ofRootAt: $0.path), origin: $0.origin) }
  }

  public func start() -> AsyncStream<Event> {
    stop()
    let (stream, continuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .bufferingNewest(4096))
    let started = queue.sync { () -> Int in
      generation += 1
      self.continuation = continuation
      self.retainedSelf = self
      let interval = DispatchTimeInterval.nanoseconds(
        Int(clamping: Instant.nanoseconds(forSeconds: healthCheckSeconds)))
      let timer = DispatchSource.makeTimerSource(queue: queue)
      timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(250))
      timer.setEventHandler { [weak self] in
        self?.checkHealth(forceReport: false)
      }
      timer.resume()
      self.healthTimer = timer
      return generation
    }
    continuation.onTermination = { [weak self] _ in
      guard let self else { return }
      self.queue.async {
        guard self.generation == started else { return }
        _ = self.stopOnQueue()
      }
    }
    queue.async { [weak self] in
      guard let self, self.generation == started else { return }
      self.checkHealth(forceReport: true)
    }
    return stream
  }

  public func stop() {
    let finished = queue.sync { stopOnQueue() }
    finished?.finish()
  }

  private func stopOnQueue() -> AsyncStream<Event>.Continuation? {
    for index in roots.indices {
      if let stream = roots[index].stream {
        TranscriptWatcher.release(stream)
      }
      roots[index].stream = nil
      roots[index].status = nil
    }
    healthTimer?.cancel()
    healthTimer = nil
    let current = continuation
    continuation = nil
    retainedSelf = nil
    return current
  }

  private func checkHealth(forceReport: Bool) {
    guard let continuation else { return }
    var changed = forceReport
    var newlyHealthy: [String] = []
    for index in roots.indices {
      let status = statusOfRoot(roots[index].configured)
      let previous = roots[index].status
      guard status != previous else { continue }
      changed = true
      roots[index].status = status
      if let stream = roots[index].stream {
        TranscriptWatcher.release(stream)
        roots[index].stream = nil
      }
      guard status == .ok else { continue }
      roots[index].canonical = TranscriptWatcher.canonicalPath(roots[index].configured)
      roots[index].stream = makeStream(for: roots[index].canonical)
      newlyHealthy.append(roots[index].canonical)
    }
    if changed {
      continuation.yield(
        .transcriptRoots(
          roots.map { RootHealth(path: $0.configured, status: $0.status ?? .missing, origin: $0.origin) }))
    }
    for activity in seedActivities(in: newlyHealthy) {
      continuation.yield(.transcriptActivity(activity))
    }
  }

  func handle(_ events: [(path: String, flags: FSEventStreamEventFlags)]) {
    guard let continuation else { return }
    let rescanFlags = FSEventStreamEventFlags(
      kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged)
    let watched = roots.filter { $0.stream != nil }.map(\.canonical)
    var needsSeed = false
    let monoNow = clock.mono()
    let wallNow = clock.wall()
    for event in events {
      if event.flags & rescanFlags != 0 {
        needsSeed = true
        continue
      }
      guard TranscriptWatcher.accepts(path: event.path, flags: event.flags, canonicalRoots: watched),
        let modified = TranscriptWatcher.modificationDate(ofRegularFileAt: event.path),
        wallNow.timeIntervalSince(modified) < seedWindow.seconds
      else { continue }
      continuation.yield(
        .transcriptActivity(
          TranscriptActivity(
            at: TranscriptWatcher.mono(of: modified, monoNow: monoNow, wallNow: wallNow),
            entrypoint: headers.entrypoint(forFileAt: event.path)
          )))
    }
    if needsSeed {
      for activity in seedActivities(in: watched) {
        continuation.yield(.transcriptActivity(activity))
      }
    }
  }

  static func accepts(path: String, flags: FSEventStreamEventFlags, canonicalRoots: [String]) -> Bool {
    guard path.hasSuffix(".jsonl"), flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile) != 0 else {
      return false
    }
    let insideRoot = canonicalRoots.contains { root in
      path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
    guard insideRoot else { return false }
    let metadataOnly = FSEventStreamEventFlags(
      kFSEventStreamEventFlagItemXattrMod | kFSEventStreamEventFlagItemChangeOwner
        | kFSEventStreamEventFlagItemInodeMetaMod)
    let changes =
      flags
      & FSEventStreamEventFlags(
        kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
          | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemModified
          | kFSEventStreamEventFlagItemFinderInfoMod | kFSEventStreamEventFlagItemCloned
          | kFSEventStreamEventFlagItemXattrMod | kFSEventStreamEventFlagItemChangeOwner
          | kFSEventStreamEventFlagItemInodeMetaMod)
    if changes != 0 && changes & ~metadataOnly == 0 {
      return false
    }
    return true
  }

  static func modificationDate(ofRegularFileAt path: String) -> Date? {
    var info = stat()
    guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
    let modified = info.st_mtimespec
    return Date(timeIntervalSince1970: Double(modified.tv_sec) + Double(modified.tv_nsec) / 1_000_000_000)
  }

  static func mono(of wall: Date, monoNow: Instant, wallNow: Date) -> Instant {
    monoNow.adding(seconds: -max(0, wallNow.timeIntervalSince(wall)))
  }

  private func seedActivities(in canonicalRoots: [String]) -> [TranscriptActivity] {
    guard !canonicalRoots.isEmpty else { return [] }
    return TranscriptScanner(roots: canonicalRoots, headers: headers).recentActivity(
      withinSeconds: seedWindow.seconds, clock: clock)
  }

  private func makeStream(for root: String) -> FSEventStreamRef? {
    var context = FSEventStreamContext(
      version: 0,
      info: Unmanaged.passUnretained(self).toOpaque(),
      retain: nil,
      release: nil,
      copyDescription: nil
    )
    let flags = FSEventStreamCreateFlags(
      kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
    guard
      let stream = FSEventStreamCreate(
        nil,
        transcriptWatcherCallback,
        &context,
        [root] as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
        0.5,
        flags
      )
    else { return nil }
    FSEventStreamSetDispatchQueue(stream, queue)
    guard FSEventStreamStart(stream) else {
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
      return nil
    }
    return stream
  }

  private static func release(_ stream: FSEventStreamRef) {
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
  }
}

private func transcriptWatcherCallback(
  _ stream: ConstFSEventStreamRef,
  _ info: UnsafeMutableRawPointer?,
  _ count: Int,
  _ paths: UnsafeMutableRawPointer,
  _ flags: UnsafePointer<FSEventStreamEventFlags>,
  _ ids: UnsafePointer<FSEventStreamEventId>
) {
  guard let info else { return }
  let watcher = Unmanaged<TranscriptWatcher>.fromOpaque(info).takeUnretainedValue()
  let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
  var events: [(path: String, flags: FSEventStreamEventFlags)] = []
  events.reserveCapacity(count)
  for index in 0..<min(count, array.count) {
    guard let path = array[index] as? String else { continue }
    events.append((path: path, flags: flags[index]))
  }
  watcher.handle(events)
}
