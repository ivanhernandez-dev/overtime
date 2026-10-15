import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import Testing
import os

struct StartupChecksTests {
  final class Hang: Sendable {
    private struct Counts: Sendable {
      var started = 0
      var returned = 0
    }

    private let gate = DispatchSemaphore(value: 0)
    private let counts = OSAllocatedUnfairLock(initialState: Counts())

    var started: Int { counts.withLock { $0.started } }
    var returned: Int { counts.withLock { $0.returned } }

    func wait() {
      counts.withLock { $0.started += 1 }
      _ = gate.wait(timeout: .now() + 120)
      counts.withLock { $0.returned += 1 }
    }

    func release() {
      for _ in 0..<max(started, 1) {
        gate.signal()
      }
    }
  }

  struct FakeWiFi: WiFiInfoPort {
    var interface: String?
    var networks: [String]?
    var hang: Hang?

    func interfaceName() -> String? {
      hang?.wait()
      return interface
    }

    func knownNetworkNames() -> [String]? {
      hang?.wait()
      return networks
    }
  }

  static let networks = ["Home", "Ivan's iPhone"]

  private func render(_ decisions: [Decision]) -> [String] {
    decisions.map { decision in
      ([decision.keyword.rawValue, decision.verb] + decision.fields.map { "\($0.key)=\($0.value)" })
        .joined(separator: " ")
    }
  }

  @Test func theThreeLinesInOrder() {
    let lines = render(
      StartupChecks.evaluate(
        interface: "en0", knownNetworks: Self.networks, configuredHotspot: "", screenLock: .immediate))
    #expect(
      lines == [
        "CHECK wifi interface=en0",
        "CHECK hotspot known=yes source=autodetect",
        "CHECK screenLock status=immediate",
      ])
  }

  @Test func aConfiguredHotspotIsMatchedByExactName() {
    let present = render(
      StartupChecks.evaluate(
        interface: "en0", knownNetworks: Self.networks, configuredHotspot: "Ivan's iPhone", screenLock: .off))
    #expect(present[1] == "CHECK hotspot known=yes source=configured")
    #expect(present[2] == "CHECK screenLock status=off")
    let absent = render(
      StartupChecks.evaluate(
        interface: "en0", knownNetworks: Self.networks, configuredHotspot: "Work Phone", screenLock: .unknown))
    #expect(absent[1] == "CHECK hotspot known=no source=configured")
    #expect(absent[2] == "CHECK screenLock status=unknown")
  }

  @Test func autodetectWithNoIPhoneIsNo() {
    let lines = render(
      StartupChecks.evaluate(interface: "en0", knownNetworks: ["Home"], configuredHotspot: "", screenLock: .immediate))
    #expect(lines[1] == "CHECK hotspot known=no source=autodetect")
  }

  @Test func missingReadingsAreUnavailable() {
    let lines = render(
      StartupChecks.evaluate(interface: nil, knownNetworks: nil, configuredHotspot: "", screenLock: .immediate))
    #expect(lines[0] == "CHECK wifi interface=unavailable")
    #expect(lines[1] == "CHECK hotspot known=unavailable source=autodetect")
  }

  @Test func aDelayedScreenLockLogsItsSeconds() {
    let lines = render(
      StartupChecks.evaluate(
        interface: "en0", knownNetworks: [], configuredHotspot: "", screenLock: .delayed(seconds: 300)))
    #expect(lines[2] == "CHECK screenLock status=delay seconds=300")
  }

  @Test func anOddInterfaceNameIsNotLoggedVerbatim() {
    let lines = render(
      StartupChecks.evaluate(
        interface: "en0 extra=\"x\"", knownNetworks: [], configuredHotspot: "", screenLock: .immediate))
    #expect(lines[0] == "CHECK wifi interface=unavailable")
  }

  @Test func noLineContainsANetworkOrHotspotName() {
    let names = Self.networks + ["Work Phone"]
    for configured in ["", "Ivan's iPhone", "Work Phone"] {
      let decisions = StartupChecks.evaluate(
        interface: "en0", knownNetworks: Self.networks, configuredHotspot: configured, screenLock: .immediate)
      for decision in decisions {
        let text = ([decision.verb] + decision.fields.flatMap { [$0.key, $0.value] }).joined(separator: " ")
        for name in names {
          #expect(!text.contains(name))
        }
        #expect(!text.contains("iPhone"))
      }
    }
  }

  @Test func theRunReadsEachPortOnce() async {
    let decisions = await StartupChecks.run(
      wifi: FakeWiFi(interface: "en0", networks: Self.networks),
      screenLock: { .delayed(seconds: 5) },
      configuredHotspot: "",
      timeoutSeconds: 5
    )
    #expect(
      render(decisions) == [
        "CHECK wifi interface=en0",
        "CHECK hotspot known=yes source=autodetect",
        "CHECK screenLock status=delay seconds=5",
      ])
  }

  @Test func aHangingWiFiPortReturnsWithinTheBound() async {
    let hang = Hang()
    defer { hang.release() }
    let wifi = FakeWiFi(interface: "en0", networks: Self.networks, hang: hang)
    let result = OSAllocatedUnfairLock<[Decision]?>(initialState: nil)
    let returned = await Engine.bounded(seconds: 30) {
      let decisions = await StartupChecks.run(
        wifi: wifi, screenLock: { .immediate }, configuredHotspot: "", timeoutSeconds: 5)
      result.withLock { $0 = decisions }
    }
    #expect(returned)
    #expect(hang.returned == 0)
    #expect(await OffPool.eventually { hang.started == 2 })
    let decisions = result.withLock { $0 } ?? []
    #expect(
      render(decisions) == [
        "CHECK wifi interface=unavailable",
        "CHECK hotspot known=unavailable source=autodetect",
        "CHECK screenLock status=immediate",
      ])
  }
}
