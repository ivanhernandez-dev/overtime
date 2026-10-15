import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing

struct PanelContentTests {
  static let home = "/Users/dev"
  static let clock = FakeClock(mono: Instant(nanoseconds: 1_000_000_000_000_000))
  static let terminal: UInt32 = 0x1000_0003

  static func session(pid: Int32, cwd: String? = "/Users/dev/proj", tty: String? = "ttys003", workingFor: Double?)
    -> SessionSummary
  {
    SessionSummary(
      pid: pid, cwd: cwd, ttyName: tty, startMono: clock.mono().adding(seconds: -86_400),
      workingSince: workingFor.map { clock.mono().adding(seconds: -$0) })
  }

  static func sessions(_ summaries: [SessionSummary], busy: Bool = true) -> SessionList {
    PanelContent.sessions(summaries, busy: busy, now: clock.mono(), homeDirectory: home)
  }

  static func claude(pid: Int32, start: UInt64) -> ProcessRecord {
    ProcessRecord(
      pid: pid, ppid: 1, uid: getuid(), comm: "claude", ttyDevice: terminal,
      startMono: Instant(nanoseconds: start * 1_000_000_000), argv0: "claude")
  }

  static func caffeinate(pid: Int32, parent: Int32) -> ProcessRecord {
    ProcessRecord(pid: pid, ppid: parent, uid: getuid(), comm: "caffeinate", argv0: "caffeinate")
  }

  @Test func theSessionIconIsTheTerminal() {
    #expect(PanelContent.sessionIcon == "terminal")
  }

  @Test func theSectionHeaderReadsInTitleCase() {
    #expect(PanelContent.header == "Claude Sessions")
    #expect(LabelCaseTests.titleCaseFindings(PanelContent.header) == [])
  }

  @Test func theFooterCopyIsOneVersionLineAndTwoActions() {
    #expect(PanelContent.versionLine("0.1.0") == "Overtime 0.1.0")
    #expect(PanelContent.settingsLabel == "Settings…")
    #expect(PanelContent.quitLabel == "Quit Overtime")
    #expect(PanelContent.quitHelp == "Quitting restores normal sleep.")
  }

  @Test func aPathUnderHomeIsAbbreviated() {
    #expect(PanelContent.abbreviatingHome("/Users/dev/proj/app", homeDirectory: Self.home) == "~/proj/app")
    #expect(PanelContent.abbreviatingHome("/Users/dev", homeDirectory: Self.home) == "~")
    #expect(PanelContent.abbreviatingHome("/Users/developer/x", homeDirectory: Self.home) == "/Users/developer/x")
    #expect(PanelContent.abbreviatingHome("/opt/work", homeDirectory: Self.home) == "/opt/work")
    #expect(PanelContent.abbreviatingHome("/Users/dev/x", homeDirectory: "/Users/dev/") == "~/x")
  }

  @Test func onlyWorkingSessionsAreListedWhileClaudeIsBusy() {
    let list = Self.sessions([
      Self.session(pid: 1, workingFor: 600), Self.session(pid: 2, workingFor: nil),
      Self.session(pid: 3, workingFor: 30),
    ])
    #expect(list.rows.map(\.id) == [1, 3])
    #expect(list.moreWorking == 0)
    #expect(list.placeholder == nil)
  }

  @Test func noSessionIsListedAsWorkingWhileClaudeIsNotBusy() {
    let list = Self.sessions(
      [
        Self.session(pid: 1, workingFor: 600), Self.session(pid: 2, workingFor: nil),
        Self.session(pid: 3, workingFor: 30),
      ], busy: false)
    #expect(list.rows.isEmpty)
    #expect(list.moreWorking == 0)
  }

  @Test func aWorkingRowShowsItsPathAndHowLongItHasWorked() throws {
    let list = Self.sessions([Self.session(pid: 1, workingFor: 3900)])
    let row = try #require(list.rows.first)
    #expect(row.title == "proj")
    #expect(row.fullPath == "~/proj")
    #expect(row.caption == "Working · 1h 5m")
    #expect(row.accessibilityText == "Session in ~/proj, working for 1 hour 5 minutes")
    #expect(list.placeholder == nil)
    #expect(list.summaryText == nil)
  }

  @Test func twoFoldersWithTheSameNameShowTheirParent() {
    let list = Self.sessions([
      Self.session(pid: 1, cwd: "/Users/dev/work/api", workingFor: 300),
      Self.session(pid: 2, cwd: "/opt/api", workingFor: 200),
      Self.session(pid: 3, cwd: "/Users/dev/beta", workingFor: 100),
    ])
    #expect(list.rows.map(\.title) == ["work/api", "opt/api", "beta"])
    #expect(list.rows.map(\.fullPath) == ["~/work/api", "/opt/api", "~/beta"])
  }

  @Test func theSameParentAndNameFallBackToTheAbbreviatedPath() {
    let list = Self.sessions([
      Self.session(pid: 1, cwd: "/Users/dev/a/x/api", workingFor: 300),
      Self.session(pid: 2, cwd: "/Users/dev/b/x/api", workingFor: 200),
    ])
    #expect(list.rows.map(\.title) == ["~/a/x/api", "~/b/x/api"])
    #expect(list.rows.map(\.fullPath) == ["~/a/x/api", "~/b/x/api"])
  }

  @Test func twoSessionsInOneFolderKeepOneTitle() {
    let list = Self.sessions([
      Self.session(pid: 1, cwd: "/Users/dev/alpha", workingFor: 300),
      Self.session(pid: 2, cwd: "/Users/dev/alpha", workingFor: 200),
    ])
    #expect(list.rows.map(\.title) == ["alpha", "alpha"])
  }

  @Test func theHomeFolderTheRootAndAnUnknownFolderKeepTheirNames() {
    let list = Self.sessions([
      Self.session(pid: 1, cwd: "/Users/dev", workingFor: 300),
      Self.session(pid: 2, cwd: "/", workingFor: 200),
      Self.session(pid: 3, cwd: nil, workingFor: 100),
    ])
    #expect(list.rows.map(\.title) == ["~", "/", "Unknown folder"])
  }

  @Test func idleSessionsAreCountedInOneQuietLine() {
    let working = (1...2).map { Self.session(pid: Int32($0), workingFor: 600) }
    let idle = (3...10).map { Self.session(pid: Int32($0), workingFor: nil) }
    let list = Self.sessions(working + idle)
    #expect(list.rows.map(\.id) == [1, 2])
    #expect(list.moreWorking == 0)
    #expect(list.idle == 8)
    #expect(list.placeholder == nil)
    #expect(list.summaryText == "8 more open, idle")
  }

  @Test func withNoWorkingSessionTheIdleOnesAreCountedUnderTheirOwnPlaceholder() {
    let list = Self.sessions((1...3).map { Self.session(pid: Int32($0), workingFor: nil) }, busy: false)
    #expect(list.rows.isEmpty)
    #expect(list.placeholder == .noneWorking)
    #expect(list.placeholder?.heading == "No Claude session is working")
    #expect(
      list.placeholder?.body == "Overtime keeps the Mac awake when Claude Code starts working in a terminal.")
    #expect(list.summaryText == "3 open, idle")
    #expect(SessionPlaceholder.transcriptOnly.heading == "No terminal session is working")
    #expect(SessionPlaceholder.transcriptOnly.heading != SessionPlaceholder.noneWorking.heading)
    let markedWorking = Self.sessions((1...3).map { Self.session(pid: Int32($0), workingFor: 60) }, busy: false)
    #expect(markedWorking == list)
  }

  @Test func transcriptOnlyActivityKeepsItsPlaceholderAndCountsIdleSessions() {
    let list = Self.sessions((1...2).map { Self.session(pid: Int32($0), workingFor: nil) }, busy: true)
    #expect(list.rows.isEmpty)
    #expect(list.placeholder == .transcriptOnly)
    #expect(list.summaryText == "2 open, idle")
  }

  @Test func anUnreadableFolderIsNamedUnknown() throws {
    let row = try #require(Self.sessions([Self.session(pid: 1, cwd: nil, workingFor: 30)]).rows.first)
    #expect(row.title == "Unknown folder")
    #expect(row.caption == "Working · <1m")
    #expect(row.accessibilityText == "Session in an unknown folder, working for less than a minute")
  }

  @Test func aTerminalClaudeWithACaffeinateChildBecomesOneWorkingRowAndTheHeroCount() throws {
    let reader = SessionReader(readDirectory: { _ in "/Users/dev/alpha" }, readTerminal: { _ in "ttys009" })
    let records = [
      Self.claude(pid: 40, start: 400), Self.caffeinate(pid: 41, parent: 40), Self.claude(pid: 50, start: 500),
    ]
    let now = Self.clock.mono()
    let snapshot = EngineSnapshot(
      busy: true, wanted: true, reason: "busy", lidClosed: false, sessions: reader.sessions(from: records, at: now))
    #expect(snapshot.sessions.map(\.pid) == [40, 50])
    let list = PanelContent.sessions(
      snapshot.sessions, busy: snapshot.busy == true, now: now.adding(seconds: 125), homeDirectory: Self.home)
    #expect(list.rows.map(\.id) == [40])
    let row = try #require(list.rows.first)
    #expect(row.caption == "Working · 2m")
    let presentation = StatusPresentation.derive(snapshot: snapshot, hostFailure: nil, engineUnresponsive: false)
    #expect(presentation.reason == "Claude is working in 1 session.")
  }

  @Test func moreWorkingSessionsThanRowsAreCountedInTheSameLine() {
    let working = (1...7).map { Self.session(pid: Int32($0), workingFor: Double(1000 - $0)) }
    let idle = (8...10).map { Self.session(pid: Int32($0), workingFor: nil) }
    let list = Self.sessions(working + idle)
    #expect(list.rows.map(\.id) == [1, 2, 3, 4, 5])
    #expect(list.moreWorking == 2)
    #expect(list.idle == 3)
    #expect(list.summaryText == "2 more working, 3 idle")
    let onlyWorking = Self.sessions(working)
    #expect(onlyWorking.moreWorking == 2)
    #expect(onlyWorking.idle == 0)
    #expect(onlyWorking.summaryText == "2 more working")
  }

  @Test func noSessionsWhileNotWantedIsTheEmptyState() {
    let list = Self.sessions([], busy: false)
    #expect(list.rows.isEmpty)
    #expect(list.placeholder?.heading == "No Claude sessions")
    #expect(
      list.placeholder?.body == "Overtime keeps the Mac awake when Claude Code starts working in a terminal.")
    #expect(list.summaryText == nil)
  }

  @Test func noSessionsWhileWantedIsTheTranscriptOnlyState() {
    let list = Self.sessions([], busy: true)
    #expect(list.placeholder?.heading == "No terminal session is working")
    #expect(list.placeholder?.body == "Claude is active in another app, such as an editor, or in a subagent.")
    #expect(SessionPlaceholder.noneWorking.heading == "No Claude session is working")
    #expect(list.placeholder?.heading != SessionPlaceholder.noneWorking.heading)
    #expect(list.summaryText == nil)
  }

  @Test(arguments: [
    (30.0, "<1m", "less than a minute"), (45 * 60.0, "45m", "45 minutes"), (65 * 60.0, "1h 5m", "1 hour 5 minutes"),
    (120 * 60.0, "2h 0m", "2 hours"), (61.0, "1m", "1 minute"),
  ])
  func elapsedFormats(_ seconds: Double, _ text: String, _ spoken: String) {
    #expect(TimingFormat.elapsed(seconds) == text)
    #expect(TimingFormat.spokenElapsed(seconds) == spoken)
  }
}
