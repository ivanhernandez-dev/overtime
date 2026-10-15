import OvertimeAppSupport
import Testing

struct UpdateReminderTests {
  @Test(arguments: [(true, true), (false, false)])
  func sparkleShowsAScheduledUpdateOnlyInImmediateFocus(immediateFocus: Bool, shows: Bool) {
    #expect(UpdateReminder.sparkleShowsScheduledUpdate(immediateFocus: immediateFocus) == shows)
  }

  @Test func aNewReminderHasNothingWaitingAndNothingStaged() {
    let reminder = UpdateReminder()
    #expect(reminder.waitingVersion == nil)
    #expect(!reminder.isWaiting)
    #expect(!reminder.stagedForQuit)
  }

  @Test func anUpdateSparkleDoesNotShowWaitsWithItsVersion() {
    var reminder = UpdateReminder()
    reminder.willShowUpdate(handledBySparkle: false, version: "0.1.1")
    #expect(reminder.waitingVersion == "0.1.1")
    #expect(reminder.isWaiting)
  }

  @Test func anUpdateSparkleShowsItselfDoesNotWait() {
    var reminder = UpdateReminder()
    reminder.willShowUpdate(handledBySparkle: true, version: "0.1.1")
    #expect(reminder.waitingVersion == nil)
    #expect(!reminder.isWaiting)
  }

  @Test func theUserAttendingToTheUpdateClearsTheWait() {
    var reminder = UpdateReminder()
    reminder.willShowUpdate(handledBySparkle: false, version: "0.1.1")
    reminder.userAttended()
    #expect(reminder.waitingVersion == nil)
    #expect(!reminder.isWaiting)
  }

  @Test func theEndOfTheUpdateSessionClearsTheWait() {
    var reminder = UpdateReminder()
    reminder.willShowUpdate(handledBySparkle: false, version: "0.1.1")
    reminder.sessionFinished()
    #expect(reminder.waitingVersion == nil)
    #expect(!reminder.isWaiting)
  }

  @Test func aSecondWaitingUpdateReplacesTheVersion() {
    var reminder = UpdateReminder()
    reminder.willShowUpdate(handledBySparkle: false, version: "0.1.1")
    reminder.willShowUpdate(handledBySparkle: false, version: "0.1.2")
    #expect(reminder.waitingVersion == "0.1.2")
  }

  @Test func anUpdateSparkleShowsLeavesAnEarlierWaitInPlace() {
    var reminder = UpdateReminder()
    reminder.willShowUpdate(handledBySparkle: false, version: "0.1.1")
    reminder.willShowUpdate(handledBySparkle: true, version: "0.1.2")
    #expect(reminder.waitingVersion == "0.1.1")
  }

  @Test func aStagedInstallIsRecordedAndNeitherClearForgetsIt() {
    var reminder = UpdateReminder()
    reminder.noteStagedForQuit()
    #expect(reminder.stagedForQuit)
    reminder.willShowUpdate(handledBySparkle: false, version: "0.1.1")
    reminder.userAttended()
    #expect(reminder.stagedForQuit)
    reminder.sessionFinished()
    #expect(reminder.stagedForQuit)
    #expect(!reminder.isWaiting)
  }

  @Test(arguments: [
    (false, false, true),
    (true, false, false),
    (false, true, false),
    (true, true, false),
  ])
  func aCheckIsAllowedOnlyWhileNeitherTerminatingNorUninstalling(
    terminating: Bool, uninstalling: Bool, allowed: Bool
  ) {
    #expect(UpdateCheckGate.allowsCheck(terminating: terminating, uninstalling: uninstalling) == allowed)
  }

  @Test func anInstallOrRelaunchIsRefusedOnlyWhileAnUninstallRuns() {
    #expect(UpdateCheckGate.allowsInstall(uninstalling: false))
    #expect(!UpdateCheckGate.allowsInstall(uninstalling: true))
  }

  @Test(arguments: [
    (UpdaterHost.live, false, true),
    (UpdaterHost.live, true, false),
    (UpdaterHost.testHost, false, false),
    (UpdaterHost.testHost, true, false),
    (UpdaterHost.blocked, false, false),
    (UpdaterHost.blocked, true, false),
  ])
  func onlyTheLiveReleaseAppBuildsAnUpdater(host: UpdaterHost, debugBuild: Bool, builds: Bool) {
    #expect(UpdaterBuildPolicy.buildsUpdater(host: host, debugBuild: debugBuild) == builds)
  }
}
