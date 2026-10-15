import CoreWLAN
import Foundation
import OvertimeCore

public enum RadioError: Error, Sendable, Equatable {
  case noInterface
  case notFound
  case insecureOnly
  case timedOut
  case coreWLAN(code: Int)
}

public struct AdminRequirements: Sendable, Equatable {
  public var power: Bool
  public var association: Bool

  public init(power: Bool, association: Bool) {
    self.power = power
    self.association = association
  }
}

public enum SavedProfileSecurity: Sendable, Equatable {
  case absent
  case security(rawValue: Int)
}

public protocol WiFiRadio: Sendable {
  func interfaceName() -> String?
  func adminRequirements(interface: String) -> AdminRequirements?
  func savedSecurity(interface: String, ssid: String) -> SavedProfileSecurity?
  func powerOn(interface: String) -> Bool?
  func setPower(interface: String, on: Bool) -> Result<Void, RadioError>
  func joinSaved(interface: String, ssid: String) -> Result<Void, RadioError>
  func powerCallPending() -> Bool
}

public struct CoreWLANRadio: WiFiRadio {
  public static let callSeconds: Double = Timing.systemCallTimeoutSeconds
  public static let readKey = "wifi.read"
  public static let powerKey = "wifi.power"
  public static let scanKey = "wifi.scan"
  public static let associateKey = "wifi.associate"
  static let refusedSecurity: [CWSecurity] = [.none, .OWE, .oweTransition, .unknown]
  public static let refusedSecurityValues: Set<Int> = Set(refusedSecurity.map(\.rawValue))

  public static func acceptsSaved(_ saved: SavedProfileSecurity?) -> Bool {
    guard case .security(let rawValue) = saved else { return false }
    return !refusedSecurityValues.contains(rawValue)
  }

  public static func savedProfileSecurity(_ securities: [Int]) -> SavedProfileSecurity {
    guard let first = securities.first else { return .absent }
    return .security(rawValue: securities.first(where: refusedSecurityValues.contains) ?? first)
  }

  public enum ScanChoice<Network> {
    case match(Network)
    case none
    case insecureOnly
  }

  public static func scanChoice<Network>(
    _ networks: [Network], ssid: String, saved: Int, ssidOf: (Network) -> String?,
    supports: (Network, Int) -> Bool, rssi: (Network) -> Int
  ) -> ScanChoice<Network> {
    let sameName = networks.filter { ssidOf($0) == ssid }
    func insecure(_ network: Network) -> Bool {
      refusedSecurityValues.contains { supports(network, $0) }
    }
    let candidates = sameName.filter { supports($0, saved) && !insecure($0) }
    if let best = candidates.max(by: { rssi($0) < rssi($1) }) { return .match(best) }
    return !sameName.isEmpty && sameName.allSatisfy(insecure) ? .insecureOnly : .none
  }

  private final class NetworkBox: @unchecked Sendable {
    let network: CWNetwork

    init(_ network: CWNetwork) {
      self.network = network
    }
  }

  private let runner: DeadlineRunner

  public init(runner: DeadlineRunner = DeadlineRunner()) {
    self.runner = runner
  }

  public func interfaceName() -> String? {
    switch runner.run(timeout: Self.callSeconds, key: Self.readKey, { KnownNetworks.interfaceName() }) {
    case .value(let name): name
    case .timedOut: nil
    }
  }

  public func adminRequirements(interface: String) -> AdminRequirements? {
    let outcome = runner.run(timeout: Self.callSeconds, key: Self.readKey) { () -> AdminRequirements? in
      guard let configuration = CWWiFiClient.shared().interface(withName: interface)?.configuration() else {
        return nil
      }
      return AdminRequirements(
        power: configuration.requireAdministratorForPower,
        association: configuration.requireAdministratorForAssociation)
    }
    switch outcome {
    case .value(let requirements): return requirements
    case .timedOut: return nil
    }
  }

  public func savedSecurity(interface: String, ssid: String) -> SavedProfileSecurity? {
    let outcome = runner.run(timeout: Self.callSeconds, key: Self.readKey) { () -> SavedProfileSecurity? in
      guard let profiles = CWWiFiClient.shared().interface(withName: interface)?.configuration()?.networkProfiles
      else { return nil }
      let saved = profiles.compactMap { $0 as? CWNetworkProfile }.filter { $0.ssid == ssid }
      return Self.savedProfileSecurity(saved.map(\.security.rawValue))
    }
    switch outcome {
    case .value(let saved): return saved
    case .timedOut: return nil
    }
  }

  public func powerOn(interface: String) -> Bool? {
    let outcome = runner.run(timeout: Self.callSeconds, key: Self.readKey) { () -> Bool? in
      CWWiFiClient.shared().interface(withName: interface)?.powerOn()
    }
    switch outcome {
    case .value(let on): return on
    case .timedOut: return nil
    }
  }

  public func setPower(interface: String, on: Bool) -> Result<Void, RadioError> {
    let outcome = runner.run(timeout: Self.callSeconds, key: Self.powerKey) { () -> Result<Void, RadioError> in
      guard let wlan = CWWiFiClient.shared().interface(withName: interface) else { return .failure(.noInterface) }
      do {
        try wlan.setPower(on)
        return .success(())
      } catch {
        return .failure(.coreWLAN(code: (error as NSError).code))
      }
    }
    switch outcome {
    case .value(let result): return result
    case .timedOut: return .failure(.timedOut)
    }
  }

  public func powerCallPending() -> Bool {
    runner.isOutstanding(key: Self.powerKey)
  }

  public func joinSaved(interface: String, ssid: String) -> Result<Void, RadioError> {
    let scan = runner.run(timeout: Self.callSeconds, key: Self.scanKey) { () -> Result<NetworkBox, RadioError> in
      Self.strongestMatch(interface: interface, ssid: ssid).map(NetworkBox.init)
    }
    let box: NetworkBox
    switch scan {
    case .timedOut: return .failure(.timedOut)
    case .value(.failure(let error)): return .failure(error)
    case .value(.success(let found)): box = found
    }
    let association = runner.run(timeout: Self.callSeconds, key: Self.associateKey) { () -> Result<Void, RadioError> in
      guard let wlan = CWWiFiClient.shared().interface(withName: interface) else { return .failure(.noInterface) }
      do {
        try wlan.associate(to: box.network, password: nil)
        return .success(())
      } catch {
        return .failure(.coreWLAN(code: (error as NSError).code))
      }
    }
    switch association {
    case .value(let result): return result
    case .timedOut: return .failure(.timedOut)
    }
  }

  private static func strongestMatch(interface: String, ssid: String) -> Result<CWNetwork, RadioError> {
    guard let wlan = CWWiFiClient.shared().interface(withName: interface) else { return .failure(.noInterface) }
    let profiles = wlan.configuration()?.networkProfiles.compactMap { $0 as? CWNetworkProfile } ?? []
    let saved = savedProfileSecurity(profiles.filter { $0.ssid == ssid }.map(\.security.rawValue))
    guard acceptsSaved(saved), case .security(let savedRaw) = saved else { return .failure(.notFound) }
    do {
      let scanned = Array(try wlan.scanForNetworks(withName: ssid))
      let choice = scanChoice(
        scanned, ssid: ssid, saved: savedRaw, ssidOf: { $0.ssid },
        supports: { network, raw in CWSecurity(rawValue: raw).map(network.supportsSecurity) ?? false },
        rssi: { $0.rssiValue })
      switch choice {
      case .match(let best): return .success(best)
      case .none: return .failure(.notFound)
      case .insecureOnly: return .failure(.insecureOnly)
      }
    } catch {
      return .failure(.coreWLAN(code: (error as NSError).code))
    }
  }
}
