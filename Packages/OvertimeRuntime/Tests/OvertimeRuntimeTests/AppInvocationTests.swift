import OvertimeAppSupport
import Testing

struct AppInvocationTests {
  @Test(arguments: [[], ["-NSDocumentRevisionsDebugMode", "YES"], ["--clear-backend", "record:/tmp/x"], ["-reset"]])
  func anythingNotStartingWithResetLaunchesTheApp(_ arguments: [String]) {
    #expect(AppInvocation.parse(arguments, allowsRecordBackend: true) == .app)
    #expect(AppInvocation.parse(arguments, allowsRecordBackend: false) == .app)
  }

  @Test func resetAloneUsesIOKit() {
    #expect(AppInvocation.parse(["--reset"], allowsRecordBackend: false) == .reset(.iokit))
    #expect(AppInvocation.parse(["--reset"], allowsRecordBackend: true) == .reset(.iokit))
  }

  @Test func theRecordBackendNeedsItToBeAllowed() {
    let arguments = ["--reset", "--clear-backend", "record:/tmp/x"]
    #expect(AppInvocation.parse(arguments, allowsRecordBackend: true) == .reset(.record("/tmp/x")))
    guard case .usage = AppInvocation.parse(arguments, allowsRecordBackend: false) else {
      Issue.record("record backend accepted without permission")
      return
    }
  }

  @Test(arguments: [
    ["--reset", "--clear-backend", "record:"],
    ["--reset", "--clear-backend", "bogus"],
    ["--reset", "--clear-backend"],
    ["--reset", "extra"],
    ["--reset", "--clear-backend", "record:/tmp/x", "extra"],
    ["--reset", "--reset"],
  ])
  func malformedResetArgumentsAreUsage(_ arguments: [String]) {
    for allowed in [true, false] {
      guard case .usage(let message) = AppInvocation.parse(arguments, allowsRecordBackend: allowed) else {
        Issue.record("\(arguments) was not rejected")
        continue
      }
      #expect(message.contains("--reset"))
    }
  }

  @Test func uninstallParsesWithAndWithoutPurge() {
    for allowed in [true, false] {
      #expect(AppInvocation.parse(["--uninstall"], allowsRecordBackend: allowed) == .uninstall(purge: false))
      #expect(AppInvocation.parse(["--uninstall", "--purge"], allowsRecordBackend: allowed) == .uninstall(purge: true))
    }
    #expect(AppInvocation.uninstallFlag == "--uninstall")
    #expect(AppInvocation.purgeFlag == "--purge")
  }

  @Test(arguments: [
    ["--uninstall", "extra"],
    ["--uninstall", "--purge", "--purge"],
    ["--uninstall", "--reset"],
    ["--uninstall", "--purge", "x"],
    ["--uninstall", "--PURGE"],
    ["--uninstall", ""],
  ])
  func anythingElseAfterUninstallIsUsage(_ arguments: [String]) {
    for allowed in [true, false] {
      guard case .usage(let message) = AppInvocation.parse(arguments, allowsRecordBackend: allowed) else {
        Issue.record("\(arguments) was not rejected")
        continue
      }
      #expect(message.contains("--uninstall"))
      #expect(message.contains("       Overtime --uninstall [--purge]"))
    }
  }

  @Test(arguments: [["--purge"], ["--purge", "--uninstall"], ["-uninstall"]])
  func purgeOrUninstallNotFirstLaunchesTheApp(_ arguments: [String]) {
    #expect(AppInvocation.parse(arguments, allowsRecordBackend: true) == .app)
    #expect(AppInvocation.parse(arguments, allowsRecordBackend: false) == .app)
  }

  @Test func theUsageTextListsResetAndUninstall() {
    guard case .usage(let release) = AppInvocation.parse(["--reset", "x"], allowsRecordBackend: false) else {
      Issue.record("reset with an extra argument was not rejected")
      return
    }
    #expect(release == "usage: Overtime --reset\n       Overtime --uninstall [--purge]")
    guard case .usage(let debug) = AppInvocation.parse(["--reset", "x"], allowsRecordBackend: true) else {
      Issue.record("reset with an extra argument was not rejected")
      return
    }
    #expect(
      debug
        == "usage: Overtime --reset\n       Overtime --reset --clear-backend record:<path>\n"
        + "       Overtime --uninstall [--purge]")
  }
}
