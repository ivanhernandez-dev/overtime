import Foundation
import OvertimeCore

public struct NetworkInterfaceInfo: Sendable, Equatable, Codable {
  public var bsdName: String
  public var type: String

  public init(bsdName: String, type: String) {
    self.bsdName = bsdName
    self.type = type
  }
}

public enum NetworkFactsParser {
  public static let hotspotRouter = "172.20.10.1"
  public static let hotspotMask = "255.255.255.240"
  public static let hotspotPrefix = "172.20.10."
  public static let hotspotHosts = 2...14
  public static let wifiType = "IEEE80211"
  public static let wiredTypes: Set<String> = ["Ethernet", "FireWire", "Bond", "VLAN"]
  public static let virtualPrefixes = ["bridge", "utun", "ipsec", "ppp", "awdl", "llw", "anpi", "ap"]
  public static let allowedKeys: Set<String> = [
    "Interfaces", "Addresses", "SubnetMasks", "InterfaceName", "Router", "Power Status",
  ]
  public static let interfaceListKey = "State:/Network/Interface"
  public static let interfaceIPv4Pattern = "State:/Network/Interface/[^/]+/IPv4"
  public static let serviceIPv4Pattern = "State:/Network/Service/[^/]+/IPv4"
  static let servicePrefix = "State:/Network/Service/"
  static let ipv4Suffix = "/IPv4"

  public static func interfaceIPv4Key(_ bsdName: String) -> String {
    "State:/Network/Interface/\(bsdName)/IPv4"
  }

  public static func airPortKey(_ bsdName: String) -> String {
    "State:/Network/Interface/\(bsdName)/AirPort"
  }

  struct ServiceRoute: Equatable {
    var interface: String
    var router: String?
  }

  public static func parse(interfaces: [NetworkInterfaceInfo], store: [String: Any]) -> NetworkFacts {
    let wifi = interfaces.first { $0.type == wifiType }?.bsdName
    let routes = serviceRoutes(store)
    let onHotspot = wifi.flatMap { hotspot(wifi: $0, store: store, routes: routes) }
    let wired = interfaces.contains { isWired($0, wifi: wifi, store: store, routes: routes) }
    let powered = wifi.flatMap { value(store, airPortKey($0), "Power Status") as? Bool }
    return NetworkFacts(wifiInterface: wifi, onHotspot: onHotspot, wired: wired, wifiPowered: powered)
  }

  static func value(_ store: [String: Any], _ key: String, _ field: String) -> Any? {
    guard allowedKeys.contains(field), let entry = store[key] as? [String: Any] else { return nil }
    return entry[field]
  }

  static func strings(_ store: [String: Any], _ key: String, _ field: String) -> [String] {
    (value(store, key, field) as? [String]) ?? []
  }

  static func serviceRoutes(_ store: [String: Any]) -> [ServiceRoute] {
    store.keys.filter { $0.hasPrefix(servicePrefix) && $0.hasSuffix(ipv4Suffix) }.sorted().compactMap { key in
      guard let interface = value(store, key, "InterfaceName") as? String else { return nil }
      return ServiceRoute(interface: interface, router: value(store, key, "Router") as? String)
    }
  }

  static func hotspot(wifi: String, store: [String: Any], routes: [ServiceRoute]) -> Bool? {
    let key = interfaceIPv4Key(wifi)
    let addresses = strings(store, key, "Addresses")
    guard !addresses.isEmpty else { return nil }
    guard routes.contains(where: { $0.interface == wifi && $0.router == hotspotRouter }) else { return false }
    let masks = strings(store, key, "SubnetMasks")
    return addresses.indices.contains { index in
      isHotspotHost(addresses[index]) && index < masks.count && masks[index] == hotspotMask
    }
  }

  static func isHotspotHost(_ address: String) -> Bool {
    guard address.hasPrefix(hotspotPrefix) else { return false }
    let digits = address.dropFirst(hotspotPrefix.count)
    guard (1...2).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }), let host = Int(digits)
    else { return false }
    return hotspotHosts.contains(host)
  }

  static func isWired(
    _ interface: NetworkInterfaceInfo, wifi: String?, store: [String: Any], routes: [ServiceRoute]
  ) -> Bool {
    let name = interface.bsdName
    guard wiredTypes.contains(interface.type), name != wifi,
      !virtualPrefixes.contains(where: { name.hasPrefix($0) })
    else { return false }
    guard !strings(store, interfaceIPv4Key(name), "Addresses").isEmpty else { return false }
    return routes.contains { $0.interface == name && !($0.router ?? "").isEmpty }
  }
}
