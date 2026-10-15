public enum SettingsPane: String, CaseIterable, Sendable, Identifiable {
  case general
  case detection
  case battery
  case network
  case unplugProtection
  case diagnostics
  case about

  public var id: String {
    rawValue
  }

  public var title: String {
    switch self {
    case .general:
      "General"
    case .detection:
      "Detection"
    case .battery:
      "Battery"
    case .network:
      "Network"
    case .unplugProtection:
      "Unplug Protection"
    case .diagnostics:
      "Diagnostics"
    case .about:
      "About"
    }
  }

  public var symbol: String {
    switch self {
    case .general:
      "gearshape"
    case .detection:
      "waveform.path.ecg"
    case .battery:
      "battery.75percent"
    case .network:
      "wifi"
    case .unplugProtection:
      "powerplug"
    case .diagnostics:
      "stethoscope"
    case .about:
      "info.circle"
    }
  }

  public var tileColor: PaneTileColor {
    switch self {
    case .general, .about:
      .gray
    case .detection:
      .purple
    case .battery:
      .green
    case .network:
      .blue
    case .unplugProtection:
      .orange
    case .diagnostics:
      .red
    }
  }

  public var summary: String {
    switch self {
    case .general:
      "Launch at login, the display and notifications."
    case .detection:
      "How Overtime tells that Claude is working."
    case .battery:
      "When Overtime lets the Mac sleep on battery."
    case .network:
      "Switching to your iPhone hotspot when the network fails."
    case .unplugProtection:
      "Keeps the lid-closed Mac awake when you unplug power or a display."
    case .diagnostics:
      "Detection health, the self-test and an export for bug reports."
    case .about:
      "Version, updates, acknowledgements and uninstall."
    }
  }
}

public enum PaneTileColor: CaseIterable, Sendable, Equatable {
  case gray
  case purple
  case green
  case blue
  case orange
  case red
}

public enum PaneTileSize: CaseIterable, Sendable, Equatable {
  case sidebar
  case header

  public var side: Double {
    switch self {
    case .sidebar: 22
    case .header: 44
    }
  }

  public var symbolSide: Double {
    switch self {
    case .sidebar: 14
    case .header: 26
    }
  }
}

public enum PaneTile {
  public static let highlightOpacity = 0.22
}
