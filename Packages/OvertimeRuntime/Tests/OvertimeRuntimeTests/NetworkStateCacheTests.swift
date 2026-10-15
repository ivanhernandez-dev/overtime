import Foundation
import OvertimeCore
import OvertimeSystem
import Testing
import os

struct NetworkStateCacheTests {
  final class Counter: Sendable {
    private let value = OSAllocatedUnfairLock(initialState: 0)

    func bump() {
      value.withLock { $0 += 1 }
    }

    var count: Int {
      value.withLock { $0 }
    }
  }

  static let ipv4Key = NetworkFactsParser.interfaceIPv4Key("en0")

  static func started(
    _ fixture: NetworkFixture, changes: Counter = Counter()
  ) async -> (NetworkMonitor, FakeNetworkStore) {
    let store = FakeNetworkStore(fixture)
    let monitor = NetworkMonitor(source: store, knownNetworks: { nil }, onFactsChange: { changes.bump() })
    _ = await OffPool.run { monitor.start() }
    return (monitor, store)
  }

  static func synthetic(_ name: String) throws -> NetworkFixture {
    try #require(try NetworkFixture.synthetic()[name])
  }

  @Test func startingReadsTheInterfacesWatchesTheWiFiAndCopiesTheStoreOnce() async throws {
    let capture = try NetworkFixture.capture()
    let (monitor, store) = await Self.started(capture)
    #expect(store.isStarted)
    #expect(store.callLog == ["interfaces", "watch en0", "copy"])
    #expect(monitor.facts(lidClosed: false) == capture.facts)
  }

  @Test func readingTheFactsManyTimesMakesNoStoreCopyAndNoInterfaceRead() async throws {
    let (monitor, store) = await Self.started(try NetworkFixture.capture())
    for index in 0..<200 {
      _ = monitor.facts(lidClosed: index.isMultiple(of: 2))
    }
    #expect(store.copyCount == 1)
    #expect(store.interfaceReadCount == 1)
  }

  @Test func aChangeWithKeysUpdatesTheCacheFromOneNewStoreCopy() async throws {
    let (monitor, store) = await Self.started(try NetworkFixture.capture())
    let hotspot = try Self.synthetic("hotspotOnly")
    store.serve(store: hotspot.store)
    await OffPool.run { store.fire([Self.ipv4Key]) }
    #expect(store.copyCount == 2)
    #expect(store.interfaceReadCount == 1)
    #expect(monitor.facts(lidClosed: true) == hotspot.facts)
  }

  @Test func aChangeWithNoKeysReReadsTheInterfaceListAndTheStore() async throws {
    let (monitor, store) = await Self.started(try NetworkFixture.capture())
    let noWifi = try Self.synthetic("noWifi")
    store.serve(noWifi)
    await OffPool.run { store.fire([]) }
    #expect(store.interfaceReadCount == 2)
    #expect(store.copyCount == 2)
    #expect(monitor.facts(lidClosed: true) == noWifi.facts)
    #expect(monitor.facts(lidClosed: true)?.wifiInterface == nil)
  }

  @Test func aChangeOfTheInterfaceListReReadsTheInterfaces() async throws {
    let (monitor, store) = await Self.started(try NetworkFixture.capture())
    let tethering = try Self.synthetic("usbTethering")
    store.serve(tethering)
    await OffPool.run { store.fire([NetworkFactsParser.interfaceListKey, Self.ipv4Key]) }
    #expect(store.interfaceReadCount == 2)
    #expect(store.copyCount == 2)
    #expect(monitor.facts(lidClosed: true) == tethering.facts)
  }

  @Test func aFailedStoreCopyHidesTheFactsUntilTheNextGoodRead() async throws {
    let capture = try NetworkFixture.capture()
    let (monitor, store) = await Self.started(capture)
    store.failReads(true)
    await OffPool.run { store.fire([Self.ipv4Key]) }
    #expect(monitor.facts(lidClosed: true) == nil)
    store.failReads(false)
    await OffPool.run { store.fire([Self.ipv4Key]) }
    #expect(monitor.facts(lidClosed: true) == capture.facts)
  }

  @Test func aMonitorWhoseFirstStoreCopyFailsHasNoFacts() async throws {
    let store = FakeNetworkStore(try NetworkFixture.capture())
    store.failReads(true)
    let monitor = NetworkMonitor(source: store, knownNetworks: { nil })
    _ = await OffPool.run { monitor.start() }
    #expect(monitor.facts(lidClosed: false) == nil)
  }

  @Test func theStoreIsToldTheWiFiInterfaceAfterTheFirstReadAndAgainOnlyWhenItChanges() async throws {
    let (monitor, store) = await Self.started(try NetworkFixture.capture())
    defer { withExtendedLifetime(monitor) {} }
    #expect(store.watched == ["en0"])
    await OffPool.run { store.fire([]) }
    #expect(store.watched == ["en0"])
    store.serve(try Self.synthetic("noWifi"))
    await OffPool.run { store.fire([]) }
    #expect(store.watched == ["en0", nil])
    store.serve(try Self.synthetic("hotspotOnly"))
    await OffPool.run { store.fire([NetworkFactsParser.interfaceListKey]) }
    #expect(store.watched == ["en0", nil, "en0"])
    #expect(Array(store.callLog.suffix(3)) == ["interfaces", "watch en0", "copy"])
  }

  @Test func onFactsChangeRunsOncePerChangeThatAltersTheFacts() async throws {
    let changes = Counter()
    let (monitor, store) = await Self.started(try NetworkFixture.capture(), changes: changes)
    defer { withExtendedLifetime(monitor) {} }
    let initial = changes.count
    await OffPool.run { store.fire([Self.ipv4Key]) }
    #expect(changes.count == initial)
    store.serve(store: try Self.synthetic("hotspotOnly").store)
    await OffPool.run { store.fire([Self.ipv4Key]) }
    #expect(changes.count == initial + 1)
    await OffPool.run { store.fire([Self.ipv4Key]) }
    #expect(changes.count == initial + 1)
    store.failReads(true)
    await OffPool.run { store.fire([Self.ipv4Key]) }
    #expect(changes.count == initial + 2)
  }

  @Test func stoppingEndsTheSubscription() async throws {
    let (monitor, store) = await Self.started(try NetworkFixture.capture())
    monitor.stop()
    #expect(store.stopCount == 1)
    #expect(!store.isStarted)
  }

  @Test func theSystemStoreStartsCopiesAndStopsReadOnly() async {
    let monitor = NetworkMonitor(source: SystemNetworkStore(), knownNetworks: { nil })
    let started = await OffPool.run { monitor.start() }
    #expect(started)
    #expect(monitor.facts(lidClosed: nil) != nil)
    monitor.stop()
  }
}
