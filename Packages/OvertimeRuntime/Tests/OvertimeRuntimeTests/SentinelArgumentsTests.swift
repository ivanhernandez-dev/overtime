import OvertimeAppSupport
import OvertimeClamshell
import OvertimeEngine
import OvertimeSystem
import Testing

struct SentinelArgumentsTests {
  @Test func theRelaunchConfigurationPassesExactlyTheThreeFlags() {
    let configuration = RelaunchConfiguration(
      appPath: "/Applications/Overtime.app", historyPath: "/s/relaunch-history",
      suppressionPath: "/s/relaunch-suppressed")
    #expect(
      configuration.arguments == [
        "--relaunch-app", "/Applications/Overtime.app", "--relaunch-history", "/s/relaunch-history",
        "--relaunch-suppress", "/s/relaunch-suppressed",
      ])
  }

  @Test func overtimedPortsPassNoRelaunchArguments() {
    #expect(LivePorts.sentinelArguments(relaunch: nil).isEmpty)
    #expect(!LivePorts.sentinelArguments(relaunch: nil).contains { $0.hasPrefix("--relaunch") })
  }

  @Test func theAppPortsPassTheRelaunchArguments() {
    let paths = Paths.resolve(environment: ["OVERTIME_HOME": "/x"], homeDirectory: "/Users/dev")
    let configuration = AppHost.relaunchConfiguration(appPath: "/Applications/Overtime.app", paths: paths)
    #expect(
      LivePorts.sentinelArguments(relaunch: configuration) == [
        "--relaunch-app", "/Applications/Overtime.app", "--relaunch-history", "/x/support/relaunch-history",
        "--relaunch-suppress", "/x/support/relaunch-suppressed",
      ])
  }
}
