import OvertimeClamshell
import Testing

struct RelaunchPolicyTests {
  let now: Int64 = 1_000_000
  let second = RelaunchPolicy.nanosecondsPerSecond

  func decide(
    _ exit: RelaunchExit = .endOfInput(parentGone: true), history: [Int64] = [], suppressedAt: Int64? = nil,
    appRunning: Bool = false, appExists: Bool = true
  ) -> RelaunchDecision {
    RelaunchPolicy.decide(
      exit: exit, now: now, history: history, suppressedAtNanoseconds: suppressedAt.map { $0 * second },
      appRunning: appRunning, appExists: appExists)
  }

  @Test func gracefulAndSignalExitsNeverRelaunch() {
    #expect(decide(.bye) == .skip(reason: "bye"))
    #expect(decide(.signal) == .skip(reason: "signal"))
  }

  @Test func endOfInputWithALivingParentIsARetire() {
    #expect(decide(.endOfInput(parentGone: false)) == .skip(reason: "retire"))
  }

  @Test func confirmedHolderDeathRelaunchesWithAnEmptyHistory() {
    #expect(decide(.endOfInput(parentGone: true)) == .relaunch(history: [now]))
    #expect(decide(.heartbeatTimeoutTerminated) == .relaunch(history: [now]))
  }

  @Test func aMissingAppIsSkipped() {
    #expect(decide(appExists: false) == .skip(reason: "appMissing"))
  }

  @Test func aTargetThatIsNotAnOvertimeBundleIsSkippedAfterAMissingOne() {
    let invalid = RelaunchPolicy.decide(
      exit: .endOfInput(parentGone: true), now: now, history: [], suppressedAtNanoseconds: nil, appRunning: false,
      appExists: true, appValid: false)
    #expect(invalid == .skip(reason: "notAnApp"))
    let missing = RelaunchPolicy.decide(
      exit: .endOfInput(parentGone: true), now: now, history: [], suppressedAtNanoseconds: nil, appRunning: false,
      appExists: false, appValid: false)
    #expect(missing == .skip(reason: "appMissing"))
    #expect(RelaunchFlags.isAppBundlePath("/Applications/Overtime.app"))
    #expect(!RelaunchFlags.isAppBundlePath("/Applications/Overtime"))
    #expect(!RelaunchFlags.isAppBundlePath("Overtime.app"))
    #expect(!RelaunchFlags.isAppBundlePath("/.app"))
  }

  @Test func theAppSuffixIsMatchedWithoutRegardToCase() {
    #expect(RelaunchFlags.isAppBundlePath("/Applications/Overtime.APP"))
    #expect(RelaunchFlags.isAppBundlePath("/Applications/Overtime.App"))
    #expect(!RelaunchFlags.isAppBundlePath("/.APP"))
    #expect(!RelaunchFlags.isAppBundlePath("/Applications/Overtime.APPS"))
  }

  @Test func aRunningAppIsSkipped() {
    #expect(decide(appRunning: true) == .skip(reason: "running"))
  }

  @Test func theSuppressionStampHoldsFor120Seconds() {
    #expect(decide(suppressedAt: now - 119) == .skip(reason: "suppressed"))
    #expect(decide(suppressedAt: now - 120) == .relaunch(history: [now]))
    #expect(decide(suppressedAt: now + 5) == .skip(reason: "suppressed"))
  }

  @Test func aStampFarInTheFutureIsStaleAndDoesNotSuppress() {
    #expect(decide(suppressedAt: now + 6) == .relaunch(history: [now]))
    #expect(decide(suppressedAt: now + 86_400) == .relaunch(history: [now]))
    #expect(RelaunchPolicy.futureStampToleranceSeconds == 5)
  }

  @Test func aStampWrittenInReactionToTheSentinelsOwnSigtermDoesNotSuppress() {
    let sent = (now - 3) * second
    func decide(_ exit: RelaunchExit, stamp: Int64) -> RelaunchDecision {
      RelaunchPolicy.decide(
        exit: exit, now: now, history: [], suppressedAtNanoseconds: stamp, appRunning: false, appExists: true,
        terminatedAtNanoseconds: sent)
    }
    #expect(decide(.heartbeatTimeoutTerminated, stamp: sent) == .relaunch(history: [now]))
    #expect(decide(.heartbeatTimeoutTerminated, stamp: sent + second) == .relaunch(history: [now]))
    #expect(decide(.heartbeatTimeoutTerminated, stamp: sent - second) == .skip(reason: "suppressed"))
    #expect(decide(.endOfInput(parentGone: true), stamp: sent + second) == .skip(reason: "suppressed"))
  }

  @Test func aQuitStampedEarlierInTheSameSecondAsTheSentinelsSigtermStillSuppresses() {
    let sent = (now - 3) * second + 800_000_000
    func decide(stamp: Int64) -> RelaunchDecision {
      RelaunchPolicy.decide(
        exit: .heartbeatTimeoutTerminated, now: now, history: [], suppressedAtNanoseconds: stamp, appRunning: false,
        appExists: true, terminatedAtNanoseconds: sent)
    }
    #expect(decide(stamp: sent - 400_000_000) == .skip(reason: "suppressed"))
    #expect(decide(stamp: sent - 1_000) == .skip(reason: "suppressed"))
    #expect(decide(stamp: sent) == .relaunch(history: [now]))
    #expect(decide(stamp: sent + 1_000) == .relaunch(history: [now]))
  }

  @Test func theSuppressionWindowCountsWholeSecondsOfTheStamp() {
    func decide(stamp: Int64) -> RelaunchDecision {
      RelaunchPolicy.decide(
        exit: .endOfInput(parentGone: true), now: now, history: [], suppressedAtNanoseconds: stamp, appRunning: false,
        appExists: true)
    }
    #expect(decide(stamp: (now - 120) * second + 999_999_999) == .relaunch(history: [now]))
    #expect(decide(stamp: (now - 119) * second) == .skip(reason: "suppressed"))
    #expect(decide(stamp: (now + 5) * second + 999_999_999) == .skip(reason: "suppressed"))
    #expect(decide(stamp: (now + 6) * second) == .relaunch(history: [now]))
  }

  @Test func aRelaunchWithin30SecondsOfTheLastIsADuplicate() {
    #expect(decide(history: [now - 29]) == .skip(reason: "duplicate"))
    #expect(decide(history: [now - 30]) == .relaunch(history: [now - 30, now]))
  }

  @Test func atMostThreeRelaunchesCountInTheTrailingWindow() {
    let start = now - 120
    #expect(decide(history: [start, start + 40, start + 80]) == .skip(reason: "limited"))
    let later = RelaunchPolicy.decide(
      exit: .endOfInput(parentGone: true), now: start + 600, history: [start, start + 40, start + 80],
      suppressedAtNanoseconds: nil, appRunning: false, appExists: true)
    #expect(later == .relaunch(history: [start + 40, start + 80, start + 600]))
  }

  @Test func precedenceIsExitKindAppMissingRunningSuppressedDuplicateLimited() {
    let full: [Int64] = [now - 100, now - 50, now - 10]
    #expect(decide(.bye, history: full, suppressedAt: now, appRunning: true, appExists: false) == .skip(reason: "bye"))
    #expect(decide(history: full, suppressedAt: now, appRunning: true, appExists: false) == .skip(reason: "appMissing"))
    #expect(decide(history: full, suppressedAt: now, appRunning: true) == .skip(reason: "running"))
    #expect(decide(history: full, suppressedAt: now) == .skip(reason: "suppressed"))
    #expect(decide(history: full) == .skip(reason: "duplicate"))
    #expect(decide(history: [now - 100, now - 80, now - 60]) == .skip(reason: "limited"))
  }

  @Test func parseHistoryDropsMalformedFutureAndExpiredEntries() {
    let text = "\(now - 10)\nnot a number\n\(now + 1)\n\n\(now - 600)\n\(now - 599)\r\n-5\n \(now - 20)\n"
    #expect(RelaunchPolicy.parseHistory(text, now: now) == [now - 599, now - 10])
  }

  @Test func serializeHistoryRoundTrips() {
    let history: [Int64] = [now - 300, now - 200, now]
    let text = RelaunchPolicy.serializeHistory(history)
    #expect(text == "\(now - 300)\n\(now - 200)\n\(now)\n")
    #expect(RelaunchPolicy.parseHistory(text, now: now) == history)
    #expect(RelaunchPolicy.serializeHistory([]) == "")
  }

  @Test func aStampTimeInRangeConvertsExactly() {
    #expect(RelaunchPolicy.nanoseconds(seconds: 1_700_000_000, nanoseconds: 5) == 1_700_000_000_000_000_005)
    #expect(RelaunchPolicy.nanoseconds(seconds: 0, nanoseconds: 0) == 0)
    #expect(RelaunchPolicy.nanoseconds(seconds: -1, nanoseconds: 999_999_999) == -1)
    #expect(RelaunchPolicy.nanoseconds(seconds: 9_223_372_036, nanoseconds: 854_775_807) == Int64.max)
    #expect(RelaunchPolicy.nanoseconds(seconds: -9_223_372_036, nanoseconds: -854_775_808) == Int64.min)
    #expect(RelaunchPolicy.nanosecondsPerSecond == 1_000_000_000)
  }

  @Test func aStampTimeWhoseSecondsDoNotFitInNanosecondsHasNoValue() {
    #expect(RelaunchPolicy.nanoseconds(seconds: Int64.min / 2, nanoseconds: 0) == nil)
    #expect(RelaunchPolicy.nanoseconds(seconds: Int64.max / 1_000_000_000 + 1, nanoseconds: 0) == nil)
    #expect(RelaunchPolicy.nanoseconds(seconds: Int64.min / 1_000_000_000 - 1, nanoseconds: 0) == nil)
    #expect(RelaunchPolicy.nanoseconds(seconds: Int64.max, nanoseconds: 0) == nil)
    #expect(RelaunchPolicy.nanoseconds(seconds: Int64.min, nanoseconds: 0) == nil)
    #expect(RelaunchPolicy.nanoseconds(seconds: -9_223_372_037, nanoseconds: 145_224_192) == nil)
  }

  @Test func aStampTimeWhoseSumDoesNotFitHasNoValue() {
    #expect(RelaunchPolicy.nanoseconds(seconds: 9_223_372_036, nanoseconds: 854_775_808) == nil)
    #expect(RelaunchPolicy.nanoseconds(seconds: -9_223_372_036, nanoseconds: -854_775_809) == nil)
    #expect(RelaunchPolicy.nanoseconds(seconds: 9_223_372_036, nanoseconds: Int64.max) == nil)
  }

  @Test func aStampWithNoTimeNeverSuppressesAndOneConvertedInRangeStillDoes() {
    func decide(_ exit: RelaunchExit, seconds: Int64) -> RelaunchDecision {
      RelaunchPolicy.decide(
        exit: exit, now: now, history: [],
        suppressedAtNanoseconds: RelaunchPolicy.nanoseconds(seconds: seconds, nanoseconds: 0), appRunning: false,
        appExists: true)
    }
    for exit in [RelaunchExit.endOfInput(parentGone: true), .heartbeatTimeoutTerminated] {
      #expect(decide(exit, seconds: Int64.min / 2) == .relaunch(history: [now]))
      #expect(decide(exit, seconds: -9_223_372_037) == .relaunch(history: [now]))
      #expect(decide(exit, seconds: Int64.max / 1_000_000_000 + 1) == .relaunch(history: [now]))
      #expect(decide(exit, seconds: now - 1) == .skip(reason: "suppressed"))
    }
  }

  @Test func theConstantsMatchTheDecision() {
    #expect(RelaunchPolicy.windowSeconds == 600)
    #expect(RelaunchPolicy.maxRelaunches == 3)
    #expect(RelaunchPolicy.dedupeSeconds == 30)
    #expect(RelaunchPolicy.suppressionSeconds == 120)
  }
}
