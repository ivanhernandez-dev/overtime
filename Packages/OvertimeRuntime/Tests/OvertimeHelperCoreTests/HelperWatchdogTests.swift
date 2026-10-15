import Foundation
import OvertimeHelperCore
import Testing

struct HelperWatchdogTests {
  static let pmsetBoundSeconds: Double = 5

  @Test func theTimerHasAOneSecondLeewayAndAStallIsStillFoundInsideTheHeartbeat() {
    #expect(HelperWatchdog.leewaySeconds == 1, "R2-IN-07: the idle daemon's watchdog wakeups can coalesce")
    let latestStallExit =
      HelperWatchdog.stallSeconds + HelperWatchdog.checkSeconds + 2 * HelperWatchdog.leewaySeconds
    #expect(latestStallExit < HelperMachine.heartbeatTimeoutSeconds)
  }

  static let daemonSource = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Sources/overtime-helper/main.swift")

  @Test func theDaemonSchedulesItsWatchdogTimerWithTheLeeway() throws {
    let source = try String(contentsOf: Self.daemonSource, encoding: .utf8)
    let schedules = source.components(separatedBy: "\n").filter { $0.contains("watchdogTimer.schedule(") }
    #expect(schedules.count == 1)
    #expect(schedules.first?.contains("leeway: leeway") == true)
    #expect(source.contains("HelperWatchdog.leewaySeconds"))
  }

  @Test func theFirstCheckAsksTheQueueToAnswer() {
    var watchdog = HelperWatchdog()
    #expect(watchdog.check(now: 100) == .ask)
  }

  @Test func whileAnAnswerIsOutstandingNoSecondQuestionIsAsked() {
    var watchdog = HelperWatchdog()
    #expect(watchdog.check(now: 100) == .ask)
    #expect(watchdog.check(now: 105) == .wait)
    #expect(watchdog.check(now: 110) == .wait)
  }

  @Test func anAnswerMakesTheNextCheckAskAgain() {
    var watchdog = HelperWatchdog()
    #expect(watchdog.check(now: 100) == .ask)
    watchdog.answered()
    #expect(watchdog.check(now: 105) == .ask)
    watchdog.answered()
    #expect(watchdog.check(now: 110) == .ask)
  }

  @Test(arguments: [(29.999, HelperWatchdog.Step.wait), (30, .stalled), (31, .stalled), (600, .stalled)])
  func aQuestionThatStaysUnansweredFor30SecondsIsAStall(elapsed: Double, step: HelperWatchdog.Step) {
    var watchdog = HelperWatchdog()
    #expect(watchdog.check(now: 100) == .ask)
    #expect(watchdog.check(now: 100 + elapsed) == step)
  }

  @Test func aStallIsReportedOnEveryLaterCheckUntilTheQueueAnswers() {
    var watchdog = HelperWatchdog()
    #expect(watchdog.check(now: 100) == .ask)
    #expect(watchdog.check(now: 130) == .stalled)
    #expect(watchdog.check(now: 135) == .stalled)
    watchdog.answered()
    #expect(watchdog.check(now: 140) == .ask)
    #expect(watchdog.check(now: 169.999) == .wait)
    #expect(watchdog.check(now: 170) == .stalled)
  }

  @Test func theStallIsMeasuredFromTheUnansweredQuestionAndNotFromTheStart() {
    var watchdog = HelperWatchdog()
    var now = 0.0
    for _ in 0..<100 {
      #expect(watchdog.check(now: now) == .ask)
      watchdog.answered()
      now += HelperWatchdog.checkSeconds
    }
    #expect(watchdog.check(now: now) == .ask)
    #expect(watchdog.check(now: now + 29) == .wait)
    #expect(watchdog.check(now: now + 30) == .stalled)
  }

  @Test func anAnswerWithNoQuestionOutstandingChangesNothing() {
    var watchdog = HelperWatchdog()
    watchdog.answered()
    #expect(watchdog == HelperWatchdog())
    #expect(watchdog.check(now: 100) == .ask)
  }

  @Test func aClockThatReadsEarlierThanTheQuestionIsNotAStall() {
    var watchdog = HelperWatchdog()
    #expect(watchdog.check(now: 100) == .ask)
    #expect(watchdog.check(now: 40) == .wait)
  }

  @Test(arguments: [0.0, 4.9, 14.0, 25.0, 29.0])
  func aQueueThatAnswersLateButInsideTheLimitIsNeverAStall(delay: Double) {
    var watchdog = HelperWatchdog()
    var steps: [HelperWatchdog.Step] = []
    var asked: Double?
    var now = 0.0
    while now <= 600 {
      if let since = asked, now - since >= delay {
        watchdog.answered()
        asked = nil
      }
      let step = watchdog.check(now: now)
      if step == .ask { asked = now }
      steps.append(step)
      now += HelperWatchdog.checkSeconds
    }
    #expect(!steps.contains(.stalled))
    #expect(steps.filter { $0 == .ask }.count >= 600 / 35)
  }

  @Test func aQueueThatStopsAnsweringIsAStallBetween30And35SecondsAfterItsLastAnswer() {
    var watchdog = HelperWatchdog()
    var now = 0.0
    var stalledAt: Double?
    #expect(watchdog.check(now: now) == .ask)
    while stalledAt == nil, now < 600 {
      now += HelperWatchdog.checkSeconds
      if watchdog.check(now: now) == .stalled { stalledAt = now }
    }
    #expect(stalledAt == 30)
    #expect(HelperWatchdog.checkSeconds + HelperWatchdog.stallSeconds == 35)
  }

  @Test func theLimitsAreTheDocumentedOnes() {
    #expect(HelperWatchdog.checkSeconds == 5)
    #expect(HelperWatchdog.stallSeconds == 30)
  }

  @Test func aStallIsFoundBeforeTheHeartbeatLimitOfADR0011() {
    #expect(HelperWatchdog.checkSeconds + HelperWatchdog.stallSeconds < HelperMachine.heartbeatTimeoutSeconds)
  }

  @Test func theStallLimitIsLongerThanTwoOfTheLongestBoundedSequencesOnTheQueue() {
    let boundedStep = Self.pmsetBoundSeconds + HelperMachine.verifyWindowSeconds
    let failedSetAndItsRelease = 2 * boundedStep
    #expect(failedSetAndItsRelease == 14)
    #expect(HelperWatchdog.stallSeconds >= 2 * failedSetAndItsRelease)
  }
}
