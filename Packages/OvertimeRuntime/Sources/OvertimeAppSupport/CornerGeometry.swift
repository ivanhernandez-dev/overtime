import Foundation

public enum CornerPlatform: CaseIterable, Sendable {
  case macOS26AndLater
  case macOS14To25
}

public enum CornerRule: Sendable, Equatable {
  case fixed
  case concentric
  case capsule
  case circle
  case system
  case pending
}

public struct CornerEntry: Sendable, Equatable {
  public let element: String
  public let parent: String
  public let parentRadius: Double?
  public let inset: Double?
  public let minimum: Double?
  public let rule: CornerRule
  public let radius: Double?

  public init(
    element: String, parent: String, parentRadius: Double?, inset: Double?, minimum: Double?, rule: CornerRule,
    radius: Double?
  ) {
    self.element = element
    self.parent = parent
    self.parentRadius = parentRadius
    self.inset = inset
    self.minimum = minimum
    self.rule = rule
    self.radius = radius
  }
}

public enum CornerGeometry {
  public static let minimumRadius = 4.0
  public static let panelRadius = 24.0
  public static let panelPadding = 12.0
  public static let cardRadius = 12.0
  public static let rowRadius = 6.0
  public static let tileRadius = 10.0
  public static let sessionTileRadius = 5.0
  public static let chipVerticalPadding = 3.0
  public static let chipHorizontalPadding = 8.0
  public static let chipLineHeight = 14.0
  public static let maskCapFactor = 1.6
  public static let sidebarTileRadius = 6.0
  public static let paneHeaderTilePadding = 4.0

  public static func windowRadius(_ platform: CornerPlatform) -> Double {
    switch platform {
    case .macOS26AndLater: 16
    case .macOS14To25: 10
    }
  }

  public static func paneHeaderCardRadius(_ platform: CornerPlatform) -> Double {
    min(cardRadius, windowRadius(platform))
  }

  public static func paneHeaderTileRadius(_ platform: CornerPlatform) -> Double {
    concentric(parent: paneHeaderCardRadius(platform), inset: paneHeaderTilePadding, own: minimumRadius)
  }

  public static func concentric(parent: Double, inset: Double, own: Double) -> Double {
    min(parent, max(parent - inset, max(own, minimumRadius)))
  }

  public static var heroCardRadius: Double {
    concentric(parent: panelRadius, inset: panelPadding, own: cardRadius)
  }

  public static var lastRowBottomRadius: Double {
    concentric(parent: panelRadius, inset: panelPadding, own: rowRadius)
  }

  public static var chipRadius: Double {
    (chipLineHeight + 2 * chipVerticalPadding) / 2
  }

  public static func table(_ platform: CornerPlatform) -> [CornerEntry] {
    panelTable() + reopenTable(platform) + settingsTable(platform) + onboardingTable(platform)
  }

  private static func panelTable() -> [CornerEntry] {
    let window = CornerEntry(
      element: "panel.window", parent: "screen", parentRadius: nil, inset: nil, minimum: nil, rule: .fixed,
      radius: panelRadius)
    let card = CornerEntry(
      element: "panel.heroCard", parent: window.element, parentRadius: window.radius, inset: panelPadding,
      minimum: cardRadius, rule: .concentric, radius: heroCardRadius)
    let tile = CornerEntry(
      element: "panel.actionTile", parent: window.element, parentRadius: window.radius, inset: nil, minimum: nil,
      rule: .fixed, radius: tileRadius)
    return [
      window,
      CornerEntry(
        element: "panel.hairline", parent: window.element, parentRadius: window.radius, inset: 0,
        minimum: minimumRadius, rule: .concentric,
        radius: concentric(parent: panelRadius, inset: 0, own: minimumRadius)),
      card,
      indicator("panel.indicator", in: card),
      CornerEntry(
        element: "panel.chip", parent: card.element, parentRadius: card.radius, inset: PrismLayout.cardPadding,
        minimum: nil, rule: .capsule, radius: chipRadius),
      system("panel.turnSleepBackOn", in: window),
      tile,
      CornerEntry(
        element: "panel.actionTileHighlight", parent: tile.element, parentRadius: tile.radius, inset: 0,
        minimum: minimumRadius, rule: .concentric, radius: concentric(parent: tileRadius, inset: 0, own: minimumRadius)
      ),
      system("panel.sleepConfirmation", in: window),
      fixed("panel.rowHighlight", in: window, radius: rowRadius),
      CornerEntry(
        element: "panel.lastRowHighlight", parent: window.element, parentRadius: window.radius, inset: panelPadding,
        minimum: rowRadius, rule: .concentric, radius: lastRowBottomRadius),
      fixed("panel.sessionTile", in: window, radius: sessionTileRadius),
      system("panel.loginSwitch", in: window),
    ]
  }

  private static func reopenTable(_ platform: CornerPlatform) -> [CornerEntry] {
    let outer = windowRadius(platform)
    let window = CornerEntry(
      element: "reopen.window", parent: "screen", parentRadius: nil, inset: nil, minimum: nil, rule: .system,
      radius: outer)
    let card = fixed("reopen.heroCard", in: window, radius: min(cardRadius, outer))
    return [
      window,
      card,
      indicator("reopen.indicator", in: card),
      CornerEntry(
        element: "reopen.chip", parent: card.element, parentRadius: card.radius, inset: PrismLayout.cardPadding,
        minimum: nil, rule: .capsule, radius: chipRadius),
      fixed("reopen.actionTile", in: window, radius: tileRadius),
      fixed("reopen.rowHighlight", in: window, radius: rowRadius),
      CornerEntry(
        element: "reopen.lastRowHighlight", parent: window.element, parentRadius: outer, inset: panelPadding,
        minimum: rowRadius, rule: .concentric, radius: concentric(parent: outer, inset: panelPadding, own: rowRadius)),
      fixed("reopen.sessionTile", in: window, radius: sessionTileRadius),
    ]
  }

  private static func settingsTable(_ platform: CornerPlatform) -> [CornerEntry] {
    let window = CornerEntry(
      element: "settings.window", parent: "screen", parentRadius: nil, inset: nil, minimum: nil, rule: .system,
      radius: windowRadius(platform))
    let selection = system("settings.sidebarSelection", in: window)
    let card = fixed("settings.paneHeaderCard", in: window, radius: paneHeaderCardRadius(platform))
    return [
      window,
      selection,
      fixed("settings.sidebarTile", in: selection, radius: sidebarTileRadius),
      system("settings.formSection", in: window),
      card,
      CornerEntry(
        element: "settings.paneHeaderTile", parent: card.element, parentRadius: card.radius,
        inset: paneHeaderTilePadding, minimum: minimumRadius, rule: .concentric,
        radius: paneHeaderTileRadius(platform)),
      system("settings.sheet", in: window),
    ]
  }

  private static func onboardingTable(_ platform: CornerPlatform) -> [CornerEntry] {
    let window = CornerEntry(
      element: "onboarding.window", parent: "screen", parentRadius: nil, inset: nil, minimum: nil, rule: .system,
      radius: windowRadius(platform))
    return [window, system("onboarding.buttons", in: window)]
  }

  private static func fixed(_ element: String, in parent: CornerEntry, radius: Double) -> CornerEntry {
    CornerEntry(
      element: element, parent: parent.element, parentRadius: parent.radius, inset: nil, minimum: nil, rule: .fixed,
      radius: radius)
  }

  private static func indicator(_ element: String, in card: CornerEntry) -> CornerEntry {
    CornerEntry(
      element: element, parent: card.element, parentRadius: card.radius, inset: nil, minimum: nil, rule: .circle,
      radius: PrismLayout.indicatorSide / 2)
  }

  private static func system(_ element: String, in parent: CornerEntry) -> CornerEntry {
    CornerEntry(
      element: element, parent: parent.element, parentRadius: parent.radius, inset: nil, minimum: nil, rule: .system,
      radius: nil)
  }
}
