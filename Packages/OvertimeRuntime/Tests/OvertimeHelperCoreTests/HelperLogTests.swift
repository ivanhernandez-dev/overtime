import Foundation
import OvertimeHelperCore
import Testing

struct HelperLogTests {
  static let instant = Date(timeIntervalSince1970: 1_791_381_709)
  static let stamp = "2026-10-07T14:01:49Z"
  static let lineOverhead = 22

  final class Scratch {
    let root: URL

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "overtime-helper-log-\(UUID().uuidString)", isDirectory: false)
      try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    deinit {
      try? FileManager.default.removeItem(at: root)
    }

    var folder: URL { root.appendingPathComponent("Overtime Dev", isDirectory: false) }
    var logPath: String { folder.path + "/helper.log" }
    var rotatedPath: String { folder.path + "/helper.log.1" }
    var elsewhere: String { root.path + "/elsewhere" }

    func log(owner: uid_t = getuid()) -> HelperLog {
      HelperLog(directory: folder, requiredOwner: owner) { HelperLogTests.instant }
    }

    func makeFolder(mode: Int = 0o755) throws {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
      #expect(chmod(folder.path, mode_t(mode)) == 0)
    }

    func mode(_ path: String) -> Int? {
      var info = stat()
      guard lstat(path, &info) == 0 else { return nil }
      return Int(info.st_mode & 0o7777)
    }

    func size(_ path: String) -> Int? {
      var info = stat()
      guard lstat(path, &info) == 0 else { return nil }
      return Int(info.st_size)
    }

    func exists(_ path: String) -> Bool {
      var info = stat()
      return lstat(path, &info) == 0
    }

    func contents(_ path: String) -> String? {
      FileManager.default.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) }
    }
  }

  @Test func eachLineIsAUTCTimestampASpaceAndTheMessage() throws {
    let scratch = try Scratch()
    let log = scratch.log()
    log.record("set owned prior=0")
    log.record("release reason=clear sleepDisabled=0 edge=done")
    #expect(
      scratch.contents(scratch.logPath)
        == "\(Self.stamp) set owned prior=0\n\(Self.stamp) release reason=clear sleepDisabled=0 edge=done\n")
  }

  @Test func theLogFileIsWorldReadableAndItsFolderIsCreatedForIt() throws {
    let scratch = try Scratch()
    scratch.log().record("reconcile none")
    #expect(scratch.mode(scratch.folder.path) == 0o755)
    #expect(scratch.mode(scratch.logPath) == 0o644)
  }

  @Test func theNamesAndTheRotationLimitAreTheDocumentedOnes() {
    #expect(HelperLog.fileName == "helper.log")
    #expect(HelperLog.rotatedFileName == "helper.log.1")
    #expect(HelperLog.rotateBytes == 524_288)
  }

  @Test func theDefaultClockStampsTheCurrentTimeInUTC() throws {
    let scratch = try Scratch()
    let before = Date()
    HelperLog(directory: scratch.folder, requiredOwner: getuid()).record("reconcile none")
    let line = try #require(scratch.contents(scratch.logPath))
    #expect(line.hasSuffix("Z reconcile none\n"))
    let formatter = ISO8601DateFormatter()
    let written = try #require(formatter.date(from: String(line.prefix(20))))
    #expect(abs(written.timeIntervalSince(before)) < 5)
  }

  @Test func controlCharactersAndAnythingOutsidePrintableASCIIAreReplaced() throws {
    let scratch = try Scratch()
    scratch.log().record("a\u{07}b\nc\u{1B}[31m\td\u{7F}e\u{2028}f \u{E9}\u{0}")
    #expect(scratch.contents(scratch.logPath) == "\(Self.stamp) a?b?c?[31m?d?e?f ??\n")
  }

  @Test func aPrintableMessageIsWrittenUnchanged() throws {
    let scratch = try Scratch()
    let message = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCXYZ[\\]^_`abcxyz{|}~"
    scratch.log().record(message)
    #expect(scratch.contents(scratch.logPath) == "\(Self.stamp) \(message)\n")
  }

  @Test func pastTheLimitTheLogRotatesToOneOlderFileAndKeepsWriting() throws {
    let scratch = try Scratch()
    let log = scratch.log()
    let message = String(repeating: "x", count: 65_536 - Self.lineOverhead)
    for _ in 0..<8 {
      log.record(message)
    }
    #expect(scratch.size(scratch.logPath) == 524_288)
    #expect(!scratch.exists(scratch.rotatedPath))
    log.record(message)
    #expect(scratch.size(scratch.logPath) == 589_824)
    #expect(!scratch.exists(scratch.rotatedPath))
    log.record("after rotation")
    #expect(scratch.size(scratch.rotatedPath) == 589_824)
    #expect(scratch.contents(scratch.logPath) == "\(Self.stamp) after rotation\n")
    #expect(scratch.mode(scratch.logPath) == 0o644)
    #expect(scratch.mode(scratch.rotatedPath) == 0o644)
    log.record("next")
    #expect(scratch.contents(scratch.logPath) == "\(Self.stamp) after rotation\n\(Self.stamp) next\n")
  }

  @Test func aSecondRotationReplacesTheOlderFile() throws {
    let scratch = try Scratch()
    let log = scratch.log()
    try scratch.makeFolder()
    try Data("older".utf8).write(to: URL(fileURLWithPath: scratch.rotatedPath))
    let message = String(repeating: "y", count: 65_536 - Self.lineOverhead)
    for _ in 0..<9 {
      log.record(message)
    }
    #expect(scratch.contents(scratch.rotatedPath) == "older")
    log.record("fresh")
    #expect(scratch.size(scratch.rotatedPath) == 589_824)
    #expect(scratch.contents(scratch.logPath) == "\(Self.stamp) fresh\n")
  }

  @Test func anExistingLogWithAnotherModeIsMadeWorldReadableAgain() throws {
    let scratch = try Scratch()
    try scratch.makeFolder()
    try Data("earlier\n".utf8).write(to: URL(fileURLWithPath: scratch.logPath))
    #expect(chmod(scratch.logPath, 0o600) == 0)
    scratch.log().record("reconcile none")
    #expect(scratch.mode(scratch.logPath) == 0o644)
    #expect(scratch.contents(scratch.logPath) == "earlier\n\(Self.stamp) reconcile none\n")
  }

  @Test(arguments: [false, true])
  func aSymlinkedFolderGetsNoLog(trailingSlash: Bool) throws {
    let scratch = try Scratch()
    try FileManager.default.createDirectory(atPath: scratch.elsewhere, withIntermediateDirectories: false)
    #expect(symlink(scratch.elsewhere, scratch.folder.path) == 0)
    let directory = URL(fileURLWithPath: scratch.folder.path, isDirectory: trailingSlash)
    HelperLog(directory: directory, requiredOwner: getuid()).record("set owned prior=0")
    #expect(!scratch.exists(scratch.elsewhere + "/helper.log"))
  }

  @Test func aFolderOwnedBySomeoneElseGetsNoLog() throws {
    let scratch = try Scratch()
    try scratch.makeFolder()
    scratch.log(owner: getuid() + 1).record("set owned prior=0")
    #expect(!scratch.exists(scratch.logPath))
    scratch.log().record("set owned prior=0")
    #expect(scratch.exists(scratch.logPath))
  }

  @Test(arguments: [0o775, 0o757, 0o777, 0o722])
  func aFolderThatGroupOrOthersCanWriteGetsNoLog(mode: Int) throws {
    let scratch = try Scratch()
    try scratch.makeFolder(mode: mode)
    scratch.log().record("set owned prior=0")
    #expect(!scratch.exists(scratch.logPath))
  }

  @Test func aSymlinkAtTheLogPathIsNeverFollowed() throws {
    let scratch = try Scratch()
    try scratch.makeFolder()
    try Data("untouched".utf8).write(to: URL(fileURLWithPath: scratch.elsewhere))
    #expect(symlink(scratch.elsewhere, scratch.logPath) == 0)
    scratch.log().record("set owned prior=0")
    #expect(scratch.contents(scratch.elsewhere) == "untouched")
  }

  @Test func aPipeAtTheLogPathNeverBlocksTheHelper() async throws {
    let scratch = try Scratch()
    try scratch.makeFolder()
    #expect(mkfifo(scratch.logPath, 0o644) == 0)
    let log = scratch.log()
    let written = await OffPool.bounded(seconds: 5) { () -> Bool in
      log.record("set owned prior=0")
      return true
    }
    #expect(written == true)
  }

  @Test func aPipeWithAReaderAtTheLogPathGetsNoLine() async throws {
    let scratch = try Scratch()
    try scratch.makeFolder()
    #expect(mkfifo(scratch.logPath, 0o644) == 0)
    let pipe = open(scratch.logPath, O_RDONLY | O_NONBLOCK)
    #expect(pipe >= 0)
    defer { close(pipe) }
    let log = scratch.log()
    let written = await OffPool.bounded(seconds: 5) { () -> Bool in
      log.record("set owned prior=0")
      return true
    }
    #expect(written == true)
    var buffer = [UInt8](repeating: 0, count: 64)
    #expect(buffer.withUnsafeMutableBytes { Darwin.read(pipe, $0.baseAddress, $0.count) } <= 0)
  }

  @Test func theMachinesLinesReachTheFile() throws {
    let scratch = try Scratch()
    let fake = FakeHelperSystem()
    let machine = HelperMachine(system: fake, record: fake, log: scratch.log(), clock: fake)
    machine.launched()
    #expect(machine.set().code == .owned)
    #expect(machine.clear().code == .cleared)
    #expect(
      scratch.contents(scratch.logPath)
        == [
          "reconcile none", "set owned prior=0 floor=10 ceiling=60", "release reason=clear sleepDisabled=0 edge=done",
        ].map { "\(Self.stamp) \($0)\n" }.joined())
  }
}
