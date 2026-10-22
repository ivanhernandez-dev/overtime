import Foundation
import OvertimeCore
import OvertimeEngine
import OvertimeSystem

public struct SessionRow: Sendable, Equatable, Identifiable {
  public var id: Int32
  public var title: String
  public var fullPath: String
  public var caption: String
  public var accessibilityText: String

  public init(id: Int32, title: String, fullPath: String, caption: String, accessibilityText: String) {
    self.id = id
    self.title = title
    self.fullPath = fullPath
    self.caption = caption
    self.accessibilityText = accessibilityText
  }
}

public struct SessionPlaceholder: Sendable, Equatable {
  public var heading: String
  public var body: String

  public static let noSessions = SessionPlaceholder(
    heading: "No Claude sessions",
    body: "Overtime keeps the Mac awake when Claude Code starts working in a terminal.")
  public static let noneWorking = SessionPlaceholder(
    heading: "No Claude session is working",
    body: "Overtime keeps the Mac awake when Claude Code starts working in a terminal.")
  public static let transcriptOnly = SessionPlaceholder(
    heading: "No terminal session is working",
    body: "Claude is active in another app, such as an editor, or in a subagent.")
}

public struct SessionList: Sendable, Equatable {
  public var rows: [SessionRow]
  public var moreWorking: Int
  public var idle: Int
  public var placeholder: SessionPlaceholder?

  public init(rows: [SessionRow], moreWorking: Int, idle: Int, placeholder: SessionPlaceholder?) {
    self.rows = rows
    self.moreWorking = moreWorking
    self.idle = idle
    self.placeholder = placeholder
  }

  public var summaryText: String? {
    switch (moreWorking > 0, idle > 0) {
    case (false, false): nil
    case (false, true): rows.isEmpty ? "\(idle) open, idle" : "\(idle) more open, idle"
    case (true, false): "\(moreWorking) more working"
    case (true, true): "\(moreWorking) more working, \(idle) idle"
    }
  }
}

public struct LongRunningRules: Sendable, Equatable {
  public var backgroundHolding: Bool
  public var printHolding: Bool

  public init(backgroundHolding: Bool, printHolding: Bool) {
    self.backgroundHolding = backgroundHolding
    self.printHolding = printHolding
  }

  public init(snapshot: EngineSnapshot?) {
    self.init(
      backgroundHolding: snapshot?.backgroundCommandsHolding == true, printHolding: snapshot?.printRunsHolding == true)
  }

  public static let none = LongRunningRules(backgroundHolding: false, printHolding: false)
}

public enum SessionRowKind: Sendable, Equatable {
  case working
  case printRun
  case waiting
  case runningCommand

  public var countsAsWaiting: Bool {
    self == .waiting
  }
}

public enum PanelContent {
  public static let header = "Claude Sessions"
  public static let maxSessionRows = 5
  public static let unknownFolder = "Unknown folder"
  public static let sessionIcon = "terminal"
  public static let settingsLabel = "Settings…"
  public static let quitLabel = "Quit Overtime"
  public static let quitHelp = "Quitting restores normal sleep."

  public static func versionLine(_ version: String) -> String {
    "Overtime \(version)"
  }

  public static func working(_ summaries: [SessionSummary], busy: Bool) -> [SessionSummary] {
    busy ? summaries.filter(\.isWorking) : []
  }

  public static func kind(of summary: SessionSummary, busy: Bool, rules: LongRunningRules) -> SessionRowKind? {
    guard busy else { return nil }
    if summary.isWorking { return .working }
    if summary.printRun, rules.printHolding { return .printRun }
    if summary.isWaiting, rules.backgroundHolding { return summary.terminal ? .waiting : .runningCommand }
    return nil
  }

  public static func listed(_ summaries: [SessionSummary], busy: Bool, rules: LongRunningRules) -> [SessionSummary] {
    summaries.filter { kind(of: $0, busy: busy, rules: rules) != nil }
  }

  public static func sessions(
    _ summaries: [SessionSummary], busy: Bool, now: Instant, homeDirectory: String,
    rules: LongRunningRules = .none
  ) -> SessionList {
    let listed = listed(summaries, busy: busy, rules: rules)
    let listedIDs = Set(listed.map(\.pid))
    let idle = summaries.filter { $0.terminal && !listedIDs.contains($0.pid) }.count
    guard !listed.isEmpty else {
      let placeholder: SessionPlaceholder =
        busy ? .transcriptOnly : summaries.isEmpty ? .noSessions : .noneWorking
      return SessionList(rows: [], moreWorking: 0, idle: idle, placeholder: placeholder)
    }
    let shownSummaries = Array(listed.prefix(maxSessionRows))
    let paths = shownSummaries.map { $0.cwd.map { abbreviatingHome($0, homeDirectory: homeDirectory) } }
    let names = titles(forPaths: paths)
    let shown = zip(shownSummaries, names).map { summary, name in
      var shownRow = row(
        for: summary, kind: kind(of: summary, busy: busy, rules: rules) ?? .working, now: now,
        homeDirectory: homeDirectory)
      shownRow.title = name
      return shownRow
    }
    return SessionList(rows: shown, moreWorking: listed.count - shown.count, idle: idle, placeholder: nil)
  }

  public static func workingCaption(_ seconds: Double) -> String {
    "Working · \(TimingFormat.elapsed(seconds))"
  }

  public static func waitingCaption(_ seconds: Double) -> String {
    "Waiting · background command · \(TimingFormat.elapsed(seconds))"
  }

  public static func runningCommandCaption(_ seconds: Double) -> String {
    "Running a command · \(TimingFormat.elapsed(seconds))"
  }

  public static func printRunCaption(_ seconds: Double) -> String {
    "Working · claude -p · \(TimingFormat.elapsed(seconds))"
  }

  public static func row(for summary: SessionSummary, now: Instant, homeDirectory: String) -> SessionRow {
    row(for: summary, kind: .working, now: now, homeDirectory: homeDirectory)
  }

  public static func row(for summary: SessionSummary, kind: SessionRowKind, now: Instant, homeDirectory: String)
    -> SessionRow
  {
    let since: Instant? =
      switch kind {
      case .working: summary.workingSince
      case .printRun: summary.startMono
      case .waiting, .runningCommand: summary.waitingSince
      }
    let elapsed = since.map { max(0, now.seconds(since: $0)) } ?? 0
    let path = summary.cwd.map { abbreviatingHome($0, homeDirectory: homeDirectory) }
    let place = path ?? "an unknown folder"
    let spoken = TimingFormat.spokenElapsed(elapsed)
    let (caption, accessibilityText): (String, String) =
      switch kind {
      case .working:
        (workingCaption(elapsed), "Session in \(place), working for \(spoken)")
      case .printRun:
        (printRunCaption(elapsed), "claude -p run in \(place), working for \(spoken)")
      case .waiting:
        (waitingCaption(elapsed), "Session in \(place), waiting on a background command for \(spoken)")
      case .runningCommand:
        (runningCommandCaption(elapsed), "Session in \(place), running a command for \(spoken)")
      }
    return SessionRow(
      id: summary.pid, title: folderName(path), fullPath: path ?? unknownFolder, caption: caption,
      accessibilityText: accessibilityText)
  }

  public static func titles(forPaths paths: [String?]) -> [String] {
    let forms: [(String?) -> String] = [folderName, parentAndFolderName, { $0 ?? unknownFolder }]
    var levels = Array(repeating: 0, count: paths.count)
    var changed = true
    while changed {
      changed = false
      let names = paths.indices.map { forms[levels[$0]](paths[$0]) }
      for index in paths.indices where levels[index] < forms.count - 1 {
        let collides = paths.indices.contains { other in
          names[other] == names[index] && paths[other] != paths[index]
        }
        if collides {
          levels[index] += 1
          changed = true
        }
      }
    }
    return paths.indices.map { forms[levels[$0]](paths[$0]) }
  }

  static func folderName(_ path: String?) -> String {
    guard let path else { return unknownFolder }
    return pathComponents(path).last ?? "/"
  }

  static func parentAndFolderName(_ path: String?) -> String {
    guard let path else { return unknownFolder }
    let components = pathComponents(path)
    guard !components.isEmpty else { return "/" }
    return components.suffix(2).joined(separator: "/")
  }

  static func pathComponents(_ path: String) -> [String] {
    path.split(separator: "/").map(String.init)
  }

  public static func abbreviatingHome(_ path: String, homeDirectory: String) -> String {
    let home =
      homeDirectory.count > 1 && homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
    guard home.count > 1 else { return path }
    if path == home { return "~" }
    guard path.hasPrefix(home + "/") else { return path }
    return "~" + path.dropFirst(home.count)
  }
}
