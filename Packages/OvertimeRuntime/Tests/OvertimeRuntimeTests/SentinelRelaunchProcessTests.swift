import Darwin
import Foundation
import OvertimeClamshell
import Testing

final class RelaunchSetup {
  let temp: TempDirectory
  let appPath: String
  let historyPath: String
  let stampPath: String
  let spawnPath: String

  static let releaseIdentifier = "io.github.ivanhernandez-dev.overtime"

  init(
    createApp: Bool = true, bundleIdentifier: String? = RelaunchSetup.releaseIdentifier, executable: Bool = true,
    binaryPlist: Bool = false
  ) throws {
    temp = try TempDirectory()
    appPath = temp.url.appendingPathComponent("Fake.app").path(percentEncoded: false)
    historyPath = temp.url.appendingPathComponent("relaunch-history").path(percentEncoded: false)
    stampPath = temp.url.appendingPathComponent("relaunch-suppressed").path(percentEncoded: false)
    spawnPath = temp.url.appendingPathComponent("spawn").path(percentEncoded: false)
    guard createApp else { return }
    try FileManager.default.createDirectory(atPath: appPath + "/Contents/MacOS", withIntermediateDirectories: true)
    if let bundleIdentifier {
      try writeInfoPlist(["CFBundleIdentifier": bundleIdentifier], binary: binaryPlist)
    }
    if executable {
      try installExecutable(from: "/usr/bin/true")
    }
  }

  func writeInfoPlist(_ root: Any, binary: Bool = false) throws {
    let plist = try PropertyListSerialization.data(
      fromPropertyList: root, format: binary ? .binary : .xml, options: 0)
    try plist.write(to: URL(fileURLWithPath: appPath + "/" + RelaunchFlags.appInfoPlist))
  }

  var executablePath: String {
    appPath + "/" + RelaunchFlags.appExecutable
  }

  func installExecutable(from source: String) throws {
    try? FileManager.default.removeItem(atPath: executablePath)
    try FileManager.default.copyItem(atPath: source, toPath: executablePath)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executablePath)
  }

  var flags: [String] {
    [
      "--relaunch-app", appPath, "--relaunch-history", historyPath, "--relaunch-suppress", stampPath,
      "--relaunch-record", spawnPath,
    ]
  }

  var spawnLines: [String] {
    guard let text = try? String(contentsOfFile: spawnPath, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").map(String.init)
  }

  var spawnFileExists: Bool {
    FileManager.default.fileExists(atPath: spawnPath)
  }

  var historyEntries: [Int64]? {
    guard let text = try? String(contentsOfFile: historyPath, encoding: .utf8) else { return nil }
    return RelaunchPolicy.parseHistory(text, now: Int64(time(nil)))
  }
}

enum MalformedInfoPlist: String, CaseIterable, Sendable {
  case arrayRoot
  case stringRoot
  case numberIdentifier
  case arrayIdentifier

  var root: Any {
    switch self {
    case .arrayRoot: [RelaunchSetup.releaseIdentifier]
    case .stringRoot: RelaunchSetup.releaseIdentifier
    case .numberIdentifier: ["CFBundleIdentifier": 42]
    case .arrayIdentifier: ["CFBundleIdentifier": [RelaunchSetup.releaseIdentifier]]
    }
  }
}

@Suite(.serialized, .processCleanup)
struct SentinelRelaunchProcessTests {
  static let eventSeconds = SentinelProcessTests.eventSeconds
  func awaitArmed(_ run: FixtureRun) async throws -> (parent: pid_t, sentinel: pid_t) {
    let pids = try #require(await OffPool.run { run.ready() })
    try #require(await OffPool.eventually(seconds: Self.eventSeconds) { run.log.contains(" armed") })
    return pids
  }

  func awaitReady(_ run: FixtureRun) async throws {
    _ = try #require(await OffPool.run { run.ready() })
  }

  func awaitExit(_ run: FixtureRun, within seconds: Double = 5) async -> Bool {
    await OffPool.eventually(seconds: seconds) { run.log.contains(" exit reason=") }
  }

  func awaitLine(_ run: FixtureRun, startingWith prefix: String, within seconds: Double) async -> String? {
    await OffPool.run { run.line(startingWith: prefix, within: seconds) }
  }

  @Test func killNineOfAnArmedHolderClearsThenRelaunchesTheExactAppPath() async throws {
    let setup = try RelaunchSetup()
    let run = try FixtureRun(["--arm"] + setup.flags, in: setup.temp)
    let pids = try await awaitArmed(run)
    run.signalFixture(SIGKILL)
    #expect(await OffPool.eventually(seconds: Self.eventSeconds) { run.record.contains("clear eof") })
    #expect(await OffPool.eventually(seconds: Self.eventSeconds) { setup.spawnLines.count == 1 })
    #expect(setup.spawnLines == ["relaunch \(setup.appPath)"])
    #expect(await awaitExit(run))
    #expect(setup.historyEntries?.count == 1)
    let log = run.log
    let cleared = try #require(log.range(of: " clear eof kr=0"))
    let relaunched = try #require(log.range(of: " relaunch spawned pid=0 status=record"))
    #expect(cleared.upperBound <= relaunched.lowerBound)
    #expect(run.record.components(separatedBy: "clear eof").count == 2)
    #expect(await OffPool.eventually(seconds: Self.eventSeconds) { ProcessProbe.isGone(pids.sentinel) })
  }

  @Test func killNineOfAnUnarmedHolderRelaunchesWithoutAClear() async throws {
    let setup = try RelaunchSetup()
    let run = try FixtureRun(setup.flags, in: setup.temp)
    try await awaitReady(run)
    run.signalFixture(SIGKILL)
    #expect(await OffPool.eventually(seconds: Self.eventSeconds) { setup.spawnLines.count == 1 })
    #expect(await awaitExit(run))
    #expect(setup.spawnLines == ["relaunch \(setup.appPath)"])
    #expect(!run.record.contains("clear"))
  }

  @Test func byeNeverRelaunches() async throws {
    let setup = try RelaunchSetup()
    let run = try FixtureRun(["--arm", "--bye-after", "1"] + setup.flags, in: setup.temp)
    _ = try await awaitArmed(run)
    #expect(await awaitExit(run))
    #expect(run.log.contains(" relaunch skipped reason=bye"))
    #expect(run.log.contains(" exit reason=bye"))
    #expect(!setup.spawnFileExists)
  }

  @Test func aCloseByALivingHolderIsARetireAndNeverRelaunches() async throws {
    let setup = try RelaunchSetup()
    let run = try FixtureRun(["--arm", "--close-after", "1"] + setup.flags, in: setup.temp)
    _ = try await awaitArmed(run)
    #expect(await awaitExit(run))
    #expect(run.record.contains("clear eof"))
    #expect(run.log.contains(" relaunch skipped reason=retire"))
    #expect(run.process.isRunning)
    #expect(!setup.spawnFileExists)
  }

  static let backgroundLauncher = ["/usr/sbin/taskpolicy", "-b"]
  static let retireDecisionSeconds: Double = 4

  @Test func aRetireWithCoalescedTimersIsDecidedWithinTheOneSecondParentPoll() async throws {
    let setup = try RelaunchSetup()
    let run = try FixtureRun(
      ["--arm", "--close-after", "1"] + setup.flags, in: setup.temp, launcher: Self.backgroundLauncher)
    let pids = try await awaitArmed(run)
    try #require(pids.parent == run.process.processIdentifier)
    try #require(await awaitLine(run, startingWith: "CLOSED", within: Self.eventSeconds) != nil)
    #expect(await awaitExit(run, within: Self.retireDecisionSeconds))
    #expect(run.record.contains("clear eof"))
    #expect(run.log.contains(" relaunch skipped reason=retire"))
    #expect(run.process.isRunning)
    #expect(!setup.spawnFileExists)
  }

  @Test func aSignalToTheSentinelNeverRelaunches() async throws {
    let setup = try RelaunchSetup()
    let run = try FixtureRun(["--arm"] + setup.flags, in: setup.temp)
    _ = try await awaitArmed(run)
    run.signalSentinel(SIGTERM)
    #expect(await awaitExit(run))
    #expect(run.record.contains("clear signal"))
    #expect(run.log.contains(" relaunch skipped reason=signal"))
    #expect(!setup.spawnFileExists)
  }

  @Test func aFreshSuppressionStampPreventsTheRelaunch() async throws {
    let setup = try RelaunchSetup()
    let run = try FixtureRun(["--arm"] + setup.flags, in: setup.temp)
    _ = try await awaitArmed(run)
    try #require(FileManager.default.createFile(atPath: setup.stampPath, contents: Data()))
    run.signalFixture(SIGKILL)
    #expect(await awaitExit(run))
    #expect(run.record.contains("clear eof"))
    #expect(run.log.contains(" relaunch skipped reason=suppressed"))
    #expect(!setup.spawnFileExists)
  }

  @Test(arguments: [false, true])
  func aHolderThatStampsOnTheHeartbeatTimeoutSigtermIsStillRelaunched(_ exitsAfterStamp: Bool) async throws {
    let setup = try RelaunchSetup()
    let flags =
      ["--arm", "--no-heartbeat", "--timeout", "1", "--stamp-on-term", setup.stampPath]
      + (exitsAfterStamp ? ["--exit-after-stamp"] : []) + setup.flags
    let run = try FixtureRun(flags, in: setup.temp)
    let pids = try await awaitArmed(run)
    #expect(await OffPool.eventually(seconds: 4) { run.record.contains("clear heartbeat-timeout") })
    #expect(await awaitLine(run, startingWith: "STAMPED", within: 3) != nil)
    #expect(FileManager.default.fileExists(atPath: setup.stampPath))
    #expect(await OffPool.eventually(seconds: 6) { setup.spawnLines.count == 1 })
    #expect(await awaitExit(run))
    #expect(setup.spawnLines == ["relaunch \(setup.appPath)"])
    #expect(!run.log.contains("relaunch skipped"))
    #expect(setup.historyEntries?.count == 1)
    #expect(await OffPool.eventually(seconds: Self.eventSeconds) { ProcessProbe.isGone(pids.sentinel) })
  }

  @Test func aHolderRunningAsTheAppThatSaysByeOnTheHeartbeatTimeoutSigtermIsRelaunchedAfterItExits() async throws {
    let setup = try RelaunchSetup()
    let fixture = ExecutableLocator.url(named: "SentinelHolderFixture").path(percentEncoded: false)
    try setup.installExecutable(from: fixture)
    let flags =
      ["--arm", "--no-heartbeat", "--timeout", "1", "--stamp-on-term", setup.stampPath, "--bye-on-term"]
      + setup.flags
    let run = try FixtureRun(flags, in: setup.temp, executable: URL(fileURLWithPath: setup.executablePath))
    let pids = try await awaitArmed(run)
    #expect(
      ProcessProbe.canonical(ProcessProbe.executablePath(of: pids.parent) ?? "")
        == ProcessProbe.canonical(setup.executablePath))
    #expect(await OffPool.eventually(seconds: 4) { run.record.contains("clear heartbeat-timeout") })
    #expect(await awaitLine(run, startingWith: "BYE SENT", within: 3) != nil)
    #expect(await OffPool.eventually(seconds: Self.eventSeconds) { !run.process.isRunning })
    #expect(await OffPool.eventually(seconds: 6) { setup.spawnLines.count == 1 })
    #expect(await awaitExit(run))
    #expect(setup.spawnLines == ["relaunch \(setup.appPath)"])
    #expect(!run.log.contains("relaunch skipped"))
    #expect(!run.log.contains("parentKill"))
    #expect(run.log.contains(" exit reason=post-terminate"))
    #expect(await OffPool.eventually(seconds: Self.eventSeconds) { ProcessProbe.isGone(pids.sentinel) })
  }

  @Test func aStampWrittenBeforeTheHeartbeatTimeoutStillSuppresses() async throws {
    let setup = try RelaunchSetup()
    try #require(FileManager.default.createFile(atPath: setup.stampPath, contents: Data()))
    let past = Date(timeIntervalSinceNow: -10)
    try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: setup.stampPath)
    let run = try FixtureRun(["--arm", "--no-heartbeat", "--timeout", "1"] + setup.flags, in: setup.temp)
    _ = try await awaitArmed(run)
    #expect(await OffPool.eventually(seconds: 4) { run.record.contains("clear heartbeat-timeout") })
    #expect(await awaitExit(run, within: 8))
    #expect(run.log.contains(" relaunch skipped reason=suppressed"))
    #expect(!setup.spawnFileExists)
  }

  @Test func aStampWithATimeBefore1678IsStaleAndTheSentinelStillClearsRelaunchesAndExits() async throws {
    let setup = try RelaunchSetup()
    try #require(FileManager.default.createFile(atPath: setup.stampPath, contents: Data()))
    let year1600 = timeval(tv_sec: -11_676_096_000, tv_usec: 0)
    var times = [year1600, year1600]
    try #require(utimes(setup.stampPath, &times) == 0)
    var info = stat()
    try #require(lstat(setup.stampPath, &info) == 0)
    let seconds = Int64(info.st_mtimespec.tv_sec)
    try #require(seconds.multipliedReportingOverflow(by: RelaunchPolicy.nanosecondsPerSecond).overflow)
    #expect(RelaunchPolicy.nanoseconds(seconds: seconds, nanoseconds: Int64(info.st_mtimespec.tv_nsec)) == nil)
    let run = try FixtureRun(["--arm"] + setup.flags, in: setup.temp)
    let pids = try #require(await OffPool.run { run.ready() })
    try #require(await OffPool.eventually(seconds: Self.eventSeconds) { run.log.contains(" armed") })
    run.signalFixture(SIGKILL)
    #expect(await OffPool.eventually(seconds: Self.eventSeconds) { setup.spawnLines.count == 1 })
    #expect(await OffPool.eventually(seconds: 5) { run.log.contains(" exit reason=eof") })
    #expect(setup.spawnLines == ["relaunch \(setup.appPath)"])
    #expect(run.record.components(separatedBy: "clear eof").count == 2)
    let log = run.log
    let cleared = try #require(log.range(of: " clear eof kr=0"))
    let relaunched = try #require(log.range(of: " relaunch spawned pid=0 status=record"))
    #expect(cleared.upperBound <= relaunched.lowerBound)
    #expect(!log.contains("relaunch skipped"))
    #expect(await OffPool.eventually(seconds: Self.eventSeconds) { ProcessProbe.isGone(pids.sentinel) })
  }

  @Test func aHistoryPlantedAsASymlinkIsNeitherFollowedNorTruncated() async throws {
    let setup = try RelaunchSetup()
    let target = setup.temp.url.appendingPathComponent("elsewhere").path(percentEncoded: false)
    try "keep\n".write(toFile: target, atomically: false, encoding: .utf8)
    try FileManager.default.createSymbolicLink(atPath: setup.historyPath, withDestinationPath: target)
    let run = try FixtureRun(["--arm"] + setup.flags, in: setup.temp)
    _ = try await awaitArmed(run)
    run.signalFixture(SIGKILL)
    #expect(await awaitExit(run))
    #expect(run.record.contains("clear eof"))
    #expect(run.log.contains(" relaunch failed errno=\(ELOOP) step=history"))
    #expect(!setup.spawnFileExists)
    #expect((try? String(contentsOfFile: target, encoding: .utf8)) == "keep\n")
  }

  @Test func aSuppressionStampPlantedAsASymlinkIsIgnored() async throws {
    let setup = try RelaunchSetup()
    let target = setup.temp.url.appendingPathComponent("elsewhere").path(percentEncoded: false)
    try "".write(toFile: target, atomically: false, encoding: .utf8)
    try FileManager.default.createSymbolicLink(atPath: setup.stampPath, withDestinationPath: target)
    let run = try FixtureRun(["--arm"] + setup.flags, in: setup.temp)
    _ = try await awaitArmed(run)
    run.signalFixture(SIGKILL)
    #expect(await OffPool.eventually(seconds: Self.eventSeconds) { setup.spawnLines.count == 1 })
    #expect(await awaitExit(run))
    #expect(!run.log.contains("reason=suppressed"))
  }

  @Test(arguments: [
    (Optional("com.example.other"), true), (Optional<String>.none, true),
    (Optional(RelaunchSetup.releaseIdentifier), false),
  ])
  func aTargetThatIsNotAnOvertimeBundleIsNeverRelaunched(_ identifier: String?, _ executable: Bool) async throws {
    let setup = try RelaunchSetup(bundleIdentifier: identifier, executable: executable)
    let run = try FixtureRun(["--arm"] + setup.flags, in: setup.temp)
    _ = try await awaitArmed(run)
    run.signalFixture(SIGKILL)
    #expect(await awaitExit(run))
    #expect(run.record.contains("clear eof"))
    #expect(run.log.contains(" relaunch skipped reason=notAnApp"))
    #expect(!setup.spawnFileExists)
  }

  @Test(arguments: MalformedInfoPlist.allCases)
  func anInfoPlistOfTheWrongShapeIsNeverRelaunched(_ shape: MalformedInfoPlist) async throws {
    let setup = try RelaunchSetup(bundleIdentifier: nil)
    try setup.writeInfoPlist(shape.root)
    let run = try FixtureRun(["--arm"] + setup.flags, in: setup.temp)
    _ = try await awaitArmed(run)
    run.signalFixture(SIGKILL)
    #expect(await awaitExit(run))
    #expect(run.record.contains("clear eof"))
    #expect(run.log.contains(" relaunch skipped reason=notAnApp"))
    #expect(!setup.spawnFileExists)
  }

  @Test func theDebugBundleIdentifierInABinaryInfoPlistIsAccepted() async throws {
    let setup = try RelaunchSetup(bundleIdentifier: RelaunchSetup.releaseIdentifier + ".dev", binaryPlist: true)
    let run = try FixtureRun(["--arm"] + setup.flags, in: setup.temp)
    _ = try await awaitArmed(run)
    run.signalFixture(SIGKILL)
    #expect(await OffPool.eventually(seconds: Self.eventSeconds) { setup.spawnLines.count == 1 })
    #expect(await awaitExit(run))
  }

  @Test func threeRelaunchesInTheWindowLimitTheFourth() async throws {
    let setup = try RelaunchSetup()
    let now = Int64(time(nil))
    let seeded = RelaunchPolicy.serializeHistory([now - 300, now - 200, now - 100])
    try seeded.write(toFile: setup.historyPath, atomically: true, encoding: .utf8)
    let run = try FixtureRun(["--arm"] + setup.flags, in: setup.temp)
    _ = try await awaitArmed(run)
    run.signalFixture(SIGKILL)
    #expect(await awaitExit(run))
    #expect(run.log.contains(" relaunch skipped reason=limited"))
    #expect(!setup.spawnFileExists)
    #expect(setup.historyEntries == [now - 300, now - 200, now - 100])
  }

  @Test func theOvertimedShapeWithoutRelaunchFlagsNeverRelaunches() async throws {
    let setup = try RelaunchSetup()
    let run = try FixtureRun(["--arm"], in: setup.temp)
    _ = try await awaitArmed(run)
    run.signalFixture(SIGKILL)
    #expect(await awaitExit(run))
    #expect(run.record.contains("clear eof"))
    #expect(!run.log.contains("relaunch"))
    #expect(!setup.spawnFileExists)
    #expect(!FileManager.default.fileExists(atPath: setup.historyPath))
  }

  @Test func aMissingAppIsNeverRelaunched() async throws {
    let setup = try RelaunchSetup(createApp: false)
    let run = try FixtureRun(["--arm"] + setup.flags, in: setup.temp)
    _ = try await awaitArmed(run)
    run.signalFixture(SIGKILL)
    #expect(await awaitExit(run))
    #expect(run.record.contains("clear eof"))
    #expect(run.log.contains(" relaunch skipped reason=appMissing"))
    #expect(!setup.spawnFileExists)
  }

  @Test func aRunningCopyOfTheAppIsNeverRelaunched() async throws {
    let setup = try RelaunchSetup()
    let executable = setup.executablePath
    let stand = ExecutableLocator.url(named: "overtime-sentinel").path(percentEncoded: false)
    try setup.installExecutable(from: stand)
    let input = Pipe()
    let running = Process()
    running.executableURL = URL(fileURLWithPath: executable)
    running.arguments = [
      "--parent", String(getpid()), "--log",
      setup.temp.url.appendingPathComponent("stand.log").path(percentEncoded: false),
      "--clear-backend", "record:" + setup.temp.url.appendingPathComponent("stand-record").path(percentEncoded: false),
    ]
    running.standardInput = input
    running.standardOutput = FileHandle.nullDevice
    running.standardError = FileHandle.nullDevice
    try running.run()
    ProcessCleanup.track(running)
    let end = {
      try? input.fileHandleForWriting.close()
      ProcessProbe.signalIfOwn(running.processIdentifier, executable: executable, signal: SIGKILL)
    }
    try #require(
      await OffPool.eventually(seconds: Self.eventSeconds) {
        ProcessProbe.executablePath(of: running.processIdentifier) != nil
      })
    let run = try FixtureRun(["--arm"] + setup.flags, in: setup.temp)
    _ = try await awaitArmed(run)
    run.signalFixture(SIGKILL)
    #expect(await awaitExit(run))
    #expect(run.log.contains(" relaunch skipped reason=running"))
    #expect(!setup.spawnFileExists)
    end()
    #expect(await OffPool.eventually(seconds: Self.eventSeconds) { !running.isRunning })
  }

  static func usageExit(_ flags: [String], logPath: String) throws -> (exited: Bool, status: Int32?) {
    let sentinel = Process()
    sentinel.executableURL = ExecutableLocator.url(named: "overtime-sentinel")
    sentinel.arguments = ["--parent", String(getpid()), "--log", logPath] + flags
    sentinel.standardInput = FileHandle.nullDevice
    sentinel.standardOutput = FileHandle.nullDevice
    sentinel.standardError = FileHandle.nullDevice
    try sentinel.run()
    let exited = ProcessProbe.poll(within: 5) { !sentinel.isRunning }
    if !exited { kill(sentinel.processIdentifier, SIGKILL) }
    guard ProcessProbe.poll(within: ProcessCleanup.boundSeconds, { !sentinel.isRunning }) else { return (exited, nil) }
    return (exited, sentinel.terminationStatus)
  }

  @Test(arguments: [
    ["--relaunch-app", "/x/Fake.app"],
    ["--relaunch-app", "/x/Fake.app", "--relaunch-history", "/x/h"],
    ["--relaunch-history", "/x/h", "--relaunch-suppress", "/x/s"],
    ["--relaunch-spawner", "record:/x/spawn"],
    ["--relaunch-app", "Fake.app", "--relaunch-history", "/x/h", "--relaunch-suppress", "/x/s"],
    ["--relaunch-app", "/x/Fake", "--relaunch-history", "/x/h", "--relaunch-suppress", "/x/s"],
    ["--relaunch-app", "/x/Fake.app/", "--relaunch-history", "/x/h", "--relaunch-suppress", "/x/s"],
    ["--relaunch-app", "/.app", "--relaunch-history", "/x/h", "--relaunch-suppress", "/x/s"],
  ])
  func partialOrRelativeRelaunchFlagsAreAUsageError(_ flags: [String]) async throws {
    let temp = try TempDirectory()
    let logPath = temp.url.appendingPathComponent("log").path(percentEncoded: false)
    let outcome = try await OffPool.run { Result { try Self.usageExit(flags, logPath: logPath) } }.get()
    #expect(outcome.exited)
    #expect(outcome.status == 64)
  }
}
