import Foundation
import OvertimeHelperCore
import Testing

struct HelperRecordStoreTests {
  static let owning = HelperRecord(owns: true, prior: false, at: 1_234.5)
  static let released = HelperRecord(owns: false, prior: false, at: 2_000)

  final class Scratch {
    let root: URL

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "overtime-helper-record-\(UUID().uuidString)", isDirectory: false)
      try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    deinit {
      try? FileManager.default.removeItem(at: root)
    }

    var folder: URL { root.appendingPathComponent("Overtime Dev", isDirectory: false) }
    var recordPath: String { folder.path + "/helper-state.json" }
    var temporaryPath: String { recordPath + ".tmp" }
    var elsewhere: String { root.path + "/elsewhere" }

    func store(owner: uid_t = getuid()) -> HelperRecordStore {
      HelperRecordStore(directory: folder, requiredOwner: owner)
    }

    func makeFolder(mode: Int = 0o700) throws {
      try FileManager.default.createDirectory(
        at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: mode])
      #expect(chmod(folder.path, mode_t(mode)) == 0)
    }

    func plant(_ text: String) throws {
      try Data(text.utf8).write(to: URL(fileURLWithPath: recordPath))
    }

    func mode(_ path: String) -> Int? {
      var info = stat()
      guard lstat(path, &info) == 0 else { return nil }
      return Int(info.st_mode & 0o7777)
    }

    func exists(_ path: String) -> Bool {
      var info = stat()
      return lstat(path, &info) == 0
    }

    func contents(_ path: String) -> String? {
      FileManager.default.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) }
    }
  }

  @Test func aRecordRoundTripsThroughAPrivateFileInAPrivateFolder() throws {
    let scratch = try Scratch()
    let store = scratch.store()
    #expect(store.read() == .missing)
    #expect(store.write(Self.owning))
    #expect(store.read() == .loaded(Self.owning))
    #expect(scratch.mode(scratch.folder.path) == 0o700)
    #expect(scratch.mode(scratch.recordPath) == 0o600)
    #expect(!scratch.exists(scratch.temporaryPath))
    #expect(scratch.contents(scratch.recordPath) == #"{"at":1234.5,"owns":true,"prior":false}"#)
  }

  @Test func theFileNameAndTheReadLimitAreTheDocumentedOnes() {
    #expect(HelperRecordStore.fileName == "helper-state.json")
    #expect(HelperRecordStore.maxBytes == 4_096)
  }

  @Test func aLaterWriteReplacesTheRecord() throws {
    let scratch = try Scratch()
    let store = scratch.store()
    #expect(store.write(Self.owning))
    #expect(store.write(Self.released))
    #expect(store.read() == .loaded(Self.released))
    #expect(store.write(HelperRecord(owns: false, prior: true, at: 3)))
    #expect(store.read() == .loaded(HelperRecord(owns: false, prior: true, at: 3)))
    #expect(scratch.mode(scratch.recordPath) == 0o600)
  }

  @Test func aRecordThatCannotBeEncodedIsRefusedAndThePreviousOneStays() throws {
    let scratch = try Scratch()
    let store = scratch.store()
    #expect(store.write(Self.owning))
    #expect(!store.write(HelperRecord(owns: false, prior: false, at: .nan)))
    #expect(store.read() == .loaded(Self.owning))
    #expect(!scratch.exists(scratch.temporaryPath))
  }

  @Test func aFolderThatAlreadyExistsWithTheRightShapeIsUsedAsItIs() throws {
    let scratch = try Scratch()
    try scratch.makeFolder(mode: 0o755)
    let store = scratch.store()
    #expect(store.write(Self.owning))
    #expect(store.read() == .loaded(Self.owning))
    #expect(scratch.mode(scratch.folder.path) == 0o755)
  }

  @Test func aMissingFileOrAMissingFolderReadsAsMissing() throws {
    let scratch = try Scratch()
    #expect(scratch.store().read() == .missing)
    #expect(!scratch.exists(scratch.folder.path))
    try scratch.makeFolder()
    #expect(scratch.store().read() == .missing)
  }

  @Test(arguments: [false, true])
  func aSymlinkedFolderIsRefused(trailingSlash: Bool) throws {
    let scratch = try Scratch()
    try FileManager.default.createDirectory(atPath: scratch.elsewhere, withIntermediateDirectories: false)
    #expect(chmod(scratch.elsewhere, 0o700) == 0)
    #expect(symlink(scratch.elsewhere, scratch.folder.path) == 0)
    let planted = #"{"at":1,"owns":true,"prior":false}"#
    try Data(planted.utf8).write(to: URL(fileURLWithPath: scratch.elsewhere + "/helper-state.json"))
    let directory = URL(fileURLWithPath: scratch.folder.path, isDirectory: trailingSlash)
    let store = HelperRecordStore(directory: directory, requiredOwner: getuid())
    #expect(store.read() == .unreadable)
    #expect(!store.write(Self.released))
    #expect(scratch.contents(scratch.elsewhere + "/helper-state.json") == planted)
    #expect(!scratch.exists(scratch.elsewhere + "/helper-state.json.tmp"))
  }

  @Test func aFolderOwnedBySomeoneElseIsRefused() throws {
    let scratch = try Scratch()
    #expect(scratch.store().write(Self.owning))
    let foreign = scratch.store(owner: getuid() + 1)
    #expect(foreign.read() == .unreadable)
    #expect(!foreign.write(Self.released))
    #expect(scratch.store().read() == .loaded(Self.owning))
  }

  @Test func aFolderThatWouldBeCreatedForSomeoneElseIsRefused() throws {
    let scratch = try Scratch()
    let foreign = scratch.store(owner: getuid() + 1)
    #expect(foreign.read() == .missing)
    #expect(!foreign.write(Self.owning))
    #expect(!scratch.exists(scratch.recordPath))
    #expect(!scratch.exists(scratch.temporaryPath))
  }

  @Test(arguments: [0o770, 0o720, 0o707, 0o702, 0o777])
  func aFolderThatGroupOrOthersCanWriteIsRefused(mode: Int) throws {
    let scratch = try Scratch()
    #expect(scratch.store().write(Self.owning))
    #expect(chmod(scratch.folder.path, mode_t(mode)) == 0)
    let store = scratch.store()
    #expect(store.read() == .unreadable)
    #expect(!store.write(Self.released))
    #expect(!scratch.exists(scratch.temporaryPath))
    #expect(chmod(scratch.folder.path, 0o700) == 0)
    #expect(store.read() == .loaded(Self.owning))
  }

  @Test(arguments: [0o750, 0o705, 0o755, 0o500])
  func aFolderThatOnlyItsOwnerCanWriteIsReadable(mode: Int) throws {
    let scratch = try Scratch()
    #expect(scratch.store().write(Self.owning))
    #expect(chmod(scratch.folder.path, mode_t(mode)) == 0)
    #expect(scratch.store().read() == .loaded(Self.owning))
    #expect(chmod(scratch.folder.path, 0o700) == 0)
  }

  @Test func aFolderThatIsARegularFileIsRefused() throws {
    let scratch = try Scratch()
    try Data("x".utf8).write(to: scratch.folder)
    let store = scratch.store()
    #expect(store.read() == .unreadable)
    #expect(!store.write(Self.owning))
    #expect(scratch.contents(scratch.folder.path) == "x")
  }

  @Test func aFolderThatCannotBeWrittenRefusesTheWriteAndKeepsThePreviousRecord() throws {
    let scratch = try Scratch()
    let store = scratch.store()
    #expect(store.write(Self.owning))
    #expect(chmod(scratch.folder.path, 0o500) == 0)
    #expect(!store.write(Self.released))
    #expect(store.read() == .loaded(Self.owning))
    #expect(chmod(scratch.folder.path, 0o700) == 0)
  }

  @Test func aSymlinkAtTheRecordPathIsNeverFollowed() throws {
    let scratch = try Scratch()
    try scratch.makeFolder()
    let planted = #"{"at":1,"owns":false,"prior":false}"#
    try Data(planted.utf8).write(to: URL(fileURLWithPath: scratch.elsewhere))
    #expect(symlink(scratch.elsewhere, scratch.recordPath) == 0)
    let store = scratch.store()
    #expect(store.read() == .unreadable)
    #expect(store.write(Self.owning))
    #expect(scratch.contents(scratch.elsewhere) == planted)
    #expect(store.read() == .loaded(Self.owning))
    #expect(scratch.mode(scratch.recordPath) == 0o600)
  }

  @Test func aSymlinkAtTheTemporaryPathRefusesTheWriteAndKeepsThePreviousRecord() throws {
    let scratch = try Scratch()
    let store = scratch.store()
    #expect(store.write(Self.owning))
    try Data("untouched".utf8).write(to: URL(fileURLWithPath: scratch.elsewhere))
    #expect(symlink(scratch.elsewhere, scratch.temporaryPath) == 0)
    #expect(!store.write(Self.released))
    #expect(scratch.contents(scratch.elsewhere) == "untouched")
    #expect(store.read() == .loaded(Self.owning))
  }

  @Test func aStaleTemporaryFileIsOverwritten() throws {
    let scratch = try Scratch()
    let store = scratch.store()
    #expect(store.write(Self.owning))
    try Data(String(repeating: "z", count: 9_000).utf8).write(to: URL(fileURLWithPath: scratch.temporaryPath))
    #expect(chmod(scratch.temporaryPath, 0o644) == 0)
    #expect(store.write(Self.released))
    #expect(store.read() == .loaded(Self.released))
    #expect(scratch.mode(scratch.recordPath) == 0o600)
    #expect(!scratch.exists(scratch.temporaryPath))
  }

  @Test func aDirectoryAtTheRecordPathIsUnreadable() throws {
    let scratch = try Scratch()
    try scratch.makeFolder()
    try FileManager.default.createDirectory(atPath: scratch.recordPath, withIntermediateDirectories: false)
    let store = scratch.store()
    #expect(store.read() == .unreadable)
    #expect(!store.write(Self.owning))
    #expect(!scratch.exists(scratch.temporaryPath))
    #expect(store.read() == .unreadable)
  }

  @Test func aPipeAtTheRecordPathIsUnreadableAndNeverBlocks() async throws {
    let scratch = try Scratch()
    try scratch.makeFolder()
    #expect(mkfifo(scratch.recordPath, 0o600) == 0)
    let store = scratch.store()
    #expect(await OffPool.bounded(seconds: 5) { store.read() } == .unreadable)
  }

  @Test func aPipeWithAWriterAtTheRecordPathIsNeverReadAsARecord() async throws {
    let scratch = try Scratch()
    try scratch.makeFolder()
    #expect(mkfifo(scratch.recordPath, 0o600) == 0)
    let keeper = open(scratch.recordPath, O_RDONLY | O_NONBLOCK)
    #expect(keeper >= 0)
    defer { close(keeper) }
    let writer = open(scratch.recordPath, O_WRONLY | O_NONBLOCK)
    #expect(writer >= 0)
    let planted = Array(#"{"at":1,"owns":false,"prior":false}"#.utf8)
    #expect(planted.withUnsafeBytes { Darwin.write(writer, $0.baseAddress, $0.count) } == planted.count)
    #expect(close(writer) == 0)
    let store = scratch.store()
    #expect(await OffPool.bounded(seconds: 5) { store.read() } == .unreadable)
  }

  @Test func aPipeWithAReaderAtTheTemporaryPathGetsNoRecord() async throws {
    let scratch = try Scratch()
    let store = scratch.store()
    #expect(store.write(Self.owning))
    #expect(mkfifo(scratch.temporaryPath, 0o600) == 0)
    let pipe = open(scratch.temporaryPath, O_RDONLY | O_NONBLOCK)
    #expect(pipe >= 0)
    defer { close(pipe) }
    #expect(await OffPool.bounded(seconds: 5) { store.write(Self.released) } == false)
    var buffer = [UInt8](repeating: 0, count: 64)
    #expect(buffer.withUnsafeMutableBytes { Darwin.read(pipe, $0.baseAddress, $0.count) } <= 0)
    #expect(store.read() == .loaded(Self.owning))
  }

  @Test func aPipeAtTheTemporaryPathRefusesTheWriteAndNeverBlocks() async throws {
    let scratch = try Scratch()
    let store = scratch.store()
    #expect(store.write(Self.owning))
    #expect(mkfifo(scratch.temporaryPath, 0o600) == 0)
    #expect(await OffPool.bounded(seconds: 5) { store.write(Self.released) } == false)
    #expect(store.read() == .loaded(Self.owning))
  }

  @Test(arguments: [(4_096, true), (4_097, false), (5_120, false)])
  func aRecordLargerThanFourKibibytesIsUnreadable(bytes: Int, loads: Bool) throws {
    let scratch = try Scratch()
    try scratch.makeFolder()
    let body = #"{"at":7,"owns":true,"prior":false}"#
    try scratch.plant(body + String(repeating: " ", count: bytes - body.utf8.count))
    #expect(scratch.store().read() == (loads ? .loaded(HelperRecord(owns: true, prior: false, at: 7)) : .unreadable))
  }

  @Test(arguments: [
    "", "{", "not json", "[]", "null", #"{"owns":true,"prior":false}"#, #"{"at":1,"prior":false}"#,
    #"{"at":1,"owns":true}"#, #"{"at":1,"owns":1,"prior":false}"#, #"{"at":"1","owns":true,"prior":false}"#,
    #"{"at":1,"owns":"true","prior":false}"#,
  ])
  func aRecordThatDoesNotDecodeIsUnreadable(text: String) throws {
    let scratch = try Scratch()
    try scratch.makeFolder()
    try scratch.plant(text)
    #expect(scratch.store().read() == .unreadable)
  }

  @Test func aRecordWithAnExtraKeyStillLoads() throws {
    let scratch = try Scratch()
    try scratch.makeFolder()
    try scratch.plant(#"{"at":1,"owns":true,"prior":true,"later":"field"}"#)
    #expect(scratch.store().read() == .loaded(HelperRecord(owns: true, prior: true, at: 1)))
  }

  @Test func theMachineKeepsItsOwnershipInTheFileBeforeItSetsSleepDisabled() throws {
    let scratch = try Scratch()
    let store = scratch.store()
    let fake = FakeHelperSystem()
    let machine = HelperMachine(system: fake, record: store, log: fake, clock: fake)
    fake.advance(seconds: 42)
    #expect(machine.set().code == .owned)
    #expect(store.read() == .loaded(HelperRecord(owns: true, prior: false, at: FakeHelperSystem.startSeconds + 42)))
    #expect(machine.clear().code == .cleared)
    #expect(store.read() == .loaded(HelperRecord(owns: false, prior: false, at: FakeHelperSystem.startSeconds + 42)))
  }

  @Test func aRefusedFolderMakesTheMachineRefuseTheSetWithoutRunningPmset() throws {
    let scratch = try Scratch()
    try scratch.makeFolder(mode: 0o770)
    let fake = FakeHelperSystem()
    let machine = HelperMachine(system: fake, record: scratch.store(), log: fake, clock: fake)
    #expect(machine.set() == HelperReply(code: .refused, message: "recordWrite"))
    #expect(fake.pmsetWrites.isEmpty)
    #expect(fake.sleepDisabled == false)
    #expect(!scratch.exists(scratch.recordPath))
  }

  @Test func anOwningRecordLeftInTheFileIsReleasedAtTheNextLaunch() throws {
    let scratch = try Scratch()
    let store = scratch.store()
    #expect(store.write(Self.owning))
    let fake = FakeHelperSystem(sleepDisabled: true)
    let machine = HelperMachine(system: fake, record: store, log: fake, clock: fake)
    machine.launched()
    #expect(fake.logLines.first == "reconcile owned")
    #expect(fake.pmsetWrites == [false])
    #expect(fake.edgeCount == 1)
    #expect(store.read() == .loaded(HelperRecord(owns: false, prior: false, at: FakeHelperSystem.startSeconds)))
  }

  @Test func aCorruptRecordInTheFileIsReconciledAsOwnedAtLaunch() throws {
    let scratch = try Scratch()
    try scratch.makeFolder()
    try scratch.plant(#"{"owns":fal"#)
    let store = scratch.store()
    let fake = FakeHelperSystem(sleepDisabled: true)
    let machine = HelperMachine(system: fake, record: store, log: fake, clock: fake)
    machine.launched()
    #expect(fake.logLines.first == "reconcile ambiguous")
    #expect(fake.pmsetWrites == [false])
    #expect(store.read() == .loaded(HelperRecord(owns: false, prior: false, at: FakeHelperSystem.startSeconds)))
  }

  @Test func aMissingRecordFileReleasesNothingAtLaunchAndIsCreated() throws {
    let scratch = try Scratch()
    let store = scratch.store()
    let fake = FakeHelperSystem(sleepDisabled: true)
    let machine = HelperMachine(system: fake, record: store, log: fake, clock: fake)
    machine.launched()
    #expect(fake.logLines == ["reconcile none"])
    #expect(fake.pmsetWrites.isEmpty)
    #expect(fake.edgeCount == 0)
    #expect(store.read() == .loaded(HelperRecord(owns: false, prior: false, at: FakeHelperSystem.startSeconds)))
  }
}
