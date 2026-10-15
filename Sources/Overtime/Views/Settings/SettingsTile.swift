import AppKit
import OvertimeAppSupport
import SwiftUI

extension PaneTileColor {
  var nsColor: NSColor {
    switch self {
    case .gray: .systemGray
    case .purple: .systemPurple
    case .green: .systemGreen
    case .blue: .systemBlue
    case .orange: .systemOrange
    case .red: .systemRed
    }
  }
}

struct SettingsTile: View {
  let pane: SettingsPane
  let size: PaneTileSize

  var body: some View {
    let side = CGFloat(size.side)
    let symbolSide = CGFloat(size.symbolSide)
    Image(systemName: pane.symbol)
      .resizable()
      .scaledToFit()
      .foregroundStyle(.white)
      .frame(width: symbolSide, height: symbolSide)
      .frame(width: side, height: side)
      .background {
        ZStack {
          shape.fill(Color(nsColor: pane.tileColor.nsColor))
          shape.fill(highlight)
        }
      }
      .accessibilityHidden(true)
  }

  private var shape: AnyShape {
    switch size {
    case .sidebar: AnyShape(CornerShapes.sidebarTile)
    case .header: CornerShapes.paneHeaderTile
    }
  }

  private var highlight: LinearGradient {
    LinearGradient(
      colors: [.white.opacity(PaneTile.highlightOpacity), .white.opacity(0)], startPoint: .top, endPoint: .bottom)
  }
}
