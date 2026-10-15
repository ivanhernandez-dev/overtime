import Foundation
import OvertimeCore
import OvertimeSystem
import Testing

struct PathsTests {
  @Test func theRelaunchFilesLiveInTheSupportFolder() {
    let paths = Paths.resolve(environment: ["OVERTIME_HOME": "/x"], homeDirectory: "/Users/dev")
    #expect(paths.relaunchHistory.path(percentEncoded: false) == "/x/support/relaunch-history")
    #expect(paths.relaunchSuppression.path(percentEncoded: false) == "/x/support/relaunch-suppressed")
  }

  @Test func theLoginItemRecordLivesInTheSupportFolder() {
    let paths = Paths.resolve(environment: ["OVERTIME_HOME": "/x"], homeDirectory: "/Users/dev")
    #expect(paths.loginItemRecord.path(percentEncoded: false) == "/x/support/login-item.json")
  }

  @Test func thePreferencesFileLivesInTheSupportFolder() {
    let paths = Paths.resolve(environment: ["OVERTIME_HOME": "/x"], homeDirectory: "/Users/dev")
    #expect(paths.preferencesFile.path(percentEncoded: false) == "/x/support/preferences.json")
    #expect(paths.preferencesFile.deletingLastPathComponent() == paths.settingsFile.deletingLastPathComponent())
    #expect(
      Paths.resolve(environment: [:], homeDirectory: "/Users/dev", appName: "Overtime Dev").preferencesFile.path(
        percentEncoded: false) == "/Users/dev/Library/Application Support/Overtime Dev/preferences.json")
  }

  @Test func overtimeHomeReplacesBothDirectories() {
    let paths = Paths.resolve(environment: ["OVERTIME_HOME": "/x"], homeDirectory: "/Users/dev")
    #expect(paths.supportDirectory.path(percentEncoded: false) == "/x/support/")
    #expect(paths.logsDirectory.path(percentEncoded: false) == "/x/logs/")
    #expect(paths.decisionLog(.shadow).path(percentEncoded: false) == "/x/logs/overtimed-shadow.log")
  }

  @Test func defaultLayoutUsesTheUserLibrary() {
    let paths = Paths.resolve(environment: [:], homeDirectory: "/Users/dev")
    #expect(paths.supportDirectory.path(percentEncoded: false) == "/Users/dev/Library/Application Support/Overtime/")
    #expect(paths.logsDirectory.path(percentEncoded: false) == "/Users/dev/Library/Logs/Overtime/")
    #expect(Paths.resolve(environment: ["OVERTIME_HOME": ""], homeDirectory: "/Users/dev") == paths)
  }

  @Test func theDebugAppNameGetsItsOwnRoots() {
    let paths = Paths.resolve(environment: [:], homeDirectory: "/Users/dev", appName: "Overtime Dev")
    #expect(
      paths.supportDirectory.path(percentEncoded: false) == "/Users/dev/Library/Application Support/Overtime Dev/")
    #expect(paths.logsDirectory.path(percentEncoded: false) == "/Users/dev/Library/Logs/Overtime Dev/")
  }

  @Test func theDefaultAppNameKeepsTodaysPaths() {
    #expect(
      Paths.resolve(environment: [:], homeDirectory: "/Users/dev", appName: "Overtime")
        == Paths.resolve(environment: [:], homeDirectory: "/Users/dev"))
  }

  @Test func overtimeHomeWinsForAnyAppName() {
    let paths = Paths.resolve(
      environment: ["OVERTIME_HOME": "/x"], homeDirectory: "/Users/dev", appName: "Overtime Dev")
    #expect(paths == Paths.resolve(environment: ["OVERTIME_HOME": "/x"], homeDirectory: "/Users/dev"))
    #expect(paths.supportDirectory.path(percentEncoded: false) == "/x/support/")
  }

  @Test func shadowFilesNeverShareANameWithLiveFiles() {
    let paths = Paths.resolve(environment: ["OVERTIME_HOME": "/x"], homeDirectory: "/Users/dev")
    let pairs: [(URL, URL)] = [
      (paths.decisionLog(.shadow), paths.decisionLog(.live)),
      (paths.errorLog(.shadow), paths.errorLog(.live)),
      (paths.stateFile(.shadow), paths.stateFile(.live)),
      (paths.lockFile(.shadow), paths.lockFile(.live)),
      (paths.controlSocket(.shadow), paths.controlSocket(.live)),
    ]
    for (shadow, live) in pairs {
      #expect(shadow.lastPathComponent != live.lastPathComponent)
    }
    #expect(paths.stateFile(.live).lastPathComponent == "state.json")
    #expect(paths.stateFile(.shadow).lastPathComponent == "shadow-state.json")
    #expect(paths.lockFile(.live).lastPathComponent == "overtimed.lock")
    #expect(paths.controlSocket(.shadow).lastPathComponent == "overtimed-shadow.sock")
    #expect(paths.errorLog(.shadow).lastPathComponent == "overtimed-shadow-error.log")
  }

  @Test func createDirectoriesUsesOwnerOnlyMode() throws {
    let temp = try TempDirectory()
    let paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path], homeDirectory: "/Users/dev")
    try paths.createDirectories()
    for directory in [paths.supportDirectory, paths.logsDirectory] {
      let attributes = try FileManager.default.attributesOfItem(atPath: directory.path(percentEncoded: false))
      #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }
  }
}
