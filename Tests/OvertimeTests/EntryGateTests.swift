import Foundation
import OvertimeAppSupport
import OvertimeSystem
import Testing

@testable import Overtime

@MainActor
struct EntryGateTests {
  @Test func aSupportFolderThatCannotBeCreatedIsReportedAsStorageAndLogged() throws {
    let folder = try TestFolder()
    let blocker = folder.url.appendingPathComponent("root")
    try Data("a file where the root folder should be".utf8).write(to: blocker)
    var logged: [String] = []
    let mode = Entry.gate(
      environment: ["OVERTIME_HOME": blocker.path(percentEncoded: false)], homeDirectory: folder.path,
      logError: { logged.append($0) })
    #expect(mode == .some(.blocked(.storageUnavailable)))
    #expect(logged.count == 1)
    #expect(logged.first?.hasPrefix("ERROR support directories failed reason=") == true)
    #expect(logged.first?.count ?? 0 > "ERROR support directories failed reason=".count)
    let presentation = StatusPresentation.derive(
      snapshot: nil, hostFailure: .storageUnavailable, engineUnresponsive: false)
    #expect(!presentation.reason.contains("already running"))
  }
}
