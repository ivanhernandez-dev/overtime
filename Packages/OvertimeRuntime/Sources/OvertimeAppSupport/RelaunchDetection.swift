import Foundation
import OvertimeClamshell
import OvertimeSystem

public enum RelaunchDetection {
  public static let windowSeconds: Int64 = 60
  static let maxWallSeconds: Double = 1e15

  public static func wasRelaunched(historyText: String, launchWall: Date) -> Bool {
    let seconds = launchWall.timeIntervalSince1970
    guard seconds.isFinite, abs(seconds) < maxWallSeconds else { return false }
    let launch = Int64(seconds.rounded(.down))
    guard let newest = RelaunchPolicy.parseHistory(historyText, now: launch).last else { return false }
    let (elapsed, overflow) = launch.subtractingReportingOverflow(newest)
    return !overflow && elapsed >= 0 && elapsed <= windowSeconds
  }

  public static func readHistory(at url: URL) -> String? {
    let read = PrivateFile.read(
      at: url.path(percentEncoded: false), maxBytes: RelaunchPolicy.maximumHistoryBytes)
    guard case .data(let data) = read else { return nil }
    return String(decoding: data, as: UTF8.self)
  }

  public static func wasRelaunched(historyAt url: URL, launchWall: Date) -> Bool {
    guard let text = readHistory(at: url) else { return false }
    return wasRelaunched(historyText: text, launchWall: launchWall)
  }
}
