import Foundation
import OvertimeAppSupport
import OvertimeSystem
import Testing
import os

final class FakeLoginItemService: LoginItemService {
  struct FakeError: Error, CustomStringConvertible {
    var description: String { "Operation not permitted" }
  }

  private struct State {
    var status: LoginItemStatus
    var calls: [String] = []
    var failRegister = false
    var statusAfterFailure: LoginItemStatus?
  }

  private let state: OSAllocatedUnfairLock<State>

  init(status: LoginItemStatus = .notRegistered) {
    state = OSAllocatedUnfairLock(initialState: State(status: status))
  }

  var status: LoginItemStatus {
    state.withLock { $0.status }
  }

  var calls: [String] {
    state.withLock { $0.calls }
  }

  func setStatus(_ status: LoginItemStatus) {
    state.withLock { $0.status = status }
  }

  func failRegister(leaving status: LoginItemStatus) {
    state.withLock {
      $0.failRegister = true
      $0.statusAfterFailure = status
    }
  }

  func register() throws {
    try state.withLock { state in
      state.calls.append("register")
      if state.failRegister {
        state.status = state.statusAfterFailure ?? state.status
        throw FakeError()
      }
      state.status = .enabled
    }
  }

  func unregister() throws {
    state.withLock { state in
      state.calls.append("unregister")
      state.status = .notRegistered
    }
  }

  func openSystemSettings() {
    state.withLock { $0.calls.append("openSystemSettings") }
  }
}

struct LoginItemServiceTests {
  static let approval = "Needs your approval in System Settings > General > Login Items."
  static let failure =
    "Couldn't change the login item. Try again, or add Overtime in System Settings > General > Login Items."

  func supportReady(_ temp: TempDirectory) throws -> URL {
    let paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path], homeDirectory: "/Users/dev")
    try paths.createDirectories()
    return paths.loginItemRecord
  }

  @Test func theStatusMapsToTheSwitchAndTheCaption() {
    #expect(LoginItemPanel(service: FakeLoginItemService(status: .enabled)).isOn)
    #expect(LoginItemPanel(service: FakeLoginItemService(status: .enabled)).caption == nil)
    let approval = LoginItemPanel(service: FakeLoginItemService(status: .requiresApproval))
    #expect(approval.isOn)
    #expect(approval.caption == LoginItemCaption(text: Self.approval, tone: .warning))
    #expect(approval.caption?.actionLabel == "Open Login Items")
    for status in [LoginItemStatus.notRegistered, .notFound] {
      let panel = LoginItemPanel(service: FakeLoginItemService(status: status))
      #expect(!panel.isOn)
      #expect(panel.caption == nil)
    }
  }

  @Test func theCopyMatchesTheSpec() {
    #expect(LoginItemCaption.toggleLabel == "Launch at login")
    #expect(LoginItemCaption.openLabel == "Open Login Items")
    #expect(LoginItemCaption.for(status: .requiresApproval, lastError: nil)?.text == Self.approval)
    #expect(LoginItemCaption.for(status: .enabled, lastError: "x")?.text == Self.failure)
    #expect(LoginItemCaption.for(status: .notRegistered, lastError: "x")?.tone == .error)
  }

  @Test func aFirstRunRegistersWheneverNoRecordExists() throws {
    #expect(FirstRunLogin.shouldRegister(record: .missing))
    let offered = LoginItemRecord(offered: true, at: Date(timeIntervalSince1970: 0))
    #expect(!FirstRunLogin.shouldRegister(record: .recorded(offered)))
    #expect(!FirstRunLogin.shouldRegister(record: .unreadable))
    let temp = try TempDirectory()
    let url = try supportReady(temp)
    let service = FakeLoginItemService(status: .notRegistered)
    #expect(FirstRunLogin.apply(service: service, recordURL: url, now: Date()))
    #expect(service.calls == ["register"])
    guard case .recorded(let record) = LoginItemRecord.read(at: url) else {
      Issue.record("expected a login item record")
      return
    }
    #expect(record.offered)
    #expect(!FirstRunLogin.apply(service: service, recordURL: url, now: Date()))
    #expect(service.calls == ["register"])
  }

  @Test func theFirstAutomaticRegistrationHappensOnceAndRespectsALaterOff() throws {
    let temp = try TempDirectory()
    let url = try supportReady(temp)
    let service = FakeLoginItemService(status: .notRegistered)
    #expect(FirstRunLogin.apply(service: service, recordURL: url, now: Date()))
    #expect(service.calls == ["register"])
    #expect(service.status == .enabled)
    guard case .recorded(let record) = LoginItemRecord.read(at: url) else {
      Issue.record("expected a login item record")
      return
    }
    #expect(record.offered)
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    service.setStatus(.notRegistered)
    #expect(!FirstRunLogin.apply(service: service, recordURL: url, now: Date()))
    #expect(service.calls == ["register"])
  }

  @Test func aFailedFirstRegistrationIsLoggedAndStillRecordedAsOffered() throws {
    let temp = try TempDirectory()
    let url = try supportReady(temp)
    let service = FakeLoginItemService()
    service.failRegister(leaving: .notRegistered)
    let logged = OSAllocatedUnfairLock<[String]>(initialState: [])
    #expect(
      !FirstRunLogin.apply(service: service, recordURL: url, now: Date()) { message in
        logged.withLock { $0.append(message) }
      })
    #expect(logged.withLock { $0 } == ["Operation not permitted"])
    #expect(LoginItemRecord.read(at: url) != .missing)
  }

  @Test func aThrowingRegisterShowsTheErrorCaptionAndTheSwitchFollowsTheService() {
    let service = FakeLoginItemService(status: .notRegistered)
    service.failRegister(leaving: .notRegistered)
    var panel = LoginItemPanel(service: service)
    var logged: [String] = []
    panel.setEnabled(true) { logged.append($0) }
    #expect(panel.caption == LoginItemCaption(text: Self.failure, tone: .error))
    #expect(panel.isOn == false)
    #expect(panel.isOn == (service.status == .enabled || service.status == .requiresApproval))
    #expect(logged == ["Operation not permitted"])
  }

  @Test func aSuccessfulToggleClearsAnEarlierError() {
    let service = FakeLoginItemService(status: .notRegistered)
    service.failRegister(leaving: .notRegistered)
    var panel = LoginItemPanel(service: service)
    panel.setEnabled(true) { _ in }
    #expect(panel.caption?.tone == .error)
    let healthy = FakeLoginItemService(status: .notRegistered)
    panel = LoginItemPanel(service: healthy)
    panel.setEnabled(true) { _ in }
    #expect(panel.caption == nil)
    #expect(panel.isOn)
  }

  @Test func togglingOnRegistersOnceAndOffUnregistersOnce() {
    let service = FakeLoginItemService(status: .notRegistered)
    var panel = LoginItemPanel(service: service)
    panel.setEnabled(true) { _ in }
    panel.setEnabled(true) { _ in }
    #expect(service.calls == ["register"])
    panel.setEnabled(false) { _ in }
    panel.setEnabled(false) { _ in }
    #expect(service.calls == ["register", "unregister"])
    #expect(!panel.isOn)
  }

  @Test func openLoginItemsOpensSystemSettings() {
    let service = FakeLoginItemService()
    LoginItemPanel(service: service).openSystemSettings()
    #expect(service.calls == ["openSystemSettings"])
  }

  @Test func aRecordPlantedAsASymlinkIsUnreadableAndNotFollowed() throws {
    let temp = try TempDirectory()
    let url = try supportReady(temp)
    let target = temp.url.appendingPathComponent("elsewhere.json")
    try Data("{\"offered\": false, \"at\": \"2026-09-27T00:00:00Z\"}".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
    #expect(LoginItemRecord.read(at: url) == .unreadable)
  }

  @Test func anUnreadableRecordCountsAsOffered() throws {
    let temp = try TempDirectory()
    let url = try supportReady(temp)
    try Data("not json".utf8).write(to: url)
    #expect(LoginItemRecord.read(at: url) == .unreadable)
    let service = FakeLoginItemService()
    #expect(!FirstRunLogin.apply(service: service, recordURL: url, now: Date()))
    #expect(service.calls.isEmpty)
  }
}
