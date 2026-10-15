import Foundation
import OvertimeAppSupport
import Testing

struct CornerGeometryTests {
  static let tolerance = 0.5

  static let auditedSurfaces = [
    "panel.window", "panel.hairline", "panel.heroCard", "panel.indicator", "panel.chip", "panel.turnSleepBackOn",
    "panel.actionTile", "panel.actionTileHighlight", "panel.sleepConfirmation", "panel.rowHighlight",
    "panel.lastRowHighlight", "panel.sessionTile", "panel.loginSwitch", "reopen.window", "reopen.heroCard",
    "reopen.indicator", "reopen.chip", "reopen.actionTile", "reopen.rowHighlight", "reopen.lastRowHighlight",
    "reopen.sessionTile", "settings.window", "settings.sidebarSelection", "settings.sidebarTile",
    "settings.formSection", "settings.paneHeaderCard", "settings.paneHeaderTile", "settings.sheet",
    "onboarding.window", "onboarding.buttons",
  ]

  struct Target {
    let rule: CornerRule
    let macOS26AndLater: Double?
    let macOS14To25: Double?

    init(_ rule: CornerRule, _ macOS26AndLater: Double?, _ macOS14To25: Double?) {
      self.rule = rule
      self.macOS26AndLater = macOS26AndLater
      self.macOS14To25 = macOS14To25
    }

    func radius(_ platform: CornerPlatform) -> Double? {
      switch platform {
      case .macOS26AndLater: macOS26AndLater
      case .macOS14To25: macOS14To25
      }
    }
  }

  static let targets: [String: Target] = [
    "panel.window": Target(.fixed, 24, 24),
    "panel.hairline": Target(.concentric, 24, 24),
    "panel.heroCard": Target(.concentric, 12, 12),
    "panel.indicator": Target(.circle, 18, 18),
    "panel.chip": Target(.capsule, 10, 10),
    "panel.turnSleepBackOn": Target(.system, nil, nil),
    "panel.actionTile": Target(.fixed, 10, 10),
    "panel.actionTileHighlight": Target(.concentric, 10, 10),
    "panel.sleepConfirmation": Target(.system, nil, nil),
    "panel.rowHighlight": Target(.fixed, 6, 6),
    "panel.lastRowHighlight": Target(.concentric, 12, 12),
    "panel.sessionTile": Target(.fixed, 5, 5),
    "panel.loginSwitch": Target(.system, nil, nil),
    "reopen.window": Target(.system, 16, 10),
    "reopen.heroCard": Target(.fixed, 12, 10),
    "reopen.indicator": Target(.circle, 18, 18),
    "reopen.chip": Target(.capsule, 10, 10),
    "reopen.actionTile": Target(.fixed, 10, 10),
    "reopen.rowHighlight": Target(.fixed, 6, 6),
    "reopen.lastRowHighlight": Target(.concentric, 6, 6),
    "reopen.sessionTile": Target(.fixed, 5, 5),
    "settings.window": Target(.system, 16, 10),
    "settings.sidebarSelection": Target(.system, nil, nil),
    "settings.sidebarTile": Target(.fixed, 6, 6),
    "settings.formSection": Target(.system, nil, nil),
    "settings.paneHeaderCard": Target(.fixed, 12, 10),
    "settings.paneHeaderTile": Target(.concentric, 8, 6),
    "settings.sheet": Target(.system, nil, nil),
    "onboarding.window": Target(.system, 16, 10),
    "onboarding.buttons": Target(.system, nil, nil),
  ]

  @Test func theConcentricRadiusIsTheParentMinusTheInsetWithinItsBounds() {
    #expect(CornerGeometry.minimumRadius == 4)
    let cases: [(parent: Double, inset: Double, own: Double, radius: Double)] = [
      (24, 12, 6, 12), (24, 12, 12, 12), (16, 12, 6, 6), (10, 12, 12, 10), (24, 30, 4, 4), (24, 0, 4, 24),
      (12, 4, 4, 8), (10, 4, 4, 6),
    ]
    for item in cases {
      let radius = CornerGeometry.concentric(parent: item.parent, inset: item.inset, own: item.own)
      #expect(radius == item.radius, "concentric(\(item.parent), \(item.inset), \(item.own)) is \(radius)")
    }
  }

  @Test func thePanelChainIsConcentricWithThePanel() {
    #expect(CornerGeometry.panelRadius == 24)
    #expect(CornerGeometry.panelPadding == 12)
    #expect(CornerGeometry.cardRadius == 12)
    #expect(CornerGeometry.heroCardRadius == 12)
    #expect(CornerGeometry.heroCardRadius == CornerGeometry.panelRadius - CornerGeometry.panelPadding)
    #expect(CornerGeometry.rowRadius == 6)
    #expect(CornerGeometry.lastRowBottomRadius == 12)
    #expect(CornerGeometry.lastRowBottomRadius == CornerGeometry.panelRadius - CornerGeometry.panelPadding)
    #expect(CornerGeometry.tileRadius == 10)
    #expect(CornerGeometry.sessionTileRadius == 5)
    #expect(CornerGeometry.chipVerticalPadding == 3)
    #expect(CornerGeometry.chipHorizontalPadding == 8)
    #expect(CornerGeometry.chipLineHeight == 14)
    #expect(CornerGeometry.chipRadius == 10)
    #expect(
      CornerGeometry.chipRadius == (CornerGeometry.chipLineHeight + 2 * CornerGeometry.chipVerticalPadding) / 2)
    #expect(CornerGeometry.chipRadius <= CornerGeometry.heroCardRadius)
    #expect(CornerGeometry.maskCapFactor == 1.6)
    #expect(CornerGeometry.maskCapFactor >= 1.53)
  }

  @Test func theWindowRadiusFollowsThePlatform() {
    #expect(CornerPlatform.allCases == [.macOS26AndLater, .macOS14To25])
    #expect(CornerGeometry.windowRadius(.macOS26AndLater) == 16)
    #expect(CornerGeometry.windowRadius(.macOS14To25) == 10)
  }

  @Test(arguments: CornerPlatform.allCases)
  func everyChildIsNoRounderThanItsParent(platform: CornerPlatform) throws {
    let table = CornerGeometry.table(platform)
    try #require(!table.isEmpty)
    for entry in table where [.fixed, .concentric, .capsule].contains(entry.rule) {
      guard let radius = entry.radius, let parentRadius = entry.parentRadius else { continue }
      #expect(radius <= parentRadius, "\(entry.element) is \(radius), rounder than its parent \(parentRadius)")
    }
    let exempt = table.filter { $0.rule == .circle }.map(\.element)
    #expect(exempt == ["panel.indicator", "reopen.indicator"])
    let pending = table.filter { $0.rule == .pending }.map(\.element)
    #expect(pending == [])
  }

  @Test(arguments: CornerPlatform.allCases)
  func everyConcentricEntryIsItsParentMinusItsInset(platform: CornerPlatform) throws {
    let concentric = CornerGeometry.table(platform).filter { $0.rule == .concentric }
    try #require(concentric.count >= 4)
    for entry in concentric {
      let parent = try #require(entry.parentRadius, "\(entry.element) has no parent radius")
      let inset = try #require(entry.inset, "\(entry.element) has no inset")
      let minimum = try #require(entry.minimum, "\(entry.element) has no minimum")
      let radius = try #require(entry.radius, "\(entry.element) has no radius")
      let rule = CornerGeometry.concentric(parent: parent, inset: inset, own: minimum)
      #expect(abs(radius - rule) <= Self.tolerance, "\(entry.element) is \(radius), the rule gives \(rule)")
      if parent - inset >= max(minimum, CornerGeometry.minimumRadius) {
        #expect(abs(radius - (parent - inset)) <= Self.tolerance, "\(entry.element) is not its parent minus its inset")
      }
    }
  }

  @Test(arguments: CornerPlatform.allCases)
  func theTableNamesEveryAuditedSurface(platform: CornerPlatform) throws {
    let table = CornerGeometry.table(platform)
    #expect(table.map(\.element) == Self.auditedSurfaces)
    #expect(Set(table.map(\.element)).count == table.count)
    var seen: [String: CornerEntry] = [:]
    for entry in table {
      if entry.parent == "screen" {
        #expect(entry.parentRadius == nil, "\(entry.element) sits on the screen and has a parent radius")
      } else {
        let parent = try #require(seen[entry.parent], "\(entry.element) names \(entry.parent), not an earlier entry")
        let prefix = entry.element.split(separator: ".").first
        #expect(entry.parent.split(separator: ".").first == prefix, "\(entry.element) has a parent in another host")
        #expect(entry.parentRadius == parent.radius, "\(entry.element) does not carry its parent's radius")
      }
      seen[entry.element] = entry
    }
  }

  @Test(arguments: CornerPlatform.allCases)
  func theTableHoldsTheTargetRadii(platform: CornerPlatform) throws {
    let table = CornerGeometry.table(platform)
    try #require(table.count == Self.targets.count)
    for entry in table {
      let target = try #require(Self.targets[entry.element], "\(entry.element) is not an audited surface")
      #expect(entry.rule == target.rule, "\(entry.element) follows \(entry.rule), expected \(target.rule)")
      #expect(entry.radius == target.radius(platform), "\(entry.element) is \(String(describing: entry.radius))")
    }
    let systemWithRadius = table.filter { $0.rule == .system && $0.radius != nil }.map(\.element)
    #expect(systemWithRadius == ["reopen.window", "settings.window", "onboarding.window"])
    let circles = table.filter { $0.rule == .circle }
    #expect(circles.map(\.element) == ["panel.indicator", "reopen.indicator"])
    for circle in circles {
      #expect(circle.radius == PrismLayout.indicatorSide / 2, "\(circle.element) is not half the indicator side")
      #expect(circle.inset == nil, "\(circle.element) has an inset")
      #expect(circle.minimum == nil, "\(circle.element) has a minimum")
    }
    let sidebarTile = try #require(table.first { $0.element == "settings.sidebarTile" })
    #expect(sidebarTile.parent == "settings.sidebarSelection")
    #expect(sidebarTile.parentRadius == nil)
    let headerTile = try #require(table.first { $0.element == "settings.paneHeaderTile" })
    #expect(headerTile.parent == "settings.paneHeaderCard")
    #expect(headerTile.inset == CornerGeometry.paneHeaderTilePadding)
    #expect(headerTile.minimum == CornerGeometry.minimumRadius)
  }

  @Test func thePaneHeaderTileIsConcentricWithItsCard() {
    #expect(CornerGeometry.sidebarTileRadius == 6)
    #expect(CornerGeometry.paneHeaderTilePadding == 4)
    let expected: [(platform: CornerPlatform, card: Double, tile: Double)] = [
      (.macOS26AndLater, 12, 8), (.macOS14To25, 10, 6),
    ]
    #expect(expected.map(\.platform) == CornerPlatform.allCases)
    for item in expected {
      let card = CornerGeometry.paneHeaderCardRadius(item.platform)
      let tile = CornerGeometry.paneHeaderTileRadius(item.platform)
      #expect(card == item.card, "the header card on \(item.platform) is \(card)")
      #expect(card == min(CornerGeometry.cardRadius, CornerGeometry.windowRadius(item.platform)))
      #expect(tile == item.tile, "the header tile on \(item.platform) is \(tile)")
      #expect(tile == card - CornerGeometry.paneHeaderTilePadding)
      #expect(tile < card)
    }
  }
}
