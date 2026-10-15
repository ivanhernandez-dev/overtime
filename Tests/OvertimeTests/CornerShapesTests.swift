import Foundation
import OvertimeAppSupport
import SwiftUI
import Testing

@testable import Overtime

@MainActor
struct CornerShapesTests {
  static let containers: [(container: CGFloat, card: CGFloat, lastRowBottom: CGFloat)] = [
    (24, 12, 12), (16, 12, 6), (10, 10, 6),
  ]

  @Test func theFallbackShapesAreConcentricWithTheirContainer() {
    for item in Self.containers {
      let card = CornerShapes.heroCardFallback(container: item.container)
      let concentricCard = CornerGeometry.concentric(
        parent: Double(item.container), inset: CornerGeometry.panelPadding, own: CornerGeometry.cardRadius)
      #expect(card.cornerSize.width == item.card, "the card in a \(item.container) pt container")
      #expect(card.cornerSize.height == item.card)
      #expect(card.cornerSize.width == CGFloat(concentricCard))
      #expect(card.style == .continuous)

      let lastRow = CornerShapes.rowHighlightFallback(lastRow: true, container: item.container).cornerRadii
      #expect(lastRow.topLeading == 6)
      #expect(lastRow.topTrailing == 6)
      #expect(lastRow.bottomLeading == item.lastRowBottom, "the last row in a \(item.container) pt container")
      #expect(lastRow.bottomTrailing == item.lastRowBottom)
      #expect(CornerShapes.rowHighlightFallback(lastRow: true, container: item.container).style == .continuous)

      let row = CornerShapes.rowHighlightFallback(lastRow: false, container: item.container)
      let corners = [
        row.cornerRadii.topLeading, row.cornerRadii.topTrailing, row.cornerRadii.bottomLeading,
        row.cornerRadii.bottomTrailing,
      ]
      #expect(corners == [6, 6, 6, 6])
      #expect(row.style == .continuous)
    }
  }

  @Test func theFixedShapesReadTheCatalogue() {
    let shapes: [(shape: RoundedRectangle, radius: Double, points: CGFloat)] = [
      (CornerShapes.panel, CornerGeometry.panelRadius, 24),
      (CornerShapes.actionTile, CornerGeometry.tileRadius, 10),
      (CornerShapes.sessionTile, CornerGeometry.sessionTileRadius, 5),
    ]
    for item in shapes {
      #expect(item.shape.cornerSize.width == CGFloat(item.radius))
      #expect(item.shape.cornerSize.width == item.points)
      #expect(item.shape.cornerSize.height == item.points)
      #expect(item.shape.style == .continuous)
    }
    #expect(MenuBarPanelController.cornerRadius == CornerShapes.panel.cornerSize.width)
    let headerCard = CornerShapes.paneHeaderCard(for: CornerShapes.platform)
    #expect(CornerShapes.paneHeaderCard.cornerSize == headerCard.cornerSize)
    #expect(CornerShapes.paneHeaderCard.style == .continuous)
  }

  @Test func theSettingsFallbackShapesFollowThePlatform() {
    let expected: [(platform: CornerPlatform, card: CGFloat, tile: CGFloat)] = [
      (.macOS26AndLater, 12, 8), (.macOS14To25, 10, 6),
    ]
    #expect(expected.map(\.platform) == CornerPlatform.allCases)
    for item in expected {
      let card = CornerShapes.paneHeaderCard(for: item.platform)
      #expect(card.cornerSize.width == item.card, "the header card on \(item.platform)")
      #expect(card.cornerSize.height == item.card)
      #expect(card.cornerSize.width == CGFloat(CornerGeometry.paneHeaderCardRadius(item.platform)))
      #expect(card.style == .continuous)

      let tile = CornerShapes.paneHeaderTileFallback(item.platform)
      #expect(tile.cornerSize.width == item.tile, "the header tile on \(item.platform)")
      #expect(tile.cornerSize.height == item.tile)
      #expect(tile.cornerSize.width == CGFloat(CornerGeometry.paneHeaderTileRadius(item.platform)))
      #expect(tile.style == .continuous)
    }
    let sidebar = CornerShapes.sidebarTile
    #expect(sidebar.cornerSize.width == 6)
    #expect(sidebar.cornerSize.height == 6)
    #expect(sidebar.cornerSize.width == CGFloat(CornerGeometry.sidebarTileRadius))
    #expect(sidebar.style == .continuous)
  }
}
