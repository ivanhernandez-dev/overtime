import CoreLocation
import OvertimeAppSupport

@MainActor
final class LocationStatusReader: NSObject, LocationStatusPort, CLLocationManagerDelegate {
  private let manager = CLLocationManager()
  var onChange: (LocationAuthorization) -> Void = { _ in }

  override init() {
    super.init()
    manager.delegate = self
  }

  func status() -> LocationAuthorization {
    Self.authorization(manager.authorizationStatus)
  }

  func request() {
    manager.requestWhenInUseAuthorization()
  }

  nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      onChange(status())
    }
  }

  nonisolated static func authorization(_ status: CLAuthorizationStatus) -> LocationAuthorization {
    switch status {
    case .authorizedAlways:
      .authorized
    case .denied:
      .denied
    case .restricted:
      .restricted
    case .notDetermined:
      .notDetermined
    @unknown default:
      .notDetermined
    }
  }
}
