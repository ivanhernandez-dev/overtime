import Foundation

public struct SessionActivity: Sendable, Equatable {
  public struct Session: Sendable, Equatable {
    public var pid: Int32
    public var start: Instant?

    public init(pid: Int32, start: Instant?) {
      self.pid = pid
      self.start = start
    }
  }

  private struct Episode: Sendable, Equatable {
    var start: Instant?
    var since: Instant
    var lastSeen: Instant
  }

  private var episodes: [Int32: Episode] = [:]

  public init() {}

  public mutating func update(
    sessions: [Session], busyPIDs: Set<Int32>, at now: Instant,
    graceSeconds: Double = Timing.sessionWorkingGraceSeconds
  ) -> [Int32: Instant] {
    var starts: [Int32: Instant?] = [:]
    for session in sessions {
      starts[session.pid] = session.start
    }
    episodes = episodes.filter { pid, episode in
      guard let start = starts[pid] else { return false }
      return start == episode.start
    }
    let grace = Instant.nanoseconds(forSeconds: graceSeconds)
    episodes = episodes.filter { _, episode in
      now.nanoseconds(since: episode.lastSeen) < grace
    }
    for session in sessions where busyPIDs.contains(session.pid) {
      if var episode = episodes[session.pid] {
        episode.lastSeen = now
        episodes[session.pid] = episode
      } else {
        episodes[session.pid] = Episode(start: session.start, since: now, lastSeen: now)
      }
    }
    return episodes.mapValues(\.since)
  }
}
