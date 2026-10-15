import Foundation
import OvertimeCore
import OvertimeSystem

public protocol WiFiInfoPort: Sendable {
  func interfaceName() -> String?
  func knownNetworkNames() -> [String]?
}

public enum StartupChecks {
  public static let unavailable = "unavailable"
  public static let autodetectMarker = "iPhone"

  public static func evaluate(
    interface: String?, knownNetworks: [String]?, configuredHotspot: String, screenLock: ScreenLockStatus
  ) -> [Decision] {
    [
      Decision(
        keyword: .check, verb: "wifi",
        fields: [DecisionField(key: "interface", value: sanitizedInterface(interface) ?? unavailable)]),
      hotspot(knownNetworks: knownNetworks, configuredHotspot: configuredHotspot),
      Decision(keyword: .check, verb: "screenLock", fields: screenLockFields(screenLock)),
    ]
  }

  public static func run(
    wifi: any WiFiInfoPort,
    screenLock: @escaping @Sendable () -> ScreenLockStatus,
    configuredHotspot: String,
    timeoutSeconds: Double = Timing.systemCallTimeoutSeconds,
    runner: DeadlineRunner = DeadlineRunner()
  ) async -> [Decision] {
    async let interface = runner.perform(timeout: timeoutSeconds, key: "check.wifiInterface") {
      wifi.interfaceName()
    }
    async let networks = runner.perform(timeout: timeoutSeconds, key: "check.wifiNetworks") {
      wifi.knownNetworkNames()
    }
    async let lock = runner.perform(timeout: timeoutSeconds, key: "check.screenLock", screenLock)
    let interfaceName: String? =
      if case .value(let name) = await interface { name } else { nil }
    let networkNames: [String]? =
      if case .value(let names) = await networks { names } else { nil }
    let lockStatus: ScreenLockStatus =
      if case .value(let status) = await lock { status } else { .unknown }
    return evaluate(
      interface: interfaceName, knownNetworks: networkNames, configuredHotspot: configuredHotspot,
      screenLock: lockStatus)
  }

  static func hotspot(knownNetworks: [String]?, configuredHotspot: String) -> Decision {
    let configured = !configuredHotspot.isEmpty
    let known: String
    if let knownNetworks {
      let found =
        configured
        ? knownNetworks.contains(configuredHotspot)
        : knownNetworks.contains { $0.contains(autodetectMarker) }
      known = found ? "yes" : "no"
    } else {
      known = unavailable
    }
    return Decision(
      keyword: .check, verb: "hotspot",
      fields: [
        DecisionField(key: "known", value: known),
        DecisionField(key: "source", value: configured ? "configured" : "autodetect"),
      ])
  }

  static func screenLockFields(_ status: ScreenLockStatus) -> [DecisionField] {
    switch status {
    case .immediate:
      [DecisionField(key: "status", value: "immediate")]
    case .delayed(let seconds):
      [DecisionField(key: "status", value: "delay"), DecisionField(key: "seconds", value: String(seconds))]
    case .off:
      [DecisionField(key: "status", value: "off")]
    case .unknown:
      [DecisionField(key: "status", value: "unknown")]
    }
  }

  static func sanitizedInterface(_ name: String?) -> String? {
    guard let name, !name.isEmpty, name.count <= 16,
      name.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) })
    else { return nil }
    return name
  }
}
