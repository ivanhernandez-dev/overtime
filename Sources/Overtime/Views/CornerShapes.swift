import OvertimeAppSupport
import SwiftUI

enum PanelRowCorners {
  case row
  case lastRow
  case tile
}

enum CornerShapes {
  static var panel: RoundedRectangle {
    RoundedRectangle(cornerRadius: CGFloat(CornerGeometry.panelRadius), style: .continuous)
  }

  static var actionTile: RoundedRectangle {
    RoundedRectangle(cornerRadius: CGFloat(CornerGeometry.tileRadius), style: .continuous)
  }

  static var sessionTile: RoundedRectangle {
    RoundedRectangle(cornerRadius: CGFloat(CornerGeometry.sessionTileRadius), style: .continuous)
  }

  static var platform: CornerPlatform {
    if #available(macOS 26, *) {
      return .macOS26AndLater
    }
    return .macOS14To25
  }

  static var paneHeaderCard: RoundedRectangle {
    paneHeaderCard(for: platform)
  }

  static func paneHeaderCard(for platform: CornerPlatform) -> RoundedRectangle {
    RoundedRectangle(cornerRadius: CGFloat(CornerGeometry.paneHeaderCardRadius(platform)), style: .continuous)
  }

  static var paneHeaderTile: AnyShape {
    if #available(macOS 26, *) {
      return AnyShape(
        ConcentricRectangle(
          corners: .concentric(minimum: .fixed(CGFloat(CornerGeometry.minimumRadius))), isUniform: true))
    }
    return AnyShape(paneHeaderTileFallback(.macOS14To25))
  }

  static func paneHeaderTileFallback(_ platform: CornerPlatform) -> RoundedRectangle {
    RoundedRectangle(cornerRadius: CGFloat(CornerGeometry.paneHeaderTileRadius(platform)), style: .continuous)
  }

  static var sidebarTile: RoundedRectangle {
    RoundedRectangle(cornerRadius: CGFloat(CornerGeometry.sidebarTileRadius), style: .continuous)
  }

  static func heroCard(container: CGFloat) -> AnyShape {
    if #available(macOS 26, *) {
      return AnyShape(
        ConcentricRectangle(
          corners: .concentric(minimum: .fixed(CGFloat(CornerGeometry.cardRadius))), isUniform: true))
    }
    return AnyShape(heroCardFallback(container: container))
  }

  static func heroCardFallback(container: CGFloat) -> RoundedRectangle {
    let radius = CornerGeometry.concentric(
      parent: Double(container), inset: CornerGeometry.panelPadding, own: CornerGeometry.cardRadius)
    return RoundedRectangle(cornerRadius: CGFloat(radius), style: .continuous)
  }

  static func rowHighlight(_ corners: PanelRowCorners, container: CGFloat) -> AnyShape {
    if corners == .tile {
      return AnyShape(actionTile)
    }
    if #available(macOS 26, *) {
      let row = CGFloat(CornerGeometry.rowRadius)
      return AnyShape(
        ConcentricRectangle(uniformTopCorners: .fixed(row), uniformBottomCorners: .concentric(minimum: .fixed(row))))
    }
    return AnyShape(rowHighlightFallback(lastRow: corners == .lastRow, container: container))
  }

  static func rowHighlightFallback(lastRow: Bool, container: CGFloat) -> UnevenRoundedRectangle {
    let top = CGFloat(CornerGeometry.rowRadius)
    let concentric = CornerGeometry.concentric(
      parent: Double(container), inset: CornerGeometry.panelPadding, own: CornerGeometry.rowRadius)
    let bottom = lastRow ? CGFloat(concentric) : top
    return UnevenRoundedRectangle(
      topLeadingRadius: top, bottomLeadingRadius: bottom, bottomTrailingRadius: bottom, topTrailingRadius: top,
      style: .continuous)
  }
}

extension EnvironmentValues {
  @Entry var cornerContainerRadius: CGFloat = CGFloat(CornerGeometry.windowRadius(.macOS14To25))
}

private struct CornerContainer: ViewModifier {
  let shape: RoundedRectangle

  func body(content: Content) -> some View {
    if #available(macOS 26, *) {
      content
        .containerShape(shape)
        .environment(\.cornerContainerRadius, shape.cornerSize.width)
    } else {
      content
        .environment(\.cornerContainerRadius, shape.cornerSize.width)
    }
  }
}

extension View {
  func cornerContainer(_ shape: RoundedRectangle) -> some View {
    modifier(CornerContainer(shape: shape))
  }
}
