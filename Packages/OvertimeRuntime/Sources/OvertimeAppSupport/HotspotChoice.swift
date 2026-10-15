import OvertimeCore

public enum HotspotChoice: Sendable, Hashable {
  case none
  case autoDetect
  case named(String)
  case unknown(String)

  public static let pickerLabel = "iPhone hotspot"
  public static let noneLabel = "None"
  public static let autoDetectLabel = "Auto-detect iPhone hotspot"
  public static let unknownSuffix = " (not in known networks)"

  public init(settings: Settings, knownNetworks: [String]?) {
    let stored = settings.hotspot
    guard !stored.isEmpty else {
      self = settings.hotspotAutoDetect ? .autoDetect : .none
      return
    }
    if let knownNetworks, !knownNetworks.contains(stored) {
      self = .unknown(stored)
    } else {
      self = .named(stored)
    }
  }

  public var label: String {
    switch self {
    case .none:
      Self.noneLabel
    case .autoDetect:
      Self.autoDetectLabel
    case .named(let name):
      name
    case .unknown(let name):
      name + Self.unknownSuffix
    }
  }

  public var isNone: Bool {
    self == .none
  }

  public var networkName: String? {
    switch self {
    case .none, .autoDetect:
      nil
    case .named(let name), .unknown(let name):
      name
    }
  }

  public func apply(to settings: Settings) -> Settings {
    var result = settings
    switch self {
    case .none:
      result.hotspot = ""
      result.hotspotAutoDetect = false
    case .autoDetect:
      result.hotspot = ""
      result.hotspotAutoDetect = true
    case .named(let name), .unknown(let name):
      result.hotspot = name
      result.hotspotAutoDetect = false
    }
    return result
  }
}

public enum HotspotPicker {
  public enum Entry: Sendable, Hashable {
    case choice(HotspotChoice)
    case divider
  }

  public static let unreadableCaption = "Couldn't read your known Wi-Fi networks."
  public static let sectionCaption =
    "If the network stops working while the lid is closed and Claude is working, Overtime switches the Mac to this hotspot, and back to your usual network when you open the lid."

  public static func entries(knownNetworks: [String]?, stored: HotspotChoice) -> [Entry] {
    var entries: [Entry] = [.choice(.none), .choice(.autoDetect)]
    var names = sortedNames(knownNetworks ?? []).map { Entry.choice(.named($0)) }
    switch stored {
    case .named(let name) where !(knownNetworks ?? []).contains(name):
      names.append(.choice(.named(name)))
    case .unknown:
      names.append(.choice(stored))
    case .none, .autoDetect, .named:
      break
    }
    if !names.isEmpty {
      entries.append(.divider)
      entries.append(contentsOf: names)
    }
    return entries
  }

  public static func caption(knownNetworks: [String]?) -> String? {
    knownNetworks == nil ? unreadableCaption : nil
  }

  public static func sortedNames(_ names: [String]) -> [String] {
    var seen = Set<String>()
    return
      names
      .filter { Settings.isValidSSID($0) && seen.insert($0).inserted }
      .sorted { lhs, rhs in
        switch lhs.caseInsensitiveCompare(rhs) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: lhs < rhs
        }
      }
  }
}
