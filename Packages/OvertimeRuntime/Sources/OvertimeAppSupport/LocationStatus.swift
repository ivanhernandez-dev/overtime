public enum LocationAuthorization: Sendable, Equatable {
  case notDetermined
  case denied
  case restricted
  case authorized
}

public protocol LocationStatusPort: Sendable {
  @MainActor func status() -> LocationAuthorization
  @MainActor func request()
}

public struct LocationRow: Sendable, Equatable {
  public enum Tone: Sendable, Equatable {
    case success
    case info
    case warning
  }

  public enum Action: Sendable, Equatable {
    case allowLocation
    case openLocationServices
  }

  public static let authorizedTitle = "Location access is on."
  public static let notDeterminedTitle = "Location access lets Overtime join your iPhone hotspot directly."
  public static let deniedTitle = "Location access is off for Overtime."
  public static let allowLabel = "Allow Location Access"
  public static let openLabel = "Open Location Services"
  public static let caption = "Overtime never stores or sends your location."

  public let symbol: String
  public let tone: Tone
  public let title: String
  public let action: Action?

  public var actionLabel: String? {
    switch action {
    case .allowLocation: Self.allowLabel
    case .openLocationServices: Self.openLabel
    case nil: nil
    }
  }

  public static func `for`(_ status: LocationAuthorization) -> LocationRow {
    switch status {
    case .authorized:
      LocationRow(symbol: "checkmark.circle.fill", tone: .success, title: authorizedTitle, action: nil)
    case .notDetermined:
      LocationRow(symbol: "info.circle", tone: .info, title: notDeterminedTitle, action: .allowLocation)
    case .denied, .restricted:
      LocationRow(
        symbol: "exclamationmark.triangle.fill", tone: .warning, title: deniedTitle, action: .openLocationServices)
    }
  }

  public static func `for`(_ status: LocationAuthorization, choice: HotspotChoice) -> LocationRow? {
    choice.isNone ? nil : self.for(status)
  }
}
