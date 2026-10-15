import Foundation
import OvertimeAppSupport
import OvertimeSystem
import Testing
import os

@testable import Overtime

@MainActor
struct UpdaterWiringTests {
  @Test func theTestHostIsADebugBuildWithNoUpdater() throws {
    #expect(AppMode.current == .testHost)
    #expect(AppDelegate.isDebugBuild)
    let delegate = try #require(AppDelegate.shared)
    #expect(!delegate.updaterAttached)
    #expect(delegate.updaterPort == nil)
  }

  @Test func eachAppModeMapsToItsUpdaterHost() throws {
    #expect(AppDelegate.updaterHost(for: .testHost) == .testHost)
    #expect(AppDelegate.updaterHost(for: .blocked(.storageUnavailable)) == .blocked)
    let folder = try TestFolder()
    let lock = try InstanceLock.acquire(at: folder.url.appendingPathComponent("updater-wiring.lock"))
    defer { lock.release() }
    #expect(AppDelegate.updaterHost(for: .live(HeldLocks(primary: lock, secondary: nil))) == .live)
  }

  @Test func noModeOfThisBuildWouldBuildAnUpdater() {
    for host in [UpdaterHost.testHost, .blocked, .live] {
      #expect(!UpdaterBuildPolicy.buildsUpdater(host: host, debugBuild: AppDelegate.isDebugBuild))
    }
  }

  @Test func anUpdaterThatWasNeverStartedReportsOnlyEmptyValues() {
    let updater = SparkleUpdater(refuseChecks: { (terminating: false, uninstalling: false) })
    #expect(!updater.isStarted)
    #expect(!updater.canCheckForUpdates)
    #expect(updater.lastUpdateCheckDate == nil)
    #expect(!updater.automaticallyChecksForUpdates)
    #expect(!updater.automaticallyDownloadsUpdates)
    #expect(!updater.allowsAutomaticUpdates)
    #expect(!updater.reminder.isWaiting)
    #expect(!updater.reminder.stagedForQuit)
    updater.automaticallyChecksForUpdates = true
    updater.checkForUpdates()
    #expect(!updater.automaticallyChecksForUpdates)
    #expect(!updater.isStarted)
  }

  @Test func aWaitingUpdateIsRecordedAndClearedWithAChangeEachTime() {
    let updater = SparkleUpdater(refuseChecks: { (terminating: false, uninstalling: false) })
    var changes = 0
    updater.onChange = { changes += 1 }
    updater.reminderWillShow(handledBySparkle: false, version: "0.1.1")
    #expect(updater.reminder.waitingVersion == "0.1.1")
    updater.reminderAttended()
    #expect(!updater.reminder.isWaiting)
    updater.reminderWillShow(handledBySparkle: false, version: "0.1.2")
    updater.reminderSessionFinished()
    #expect(!updater.reminder.isWaiting)
    updater.reminderWillShow(handledBySparkle: true, version: "0.1.3")
    #expect(!updater.reminder.isWaiting)
    #expect(changes == 5)
  }

  @Test func aStagedInstallIsRecordedForTheQuit() {
    let updater = SparkleUpdater(refuseChecks: { (terminating: false, uninstalling: false) })
    var changes = 0
    updater.onChange = { changes += 1 }
    updater.stageForQuit()
    #expect(updater.reminder.stagedForQuit)
    #expect(changes == 1)
  }

  @Test func theStagedFlagTheUninstallReadsFollowsTheUpdaterWhenItChanges() {
    let updater = SparkleUpdater(refuseChecks: { (terminating: false, uninstalling: false) })
    let mirror = OSAllocatedUnfairLock(initialState: false)
    updater.onChange = { [weak updater] in AppDelegate.mirrorStagedForQuit(from: updater, into: mirror) }
    #expect(!mirror.withLock { $0 })
    updater.stageForQuit()
    #expect(mirror.withLock { $0 })
    AppDelegate.mirrorStagedForQuit(from: nil, into: mirror)
    #expect(!mirror.withLock { $0 })
  }

  @Test(arguments: [(false, false, true), (true, false, true), (false, true, false), (true, true, false)])
  func anInstallAndItsRelaunchAreRefusedWhileAnUninstallRuns(terminating: Bool, uninstalling: Bool, allowed: Bool) {
    let updater = SparkleUpdater(refuseChecks: { (terminating: terminating, uninstalling: uninstalling) })
    do {
      try updater.permitInstall()
      #expect(allowed)
    } catch {
      #expect(!allowed)
      let refusal = error as NSError
      #expect(refusal.domain == SparkleUpdater.errorDomain)
      #expect(refusal.code == SparkleUpdater.installRefusedCode)
      #expect(refusal.localizedDescription == "Overtime won't install updates while it uninstalls.")
    }
    #expect(updater.relaunchAllowed == allowed)
    #expect(updater.postponesRelaunchForever == !allowed)
  }

  @Test(arguments: [false, true])
  func anInstallOnQuitWhileUninstallingRemovesTheStagedUpdateInsteadOfStagingIt(uninstalling: Bool) {
    var removals = 0
    let updater = SparkleUpdater(
      refuseChecks: { (terminating: false, uninstalling: uninstalling) }, removeStagedUpdate: { removals += 1 })
    var changes = 0
    updater.onChange = { changes += 1 }
    #expect(updater.installOnQuit() == uninstalling)
    #expect(removals == (uninstalling ? 1 : 0))
    #expect(updater.reminder.stagedForQuit == !uninstalling)
    #expect(changes == (uninstalling ? 0 : 1))
  }

  @Test(arguments: [(false, false, true), (true, false, false), (false, true, false), (true, true, false)])
  func aCheckIsRefusedWhileTerminatingOrUninstalling(terminating: Bool, uninstalling: Bool, allowed: Bool) {
    let updater = SparkleUpdater(refuseChecks: { (terminating: terminating, uninstalling: uninstalling) })
    do {
      try updater.permitCheck()
      #expect(allowed)
    } catch {
      #expect(!allowed)
      let refusal = error as NSError
      #expect(refusal.domain == SparkleUpdater.errorDomain)
      #expect(refusal.code == SparkleUpdater.checkRefusedCode)
    }
  }
}
