import Foundation
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import os

struct NetworkFixture: @unchecked Sendable {
  enum LoadError: Error {
    case missing(String)
    case malformed(String)
  }

  let interfaces: [NetworkInterfaceInfo]
  let store: [String: Any]

  static func url(_ name: String) throws -> URL {
    guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "network") else {
      throw LoadError.missing(name)
    }
    return url
  }

  static func object(_ name: String) throws -> [String: Any] {
    let data = try Data(contentsOf: try url(name))
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw LoadError.malformed(name)
    }
    return object
  }

  static func capture() throws -> NetworkFixture {
    try NetworkFixture(object: try object("capture"), name: "capture")
  }

  static func synthetic() throws -> [String: NetworkFixture] {
    var cases: [String: NetworkFixture] = [:]
    for (name, value) in try object("synthetic") {
      guard let object = value as? [String: Any] else { throw LoadError.malformed(name) }
      cases[name] = try NetworkFixture(object: object, name: name)
    }
    return cases
  }

  init(interfaces: [NetworkInterfaceInfo], store: [String: Any]) {
    self.interfaces = interfaces
    self.store = store
  }

  init(object: [String: Any], name: String) throws {
    guard let list = object["interfaces"] as? [[String: Any]], let store = object["store"] as? [String: Any] else {
      throw LoadError.malformed(name)
    }
    interfaces = try list.map { entry in
      guard let bsdName = entry["bsdName"] as? String, let type = entry["type"] as? String else {
        throw LoadError.malformed(name)
      }
      return NetworkInterfaceInfo(bsdName: bsdName, type: type)
    }
    self.store = store
  }

  var facts: NetworkFacts {
    NetworkFactsParser.parse(interfaces: interfaces, store: store)
  }
}

final class FakeNetworkStore: NetworkStoreSource, @unchecked Sendable {
  private let lock = NSLock()
  private var interfaceList: [NetworkInterfaceInfo]
  private var storeContents: [String: Any]
  private var failing = false
  private var startResult = true
  private var copies = 0
  private var interfaceReads = 0
  private var watchedInterfaces: [String?] = []
  private var handler: (@Sendable ([String]) -> Void)?
  private var handlerQueue: DispatchQueue?
  private var stops = 0
  private var starts = 0
  private var startGate: DispatchSemaphore?
  private var calls: [String] = []

  init(interfaces: [NetworkInterfaceInfo] = [], store: [String: Any] = [:]) {
    interfaceList = interfaces
    storeContents = store
  }

  convenience init(_ fixture: NetworkFixture) {
    self.init(interfaces: fixture.interfaces, store: fixture.store)
  }

  var copyCount: Int { lock.withLock { copies } }
  var interfaceReadCount: Int { lock.withLock { interfaceReads } }
  var watched: [String?] { lock.withLock { watchedInterfaces } }
  var stopCount: Int { lock.withLock { stops } }
  var isStarted: Bool { lock.withLock { handler != nil } }
  var callLog: [String] { lock.withLock { calls } }

  func serve(_ fixture: NetworkFixture) {
    lock.withLock {
      interfaceList = fixture.interfaces
      storeContents = fixture.store
    }
  }

  func serve(store: [String: Any]) {
    lock.withLock { storeContents = store }
  }

  func failReads(_ fail: Bool) {
    lock.withLock { failing = fail }
  }

  func refuseStart(_ refuse: Bool = true) {
    lock.withLock { startResult = !refuse }
  }

  func holdStarts() {
    lock.withLock { startGate = DispatchSemaphore(value: 0) }
  }

  func releaseStarts() {
    let gate = lock.withLock { () -> DispatchSemaphore? in
      defer { startGate = nil }
      return startGate
    }
    for _ in 0..<16 {
      gate?.signal()
    }
  }

  var startCount: Int { lock.withLock { starts } }

  func fire(_ keys: [String]) {
    let (handler, queue) = lock.withLock { (self.handler, self.handlerQueue) }
    guard let handler, let queue else { return }
    queue.sync { handler(keys) }
  }

  func start(queue: DispatchQueue, onChange: @escaping @Sendable ([String]) -> Void) -> Bool {
    let gate = lock.withLock { () -> DispatchSemaphore? in
      starts += 1
      return startGate
    }
    gate?.wait()
    return lock.withLock {
      handler = onChange
      handlerQueue = queue
      return startResult
    }
  }

  func watchWiFi(interface: String?) {
    lock.withLock {
      watchedInterfaces.append(interface)
      calls.append("watch \(interface ?? "none")")
    }
  }

  func interfaces() -> [NetworkInterfaceInfo] {
    lock.withLock {
      interfaceReads += 1
      calls.append("interfaces")
      return interfaceList
    }
  }

  func copyStore() -> [String: Any]? {
    lock.withLock {
      copies += 1
      calls.append("copy")
      return failing ? nil : storeContents
    }
  }

  func stop() {
    lock.withLock {
      stops += 1
      handler = nil
      handlerQueue = nil
    }
  }
}

struct ClosureNetworkPort: NetworkPort {
  var onFacts: @Sendable (Bool?) -> NetworkFacts? = { _ in nil }
  var onAutoDetect: @Sendable (Bool) -> Void = { _ in }
  var onProbe: @Sendable () -> Bool = { false }
  var onJoin: @Sendable (String) -> EffectOutcome = { _ in .failed(code: NoNetworkPort.disabledCode) }
  var onCycle: @Sendable () -> EffectOutcome = { .failed(code: NoNetworkPort.disabledCode) }
  var onRecover: @Sendable () -> EffectOutcome = { .succeeded }
  var onAttach: @Sendable (@escaping @Sendable (Decision) -> Void) -> Void = { _ in }
  let recoveries = OSAllocatedUnfairLock(initialState: 0)

  var recoverCount: Int {
    recoveries.withLock { $0 }
  }

  func facts(lidClosed: Bool?) -> NetworkFacts? {
    onFacts(lidClosed)
  }

  func recoverIfLeftOff() -> EffectOutcome {
    recoveries.withLock { $0 += 1 }
    return onRecover()
  }

  func attachLog(_ log: @escaping @Sendable (Decision) -> Void) {
    onAttach(log)
  }

  func autoDetectInUse(_ inUse: Bool) {
    onAutoDetect(inUse)
  }

  func probe() -> Bool {
    onProbe()
  }

  func joinHotspot(_ name: String) -> EffectOutcome {
    onJoin(name)
  }

  func cycleWifi() -> EffectOutcome {
    onCycle()
  }
}

final class BlockingNetworkPort: NetworkPort, Sendable {
  enum Action: String, Sendable {
    case probe
    case join
    case cycle
  }

  private struct Script: Sendable {
    var facts: NetworkFacts?
    var blocking: Set<Action>
    var released = false
    var waiting = 0
    var probeAnswers: [Bool] = []
    var defaultProbe = false
    var joinOutcome = EffectOutcome.succeeded
    var cycleOutcome = EffectOutcome.succeeded
    var started: [Action] = []
    var finished: [Action] = []
  }

  private let script: OSAllocatedUnfairLock<Script>
  private let gate = DispatchSemaphore(value: 0)

  init(facts: NetworkFacts? = nil, blocking: Set<Action> = [.probe, .join, .cycle]) {
    script = OSAllocatedUnfairLock(initialState: Script(facts: facts, blocking: blocking))
  }

  func answerProbes(_ answers: [Bool], otherwise: Bool = false) {
    script.withLock { script in
      script.probeAnswers = answers
      script.defaultProbe = otherwise
    }
  }

  func answerJoin(_ outcome: EffectOutcome) {
    script.withLock { $0.joinOutcome = outcome }
  }

  func answerCycle(_ outcome: EffectOutcome) {
    script.withLock { $0.cycleOutcome = outcome }
  }

  func release() {
    let waiting = script.withLock { script -> Int in
      script.released = true
      defer { script.waiting = 0 }
      return script.waiting
    }
    for _ in 0..<waiting {
      gate.signal()
    }
  }

  var started: [Action] {
    script.withLock { $0.started }
  }

  var finished: [Action] {
    script.withLock { $0.finished }
  }

  func count(_ action: Action) -> Int {
    started.filter { $0 == action }.count
  }

  private func enter(_ action: Action) {
    let blocks = script.withLock { script -> Bool in
      script.started.append(action)
      guard script.blocking.contains(action), !script.released else { return false }
      script.waiting += 1
      return true
    }
    if blocks { gate.wait() }
  }

  private func leave(_ action: Action) {
    script.withLock { $0.finished.append(action) }
  }

  func facts(lidClosed: Bool?) -> NetworkFacts? {
    script.withLock { $0.facts }
  }

  func autoDetectInUse(_ inUse: Bool) {}

  func probe() -> Bool {
    enter(.probe)
    defer { leave(.probe) }
    return script.withLock { script -> Bool in
      guard !script.probeAnswers.isEmpty else { return script.defaultProbe }
      return script.probeAnswers.removeFirst()
    }
  }

  func joinHotspot(_ name: String) -> EffectOutcome {
    enter(.join)
    defer { leave(.join) }
    return script.withLock { $0.joinOutcome }
  }

  func cycleWifi() -> EffectOutcome {
    enter(.cycle)
    defer { leave(.cycle) }
    return script.withLock { $0.cycleOutcome }
  }

  func recoverIfLeftOff() -> EffectOutcome {
    .succeeded
  }
}

final class NetworkEventCollector: Sendable {
  private let box: OSAllocatedUnfairLock<[Event]>
  private let task: Task<Void, Never>

  init(_ stream: AsyncStream<Event>) {
    let box = OSAllocatedUnfairLock<[Event]>(initialState: [])
    self.box = box
    task = Task {
      for await event in stream {
        box.withLock { $0.append(event) }
      }
    }
  }

  deinit {
    task.cancel()
  }

  var events: [Event] {
    box.withLock { $0 }
  }

  func waitFor(count: Int, seconds: Double = 5) async -> Bool {
    await OffPool.eventually(seconds: seconds) { self.events.count >= count }
  }
}

final class BatchRecordingInterpreter: EffectInterpreter {
  private let inner: LiveInterpreter
  private let results = OSAllocatedUnfairLock<[[Event]]>(initialState: [])

  init(_ inner: LiveInterpreter) {
    self.inner = inner
  }

  var batchResults: [[Event]] {
    results.withLock { $0 }
  }

  var networkEvents: AsyncStream<Event>? {
    inner.networkEvents
  }

  func enqueue(_ effects: [Effect], wall: Date) -> Task<[Event], Never> {
    let batch = inner.enqueue(effects, wall: wall)
    let results = results
    return Task {
      let value = await batch.value
      results.withLock { $0.append(value) }
      return value
    }
  }

  func logNow(_ decision: Decision, wall: Date) {
    inner.logNow(decision, wall: wall)
  }
}
