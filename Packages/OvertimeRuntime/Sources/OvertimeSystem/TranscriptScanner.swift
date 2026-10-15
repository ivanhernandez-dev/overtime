import Foundation
import OvertimeCore

public struct TranscriptScanner: Sendable {
  public static let defaultMaxEntries = 50_000

  public var roots: [String]
  public var headers: TranscriptHeaderReader?
  public var maxEntries: Int

  public init(
    roots: [String], headers: TranscriptHeaderReader? = nil, maxEntries: Int = TranscriptScanner.defaultMaxEntries
  ) {
    self.roots = roots
    self.headers = headers
    self.maxEntries = maxEntries
  }

  public func recentActivity(withinSeconds: Double, clock: any ClockPort) -> [TranscriptActivity] {
    let monoNow = clock.mono()
    let wallNow = clock.wall()
    let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
    var activities: [TranscriptActivity] = []
    var visited = 0
    for root in roots {
      let rootURL = URL(fileURLWithPath: root, isDirectory: true)
      guard
        let enumerator = FileManager.default.enumerator(
          at: rootURL, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
      else { continue }
      for case let file as URL in enumerator {
        visited += 1
        guard visited <= maxEntries else { return activities }
        guard file.pathExtension == "jsonl", let values = try? file.resourceValues(forKeys: Set(keys)),
          values.isRegularFile == true,
          values.isSymbolicLink != true,
          let modified = values.contentModificationDate
        else { continue }
        let age = max(0, wallNow.timeIntervalSince(modified))
        guard age < withinSeconds else { continue }
        activities.append(
          TranscriptActivity(
            at: monoNow.adding(seconds: -age),
            entrypoint: headers?.entrypoint(forFileAt: file.path(percentEncoded: false))
          ))
      }
    }
    return activities
  }
}
