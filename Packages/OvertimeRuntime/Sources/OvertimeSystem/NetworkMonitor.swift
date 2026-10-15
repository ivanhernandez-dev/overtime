import Foundation
import OvertimeCore
import SystemConfiguration
import os

public protocol NetworkStoreSource: Sendable {
  func start(queue: DispatchQueue, onChange: @escaping @Sendable ([String]) -> Void) -> Bool
  func watchWiFi(interface: String?)
  func interfaces() -> [NetworkInterfaceInfo]
  func copyStore() -> [String: Any]?
  func stop()
}

public final class SystemNetworkStore: NetworkStoreSource, @unchecked Sendable {
  static let storeName = "io.github.ivanhernandez-dev.overtime.network"

  private let lock = NSLock()
  private var store: SCDynamicStore?
  private var onChange: (@Sendable ([String]) -> Void)?
  private var wifi: String?

  public init() {}

  public func start(queue: DispatchQueue, onChange: @escaping @Sendable ([String]) -> Void) -> Bool {
    stop()
    var context = SCDynamicStoreContext(
      version: 0,
      info: Unmanaged.passUnretained(self).toOpaque(),
      retain: { info in
        _ = Unmanaged<SystemNetworkStore>.fromOpaque(info).retain()
        return info
      },
      release: { info in
        Unmanaged<SystemNetworkStore>.fromOpaque(info).release()
      },
      copyDescription: nil
    )
    let callback: SCDynamicStoreCallBack = { _, changed, info in
      guard let info else { return }
      let source = Unmanaged<SystemNetworkStore>.fromOpaque(info).takeUnretainedValue()
      source.deliver((changed as? [String]) ?? [])
    }
    guard let created = SCDynamicStoreCreate(nil, Self.storeName as CFString, callback, &context) else {
      return false
    }
    let watched = lock.withLock { () -> String? in
      self.store = created
      self.onChange = onChange
      return self.wifi
    }
    guard SCDynamicStoreSetNotificationKeys(created, Self.keys(wifi: watched) as CFArray, Self.patterns as CFArray),
      SCDynamicStoreSetDispatchQueue(created, queue)
    else {
      stop()
      return false
    }
    return true
  }

  public func watchWiFi(interface: String?) {
    let current = lock.withLock { () -> SCDynamicStore? in
      self.wifi = interface
      return self.store
    }
    guard let current else { return }
    _ = SCDynamicStoreSetNotificationKeys(current, Self.keys(wifi: interface) as CFArray, Self.patterns as CFArray)
  }

  public func interfaces() -> [NetworkInterfaceInfo] {
    let all = (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? []
    return all.compactMap { interface in
      guard let name = SCNetworkInterfaceGetBSDName(interface) as String?,
        let type = SCNetworkInterfaceGetInterfaceType(interface) as String?
      else { return nil }
      return NetworkInterfaceInfo(bsdName: name, type: type)
    }
  }

  public func copyStore() -> [String: Any]? {
    let (current, watched) = lock.withLock { (self.store, self.wifi) }
    guard let reader = current ?? SCDynamicStoreCreate(nil, Self.storeName as CFString, nil, nil) else { return nil }
    return SCDynamicStoreCopyMultiple(reader, Self.keys(wifi: watched) as CFArray, Self.patterns as CFArray)
      as? [String: Any]
  }

  public func stop() {
    let current = lock.withLock { () -> SCDynamicStore? in
      let current = self.store
      self.store = nil
      self.onChange = nil
      return current
    }
    guard let current else { return }
    SCDynamicStoreSetDispatchQueue(current, nil)
  }

  static func keys(wifi: String?) -> [String] {
    [NetworkFactsParser.interfaceListKey] + (wifi.map { [NetworkFactsParser.airPortKey($0)] } ?? [])
  }

  static let patterns = [NetworkFactsParser.interfaceIPv4Pattern, NetworkFactsParser.serviceIPv4Pattern]

  private func deliver(_ changed: [String]) {
    let handler = lock.withLock { self.onChange }
    handler?(changed)
  }
}

public final class NetworkMonitor: @unchecked Sendable {
  private struct Cache: Sendable {
    var interfaces: [NetworkInterfaceInfo] = []
    var watchedWiFi: String??
    var parsed: NetworkFacts?
    var candidate: String?
    var autoDetect = false
    var generation: UInt64 = 0
    var lastLidClosed: Bool?

    var facts: NetworkFacts? {
      guard var facts = parsed else { return nil }
      facts.autoHotspot = candidate
      return facts
    }
  }

  public static let knownNetworksRunnerKey = "wifi.known"

  private let source: any NetworkStoreSource
  private let knownNetworks: @Sendable () -> [String]?
  private let readTimeoutSeconds: Double
  private let onFactsChange: @Sendable () -> Void
  private let queue = DispatchQueue(label: "io.github.ivanhernandez-dev.overtime.network-monitor")
  private let readQueue = DispatchQueue(label: "io.github.ivanhernandez-dev.overtime.known-networks")
  private let runner = DeadlineRunner()
  private let cache: OSAllocatedUnfairLock<Cache>

  public init(
    source: any NetworkStoreSource = SystemNetworkStore(),
    knownNetworks: @escaping @Sendable () -> [String]? = KnownNetworks.names,
    readTimeoutSeconds: Double = Timing.systemCallTimeoutSeconds,
    onFactsChange: @escaping @Sendable () -> Void = {}
  ) {
    self.source = source
    self.knownNetworks = knownNetworks
    self.readTimeoutSeconds = readTimeoutSeconds
    self.onFactsChange = onFactsChange
    cache = OSAllocatedUnfairLock(initialState: Cache())
  }

  @discardableResult
  public func start() -> Bool {
    let started = source.start(queue: queue) { [weak self] changed in
      self?.refresh(changed: changed)
    }
    queue.sync { refresh(changed: []) }
    return started
  }

  public func stop() {
    source.stop()
  }

  public func facts(lidClosed: Bool?) -> NetworkFacts? {
    let (facts, read) = cache.withLock { cache -> (NetworkFacts?, UInt64?) in
      let edge = lidClosed == true && cache.lastLidClosed != true
      cache.lastLidClosed = lidClosed
      guard edge, cache.autoDetect else { return (cache.facts, nil) }
      cache.generation &+= 1
      return (cache.facts, cache.generation)
    }
    if let read {
      readKnownNetworks(generation: read)
    }
    return facts
  }

  public func autoDetectInUse(_ inUse: Bool) {
    let read = update { cache -> UInt64? in
      cache.autoDetect = inUse
      cache.generation &+= 1
      guard inUse else {
        cache.candidate = nil
        return nil
      }
      return cache.generation
    }
    if let read {
      readKnownNetworks(generation: read)
    }
  }

  @discardableResult
  private func update<Result: Sendable>(_ body: @Sendable (inout Cache) -> Result) -> Result {
    let (before, result, after) = cache.withLock { cache in
      let before = cache.facts
      let result = body(&cache)
      return (before, result, cache.facts)
    }
    if before != after {
      onFactsChange()
    }
    return result
  }

  private func readKnownNetworks(generation: UInt64) {
    let runner = runner
    let knownNetworks = knownNetworks
    let timeout = readTimeoutSeconds
    readQueue.async { [weak self] in
      let names: [String]?
      switch runner.run(timeout: timeout, key: Self.knownNetworksRunnerKey, knownNetworks) {
      case .value(let read):
        names = read
      case .timedOut:
        names = nil
      }
      let candidate = KnownNetworks.autoHotspot(in: names)
      self?.update { cache in
        guard cache.generation == generation, cache.autoDetect else { return }
        cache.candidate = candidate
      }
    }
  }

  private func refresh(changed: [String]) {
    if changed.isEmpty || changed.contains(NetworkFactsParser.interfaceListKey) {
      let interfaces = source.interfaces()
      cache.withLock { $0.interfaces = interfaces }
    }
    let (interfaces, watched) = cache.withLock { ($0.interfaces, $0.watchedWiFi) }
    let wifi = interfaces.first { $0.type == NetworkFactsParser.wifiType }?.bsdName
    if watched != .some(wifi) {
      source.watchWiFi(interface: wifi)
      cache.withLock { $0.watchedWiFi = .some(wifi) }
    }
    let store = source.copyStore()
    let parsed = store.map { NetworkFactsParser.parse(interfaces: interfaces, store: $0) }
    update { $0.parsed = parsed }
  }
}
