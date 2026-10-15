import Foundation
import Testing

@testable import OvertimeCore

struct SessionActivityTests {
  static let me: UInt32 = 501
  static let terminal: UInt32 = 0x1000_0005

  static func at(_ seconds: Double) -> Instant {
    Instant(nanoseconds: 0).adding(seconds: seconds)
  }

  static func session(_ pid: Int32, start: Double = 1) -> SessionActivity.Session {
    SessionActivity.Session(pid: pid, start: at(start))
  }

  static func claude(pid: Int32, uid: UInt32 = me, tty: UInt32 = terminal) -> ProcessRecord {
    ProcessRecord(
      pid: pid, ppid: 90, uid: uid, comm: "2.1.300", ttyDevice: tty, startMono: at(1), argv0: "claude")
  }

  static func caffeinate(pid: Int32, parent: Int32, uid: UInt32 = me) -> ProcessRecord {
    ProcessRecord(pid: pid, ppid: parent, uid: uid, comm: "caffeinate", startMono: at(2), argv0: "caffeinate")
  }

  static func other(pid: Int32, comm: String, argv0: String, tty: UInt32 = ProcessRecord.noDevice) -> ProcessRecord {
    ProcessRecord(pid: pid, ppid: 90, uid: me, comm: comm, ttyDevice: tty, startMono: at(1), argv0: argv0)
  }

  @Test func aCaffeinateChildMakesASessionWorkingFromThatTick() {
    var activity = SessionActivity()
    let sessions = [Self.session(7), Self.session(8)]
    #expect(activity.update(sessions: sessions, busyPIDs: [7], at: Self.at(10)) == [7: Self.at(10)])
    #expect(activity.update(sessions: sessions, busyPIDs: [7], at: Self.at(12)) == [7: Self.at(10)])
  }

  @Test func aRestartGapShorterThanTheGraceKeepsTheEpisode() {
    var activity = SessionActivity()
    let sessions = [Self.session(7)]
    _ = activity.update(sessions: sessions, busyPIDs: [7], at: Self.at(0))
    #expect(activity.update(sessions: sessions, busyPIDs: [], at: Self.at(2)) == [7: Self.at(0)])
    #expect(activity.update(sessions: sessions, busyPIDs: [], at: Self.at(4)) == [7: Self.at(0)])
    #expect(activity.update(sessions: sessions, busyPIDs: [7], at: Self.at(6)) == [7: Self.at(0)])
    #expect(activity.update(sessions: sessions, busyPIDs: [], at: Self.at(95.999)) == [7: Self.at(0)])
  }

  @Test func theEpisodeEndsWhenTheGracePassesWithoutACaffeinate() {
    var activity = SessionActivity()
    let sessions = [Self.session(7)]
    _ = activity.update(sessions: sessions, busyPIDs: [7], at: Self.at(0))
    #expect(activity.update(sessions: sessions, busyPIDs: [], at: Self.at(89.999)) == [7: Self.at(0)])
    #expect(activity.update(sessions: sessions, busyPIDs: [], at: Self.at(90)) == [:])
  }

  @Test func aCaffeinateAfterTheGraceStartsANewEpisode() {
    var activity = SessionActivity()
    let sessions = [Self.session(7)]
    _ = activity.update(sessions: sessions, busyPIDs: [7], at: Self.at(0))
    #expect(activity.update(sessions: sessions, busyPIDs: [], at: Self.at(90)) == [:])
    #expect(activity.update(sessions: sessions, busyPIDs: [7], at: Self.at(100)) == [7: Self.at(100)])
  }

  @Test func aLongGapStartsANewEpisodeEvenWithTheCaffeinateBack() {
    var activity = SessionActivity()
    let sessions = [Self.session(7)]
    _ = activity.update(sessions: sessions, busyPIDs: [7], at: Self.at(0))
    #expect(activity.update(sessions: sessions, busyPIDs: [7], at: Self.at(3600)) == [7: Self.at(3600)])
  }

  @Test func aReusedPIDWithANewStartStartsOver() {
    var activity = SessionActivity()
    _ = activity.update(sessions: [Self.session(7, start: 1)], busyPIDs: [7], at: Self.at(10))
    let reused = activity.update(sessions: [Self.session(7, start: 500)], busyPIDs: [7], at: Self.at(12))
    #expect(reused == [7: Self.at(12)])
  }

  @Test func aSessionThatLeavesIsForgotten() {
    var activity = SessionActivity()
    _ = activity.update(sessions: [Self.session(7)], busyPIDs: [7], at: Self.at(0))
    #expect(activity.update(sessions: [], busyPIDs: [], at: Self.at(2)) == [:])
    #expect(activity.update(sessions: [Self.session(7)], busyPIDs: [7], at: Self.at(4)) == [7: Self.at(4)])
  }

  @Test func busySessionPIDsFollowTheDetectorRule() {
    let records = [
      Self.claude(pid: 30),
      Self.caffeinate(pid: 31, parent: 30),
      Self.caffeinate(pid: 32, parent: 30),
      Self.claude(pid: 40),
      Self.claude(pid: 50, tty: ProcessRecord.noDevice),
      Self.caffeinate(pid: 51, parent: 50),
      Self.other(pid: 60, comm: "zsh", argv0: "-zsh", tty: Self.terminal),
      Self.caffeinate(pid: 61, parent: 60),
      Self.caffeinate(pid: 70, parent: 1),
      Self.claude(pid: 80, uid: 502),
      Self.caffeinate(pid: 81, parent: 80),
    ]
    let busy = ClaudeCodeDetector.busySessionPIDs(in: records)
    #expect(busy == [30])
    #expect(busy.count == ClaudeCodeDetector(userID: Self.me).signals(from: records).sessionCount)
  }

  @Test func theMeasuredProcessShapeYieldsThreeWorkingSessions() {
    var records = (101...110).map { Self.claude(pid: Int32($0)) }
    records.append(Self.claude(pid: 111, tty: ProcessRecord.noDevice))
    records.append(contentsOf: [103, 106, 109].map { Self.caffeinate(pid: Int32($0 + 100), parent: Int32($0)) })
    records.append(Self.other(pid: 120, comm: "zsh", argv0: "-zsh", tty: Self.terminal))
    records.append(Self.caffeinate(pid: 220, parent: 120))
    records.append(Self.other(pid: 130, comm: "python3", argv0: "python3"))
    records.append(Self.caffeinate(pid: 230, parent: 130))
    records.append(Self.caffeinate(pid: 240, parent: 1))
    #expect(ClaudeCodeDetector.busySessionPIDs(in: records) == [103, 106, 109])
  }

  @Test func theWorkingGraceIsNinetySeconds() {
    #expect(Timing.sessionWorkingGraceSeconds == 90)
    #expect(Timing.sessionWorkingGraceSeconds == Settings().transcriptWindowSeconds - 30)
    #expect(Timing.sessionWorkingGraceSeconds > Timing.tickSeconds)
  }
}
