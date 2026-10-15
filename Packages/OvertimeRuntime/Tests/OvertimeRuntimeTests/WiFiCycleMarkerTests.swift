import Foundation
import OvertimeSystem
import Testing

struct WiFiCycleMarkerTests {
  struct Folder {
    let temp: TempDirectory
    let marker: WiFiCycleMarker

    init() throws {
      temp = try TempDirectory()
      marker = WiFiCycleMarker(url: temp.url.appendingPathComponent("wifi-cycle.json"))
    }

    var path: String {
      marker.url.path(percentEncoded: false)
    }

    func entries() -> [String] {
      ((try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? []).sorted()
    }

    func mode() -> mode_t? {
      var info = stat()
      return lstat(path, &info) == 0 ? info.st_mode & 0o777 : nil
    }

    func plant(_ text: String) throws {
      try Data(text.utf8).write(to: marker.url)
    }

    func keys() throws -> Set<String> {
      let data = try Data(contentsOf: marker.url)
      let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
      return Set(object.keys)
    }
  }

  static let started = Date(timeIntervalSince1970: 1_791_515_803.75)

  @Test func aWrittenMarkerReadsBackAsPresentInAPrivateFileWithNoTemporarySiblingLeft() throws {
    let folder = try Folder()
    #expect(folder.marker.write(interface: "en0", startedAt: Self.started))
    #expect(folder.marker.read() == .present(interface: "en0"))
    #expect(folder.mode() == 0o600)
    #expect(folder.entries() == ["wifi-cycle.json"])
  }

  @Test func theFileHoldsExactlyTheVersionTheInterfaceAndTheStartTime() throws {
    let folder = try Folder()
    #expect(folder.marker.write(interface: "en10", startedAt: Self.started))
    #expect(try folder.keys() == ["version", "interface", "startedAt"])
    let text = try String(contentsOf: folder.marker.url, encoding: .utf8)
    #expect(text == #"{"interface":"en10","startedAt":1791515803,"version":1}"#)
  }

  @Test func aSettledMarkerAddsOnlyTheSettledFlagAndReadsBackSettled() throws {
    let folder = try Folder()
    #expect(folder.marker.write(interface: "en10", startedAt: Self.started, settled: true))
    let text = try String(contentsOf: folder.marker.url, encoding: .utf8)
    #expect(text == #"{"interface":"en10","settled":true,"startedAt":1791515803,"version":1}"#)
    let reading = folder.marker.readWithStart()
    #expect(reading.state == .present(interface: "en10"))
    #expect(reading.settled)
    #expect(folder.mode() == 0o600)
    #expect(folder.entries() == ["wifi-cycle.json"])
  }

  @Test(arguments: [
    #"{"interface":"en0","startedAt":0,"version":1}"#,
    #"{"interface":"en0","settled":false,"startedAt":0,"version":1}"#,
  ])
  func aMarkerWithoutATrueSettledFlagReadsUnsettled(_ text: String) throws {
    let folder = try Folder()
    try folder.plant(text)
    let reading = folder.marker.readWithStart()
    #expect(reading.state == .present(interface: "en0"))
    #expect(!reading.settled)
  }

  @Test func aPlainWriteReadsBackUnsettled() throws {
    let folder = try Folder()
    #expect(folder.marker.write(interface: "en0", startedAt: Self.started))
    #expect(!folder.marker.readWithStart().settled)
  }

  @Test func aSecondWriteReplacesTheFirst() throws {
    let folder = try Folder()
    #expect(folder.marker.write(interface: "en0", startedAt: Self.started))
    #expect(folder.marker.write(interface: "en1", startedAt: Self.started.addingTimeInterval(60)))
    #expect(folder.marker.read() == .present(interface: "en1"))
    #expect(folder.mode() == 0o600)
    #expect(folder.entries() == ["wifi-cycle.json"])
  }

  @Test func removeLeavesNoMarkerAndRemovingAMissingMarkerCountsAsRemoved() throws {
    let folder = try Folder()
    #expect(folder.marker.write(interface: "en0", startedAt: Self.started))
    #expect(folder.marker.remove())
    #expect(folder.marker.read() == .absent)
    #expect(folder.entries().isEmpty)
    #expect(folder.marker.remove())
    #expect(folder.marker.read() == .absent)
  }

  @Test func aSymlinkToAValidMarkerIsNotFollowed() throws {
    let folder = try Folder()
    let target = WiFiCycleMarker(url: folder.temp.url.appendingPathComponent("elsewhere.json"))
    #expect(target.write(interface: "en0", startedAt: Self.started))
    try FileManager.default.createSymbolicLink(at: folder.marker.url, withDestinationURL: target.url)
    #expect(folder.marker.read() == .unreadable)
    #expect(folder.marker.remove())
    #expect(target.read() == .present(interface: "en0"))
  }

  @Test func aWriteOverASymlinkReplacesTheLinkAndNeverWritesThroughIt() throws {
    let folder = try Folder()
    let target = folder.temp.url.appendingPathComponent("elsewhere.json")
    try Data("untouched".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: folder.marker.url, withDestinationURL: target)
    #expect(folder.marker.write(interface: "en0", startedAt: Self.started))
    #expect(try String(contentsOf: target, encoding: .utf8) == "untouched")
    #expect(folder.marker.read() == .present(interface: "en0"))
    #expect(folder.mode() == 0o600)
  }

  @Test func aMarkerAtTheSizeCapIsReadAndOneByteMoreIsNot() throws {
    #expect(WiFiCycleMarker.maxBytes == 4096)
    let folder = try Folder()
    let valid = #"{"interface":"en0","startedAt":0,"version":1}"#
    try folder.plant(valid + String(repeating: " ", count: WiFiCycleMarker.maxBytes - valid.utf8.count))
    #expect(folder.marker.read() == .present(interface: "en0"))
    try folder.plant(valid + String(repeating: " ", count: WiFiCycleMarker.maxBytes + 1 - valid.utf8.count))
    #expect(folder.marker.read() == .unreadable)
  }

  static let unreadableContents: [String] = [
    "",
    "not a marker",
    #"{"interface":"en0","startedAt":0,"version":2}"#,
    #"{"interface":"utun1","startedAt":0,"version":1}"#,
    #"{"interface":"en0","version":1}"#,
    #"{"interface":"en0","startedAt":0.5,"version":1}"#,
    #"{"interface":"en0","settled":"yes","startedAt":0,"version":1}"#,
    #"["en0"]"#,
  ]

  @Test(arguments: unreadableContents) func contentsThatAreNotAVersionOneMarkerAreUnreadable(_ text: String) throws {
    let folder = try Folder()
    try folder.plant(text)
    #expect(folder.marker.read() == .unreadable)
  }

  @Test func aDirectoryOrAPipeAtTheMarkerPathIsUnreadable() throws {
    let folder = try Folder()
    try FileManager.default.createDirectory(at: folder.marker.url, withIntermediateDirectories: false)
    #expect(folder.marker.read() == .unreadable)
    #expect(!folder.marker.remove())
    let pipe = WiFiCycleMarker(url: folder.temp.url.appendingPathComponent("pipe.json"))
    #expect(mkfifo(pipe.url.path(percentEncoded: false), 0o600) == 0)
    #expect(pipe.read() == .unreadable)
  }

  @Test func aWriteThatCannotReplaceTheMarkerLeavesNoTemporaryFile() throws {
    let folder = try Folder()
    try FileManager.default.createDirectory(at: folder.marker.url, withIntermediateDirectories: false)
    #expect(!folder.marker.write(interface: "en0", startedAt: Self.started))
    #expect(folder.entries() == ["wifi-cycle.json"])
    #expect(folder.marker.read() == .unreadable)
  }

  @Test func aWriteIntoAFolderThatDoesNotExistFailsAndCreatesNothing() throws {
    let folder = try Folder()
    let missing = WiFiCycleMarker(url: folder.temp.url.appendingPathComponent("missing/wifi-cycle.json"))
    #expect(!missing.write(interface: "en0", startedAt: Self.started))
    #expect(missing.read() == .absent)
    #expect(folder.entries().isEmpty)
  }

  @Test(arguments: ["", "en", "utun1", "en0x"])
  func aWriteForAnythingButAWiFiInterfaceNameIsRefused(_ interface: String) throws {
    let folder = try Folder()
    #expect(!folder.marker.write(interface: interface, startedAt: Self.started))
    #expect(folder.entries().isEmpty)
  }

  @Test func aStartTimeThatCannotBeStoredRefusesTheWrite() throws {
    let folder = try Folder()
    #expect(!folder.marker.write(interface: "en0", startedAt: Date(timeIntervalSince1970: .infinity)))
    #expect(!folder.marker.write(interface: "en0", startedAt: Date(timeIntervalSince1970: 1e16)))
    #expect(folder.entries().isEmpty)
    #expect(folder.marker.write(interface: "en0", startedAt: Date(timeIntervalSince1970: -1)))
  }

  @Test func theMarkerLivesInTheSupportFolder() {
    let paths = Paths(
      supportDirectory: URL(fileURLWithPath: "/tmp/support", isDirectory: true),
      logsDirectory: URL(fileURLWithPath: "/tmp/logs", isDirectory: true))
    #expect(paths.wifiCycleMarker.path(percentEncoded: false) == "/tmp/support/wifi-cycle.json")
  }
}
