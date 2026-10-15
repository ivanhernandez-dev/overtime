import Foundation
import OvertimeCore
import OvertimeEngine
import OvertimeHelperClient
import OvertimeHelperCore
import Testing
import os

@testable import OvertimeAppSupport

final class FakeHelperInstaller: HelperInstallerService {
  struct FakeError: Error, CustomStringConvertible {
    var description: String { "Operation not permitted" }
  }

  private struct State {
    var status: HelperInstallerStatus
    var calls: [String] = []
    var statusReads = 0
    var failRegister = false
    var statusAfterFailure: HelperInstallerStatus?
    var failUnregister = false
    var statusAfterUnregisterFailure: HelperInstallerStatus?
    var hanging: Set<String> = []
    var hangsEnded = 0
  }

  private let state: OSAllocatedUnfairLock<State>
  private let gate = DispatchSemaphore(value: 0)

  init(status: HelperInstallerStatus = .notRegistered) {
    state = OSAllocatedUnfairLock(initialState: State(status: status))
  }

  var status: HelperInstallerStatus {
    let hangs = state.withLock { state -> Bool in
      state.statusReads += 1
      return state.hanging.contains("status")
    }
    hangIf(hangs)
    return state.withLock { $0.status }
  }

  func hang(_ calls: Set<String>) {
    state.withLock { $0.hanging = calls }
  }

  func releaseHangs() {
    state.withLock { $0.hanging = [] }
    for _ in 0..<16 { gate.signal() }
  }

  var hangsEnded: Int {
    state.withLock { $0.hangsEnded }
  }

  private func hangIf(_ hangs: Bool) {
    if hangs {
      _ = gate.wait(timeout: .now() + 10)
      state.withLock { $0.hangsEnded += 1 }
    }
  }

  private func hangs(_ call: String) -> Bool {
    state.withLock { $0.hanging.contains(call) }
  }

  var calls: [String] {
    state.withLock { $0.calls }
  }

  var statusReads: Int {
    state.withLock { $0.statusReads }
  }

  func setStatus(_ status: HelperInstallerStatus) {
    state.withLock { $0.status = status }
  }

  func failRegister(leaving status: HelperInstallerStatus) {
    state.withLock {
      $0.failRegister = true
      $0.statusAfterFailure = status
    }
  }

  func failUnregister(leaving status: HelperInstallerStatus? = nil) {
    state.withLock {
      $0.failUnregister = true
      $0.statusAfterUnregisterFailure = status
    }
  }

  func register() throws {
    state.withLock { $0.calls.append("register") }
    hangIf(hangs("register"))
    try state.withLock { state in
      if state.failRegister {
        state.status = state.statusAfterFailure ?? state.status
        throw FakeError()
      }
      state.status = .enabled
    }
  }

  func unregister() throws {
    state.withLock { $0.calls.append("unregister") }
    hangIf(hangs("unregister"))
    try state.withLock { state in
      if state.failUnregister {
        state.status = state.statusAfterUnregisterFailure ?? state.status
        throw FakeError()
      }
      state.status = .notRegistered
    }
  }

  func openSystemSettings() {
    state.withLock { $0.calls.append("openSystemSettings") }
    hangIf(hangs("openSystemSettings"))
  }
}

final class ScriptedStatusHelper: NSObject, NSXPCListenerDelegate, HelperXPCProtocol, @unchecked Sendable {
  enum Answer: Sendable {
    case status(HelperStatus)
    case garbage
    case silence
  }

  private struct Script: Sendable {
    var answers: [Answer]
    var versions: [Int] = []
    var sets = 0
  }

  let listener = NSXPCListener.anonymous()
  private let script: OSAllocatedUnfairLock<Script>
  private let held = OSAllocatedUnfairLock<[Any]>(uncheckedState: [])
  private let made = OSAllocatedUnfairLock(initialState: 0)

  init(_ answers: [Answer]) {
    script = OSAllocatedUnfairLock(initialState: Script(answers: answers))
    super.init()
    listener.setConnectionCodeSigningRequirement(OwnRequirement.string())
    listener.delegate = self
    listener.resume()
  }

  var versionsAsked: [Int] { script.withLock { $0.versions } }
  var sets: Int { script.withLock { $0.sets } }
  var connectionsMade: Int { made.withLock { $0 } }

  func port(timeoutSeconds: Double = HelperXPCClient.defaultTimeoutSeconds) -> XPCHelperPort {
    XPCHelperPort(
      client: HelperTestClient.make(
        to: listener, counting: made, requirement: OwnRequirement.string(), timeoutSeconds: timeoutSeconds))
  }

  func stop() {
    listener.invalidate()
  }

  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
    connection.exportedInterface = NSXPCInterface(with: HelperXPCProtocol.self)
    connection.exportedObject = self
    connection.resume()
    return true
  }

  func setSleepDisabled(_ enabled: Bool, reply: @escaping @Sendable (Int32, String) -> Void) {
    script.withLock { $0.sets += 1 }
    reply(HelperReplyCode.refused.rawValue, "scripted")
  }

  func status(appHelperVersion: Int, reply: @escaping @Sendable (Data) -> Void) {
    let answer = script.withLock { script -> Answer in
      script.versions.append(appHelperVersion)
      return script.answers.count > 1 ? script.answers.removeFirst() : (script.answers.first ?? .silence)
    }
    switch answer {
    case .status(let status):
      reply(status.encoded())
    case .garbage:
      reply(Data("not a status".utf8))
    case .silence:
      held.withLockUnchecked { $0.append(reply) }
    }
  }
}

final class HelperStateLog: Sendable {
  private let seen = OSAllocatedUnfairLock<[HelperMonitorState]>(initialState: [])

  var states: [HelperMonitorState] {
    seen.withLock { $0 }
  }

  func record(_ state: HelperMonitorState) {
    seen.withLock { $0.append(state) }
  }
}

struct HelperMonitorTests {
  static let ready = HelperFacts(installed: true, reachable: true, current: true, owns: false, sleepDisabled: false)
  static let notReady = HelperFacts(installed: true, reachable: false, current: false)
  static let notInstalled = HelperFacts(installed: false, reachable: false, current: false)
  static let current = ScriptedStatusHelper.Answer.status(
    HelperStatus(helperVersion: HelperIdentity.version, sleepDisabled: false))
  static let older = ScriptedStatusHelper.Answer.status(
    HelperStatus(helperVersion: HelperIdentity.version - 1, sleepDisabled: false, exiting: true))

  struct Scripted {
    let helper: ScriptedStatusHelper
    let installer = FakeHelperInstaller(status: .enabled)
    let host = ScriptedSnapshotHost()
    let log = HelperStateLog()
    let monitor: HelperMonitor

    init(_ answers: [ScriptedStatusHelper.Answer]) {
      helper = ScriptedStatusHelper(answers)
      let log = log
      monitor = HelperMonitor(installer: installer, port: helper.port(), onChange: { log.record($0) })
      monitor.start(host: host)
    }

    func shown(engaged: Bool = false) -> HelperUIState {
      HelperStatusPresentation.derive(monitor.state, engaged: engaged)
    }

    func firstRead() async -> Bool {
      await OffPool.eventually(seconds: HelperXPCClient.defaultTimeoutSeconds * 3) { !host.helperUpdates.isEmpty }
    }

    func finish() {
      monitor.stop()
      helper.stop()
    }
  }

  static let monitorSource = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Sources/OvertimeAppSupport/HelperMonitor.swift")

  final class Logged: Sendable {
    private let decisions = OSAllocatedUnfairLock<[Decision]>(initialState: [])

    var all: [Decision] { decisions.withLock { $0 } }

    func append(_ decision: Decision) {
      decisions.withLock { $0.append(decision) }
    }
  }

  struct Fixture {
    let helper: InProcessHelper
    let port: XPCHelperPort
    let installer: FakeHelperInstaller
    let host = ScriptedSnapshotHost()
    let logged = Logged()
    let monitor: HelperMonitor

    init(
      status: HelperInstallerStatus = .enabled, version: Int = HelperIdentity.version,
      statusSeconds: Double = HelperMonitor.statusBoundSeconds, actionSeconds: Double = HelperMonitor.actionBoundSeconds
    ) {
      helper = InProcessHelper(version: version)
      port = XPCHelperPort(client: helper.client())
      installer = FakeHelperInstaller(status: status)
      let logged = logged
      monitor = HelperMonitor(
        installer: installer, port: port, statusBoundSeconds: statusSeconds, actionBoundSeconds: actionSeconds,
        log: { logged.append($0) })
    }

    func started() async -> Bool {
      monitor.start(host: host)
      let installer = installer
      return await OffPool.eventually { installer.statusReads >= 1 && !host.helperUpdates.isEmpty }
    }
  }

  static func lid(_ closed: Bool?) -> EngineSnapshot {
    EngineSnapshot(lidClosed: closed)
  }

  @Test func withTheHelperEnabledAndCurrentARefreshMakesOneStatusCallAndSendsReadyFactsOnce() async {
    let fixture = Fixture()
    defer { fixture.helper.stop() }
    #expect(fixture.monitor.state == HelperMonitorState())
    #expect(fixture.helper.connectionsMade == 0)
    #expect(await fixture.started())
    #expect(fixture.helper.statusCalls == 1)
    #expect(fixture.helper.connectionsMade == 1)
    #expect(fixture.helper.fake.pmsetWrites.isEmpty)
    #expect(fixture.host.helperUpdates == [Self.ready])
    #expect(fixture.installer.calls.isEmpty)

    let state = fixture.monitor.state
    #expect(state.installer == .enabled)
    #expect(state.reachability == .reachable)
    #expect(state.status?.helperVersion == HelperIdentity.version)
    #expect(state.status?.engaged == false)
    #expect(state.staleAttempts == 0)
    #expect(fixture.monitor.facts == Self.ready)

    let shown = HelperStatusPresentation.derive(state, engaged: false)
    #expect(shown == .onStandingBy)
    #expect(shown.title == "On")
    #expect(shown.caption == "It turns system sleep off only while Claude works with the lid closed.")
  }

  @Test func aRefreshThatReadsTheSameAnswerAsksAgainAndSendsNothingNew() async {
    let fixture = Fixture()
    defer { fixture.helper.stop() }
    #expect(await fixture.started())
    let first = fixture.monitor.state
    #expect(await fixture.monitor.refresh() == first)
    #expect(await fixture.monitor.refresh() == first)
    #expect(fixture.helper.statusCalls == 3)
    #expect(fixture.helper.connectionsMade == 1)
    #expect(fixture.host.helperUpdates == [Self.ready])
  }

  @Test func factsThatChangeAreSentAgain() async {
    let fixture = Fixture()
    defer { fixture.helper.stop() }
    #expect(await fixture.started())
    fixture.helper.fake.setSleepDisabled(true)
    await fixture.monitor.refresh()
    var leftover = Self.ready
    leftover.sleepDisabled = true
    #expect(fixture.host.helperUpdates == [Self.ready, leftover])
    #expect(fixture.monitor.state.status?.sleepDisabled == true)
    #expect(fixture.monitor.state.status?.owns == false)
  }

  @Test func anOlderHelperIsAskedWithTheAppsVersionAndAnswersThatItIsExiting() async {
    let fixture = Fixture(version: HelperIdentity.version - 1)
    defer { fixture.helper.stop() }
    #expect(await fixture.started())
    let state = fixture.monitor.state
    #expect(state.status?.helperVersion == HelperIdentity.version - 1)
    #expect(state.status?.exiting == true)
    #expect(state.reachability == .reachable)
    #expect(state.staleAttempts == 1)
    #expect(fixture.helper.fake.logLines.contains("status stale exit=now"))
    #expect(
      fixture.host.helperUpdates
        == [HelperFacts(installed: true, reachable: true, current: false, owns: false, sleepDisabled: false)])
    #expect(fixture.host.helperUpdates.allSatisfy { !$0.ready })
    #expect(HelperStatusPresentation.derive(state, engaged: false) != .onStandingBy)

    await fixture.monitor.refresh()
    #expect(fixture.monitor.state.staleAttempts == 2)
    #expect(fixture.host.helperUpdates.count == 1)
  }

  @Test func whileThePortIsEngagedARefreshMakesNoCallAndKeepsTheFactsAlreadySent() async {
    let fixture = Fixture()
    defer { fixture.helper.stop() }
    #expect(await fixture.started())
    let port = fixture.port
    #expect(await OffPool.run { port.engage() } == .succeeded)
    #expect(fixture.helper.fake.sleepDisabled == true)
    fixture.helper.fake.forget()

    fixture.helper.fake.advance(seconds: 30)
    let first = await fixture.monitor.refresh()
    let second = await fixture.monitor.refresh()
    #expect(fixture.helper.fake.calls.isEmpty)
    #expect(fixture.helper.statusCalls == 0)
    #expect(fixture.helper.connectionsMade == 1)
    #expect(fixture.helper.connections == 1)
    #expect(fixture.host.helperUpdates == [Self.ready])
    #expect(fixture.monitor.facts == Self.ready)
    #expect(first.reachability == .reachable)
    #expect(first.installer == .enabled)
    #expect(first.status?.helperVersion == HelperIdentity.version)
    #expect(second == first)
    #expect(fixture.installer.statusReads == 3)

    fixture.helper.fake.advance(seconds: HelperMachine.heartbeatTimeoutSeconds - 31)
    fixture.helper.watch()
    #expect(fixture.helper.fake.pmsetWrites.isEmpty)
    fixture.helper.fake.advance(seconds: 1)
    fixture.helper.watch()
    #expect(fixture.helper.fake.logLines.contains("release reason=heartbeat sleepDisabled=0 edge=done"))
    #expect(fixture.helper.fake.sleepDisabled == false)
    #expect(fixture.helper.connectionsMade == 1)
  }

  @Test func whileThePortIsEngagedTheMonitorShowsTheEnginesLastAnswer() async {
    let fixture = Fixture()
    defer { fixture.helper.stop() }
    #expect(await fixture.started())
    let port = fixture.port
    #expect(await OffPool.run { port.engage() } == .succeeded)
    #expect(await OffPool.run { port.heartbeat() } == .succeeded)
    fixture.helper.fake.forget()
    let state = await fixture.monitor.refresh()
    #expect(fixture.helper.fake.calls.isEmpty)
    #expect(state.status?.engaged == true)
    #expect(state.status?.owns == true)
    #expect(state.status?.sleepDisabled == true)
    #expect(fixture.host.helperUpdates == [Self.ready])
  }

  @Test func theMonitorNeverNamesTheXPCClientOrCallsStatusItself() throws {
    let source = try String(contentsOf: Self.monitorSource, encoding: .utf8)
    #expect(source.contains("port.probe()"))
    #expect(!source.contains("HelperXPCClient"))
    #expect(!source.contains("OvertimeHelperClient"))
    #expect(!source.contains("status(appVersion"))
    #expect(!source.contains("NSXPCConnection"))
    #expect(!source.contains(".invalidate()"))
  }

  @Test func aHelperThatIsEnabledAndDoesNotAnswerSendsFactsThatAreNotReady() async {
    let silent = SilentHelper()
    defer { silent.stop() }
    let installer = FakeHelperInstaller(status: .enabled)
    let host = ScriptedSnapshotHost()
    let monitor = HelperMonitor(installer: installer, port: XPCHelperPort(client: silent.client(timeoutSeconds: 0.3)))
    monitor.start(host: host)
    #expect(await OffPool.eventually { !host.helperUpdates.isEmpty })
    #expect(host.helperUpdates == [HelperFacts(installed: true, reachable: false, current: false)])
    #expect(monitor.state.reachability == .unreachable)
    #expect(monitor.state.status == nil)
    #expect(silent.sets.isEmpty)
    #expect(HelperStatusPresentation.derive(monitor.state, engaged: false) != .onStandingBy)
  }

  @Test func aLidCloseSeenInTheSnapshotsRefreshesAndALidThatStaysClosedDoesNot() async {
    let fixture = Fixture()
    defer { fixture.helper.stop() }
    #expect(await fixture.started())
    #expect(fixture.monitor.isWatching)
    let helper = fixture.helper
    fixture.host.yield(Self.lid(false))
    fixture.host.yield(Self.lid(true))
    #expect(await OffPool.eventually { helper.statusCalls == 2 })
    fixture.host.yield(Self.lid(true))
    fixture.host.yield(Self.lid(nil))
    fixture.host.yield(Self.lid(true))
    fixture.host.yield(Self.lid(false))
    fixture.host.yield(Self.lid(nil))
    fixture.host.yield(Self.lid(true))
    #expect(await OffPool.eventually { helper.statusCalls == 3 })
    try? await Task.sleep(for: .milliseconds(100))
    #expect(helper.statusCalls == 3)
    #expect(fixture.host.helperUpdates == [Self.ready])
    #expect(helper.connectionsMade == 1)
  }

  @Test func aLidThatIsAlreadyClosedAtTheFirstSnapshotIsNotASecondRefresh() async {
    let fixture = Fixture()
    defer { fixture.helper.stop() }
    fixture.host.yield(Self.lid(true))
    #expect(await fixture.started())
    fixture.host.yield(Self.lid(true))
    try? await Task.sleep(for: .milliseconds(100))
    #expect(fixture.helper.statusCalls == 1)
  }

  @Test func aStartOnANewHostSendsTheFactsAgainAndStopSendsNothingMore() async {
    let fixture = Fixture()
    defer { fixture.helper.stop() }
    #expect(await fixture.started())
    let second = ScriptedSnapshotHost()
    fixture.monitor.start(host: second)
    #expect(await OffPool.eventually { second.helperUpdates == [Self.ready] })
    #expect(await OffPool.eventually { fixture.host.terminated == 1 })
    #expect(fixture.host.helperUpdates == [Self.ready])

    fixture.monitor.stop()
    #expect(!fixture.monitor.isWatching)
    #expect(await OffPool.eventually { second.terminated == 1 })
    fixture.helper.fake.setSleepDisabled(true)
    await fixture.monitor.refresh()
    #expect(second.helperUpdates == [Self.ready])
    #expect(fixture.monitor.facts?.sleepDisabled == true)
  }

  @Test func installRegistersOnceAndOnTheApprovalThrowOpensLoginItemsOnce() async {
    let fixture = Fixture(status: .notRegistered)
    defer { fixture.helper.stop() }
    #expect(await fixture.started())
    fixture.installer.failRegister(leaving: .requiresApproval)
    let state = await fixture.monitor.install()
    #expect(fixture.installer.calls == ["register", "openSystemSettings"])
    #expect(state.installer == .requiresApproval)
    #expect(state.lastError == nil)
    #expect(state.inFlight == nil)
    #expect(state == fixture.monitor.state)
    #expect(HelperStatusPresentation.derive(state, engaged: false) == .waitingForApproval)
    #expect(fixture.host.helperUpdates == [Self.notInstalled, Self.notReady])
    #expect(fixture.helper.connectionsMade == 0)
    #expect(fixture.helper.fake.calls.isEmpty)
  }

  @Test func anInstallThatNeedsNoApprovalReachesTheHelperAndSendsReadyFacts() async {
    let fixture = Fixture(status: .notRegistered)
    defer { fixture.helper.stop() }
    #expect(await fixture.started())
    #expect(fixture.helper.connectionsMade == 0)
    let state = await fixture.monitor.install()
    #expect(fixture.installer.calls == ["register"])
    #expect(state.installer == .enabled)
    #expect(state.lastError == nil)
    #expect(HelperStatusPresentation.derive(state, engaged: false) == .onStandingBy)
    #expect(fixture.host.helperUpdates == [Self.notInstalled, Self.ready])
    #expect(fixture.helper.connectionsMade == 1)
    #expect(fixture.helper.statusCalls == 1)
    #expect(fixture.helper.fake.pmsetWrites.isEmpty)
  }

  @Test func aRegisterErrorOtherThanApprovalIsShownUntilTheNextAction() async {
    let fixture = Fixture(status: .notRegistered)
    defer { fixture.helper.stop() }
    #expect(await fixture.started())
    fixture.installer.failRegister(leaving: .notRegistered)
    let failed = await fixture.monitor.install()
    #expect(fixture.installer.calls == ["register"])
    #expect(failed.installer == .notRegistered)
    #expect(failed.lastError == "Operation not permitted")
    #expect(failed.inFlight == nil)
    #expect(HelperStatusPresentation.derive(failed, engaged: false) == .error)
    #expect(await fixture.monitor.refresh() == failed)
    #expect(fixture.host.helperUpdates == [Self.notInstalled])
    #expect(fixture.helper.connectionsMade == 0)

    fixture.installer.failRegister(leaving: .requiresApproval)
    let retried = await fixture.monitor.install()
    #expect(retried.lastError == nil)
    #expect(HelperStatusPresentation.derive(retried, engaged: false) == .waitingForApproval)
    #expect(fixture.installer.calls == ["register", "register", "openSystemSettings"])
  }

  @Test func aRegisterErrorIsForgottenWhenTheInstallerStatusChangesByItself() async {
    let fixture = Fixture(status: .notRegistered)
    defer { fixture.helper.stop() }
    #expect(await fixture.started())
    fixture.installer.failRegister(leaving: .notFound)
    #expect(await fixture.monitor.install().lastError == "Operation not permitted")
    fixture.installer.setStatus(.requiresApproval)
    let later = await fixture.monitor.refresh()
    #expect(later.lastError == nil)
    #expect(HelperStatusPresentation.derive(later, engaged: false) == .waitingForApproval)
    #expect(fixture.installer.calls == ["register"])
  }

  @Test func whileRegisterIsInFlightTheStateIsInstalling() async {
    let helper = InProcessHelper()
    defer { helper.stop() }
    let installer = FakeHelperInstaller(status: .notRegistered)
    let log = HelperStateLog()
    let monitor = HelperMonitor(
      installer: installer, port: XPCHelperPort(client: helper.client()), onChange: { log.record($0) })
    installer.hang(["register"])
    defer { installer.releaseHangs() }
    let finished = Task { await monitor.install() }
    #expect(await OffPool.eventually { monitor.state.inFlight == .installing })
    #expect(HelperStatusPresentation.derive(monitor.state, engaged: false) == .installing)
    #expect(installer.hangsEnded == 0)
    installer.releaseHangs()
    let state = await finished.value
    #expect(state.inFlight == nil)
    #expect(state.installer == .enabled)
    #expect(log.states.first?.inFlight == .installing)
    #expect(log.states.last == state)
    #expect(log.states.count == 2)
    #expect(installer.calls == ["register"])
  }

  @Test func aRefreshAskedForDuringAnInstallRunsAfterItAndSeesItsResult() async {
    let helper = InProcessHelper()
    defer { helper.stop() }
    let installer = FakeHelperInstaller(status: .notRegistered)
    let host = ScriptedSnapshotHost()
    let monitor = HelperMonitor(installer: installer, port: XPCHelperPort(client: helper.client()))
    defer { monitor.stop() }
    monitor.start(host: host)
    #expect(await OffPool.eventually { host.helperUpdates == [Self.notInstalled] })
    installer.hang(["register"])
    defer { installer.releaseHangs() }
    let installing = Task { await monitor.install() }
    #expect(await OffPool.eventually { monitor.state.inFlight == .installing })
    let reads = installer.statusReads
    let asked = OSAllocatedUnfairLock(initialState: false)
    let refreshing = Task {
      asked.withLock { $0 = true }
      return await monitor.refresh()
    }
    #expect(await OffPool.eventually { asked.withLock { $0 } })
    #expect(installer.statusReads == reads)
    #expect(monitor.state.inFlight == .installing)
    installer.releaseHangs()
    let refreshed = await refreshing.value
    #expect(refreshed.inFlight == nil)
    #expect(refreshed.installer == .enabled)
    #expect(refreshed.reachability == .reachable)
    #expect(await installing.value == refreshed)
    #expect(host.helperUpdates == [Self.notInstalled, Self.ready])
    #expect(installer.calls == ["register"])
  }

  @Test func removeUnregistersOnceAndALaterRefreshReadsNotInstalledWithoutACall() async {
    let fixture = Fixture()
    defer { fixture.helper.stop() }
    #expect(await fixture.started())
    let state = await fixture.monitor.remove()
    #expect(fixture.installer.calls == ["unregister"])
    #expect(state == HelperMonitorState(installer: .notRegistered))
    #expect(HelperStatusPresentation.derive(state, engaged: false) == .off)
    #expect(fixture.host.helperUpdates == [Self.ready, Self.notInstalled])
    #expect(fixture.helper.statusCalls == 1)

    #expect(await fixture.monitor.refresh() == state)
    #expect(fixture.helper.statusCalls == 1)
    #expect(fixture.helper.connectionsMade == 1)
    #expect(fixture.host.helperUpdates.count == 2)
    #expect(fixture.helper.fake.pmsetWrites.isEmpty)
  }

  @Test func whileUnregisterIsInFlightTheStateIsRemoving() async {
    let fixture = Fixture()
    defer { fixture.helper.stop() }
    #expect(await fixture.started())
    fixture.installer.hang(["unregister"])
    defer { fixture.installer.releaseHangs() }
    let monitor = fixture.monitor
    let finished = Task { await monitor.remove() }
    #expect(await OffPool.eventually { monitor.state.inFlight == .removing })
    #expect(HelperStatusPresentation.derive(monitor.state, engaged: true) == .removing)
    #expect(fixture.installer.hangsEnded == 0)
    fixture.installer.releaseHangs()
    let state = await finished.value
    #expect(state.inFlight == nil)
    #expect(state.installer == .notRegistered)
  }

  static let removalMasks: Comment =
    "S-WR-03: once the user moves on, a failed removal never sticks as \"Unplug protection isn't working\" for a helper that answers, and Reconnect clears the kept failure without registering anything"
  static let removalShownOnce: Comment =
    "R3-WR-01: a failed removal is shown, with Remove still offered, through every refresh until reconnect or the pane appearing again drops it"

  @Test func anUnregisterErrorWithAHelperThatAnswersOutlivesRefreshesUntilAcknowledged() async {
    let fixture = Fixture()
    defer { fixture.helper.stop() }
    #expect(await fixture.started())
    fixture.installer.failUnregister()
    let failed = await fixture.monitor.remove()
    #expect(fixture.installer.calls == ["unregister"])
    #expect(failed.installer == .enabled)
    #expect(failed.reachability == .reachable)
    #expect(failed.lastError == "Operation not permitted", Self.removalShownOnce)
    #expect(HelperStatusPresentation.derive(failed, engaged: false) == .error, Self.removalShownOnce)
    #expect(HelperStatusPresentation.derive(failed, engaged: false).actions.contains(.remove), Self.removalShownOnce)
    #expect(fixture.host.helperUpdates == [Self.ready])
    #expect(fixture.logged.all == [HelperMonitor.unregisterFailed(timedOut: false)], Self.removalShownOnce)
    for _ in 0..<2 {
      let refreshed = await fixture.monitor.refresh()
      #expect(refreshed.lastError == "Operation not permitted", Self.removalShownOnce)
      #expect(HelperStatusPresentation.derive(refreshed, engaged: false) == .error, Self.removalShownOnce)
    }
    let acknowledged = fixture.monitor.acknowledgeRemovalFailure()
    #expect(acknowledged.lastError == nil, Self.removalMasks)
    #expect(fixture.monitor.state == acknowledged)
    #expect(HelperStatusPresentation.derive(acknowledged, engaged: false) == .onStandingBy, Self.removalMasks)
    #expect(HelperStatusPresentation.derive(acknowledged, engaged: true) == .onHolding, Self.removalMasks)
    #expect(await fixture.monitor.refresh().lastError == nil, Self.removalMasks)
    #expect(fixture.installer.calls == ["unregister"])
  }

  @Test func anUnregisterErrorWithAHelperThatDoesNotAnswerOutlivesRefreshesAndALidCloseUntilAcknowledged() async {
    let fixture = Fixture(status: .requiresApproval)
    defer { fixture.helper.stop() }
    #expect(await fixture.started())
    fixture.installer.failUnregister()
    let failed = await fixture.monitor.remove()
    #expect(failed.lastError == "Operation not permitted")
    #expect(HelperStatusPresentation.derive(failed, engaged: false) == .error)
    let reads = fixture.installer.statusReads
    fixture.host.yield(Self.lid(false))
    fixture.host.yield(Self.lid(true))
    let installer = fixture.installer
    #expect(await OffPool.eventually { installer.statusReads > reads })
    let refreshed = await fixture.monitor.refresh()
    #expect(refreshed.lastError == "Operation not permitted", Self.removalShownOnce)
    #expect(HelperStatusPresentation.derive(refreshed, engaged: false) == .error, Self.removalShownOnce)
    let acknowledged = fixture.monitor.acknowledgeRemovalFailure()
    #expect(acknowledged.lastError == nil, Self.removalShownOnce)
    #expect(HelperStatusPresentation.derive(acknowledged, engaged: false) == .waitingForApproval, Self.removalShownOnce)
  }

  @Test func acknowledgingKeepsAFailedInstallAndReportsAForgottenRemovalOnce() async {
    let fixture = Fixture(status: .notRegistered)
    defer { fixture.helper.stop() }
    let changes = OSAllocatedUnfairLock<[HelperMonitorState]>(initialState: [])
    let monitor = HelperMonitor(
      installer: fixture.installer, port: fixture.port, onChange: { state in changes.withLock { $0.append(state) } })
    fixture.installer.failRegister(leaving: .notRegistered)
    let failedInstall = await monitor.install()
    #expect(failedInstall.lastError == "Operation not permitted")
    let emitted = changes.withLock { $0.count }
    #expect(monitor.acknowledgeRemovalFailure() == failedInstall)
    #expect(changes.withLock { $0.count } == emitted)

    fixture.installer.setStatus(.requiresApproval)
    #expect(await monitor.refresh().lastError == nil)
    fixture.installer.failUnregister()
    #expect(await monitor.remove().lastError == "Operation not permitted")
    let before = changes.withLock { $0.count }
    let acknowledged = monitor.acknowledgeRemovalFailure()
    #expect(acknowledged.lastError == nil)
    #expect(changes.withLock { Array($0.dropFirst(before)) } == [acknowledged])
    #expect(monitor.acknowledgeRemovalFailure() == acknowledged)
    #expect(changes.withLock { $0.count } == before + 1)
  }

  @Test func anUnregisterErrorIsDroppedByReconnectWithoutRegisteringAnything() async {
    let fixture = Fixture(status: .requiresApproval)
    defer { fixture.helper.stop() }
    #expect(await fixture.started())
    fixture.installer.failUnregister()
    let failed = await fixture.monitor.remove()
    #expect(failed.lastError == "Operation not permitted")
    let reconnected = await fixture.monitor.reconnect()
    #expect(reconnected.lastError == nil, Self.removalMasks)
    #expect(HelperStatusPresentation.derive(reconnected, engaged: false) == .waitingForApproval, Self.removalMasks)
    #expect(fixture.installer.calls == ["unregister"], Self.removalMasks)
  }

  @Test func reconnectAfterARemovalThatThrewButLeftItUnregisteredShowsOffAndRegistersNothing() async {
    let fixture = Fixture()
    defer { fixture.helper.stop() }
    #expect(await fixture.started())
    fixture.installer.failUnregister(leaving: .notRegistered)
    let failed = await fixture.monitor.remove()
    #expect(failed.installer == .notRegistered)
    #expect(HelperStatusPresentation.derive(failed, engaged: false) == .error)
    let reconnected = await fixture.monitor.reconnect()
    #expect(HelperStatusPresentation.derive(reconnected, engaged: false) == .off, Self.removalMasks)
    #expect(fixture.installer.calls == ["unregister"], Self.removalMasks)
  }

  @Test func reconnectAfterAFailedInstallClearsTheErrorWithoutRegisteringAgain() async {
    let fixture = Fixture(status: .notRegistered)
    defer { fixture.helper.stop() }
    #expect(await fixture.started())
    fixture.installer.failRegister(leaving: .notRegistered)
    #expect(HelperStatusPresentation.derive(await fixture.monitor.install(), engaged: false) == .error)
    let reconnected = await fixture.monitor.reconnect()
    #expect(reconnected.lastError == nil)
    #expect(HelperStatusPresentation.derive(reconnected, engaged: false) == .off)
    #expect(fixture.installer.calls == ["register"], Self.removalMasks)
  }

  @Test func reconnectKeepsAStatusErrorThatTheNextReadStillSees() async {
    let scripted = Scripted([Self.current, .garbage])
    defer { scripted.finish() }
    #expect(await scripted.firstRead())
    _ = await scripted.monitor.refresh()
    let reconnected = await scripted.monitor.reconnect()
    #expect(reconnected.lastError != nil)
    #expect(scripted.installer.calls.isEmpty)
  }

  static let bounded: Comment =
    "S-WR-02: every SMAppService call is bounded, so one that hangs cannot wedge later refreshes, installs and removes"
  static let hangBoundSeconds: Double = 1

  static func settled(_ monitor: HelperMonitor, seconds: Double = 5) async -> HelperMonitorState? {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
      let state = await monitor.refresh()
      if state.lastError == nil { return state }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return nil
  }

  static let portBound: Comment =
    "S-IN-07: a helper that does not answer ends inside the interpreter's 5 s bound, so the runner key is free for the next effect"

  @Test func thePrivilegedPortsClientGivesUpWithinThePortsOwnBound() {
    for identity in [HelperIdentity.release, HelperIdentity.dev] {
      let port = XPCHelperPort.privileged(identity: identity)
      #expect(port.boundSeconds == XPCHelperPort.defaultBoundSeconds)
      #expect(port.client.timeoutSeconds == port.boundSeconds, Self.portBound)
      #expect(port.client.timeoutSeconds < Timing.systemCallTimeoutSeconds)
      #expect(port.client.requirement == identity.helperRequirement)
    }
  }

  @Test func theInstallerBoundsAreTheProjectsSystemCallBoundAndALongerOneForTheActions() {
    #expect(HelperMonitor.statusBoundSeconds == Timing.systemCallTimeoutSeconds)
    #expect(HelperMonitor.actionBoundSeconds == 20)
    #expect(
      HelperMonitor.actionBoundSeconds > 7, "unregister waits for the helper's release: 5 s pmset plus a 2 s verify")
  }

  @Test func aStatusReadThatHangsIsCutAtItsBoundKeepsTheFactsAndTheNextRefreshDoesNotQueueBehindIt() async {
    let fixture = Fixture(statusSeconds: Self.hangBoundSeconds, actionSeconds: Self.hangBoundSeconds)
    defer {
      fixture.installer.releaseHangs()
      fixture.helper.stop()
    }
    #expect(await fixture.started())
    let reads = fixture.installer.statusReads
    fixture.installer.hang(["status"])
    let first = await fixture.monitor.refresh()
    #expect(fixture.installer.hangsEnded == 0, Self.bounded)
    #expect(first.installer == .enabled)
    #expect(first.reachability == .reachable)
    #expect(first.lastError == HelperMonitor.timedOutReason, Self.bounded)
    #expect(HelperStatusPresentation.derive(first, engaged: false) == .error)
    #expect(fixture.host.helperUpdates == [Self.ready], "a status read that timed out keeps the facts already sent")
    #expect(await fixture.monitor.refresh().lastError == HelperMonitor.timedOutReason)
    #expect(fixture.installer.hangsEnded == 0, Self.bounded)
    #expect(fixture.installer.statusReads == reads + 1, "the hung read is not called a second time")
    fixture.installer.releaseHangs()
    let recovered = await Self.settled(fixture.monitor)
    #expect(recovered?.installer == .enabled)
    #expect(recovered.map { HelperStatusPresentation.derive($0, engaged: false) } == .onStandingBy)
  }

  @Test func aFirstStatusReadThatHangsLeavesCheckingForTheErrorRow() async {
    let helper = InProcessHelper()
    defer { helper.stop() }
    let installer = FakeHelperInstaller(status: .enabled)
    installer.hang(["status"])
    defer { installer.releaseHangs() }
    let monitor = HelperMonitor(
      installer: installer, port: XPCHelperPort(client: helper.client()), statusBoundSeconds: Self.hangBoundSeconds,
      actionBoundSeconds: Self.hangBoundSeconds)
    let state = await monitor.refresh()
    #expect(state.installer == nil)
    #expect(state.lastError == HelperMonitor.timedOutReason)
    #expect(HelperStatusPresentation.derive(state, engaged: false) == .error, Self.bounded)
    #expect(helper.connectionsMade == 0)
  }

  @Test func aRegisterThatHangsEndsTheInstallAtItsBoundAndASecondInstallDoesNotCallItAgain() async {
    let fixture = Fixture(
      status: .notRegistered, statusSeconds: Self.hangBoundSeconds, actionSeconds: Self.hangBoundSeconds)
    defer {
      fixture.installer.releaseHangs()
      fixture.helper.stop()
    }
    #expect(await fixture.started())
    fixture.installer.hang(["register"])
    let failed = await fixture.monitor.install()
    #expect(fixture.installer.hangsEnded == 0, Self.bounded)
    #expect(failed.inFlight == nil)
    #expect(failed.installer == .notRegistered)
    #expect(failed.lastError == HelperMonitor.timedOutReason)
    #expect(HelperStatusPresentation.derive(failed, engaged: false) == .error)
    #expect(await fixture.monitor.install().inFlight == nil)
    #expect(fixture.installer.hangsEnded == 0, Self.bounded)
    #expect(fixture.installer.calls == ["register"])
  }

  @Test func anUnregisterThatHangsEndsTheRemovalAtItsBoundAndASecondRemoveDoesNotCallItAgain() async {
    let fixture = Fixture(statusSeconds: Self.hangBoundSeconds, actionSeconds: Self.hangBoundSeconds)
    defer {
      fixture.installer.releaseHangs()
      fixture.helper.stop()
    }
    #expect(await fixture.started())
    fixture.installer.hang(["unregister"])
    let ended = await fixture.monitor.remove()
    #expect(fixture.installer.hangsEnded == 0, Self.bounded)
    #expect(ended.inFlight == nil)
    #expect(ended.installer == .enabled)
    #expect(ended.lastError == HelperMonitor.timedOutReason, Self.removalShownOnce)
    #expect(fixture.logged.all == [HelperMonitor.unregisterFailed(timedOut: true)], Self.removalShownOnce)
    #expect(await fixture.monitor.remove().inFlight == nil)
    #expect(fixture.installer.hangsEnded == 0, Self.bounded)
    #expect(fixture.installer.calls == ["unregister"])
  }

  @Test func openLoginItemsThatHangsIsCutAtItsBound() async {
    let fixture = Fixture(
      status: .requiresApproval, statusSeconds: Self.hangBoundSeconds, actionSeconds: Self.hangBoundSeconds)
    defer {
      fixture.installer.releaseHangs()
      fixture.helper.stop()
    }
    #expect(await fixture.started())
    fixture.installer.hang(["openSystemSettings"])
    await fixture.monitor.openLoginItems()
    await fixture.monitor.openLoginItems()
    #expect(fixture.installer.hangsEnded == 0, Self.bounded)
    #expect(fixture.installer.calls == ["openSystemSettings"])
  }

  @Test func openLoginItemsOpensSystemSettingsAndNothingElse() async {
    let fixture = Fixture(status: .requiresApproval)
    defer { fixture.helper.stop() }
    #expect(await fixture.started())
    await fixture.monitor.openLoginItems()
    #expect(fixture.installer.calls == ["openSystemSettings"])
    #expect(fixture.helper.connectionsMade == 0)
  }

  @Test func anOlderHelperIsUpdatingAndReadsOnOnceTheBundledOneAnswers() async {
    let scripted = Scripted([Self.older, Self.current])
    defer { scripted.finish() }
    #expect(await scripted.firstRead())
    #expect(scripted.shown() == .updating)
    #expect(scripted.monitor.state.staleAttempts == 1)
    await scripted.monitor.refresh()
    #expect(scripted.shown() == .onStandingBy)
    #expect(scripted.monitor.state.staleAttempts == 0)
    #expect(scripted.host.helperUpdates.map(\.ready) == [false, true])
    #expect(scripted.helper.versionsAsked == [HelperIdentity.version, HelperIdentity.version])
    #expect(scripted.helper.sets == 0)
  }

  @Test func aHelperThatIsStillOlderOnTheNextReadIsOutOfDate() async {
    let scripted = Scripted([Self.older])
    defer { scripted.finish() }
    #expect(await scripted.firstRead())
    #expect(scripted.shown() == .updating)
    await scripted.monitor.refresh()
    #expect(scripted.shown() == .outOfDate)
    await scripted.monitor.refresh()
    #expect(scripted.shown() == .outOfDate)
    #expect(scripted.host.helperUpdates.map(\.ready) == [false])
    #expect(scripted.helper.sets == 0)
  }

  @Test func oneMissedProbeAfterAnAnswerChangesNothing() async {
    let scripted = Scripted([Self.current, .silence, Self.current])
    defer { scripted.finish() }
    #expect(await scripted.firstRead())
    let answered = scripted.monitor.state
    #expect(scripted.shown() == .onStandingBy)
    #expect(await scripted.monitor.refresh() == answered)
    #expect(scripted.host.helperUpdates == [Self.ready])
    #expect(scripted.monitor.facts == Self.ready)
    #expect(await scripted.monitor.refresh() == answered)
    #expect(scripted.helper.versionsAsked.count == 3)
    #expect(scripted.host.helperUpdates == [Self.ready])
    #expect(scripted.log.states == [answered])
  }

  @Test func aSecondMissedProbeInARowReadsAsNeedingApprovalAgainAndSendsNotReadyFacts() async {
    let scripted = Scripted([Self.current, .silence])
    defer { scripted.finish() }
    #expect(await scripted.firstRead())
    await scripted.monitor.refresh()
    #expect(scripted.shown() == .onStandingBy)
    #expect(scripted.host.helperUpdates == [Self.ready])
    let state = await scripted.monitor.refresh()
    #expect(state.reachability == .unreachable)
    #expect(state.status == nil)
    #expect(state.lastError == nil)
    #expect(scripted.shown() == .needsApprovalAgain)
    #expect(scripted.host.helperUpdates == [Self.ready, Self.notReady])
  }

  @Test func aHelperThatNeverAnsweredIsBelievedOnTheFirstMiss() async {
    let scripted = Scripted([.silence, Self.current])
    defer { scripted.finish() }
    #expect(await scripted.firstRead())
    #expect(scripted.shown() == .needsApprovalAgain)
    #expect(scripted.host.helperUpdates == [Self.notReady])
    await scripted.monitor.refresh()
    #expect(scripted.shown() == .onStandingBy)
    #expect(scripted.host.helperUpdates == [Self.notReady, Self.ready])
  }

  @Test func anAnswerThatCannotBeReadIsAnErrorAndNotAMissingApproval() async {
    let scripted = Scripted([.garbage, Self.current])
    defer { scripted.finish() }
    #expect(await scripted.firstRead())
    #expect(scripted.monitor.state.lastError == "undecodableStatus")
    #expect(scripted.monitor.state.reachability == .reachable)
    #expect(scripted.monitor.state.status == nil)
    #expect(scripted.shown() == .error)
    #expect(scripted.host.helperUpdates == [Self.notReady])
    await scripted.monitor.refresh()
    #expect(scripted.monitor.state.lastError == nil)
    #expect(scripted.shown() == .onStandingBy)
    #expect(scripted.host.helperUpdates == [Self.notReady, Self.ready])
  }

  @Test func anAnswerThatCannotBeReadIsAlsoToleratedOnceAfterAGoodOne() async {
    let scripted = Scripted([Self.current, .garbage])
    defer { scripted.finish() }
    #expect(await scripted.firstRead())
    await scripted.monitor.refresh()
    #expect(scripted.shown() == .onStandingBy)
    #expect(scripted.monitor.state.lastError == nil)
    await scripted.monitor.refresh()
    #expect(scripted.shown() == .error)
    #expect(scripted.host.helperUpdates == [Self.ready, Self.notReady])
  }

  @Test func oneMissedProbeWhileTheHelperUpdatesKeepsItUpdating() async {
    let scripted = Scripted([Self.older, .silence, Self.current])
    defer { scripted.finish() }
    #expect(await scripted.firstRead())
    await scripted.monitor.refresh()
    #expect(scripted.shown() == .updating)
    #expect(scripted.monitor.state.staleAttempts == 1)
    await scripted.monitor.refresh()
    #expect(scripted.shown() == .onStandingBy)
  }

  @Test func aReplyTheClientRejectsIsAnErrorAndNothingOfItIsKept() async {
    let helper = InProcessHelper()
    defer { helper.stop() }
    let host = ScriptedSnapshotHost()
    let port = XPCHelperPort(client: helper.client(requirement: HelperIdentity.release.helperRequirement))
    let monitor = HelperMonitor(installer: FakeHelperInstaller(status: .enabled), port: port)
    defer { monitor.stop() }
    monitor.start(host: host)
    #expect(await OffPool.eventually { !host.helperUpdates.isEmpty })
    #expect(monitor.state.lastError == "NSCocoaErrorDomain 4102")
    #expect(monitor.state.status == nil)
    #expect(HelperStatusPresentation.derive(monitor.state, engaged: false) == .error)
    #expect(host.helperUpdates == [Self.notReady])
    #expect(port.observations.current == HelperObservation())
    #expect(helper.fake.pmsetWrites.isEmpty)
  }

  @Test func onlyATimeoutOrAnInvalidConnectionCountsAsUnreachable() {
    #expect(HelperMonitor.connectionInvalidReason == "NSCocoaErrorDomain 4099")
    #expect(HelperMonitor.isUnreachable(XPCHelperPort.timedOutReason))
    #expect(HelperMonitor.isUnreachable("timedOut"))
    #expect(HelperMonitor.isUnreachable("NSCocoaErrorDomain 4099"))
    #expect(!HelperMonitor.isUnreachable("NSCocoaErrorDomain 4097"))
    #expect(!HelperMonitor.isUnreachable("NSCocoaErrorDomain 4102"))
    #expect(!HelperMonitor.isUnreachable("undecodableStatus"))
    #expect(!HelperMonitor.isUnreachable("replyCode 7"))
    #expect(!HelperMonitor.isUnreachable("noProxy"))
    #expect(!HelperMonitor.isUnreachable(""))
  }

  static let timedOut = HelperProbe.unreachable(XPCHelperPort.timedOutReason)
  static let unreadable = HelperProbe.unreachable("undecodableStatus")

  static func status(
    version: Int = HelperIdentity.version, sleepDisabled: Bool? = false, owns: Bool = false, engaged: Bool = false
  ) -> HelperStatus {
    HelperStatus(helperVersion: version, sleepDisabled: sleepDisabled, owns: owns, engaged: engaged)
  }

  static func tracked(_ probes: [HelperProbe]) -> HelperTracking {
    var tracking = HelperTracking()
    for probe in probes {
      tracking.apply(installer: .enabled, probe: probe)
    }
    return tracking
  }

  @Test func theTrackingStartsWithNoReadNoFactsAndNoError() {
    let tracking = HelperTracking()
    #expect(tracking.state == HelperMonitorState())
    #expect(tracking.facts == nil)
    #expect(tracking.misses == 0)
    #expect(tracking.actionFailure == nil)
    #expect(tracking.probeFailure == nil)
  }

  @Test func anAnswerCarriesTheHelpersOwnershipAndSleepDisabledIntoTheFacts() {
    let owning = Self.status(sleepDisabled: true, owns: true)
    let tracking = Self.tracked([.answered(owning)])
    #expect(
      tracking.facts == HelperFacts(installed: true, reachable: true, current: true, owns: true, sleepDisabled: true))
    #expect(tracking.state == HelperMonitorState(installer: .enabled, reachability: .reachable, status: owning))
    let unread = Self.tracked([.answered(Self.status(sleepDisabled: nil))])
    #expect(unread.facts == HelperFacts(installed: true, reachable: true, current: true, owns: false))
  }

  @Test func aNewerHelperIsNotCurrentEither() {
    let newer = Self.tracked([.answered(Self.status(version: HelperIdentity.version + 1))])
    #expect(newer.facts?.current == false)
    #expect(newer.state.staleAttempts == 1)
  }

  @Test(arguments: [HelperInstallerStatus.notRegistered, .notFound, .requiresApproval])
  func aStatusThatIsNotEnabledForgetsEverythingTheProbeSaid(_ status: HelperInstallerStatus) {
    var tracking = Self.tracked([.answered(Self.status(version: 0)), Self.unreadable, Self.unreadable])
    #expect(tracking.state.lastError == "undecodableStatus")
    #expect(tracking.state.staleAttempts == 1)
    #expect(tracking.state.reachability == .reachable)

    tracking.apply(installer: status, probe: nil)
    #expect(tracking.state == HelperMonitorState(installer: status))
    #expect(tracking.probeFailure == nil)
    #expect(tracking.facts == HelperFacts(installed: status == .requiresApproval, reachable: false, current: false))

    tracking.apply(installer: .enabled, probe: Self.timedOut)
    #expect(tracking.state == HelperMonitorState(installer: .enabled, reachability: .unreachable))
    #expect(tracking.facts == Self.notReady)
  }

  @Test func anAnswerAfterAMissMakesTheNextMissTheFirstAgain() {
    let answer = HelperProbe.answered(Self.status())
    let answered = Self.tracked([answer])
    var tracking = Self.tracked([answer, Self.timedOut, answer, Self.timedOut])
    #expect(tracking.state == answered.state)
    #expect(tracking.facts == Self.ready)
    #expect(tracking.misses == 1)
    tracking.apply(installer: .enabled, probe: Self.timedOut)
    #expect(tracking.misses == 2)
    #expect(tracking.state == HelperMonitorState(installer: .enabled, reachability: .unreachable))
    #expect(tracking.facts == Self.notReady)
    tracking.apply(installer: .enabled, probe: Self.timedOut)
    #expect(tracking.state.reachability == .unreachable)
    tracking.apply(installer: .enabled, probe: answer)
    #expect(tracking.state == answered.state)
    #expect(tracking.misses == 0)
  }

  @Test func theEnginesHoldCountsAsAnAnswerAndChangesNoFacts() {
    let answer = HelperProbe.answered(Self.status())
    let answered = Self.tracked([answer])
    var tracking = Self.tracked([answer, Self.timedOut, .engaged(nil), Self.timedOut])
    #expect(tracking.state == answered.state)
    #expect(tracking.facts == Self.ready)
    tracking.apply(installer: .enabled, probe: Self.timedOut)
    #expect(tracking.state.reachability == .unreachable)
    #expect(tracking.facts == Self.notReady)
  }

  @Test func theEnginesHoldShowsItsLastAnswerAndKeepsTheEarlierOneUntilThen() {
    let first = Self.status()
    let held = Self.status(sleepDisabled: true, owns: true, engaged: true)
    var tracking = Self.tracked([.answered(first), .engaged(nil)])
    #expect(tracking.state.status == first)
    tracking.apply(installer: .enabled, probe: .engaged(held))
    #expect(tracking.state.status == held)
    #expect(tracking.state.reachability == .reachable)
    #expect(tracking.facts == Self.ready)
  }

  @Test func theEnginesHoldClearsAnEarlierStatusErrorAndUnreachableState() {
    var failed = Self.tracked([Self.unreadable])
    #expect(failed.state.lastError == "undecodableStatus")
    failed.apply(installer: .enabled, probe: .engaged(nil))
    #expect(failed.state == HelperMonitorState(installer: .enabled, reachability: .reachable))
    #expect(failed.probeFailure == nil)
    #expect(failed.facts == Self.notReady)

    var silent = Self.tracked([Self.timedOut])
    #expect(silent.state.reachability == .unreachable)
    silent.apply(installer: .enabled, probe: .engaged(nil))
    #expect(silent.state.reachability == .reachable)
    #expect(silent.misses == 0)
  }

  @Test func aBelievedMissKeepsTheStaleCountAndTheNextOlderAnswerIsOutOfDate() {
    let older = HelperProbe.answered(Self.status(version: HelperIdentity.version - 1))
    var tracking = Self.tracked([older, Self.timedOut, Self.timedOut])
    #expect(tracking.state == HelperMonitorState(installer: .enabled, reachability: .unreachable, staleAttempts: 1))
    #expect(HelperStatusPresentation.derive(tracking.state, engaged: false) == .needsApprovalAgain)
    tracking.apply(installer: .enabled, probe: older)
    #expect(tracking.state.staleAttempts == 2)
    #expect(HelperStatusPresentation.derive(tracking.state, engaged: false) == .outOfDate)
  }

  @Test func aTimeoutAfterAnAnswerThatCouldNotBeReadIsUnreachableAndNoLongerAnError() {
    var tracking = Self.tracked([Self.unreadable])
    #expect(tracking.state.reachability == .reachable)
    #expect(tracking.state.lastError == "undecodableStatus")
    tracking.apply(installer: .enabled, probe: Self.timedOut)
    #expect(tracking.state == HelperMonitorState(installer: .enabled, reachability: .unreachable))
    tracking.apply(installer: .enabled, probe: .unreachable("NSCocoaErrorDomain 4097"))
    #expect(tracking.state.reachability == .reachable)
    #expect(tracking.state.lastError == "NSCocoaErrorDomain 4097")
  }

  @Test func anActionShowsItsFlightAndItsFailureUntilTheStatusChanges() {
    var tracking = HelperTracking()
    tracking.apply(installer: .notRegistered, probe: nil)
    tracking.begin(.installing)
    #expect(tracking.state == HelperMonitorState(installer: .notRegistered, inFlight: .installing))
    tracking.end(failure: HelperTracking.ActionFailure(message: "refused", status: .notRegistered))
    #expect(tracking.state == HelperMonitorState(installer: .notRegistered, lastError: "refused"))
    tracking.apply(installer: .notRegistered, probe: nil)
    #expect(tracking.state.lastError == "refused")

    tracking.begin(.installing)
    #expect(tracking.state.lastError == nil)
    #expect(tracking.actionFailure == nil)
    tracking.end(failure: HelperTracking.ActionFailure(message: "refused again", status: .notRegistered))
    tracking.apply(installer: .notFound, probe: nil)
    #expect(tracking.state == HelperMonitorState(installer: .notFound))
    #expect(tracking.actionFailure == nil)
  }

  @Test func aRemovalFailureOutlivesTheReadThatEndsItsActionAndIsForgottenAfterwardsButAnInstallFailureIsNot() {
    var tracking = HelperTracking()
    tracking.apply(installer: .enabled, probe: .answered(Self.status()))
    tracking.begin(.removing)
    tracking.end(failure: HelperTracking.ActionFailure(message: "refused", status: .enabled))
    #expect(tracking.state.lastError == "refused")
    tracking.apply(installer: .enabled, probe: .answered(Self.status()))
    #expect(tracking.state.lastError == "refused", Self.removalShownOnce)
    tracking.forgetRemovalFailure()
    #expect(tracking.state.lastError == nil, Self.removalShownOnce)
    #expect(tracking.actionFailure == nil)

    tracking.begin(.removing)
    tracking.end(failure: HelperTracking.ActionFailure(message: "refused", status: .enabled))
    tracking.apply(installer: .enabled, probe: .unreachable(XPCHelperPort.timedOutReason))
    #expect(tracking.state.lastError == "refused")
    tracking.forgetRemovalFailure()
    #expect(tracking.state.lastError == nil, Self.removalShownOnce)

    tracking.begin(.installing)
    tracking.end(failure: HelperTracking.ActionFailure(message: "register refused", status: .enabled))
    tracking.apply(installer: .enabled, probe: .answered(Self.status()))
    tracking.forgetRemovalFailure()
    #expect(tracking.state.lastError == "register refused")
    tracking.acknowledge()
    #expect(tracking.state.lastError == nil)
    #expect(tracking.actionFailure == nil)
  }

  @Test func anActionFailureIsShownBeforeAStatusErrorAndTheStatusErrorOutlivesTheAction() {
    var tracking = Self.tracked([Self.unreadable])
    tracking.begin(.removing)
    #expect(tracking.state.inFlight == .removing)
    #expect(tracking.state.lastError == "undecodableStatus")
    tracking.end(failure: HelperTracking.ActionFailure(message: "refused", status: .enabled))
    #expect(tracking.state.inFlight == nil)
    #expect(tracking.state.lastError == "refused")
    tracking.apply(installer: .enabled, probe: Self.unreadable)
    #expect(tracking.state.lastError == "refused")

    tracking.begin(.removing)
    tracking.end(failure: nil)
    #expect(tracking.state.lastError == "undecodableStatus")
    tracking.apply(installer: .enabled, probe: .answered(Self.status()))
    #expect(tracking.state.lastError == nil)
  }
}
