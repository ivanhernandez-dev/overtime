import OvertimeAppSupport
import OvertimeSystem

struct CoreWLANInfo: WiFiInfoPort {
  nonisolated func interfaceName() -> String? {
    KnownNetworks.interfaceName()
  }

  nonisolated func knownNetworkNames() -> [String]? {
    KnownNetworks.names()
  }
}
