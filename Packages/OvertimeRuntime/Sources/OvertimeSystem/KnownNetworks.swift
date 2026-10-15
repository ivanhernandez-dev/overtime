import CoreWLAN
import Foundation

public enum KnownNetworks {
  public static let autodetectMarker = "iPhone"

  public static func interfaceName() -> String? {
    CWWiFiClient.shared().interface()?.interfaceName
  }

  public static func names() -> [String]? {
    guard let profiles = CWWiFiClient.shared().interface()?.configuration()?.networkProfiles else { return nil }
    return profiles.compactMap { ($0 as? CWNetworkProfile)?.ssid }
  }

  public static func autoHotspot(in names: [String]?) -> String? {
    names?.first { $0.contains(autodetectMarker) }
  }
}
