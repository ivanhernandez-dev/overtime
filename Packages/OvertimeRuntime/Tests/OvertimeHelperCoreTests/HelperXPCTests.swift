import Foundation
import ObjectiveC
import OvertimeHelperClient
import OvertimeHelperCore
import Testing
import os

struct HelperXPCTests {
  typealias Call = FakeHelperSystem.Call

  static let ownedSet: [Call] = [
    .readSleepDisabled, .recordWrite(owns: true, prior: false), .writeSleepDisabled(true), .readSleepDisabled,
  ]
  static let connectionRelease = "release reason=connection sleepDisabled=0 edge=done"
  static let refusedByListener = "NSCocoaErrorDomain 4097"
  static let replyRefusedByClient = "NSCocoaErrorDomain 4102"
  static let queueKey = DispatchSpecificKey<Bool>()

  struct Endpoint: @unchecked Sendable {
    let value: NSXPCListenerEndpoint
  }

  struct Remote: Sendable {
    let client: HelperXPCClient

    func set(_ enabled: Bool) async -> HelperCallResult<HelperReply> {
      let client = client
      return await OffPool.run { client.set(enabled) }
    }

    func status(appVersion: Int) async -> HelperCallResult<HelperStatus> {
      let client = client
      return await OffPool.run { client.status(appVersion: appVersion) }
    }

    func invalidate() {
      client.invalidate()
    }
  }

  final class QueueProbe: HelperClock, Sendable {
    private let fake: FakeHelperSystem
    private let counts = OSAllocatedUnfairLock(initialState: (on: 0, off: 0))

    init(fake: FakeHelperSystem) {
      self.fake = fake
    }

    var onQueue: Int { counts.withLock { $0.on } }
    var offQueue: Int { counts.withLock { $0.off } }

    func now() -> Double {
      let inside = DispatchQueue.getSpecific(key: HelperXPCTests.queueKey) == true
      counts.withLock {
        if inside {
          $0.on += 1
        } else {
          $0.off += 1
        }
      }
      return fake.now()
    }
  }

  struct Watched: @unchecked Sendable {
    let machine: HelperMachine
  }

  struct ShellEvent: Sendable, Equatable {
    let needsWatch: Bool
    let onQueue: Bool
    var exitAsked = false
  }

  final class Harness {
    let fake: FakeHelperSystem
    let probe: QueueProbe
    let queue: DispatchQueue
    let machine: HelperMachine
    let service: HelperXPCService
    let listener: NSXPCListener
    private let exits: OSAllocatedUnfairLock<Int>
    private let events: OSAllocatedUnfairLock<[ShellEvent]>
    private let made = OSAllocatedUnfairLock(initialState: 0)

    init(
      listenerRequirement: String = OwnRequirement.string(), sleepDisabled: Bool? = false, lid: Bool? = true,
      version: Int = HelperIdentity.version
    ) {
      let fake = FakeHelperSystem(sleepDisabled: sleepDisabled, lid: lid)
      let probe = QueueProbe(fake: fake)
      let exits = OSAllocatedUnfairLock(initialState: 0)
      let queue = DispatchQueue(label: "HelperXPCTests.machine")
      let listener = NSXPCListener.anonymous()
      queue.setSpecific(key: HelperXPCTests.queueKey, value: true)
      let machine = HelperMachine(system: fake, record: fake, log: fake, clock: probe, version: version)
      let events = OSAllocatedUnfairLock(initialState: [ShellEvent]())
      let watched = Watched(machine: machine)
      let service = HelperXPCService(
        machine: machine, log: fake, queue: queue,
        afterEvent: {
          let inside = DispatchQueue.getSpecific(key: HelperXPCTests.queueKey) == true
          let event = ShellEvent(
            needsWatch: watched.machine.needsWatch, onQueue: inside, exitAsked: exits.withLock { $0 } > 0)
          events.withLock { $0.append(event) }
        },
        onExit: { exits.withLock { $0 += 1 } })
      service.configure(listener, requirement: listenerRequirement)
      listener.resume()
      self.fake = fake
      self.probe = probe
      self.exits = exits
      self.events = events
      self.queue = queue
      self.listener = listener
      self.machine = machine
      self.service = service
    }

    var exitCount: Int { exits.withLock { $0 } }
    var shellEvents: [ShellEvent] { events.withLock { $0 } }
    var connectionsMade: Int { made.withLock { $0 } }
    var connections: Int { queue.sync { machine.connections } }

    func client(
      requirement: String = OwnRequirement.string(), timeoutSeconds: Double = HelperXPCClient.defaultTimeoutSeconds
    ) -> Remote {
      HelperXPCTests.client(to: listener, counting: made, requirement: requirement, timeoutSeconds: timeoutSeconds)
    }

    func settle() async {
      try? await Task.sleep(for: .milliseconds(100))
      queue.sync {}
    }

    func watch() {
      queue.sync { machine.watch() }
    }

    func stop() {
      listener.invalidate()
    }
  }

  final class ScriptedHelper: NSObject, NSXPCListenerDelegate, HelperXPCProtocol, @unchecked Sendable {
    enum Script: Sendable {
      case silent
      case garbage
    }

    let listener = NSXPCListener.anonymous()
    private let script: Script
    private let held = OSAllocatedUnfairLock<[Any]>(uncheckedState: [])
    private let made = OSAllocatedUnfairLock(initialState: 0)

    init(_ script: Script) {
      self.script = script
      super.init()
      listener.setConnectionCodeSigningRequirement(OwnRequirement.string())
      listener.delegate = self
      listener.resume()
    }

    var connectionsMade: Int { made.withLock { $0 } }
    var callsHeld: Int { held.withLockUnchecked { $0.count } }

    func client(timeoutSeconds: Double) -> Remote {
      HelperXPCTests.client(
        to: listener, counting: made, requirement: OwnRequirement.string(), timeoutSeconds: timeoutSeconds)
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
      connection.exportedInterface = NSXPCInterface(with: HelperXPCProtocol.self)
      connection.exportedObject = self
      connection.resume()
      return true
    }

    func setSleepDisabled(_ enabled: Bool, reply: @escaping @Sendable (Int32, String) -> Void) {
      switch script {
      case .silent: held.withLockUnchecked { $0.append(reply) }
      case .garbage: reply(9, "unknown")
      }
    }

    func status(appHelperVersion: Int, reply: @escaping @Sendable (Data) -> Void) {
      switch script {
      case .silent: held.withLockUnchecked { $0.append(reply) }
      case .garbage: reply(Data("not a status".utf8))
      }
    }
  }

  final class AcceptSpy: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let inner: HelperXPCService
    private let accepted = OSAllocatedUnfairLock<[NSXPCConnection]>(uncheckedState: [])
    private let invalidated = OSAllocatedUnfairLock(initialState: 0)

    init(inner: HelperXPCService) {
      self.inner = inner
    }

    var connections: [NSXPCConnection] { accepted.withLockUnchecked { $0 } }
    var invalidations: Int { invalidated.withLock { $0 } }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
      let result = inner.listener(listener, shouldAcceptNewConnection: connection)
      let invalidated = invalidated
      let original = connection.invalidationHandler
      connection.invalidationHandler = {
        original?()
        invalidated.withLock { $0 += 1 }
      }
      accepted.withLockUnchecked { $0.append(connection) }
      return result
    }
  }

  static func client(
    to listener: NSXPCListener, counting made: OSAllocatedUnfairLock<Int>, requirement: String, timeoutSeconds: Double
  ) -> Remote {
    let endpoint = Endpoint(value: listener.endpoint)
    let client = HelperXPCClient(requirement: requirement, timeoutSeconds: timeoutSeconds) {
      made.withLock { $0 += 1 }
      return NSXPCConnection(listenerEndpoint: endpoint.value)
    }
    return Remote(client: client)
  }

  static func direct(_ service: HelperXPCService, _ enabled: Bool) async -> HelperReply? {
    let answer = await OffPool.bounded(seconds: 5) { () -> HelperReply? in
      let box = OSAllocatedUnfairLock<HelperReply?>(initialState: nil)
      let done = DispatchSemaphore(value: 0)
      service.setSleepDisabled(enabled) { code, message in
        box.withLock { $0 = HelperReplyCode(rawValue: code).map { HelperReply(code: $0, message: message) } }
        done.signal()
      }
      _ = done.wait(timeout: .now() + 5)
      return box.withLock { $0 }
    }
    return answer ?? nil
  }

  static func isFailed<Value>(_ result: HelperCallResult<Value>) -> Bool {
    if case .failed = result { return true }
    return false
  }

  @Test func theTestProcessHasARequirementOfItsOwnThatIsNotAPinnedOne() {
    let own = OwnRequirement.string()
    #expect(!own.isEmpty)
    for identity in [HelperIdentity.release, HelperIdentity.dev] {
      #expect(own != identity.appRequirement)
      #expect(own != identity.helperRequirement)
    }
  }

  @Test func theClientSetsReadsAndClearsSleepDisabledThroughTheHelper() async throws {
    let harness = Harness()
    defer { harness.stop() }
    let client = harness.client()
    defer { client.invalidate() }
    #expect(await client.set(true) == .success(HelperReply(code: .owned, message: "owned")))
    #expect(harness.fake.holdCalls == Self.ownedSet)
    #expect(harness.fake.sleepDisabled == true)
    let answer = await client.status(appVersion: HelperIdentity.version)
    guard case .success(let status) = answer else {
      Issue.record("status did not succeed: \(answer)")
      return
    }
    #expect(status.owns)
    #expect(status.engaged)
    #expect(status.helperVersion == 1)
    #expect(status.sleepDisabled == true)
    #expect(status.prior == false)
    #expect(status.batteryPercent == 80)
    #expect(!status.exiting)
    #expect(await client.set(false) == .success(HelperReply(code: .cleared, message: "cleared")))
    #expect(harness.fake.pmsetWrites == [true, false])
    #expect(harness.fake.sleepDisabled == false)
    #expect(harness.fake.storedRecord?.owns == false)
    #expect(harness.exitCount == 0)
  }

  @Test func everyReplyCodeCrossesTheConnectionWithItsMessage() async {
    let alreadyOn = Harness(sleepDisabled: true)
    defer { alreadyOn.stop() }
    let first = alreadyOn.client()
    defer { first.invalidate() }
    #expect(await first.set(true) == .success(HelperReply(code: .alreadyOn, message: "alreadyOn")))
    #expect(alreadyOn.fake.pmsetWrites.isEmpty)

    let lidOpen = Harness(lid: false)
    defer { lidOpen.stop() }
    let second = lidOpen.client()
    defer { second.invalidate() }
    #expect(await second.set(true) == .success(HelperReply(code: .refused, message: "lidOpen")))
    #expect(lidOpen.fake.holdCalls.isEmpty)

    let stuck = Harness()
    defer { stuck.stop() }
    let third = stuck.client()
    defer { third.invalidate() }
    #expect(await third.set(true) == .success(HelperReply(code: .owned, message: "owned")))
    stuck.fake.setWriteSucceeds(false)
    #expect(await third.set(false) == .success(HelperReply(code: .refused, message: "pmset")))
    stuck.fake.setWriteSucceeds(true)
    #expect(await third.set(false) == .success(HelperReply(code: .cleared, message: "cleared")))
  }

  @Test func oneConnectionServesEveryCallUntilItIsInvalidated() async {
    let harness = Harness()
    defer { harness.stop() }
    let client = harness.client()
    defer { client.invalidate() }
    #expect(harness.connectionsMade == 0)
    #expect(harness.connections == 0)
    _ = await client.set(true)
    _ = await client.status(appVersion: 1)
    _ = await client.status(appVersion: 1)
    _ = await client.set(false)
    #expect(harness.connectionsMade == 1)
    #expect(harness.connections == 1)
    client.invalidate()
    #expect(await OffPool.eventually { harness.connections == 0 })
    #expect(!Self.isFailed(await client.status(appVersion: 1)))
    #expect(harness.connectionsMade == 2)
    #expect(harness.connections == 1)
  }

  @Test func endingTheClientsConnectionAfterAnOwnedSetReleasesTheHold() async {
    let harness = Harness()
    defer { harness.stop() }
    let client = harness.client()
    #expect(await client.set(true) == .success(HelperReply(code: .owned, message: "owned")))
    harness.fake.forget()
    client.invalidate()
    #expect(await OffPool.eventually { harness.fake.logLines.contains(Self.connectionRelease) })
    #expect(harness.fake.pmsetWrites == [false])
    #expect(harness.fake.edgeCount == 1)
    #expect(harness.fake.storedRecord?.owns == false)
    #expect(harness.connections == 0)
  }

  static let holderRule: Comment =
    "03-REVIEW.md H-WR-02: only the connection that engaged refreshes the heartbeat, and the end of that connection releases"
  static let clearRule: Comment =
    "03-REVIEW.md H-WR-02: a clear is still accepted from any connection that passes the requirement"
  static let heartbeatRelease = "release reason=heartbeat sleepDisabled=0 edge=done"

  static func engagedStatus(_ result: HelperCallResult<HelperStatus>) -> Bool? {
    guard case .success(let status) = result else { return nil }
    return status.engaged
  }

  @Test func theEndOfTheConnectionThatEngagedReleasesWhileAnotherConnectionStaysOpen() async {
    let harness = Harness()
    defer { harness.stop() }
    let holder = harness.client()
    let other = harness.client()
    defer { other.invalidate() }
    #expect(await holder.set(true) == .success(HelperReply(code: .owned, message: "owned")))
    #expect(Self.engagedStatus(await other.status(appVersion: 1)) == true)
    #expect(harness.connections == 2)
    harness.fake.forget()
    holder.invalidate()
    #expect(await OffPool.eventually { harness.fake.logLines.contains(Self.connectionRelease) }, Self.holderRule)
    #expect(harness.fake.pmsetWrites == [false], Self.holderRule)
    #expect(harness.fake.edgeCount == 1, Self.holderRule)
    #expect(harness.fake.sleepDisabled == false, Self.holderRule)
    #expect(harness.fake.storedRecord?.owns == false, Self.holderRule)
    #expect(await OffPool.eventually { harness.connections == 1 })
    #expect(Self.engagedStatus(await other.status(appVersion: 1)) == false, Self.holderRule)
  }

  @Test func theEndOfAnotherConnectionKeepsTheHoldOfTheConnectionThatEngaged() async {
    let harness = Harness()
    defer { harness.stop() }
    let holder = harness.client()
    let other = harness.client()
    #expect(await holder.set(true) == .success(HelperReply(code: .owned, message: "owned")))
    #expect(Self.engagedStatus(await other.status(appVersion: 1)) == true)
    #expect(harness.connections == 2)
    harness.fake.forget()
    other.invalidate()
    #expect(await OffPool.eventually { harness.connections == 1 })
    await harness.settle()
    #expect(harness.fake.holdCalls.isEmpty, Self.holderRule)
    #expect(harness.fake.sleepDisabled == true, Self.holderRule)
    holder.invalidate()
    #expect(await OffPool.eventually { harness.fake.logLines.contains(Self.connectionRelease) }, Self.holderRule)
    #expect(harness.fake.pmsetWrites == [false])
    #expect(await OffPool.eventually { harness.connections == 0 })
  }

  @Test func aStatusFromAnotherConnectionAnswersAndDoesNotRefreshTheHeartbeat() async {
    let harness = Harness()
    defer { harness.stop() }
    let holder = harness.client()
    defer { holder.invalidate() }
    let other = harness.client()
    defer { other.invalidate() }
    #expect(await holder.set(true) == .success(HelperReply(code: .owned, message: "owned")))
    harness.fake.forget()
    harness.fake.advance(seconds: 54)
    #expect(Self.engagedStatus(await other.status(appVersion: 1)) == true, Self.holderRule)
    #expect(Self.engagedStatus(await other.status(appVersion: 1)) == true, Self.holderRule)
    harness.watch()
    #expect(harness.fake.pmsetWrites.isEmpty)
    harness.fake.advance(seconds: 1)
    harness.watch()
    #expect(harness.fake.logLines.contains(Self.heartbeatRelease), Self.holderRule)
    #expect(harness.fake.pmsetWrites == [false], Self.holderRule)
    #expect(harness.fake.sleepDisabled == false, Self.holderRule)
    #expect(harness.connections == 2)
  }

  @Test func aStatusFromTheConnectionThatEngagedRefreshesTheHeartbeat() async {
    let harness = Harness()
    defer { harness.stop() }
    let holder = harness.client()
    defer { holder.invalidate() }
    let other = harness.client()
    defer { other.invalidate() }
    #expect(await holder.set(true) == .success(HelperReply(code: .owned, message: "owned")))
    #expect(Self.engagedStatus(await other.status(appVersion: 1)) == true)
    harness.fake.forget()
    harness.fake.advance(seconds: 54)
    #expect(Self.engagedStatus(await holder.status(appVersion: 1)) == true, Self.holderRule)
    harness.fake.advance(seconds: 54)
    harness.watch()
    #expect(harness.fake.pmsetWrites.isEmpty, Self.holderRule)
    #expect(harness.fake.sleepDisabled == true, Self.holderRule)
    harness.fake.advance(seconds: 1)
    harness.watch()
    #expect(harness.fake.logLines.contains(Self.heartbeatRelease), Self.holderRule)
  }

  @Test func aClearFromAnotherConnectionIsAcceptedAndTheLaterEndOfEitherConnectionDoesNothingMore() async {
    let harness = Harness()
    defer { harness.stop() }
    let holder = harness.client()
    let other = harness.client()
    #expect(await holder.set(true) == .success(HelperReply(code: .owned, message: "owned")))
    harness.fake.forget()
    #expect(await other.set(false) == .success(HelperReply(code: .cleared, message: "cleared")), Self.clearRule)
    #expect(harness.fake.pmsetWrites == [false], Self.clearRule)
    #expect(harness.fake.edgeCount == 1, Self.clearRule)
    #expect(harness.fake.sleepDisabled == false, Self.clearRule)
    #expect(harness.fake.storedRecord?.owns == false, Self.clearRule)
    #expect(Self.engagedStatus(await holder.status(appVersion: 1)) == false, Self.clearRule)
    harness.fake.forget()
    other.invalidate()
    #expect(await OffPool.eventually { harness.connections == 1 })
    holder.invalidate()
    #expect(await OffPool.eventually { harness.connections == 0 })
    await harness.settle()
    #expect(harness.fake.calls.isEmpty)
  }

  @Test func aSetFromAnotherConnectionMovesTheHoldToThatConnection() async {
    let harness = Harness()
    defer { harness.stop() }
    let first = harness.client()
    let second = harness.client()
    #expect(await first.set(true) == .success(HelperReply(code: .owned, message: "owned")))
    #expect(await second.set(true) == .success(HelperReply(code: .owned, message: "owned")))
    harness.fake.forget()
    first.invalidate()
    #expect(await OffPool.eventually { harness.connections == 1 })
    await harness.settle()
    #expect(harness.fake.holdCalls.isEmpty, Self.holderRule)
    #expect(harness.fake.sleepDisabled == true, Self.holderRule)
    second.invalidate()
    #expect(await OffPool.eventually { harness.fake.logLines.contains(Self.connectionRelease) }, Self.holderRule)
    #expect(harness.fake.pmsetWrites == [false])
  }

  @Test func anInterruptionFollowedByAnInvalidationCountsTheConnectionOnce() async {
    let harness = Harness()
    defer { harness.stop() }
    let spy = AcceptSpy(inner: harness.service)
    harness.listener.delegate = spy
    let holder = harness.client()
    defer { holder.invalidate() }
    let other = harness.client()
    defer { other.invalidate() }
    #expect(await holder.set(true) == .success(HelperReply(code: .owned, message: "owned")))
    #expect(!Self.isFailed(await other.status(appVersion: 1)))
    #expect(spy.connections.count == 2)
    #expect(harness.connections == 2)
    harness.fake.forget()
    spy.connections[1].interruptionHandler?()
    #expect(await OffPool.eventually { spy.invalidations == 1 })
    await harness.settle()
    #expect(harness.connections == 1)
    #expect(harness.fake.holdCalls.isEmpty)
    #expect(harness.fake.sleepDisabled == true)
  }

  @Test func anInterruptionOfTheConnectionThatEngagedReleasesOnce() async {
    let harness = Harness()
    defer { harness.stop() }
    let spy = AcceptSpy(inner: harness.service)
    harness.listener.delegate = spy
    let holder = harness.client()
    defer { holder.invalidate() }
    let other = harness.client()
    defer { other.invalidate() }
    #expect(await holder.set(true) == .success(HelperReply(code: .owned, message: "owned")))
    #expect(!Self.isFailed(await other.status(appVersion: 1)))
    #expect(spy.connections.count == 2)
    harness.fake.forget()
    spy.connections[0].interruptionHandler?()
    #expect(await OffPool.eventually { spy.invalidations == 1 })
    await harness.settle()
    #expect(harness.connections == 1)
    #expect(harness.fake.logLines == [Self.connectionRelease], Self.holderRule)
    #expect(harness.fake.pmsetWrites == [false], Self.holderRule)
    #expect(harness.fake.sleepDisabled == false, Self.holderRule)
  }

  @Test(arguments: [HelperIdentity.release, HelperIdentity.dev])
  func aCallerThatFailsTheAppRequirementIsRefusedBeforeTheMachineRuns(identity: HelperIdentity) async {
    let harness = Harness(listenerRequirement: identity.appRequirement)
    defer { harness.stop() }
    let client = harness.client()
    defer { client.invalidate() }
    #expect(await client.set(true) == .failed(Self.refusedByListener))
    #expect(await client.status(appVersion: 1) == .failed(Self.refusedByListener))
    #expect(await client.set(false) == .failed(Self.refusedByListener))
    await harness.settle()
    #expect(harness.fake.calls.isEmpty)
    #expect(harness.probe.onQueue == 0)
    #expect(harness.probe.offQueue == 0)
    #expect(harness.connections == 0)
    #expect(harness.exitCount == 0)
  }

  @Test(arguments: [HelperIdentity.release, HelperIdentity.dev])
  func aClientThatRequiresTheRealHelperRejectsTheReplyOfAHelperThatAlreadyRan(identity: HelperIdentity) async {
    let harness = Harness()
    defer { harness.stop() }
    let client = harness.client(requirement: identity.helperRequirement)
    defer { client.invalidate() }
    #expect(await client.set(true) == .failed(Self.replyRefusedByClient))
    #expect(await OffPool.eventually { harness.fake.logLines.contains(Self.connectionRelease) })
    #expect(harness.fake.holdCalls.prefix(4) == Self.ownedSet[...])
    #expect(harness.fake.pmsetWrites == [true, false])
    #expect(harness.fake.sleepDisabled == false)
    #expect(harness.connections == 0)
  }

  @Test func aHelperThatNeverRepliesTimesOutTheCallWithinItsBound() async {
    let helper = ScriptedHelper(.silent)
    defer { helper.listener.invalidate() }
    let client = helper.client(timeoutSeconds: 1)
    defer { client.invalidate() }
    let started = Date()
    let raw = client.client
    #expect(await OffPool.bounded(seconds: 30) { raw.set(true) } == .timedOut)
    let elapsed = Date().timeIntervalSince(started)
    #expect(elapsed >= 0.9)
    #expect(elapsed < 10)
    #expect(helper.callsHeld == 1)
    #expect(helper.connectionsMade == 1)
    #expect(await OffPool.bounded(seconds: 30) { raw.status(appVersion: 1) } == .timedOut)
    #expect(helper.callsHeld == 2)
    #expect(helper.connectionsMade == 2)
  }

  @Test func anUnknownReplyCodeOrAnUndecodableStatusFailsTheCallAndDropsTheConnection() async {
    let helper = ScriptedHelper(.garbage)
    defer { helper.listener.invalidate() }
    let client = helper.client(timeoutSeconds: 5)
    defer { client.invalidate() }
    #expect(await client.set(true) == .failed("replyCode 9"))
    #expect(helper.connectionsMade == 1)
    #expect(await client.status(appVersion: 1) == .failed("undecodableStatus"))
    #expect(helper.connectionsMade == 2)
  }

  @Test func aSetThatArrivesOutsideALiveConnectionIsRefusedAndTouchesNothing() async {
    let harness = Harness()
    defer { harness.stop() }
    #expect(await Self.direct(harness.service, true) == HelperReply(code: .refused, message: "connection"))
    #expect(harness.fake.calls == [.log("set refused reason=connection")])
    #expect(await Self.direct(harness.service, false) == HelperReply(code: .cleared, message: "cleared"))
    #expect(harness.fake.holdCalls.isEmpty)
  }

  @Test func aSetFromAConnectionTheServiceNoLongerCountsIsRefused() async {
    let harness = Harness()
    defer { harness.stop() }
    let spy = AcceptSpy(inner: harness.service)
    harness.listener.delegate = spy
    let client = harness.client()
    defer { client.invalidate() }
    #expect(!Self.isFailed(await client.status(appVersion: 1)))
    #expect(spy.connections.count == 1)
    spy.connections[0].invalidationHandler?()
    #expect(await OffPool.eventually { harness.connections == 0 })
    harness.fake.forget()
    #expect(await client.set(true) == .success(HelperReply(code: .refused, message: "connection")))
    #expect(harness.fake.calls == [.log("set refused reason=connection")])
    #expect(await client.set(false) == .success(HelperReply(code: .cleared, message: "cleared")))
    #expect(harness.fake.pmsetWrites.isEmpty)
  }

  @Test func everyCallAndEveryConnectionEndRunsOnTheMachinesQueue() async {
    let harness = Harness()
    defer { harness.stop() }
    let client = harness.client()
    var seen = harness.probe.onQueue
    #expect(seen == 0)
    _ = await client.set(true)
    #expect(harness.probe.onQueue > seen)
    seen = harness.probe.onQueue
    _ = await client.status(appVersion: 1)
    #expect(harness.probe.onQueue > seen)
    seen = harness.probe.onQueue
    _ = await client.set(false)
    #expect(harness.probe.onQueue > seen)
    _ = await client.set(true)
    harness.fake.forget()
    seen = harness.probe.onQueue
    client.invalidate()
    #expect(await OffPool.eventually { harness.fake.logLines.contains(Self.connectionRelease) })
    #expect(harness.probe.onQueue > seen)
    #expect(harness.probe.offQueue == 0)
  }

  @Test func theShellHearsOfEveryCallAndConnectionEndOnTheQueueOnceTheMachineHasChanged() async {
    let harness = Harness()
    defer { harness.stop() }
    let client = harness.client()
    let watching = ShellEvent(needsWatch: true, onQueue: true)
    let idle = ShellEvent(needsWatch: false, onQueue: true)
    #expect(harness.shellEvents.isEmpty)
    _ = await client.set(true)
    #expect(await OffPool.eventually { harness.shellEvents == [watching] })
    _ = await client.status(appVersion: HelperIdentity.version)
    #expect(await OffPool.eventually { harness.shellEvents == [watching, watching] })
    _ = await client.set(false)
    #expect(await OffPool.eventually { harness.shellEvents == [watching, watching, idle] })
    _ = await client.set(true)
    #expect(await OffPool.eventually { harness.shellEvents == [watching, watching, idle, watching] })
    client.invalidate()
    #expect(await OffPool.eventually { harness.shellEvents == [watching, watching, idle, watching, idle] })
    await harness.settle()
    #expect(harness.shellEvents.count == 5)
  }

  @Test func aRefusedSetAlsoReachesTheShellAndLeavesTheWatchOff() async {
    let harness = Harness(lid: false)
    defer { harness.stop() }
    let client = harness.client()
    defer { client.invalidate() }
    #expect(await client.set(true) == .success(HelperReply(code: .refused, message: "lidOpen")))
    #expect(await OffPool.eventually { harness.shellEvents == [ShellEvent(needsWatch: false, onQueue: true)] })
  }

  @Test func theExitRequestComesBeforeTheShellHearsOfTheCallThatCausedIt() async {
    let harness = Harness()
    defer { harness.stop() }
    let client = harness.client()
    defer { client.invalidate() }
    _ = await client.status(appVersion: HelperIdentity.version + 1)
    let leaving = ShellEvent(needsWatch: false, onQueue: true, exitAsked: true)
    #expect(await OffPool.eventually { harness.shellEvents == [leaving] })
    #expect(harness.exitCount == 1)
  }

  @Test func aStaleIdleHelperRepliesAndThenAsksToExitOnce() async {
    let harness = Harness()
    defer { harness.stop() }
    let client = harness.client()
    defer { client.invalidate() }
    let answer = await client.status(appVersion: HelperIdentity.version + 1)
    guard case .success(let status) = answer else {
      Issue.record("status did not succeed: \(answer)")
      return
    }
    #expect(status.exiting)
    #expect(status.helperVersion == 1)
    #expect(await OffPool.eventually { harness.exitCount == 1 })
    _ = await client.status(appVersion: HelperIdentity.version + 1)
    #expect(await client.set(true) == .success(HelperReply(code: .refused, message: "exiting")))
    await harness.settle()
    #expect(harness.exitCount == 1)
    #expect(harness.fake.holdCalls == [.readSleepDisabled, .readSleepDisabled])
  }

  @Test func aStaleEngagedHelperAsksToExitOnlyAfterItsClear() async {
    let harness = Harness()
    defer { harness.stop() }
    let client = harness.client()
    defer { client.invalidate() }
    _ = await client.set(true)
    let answer = await client.status(appVersion: HelperIdentity.version + 1)
    guard case .success(let status) = answer else {
      Issue.record("status did not succeed: \(answer)")
      return
    }
    #expect(!status.exiting)
    await harness.settle()
    #expect(harness.exitCount == 0)
    #expect(await client.set(false) == .success(HelperReply(code: .cleared, message: "cleared")))
    #expect(await OffPool.eventually { harness.exitCount == 1 })
  }

  @Test func aStaleEngagedHelperAsksToExitWhenTheConnectionThatEngagedEnds() async {
    let harness = Harness()
    defer { harness.stop() }
    let client = harness.client()
    _ = await client.set(true)
    _ = await client.status(appVersion: HelperIdentity.version + 1)
    await harness.settle()
    #expect(harness.exitCount == 0)
    client.invalidate()
    #expect(await OffPool.eventually { harness.exitCount == 1 })
    #expect(harness.fake.logLines.contains(Self.connectionRelease))
    await harness.settle()
    #expect(harness.exitCount == 1)
  }

  @Test func thePrivilegedClientPinsTheHelperRequirementOfItsIdentityAndTheFiveSecondBound() {
    for identity in [HelperIdentity.release, HelperIdentity.dev] {
      let client = HelperXPCClient.privileged(identity: identity)
      #expect(client.requirement == identity.helperRequirement)
      #expect(client.timeoutSeconds == 5)
    }
    #expect(HelperXPCClient.defaultTimeoutSeconds == 5)
  }

  @Test func theProtocolExposesExactlySetAndStatusWithABoolAndAnIntegerInput() {
    var methods: [String: String] = [:]
    for required in [true, false] {
      for instance in [true, false] {
        var count: UInt32 = 0
        guard let list = protocol_copyMethodDescriptionList(HelperXPCProtocol.self, required, instance, &count)
        else { continue }
        for index in 0..<Int(count) {
          guard let name = list[index].name, let types = list[index].types else { continue }
          methods[NSStringFromSelector(name)] = String(cString: types)
        }
        free(list)
      }
    }
    #expect(methods.keys.sorted() == ["setSleepDisabled:reply:", "statusWithAppHelperVersion:reply:"])
    #expect(methods["setSleepDisabled:reply:"] == "v28@0:8B16@?20")
    #expect(methods["statusWithAppHelperVersion:reply:"] == "v32@0:8q16@?24")
  }
}
