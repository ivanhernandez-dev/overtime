public enum RelaunchExit: Sendable, Equatable {
  case bye
  case signal
  case endOfInput(parentGone: Bool)
  case heartbeatTimeoutTerminated
}

public enum RelaunchDecision: Sendable, Equatable {
  case relaunch(history: [Int64])
  case skip(reason: String)
}

public enum RelaunchPolicy {
  public static let windowSeconds: Int64 = 600
  public static let maxRelaunches = 3
  public static let dedupeSeconds: Int64 = 30
  public static let suppressionSeconds: Int64 = 120
  public static let futureStampToleranceSeconds: Int64 = 5
  public static let maximumHistoryBytes = 4_096
  public static let nanosecondsPerSecond: Int64 = 1_000_000_000

  public static func decide(
    exit: RelaunchExit, now: Int64, history: [Int64], suppressedAtNanoseconds: Int64?, appRunning: Bool,
    appExists: Bool, terminatedAtNanoseconds: Int64? = nil, appValid: Bool = true
  ) -> RelaunchDecision {
    switch exit {
    case .bye:
      return .skip(reason: "bye")
    case .signal:
      return .skip(reason: "signal")
    case .endOfInput(parentGone: false):
      return .skip(reason: "retire")
    case .endOfInput(parentGone: true), .heartbeatTimeoutTerminated:
      break
    }
    guard appExists else { return .skip(reason: "appMissing") }
    guard appValid else { return .skip(reason: "notAnApp") }
    guard !appRunning else { return .skip(reason: "running") }
    if let stamp = suppressedAtNanoseconds,
      suppresses(stamp, exit: exit, now: now, terminatedAtNanoseconds: terminatedAtNanoseconds)
    {
      return .skip(reason: "suppressed")
    }
    let recent = history.filter { counts($0, now: now) }.sorted()
    if let last = recent.last, now - last < dedupeSeconds {
      return .skip(reason: "duplicate")
    }
    guard recent.count < maxRelaunches else { return .skip(reason: "limited") }
    return .relaunch(history: recent + [now])
  }

  public static func parseHistory(_ text: String, now: Int64) -> [Int64] {
    text.split(whereSeparator: \.isNewline).compactMap { line in
      guard let value = Int64(line), counts(value, now: now) else { return nil }
      return value
    }.sorted()
  }

  public static func serializeHistory(_ history: [Int64]) -> String {
    history.map { String($0) + "\n" }.joined()
  }

  public static func nanoseconds(seconds: Int64, nanoseconds: Int64) -> Int64? {
    let (whole, productOverflow) = seconds.multipliedReportingOverflow(by: nanosecondsPerSecond)
    guard !productOverflow else { return nil }
    let (total, sumOverflow) = whole.addingReportingOverflow(nanoseconds)
    return sumOverflow ? nil : total
  }

  static func suppresses(
    _ stampNanoseconds: Int64, exit: RelaunchExit, now: Int64, terminatedAtNanoseconds: Int64?
  ) -> Bool {
    if exit == .heartbeatTimeoutTerminated, let terminatedAtNanoseconds, stampNanoseconds >= terminatedAtNanoseconds {
      return false
    }
    let stamp = stampNanoseconds / nanosecondsPerSecond
    guard stamp <= now + futureStampToleranceSeconds else { return false }
    return now - stamp < suppressionSeconds
  }

  private static func counts(_ entry: Int64, now: Int64) -> Bool {
    let (elapsed, overflow) = now.subtractingReportingOverflow(entry)
    return entry <= now && !overflow && elapsed < windowSeconds
  }
}

public enum RelaunchFlags {
  public static let app = "--relaunch-app"
  public static let history = "--relaunch-history"
  public static let suppress = "--relaunch-suppress"
  public static let spawner = "--relaunch-spawner"
  public static let appExecutable = "Contents/MacOS/Overtime"
  public static let appInfoPlist = "Contents/Info.plist"
  public static let bundleIdentifiers: Set<String> = [
    "io.github.ivanhernandez-dev.overtime", "io.github.ivanhernandez-dev.overtime.dev",
  ]

  public static func isAppBundlePath(_ path: String) -> Bool {
    path.hasPrefix("/") && path.lowercased().hasSuffix(".app") && path.count > ".app".count + 1
  }
}

public struct RelaunchConfiguration: Sendable, Equatable {
  public var appPath: String
  public var historyPath: String
  public var suppressionPath: String

  public init(appPath: String, historyPath: String, suppressionPath: String) {
    self.appPath = appPath
    self.historyPath = historyPath
    self.suppressionPath = suppressionPath
  }

  public var arguments: [String] {
    [RelaunchFlags.app, appPath, RelaunchFlags.history, historyPath, RelaunchFlags.suppress, suppressionPath]
  }
}
