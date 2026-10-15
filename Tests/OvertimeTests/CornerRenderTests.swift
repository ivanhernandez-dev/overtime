import AppKit
import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import SwiftUI
import Testing

@testable import Overtime

@MainActor
struct CornerRenderTests {
  nonisolated static let directory = ProcessInfo.processInfo.environment["OVERTIME_RENDER_DIR"]
  static let margin: CGFloat = 24
  static let offscreenOrigin = CGPoint(x: -20_000, y: -20_000)
  static let heldSeconds: Double = 5025
  static let powerPercent = 82

  enum Look: String, CaseIterable {
    case light
    case dark

    var appearance: NSAppearance? {
      NSAppearance(named: self == .light ? .aqua : .darkAqua)
    }

    var backdrop: NSColor {
      NSColor(white: self == .light ? 0.82 : 0.18, alpha: 1)
    }
  }

  struct Capture {
    let content: NSBitmapImageRep
    let size: CGSize
  }

  @Test(.enabled(if: CornerRenderTests.directory != nil, "renders PNGs only when OVERTIME_RENDER_DIR names a folder"))
  func rendersThePanelAndEverySettingsPane() async throws {
    let folder = URL(fileURLWithPath: try #require(Self.directory), isDirectory: true)
    var manifest: [String] = []

    let bound = PanelModelTests.Bound()
    bound.host.publish(holdingSnapshot(bound))
    #expect(await waitUntil { bound.model.snapshot?.sessions.count == 3 })
    for look in Look.allCases {
      let panel = try capture(MenuBarPanelContent(model: bound.model), size: nil, look: look)
      try write(
        compose(panel, look: look, mask: MenuBarPanelController.cornerMask()), name: "panel-holding-\(look.rawValue)",
        into: folder, manifest: &manifest)
      let reopen = try capture(ReopenWindow(model: bound.model, close: {}), size: nil, look: look)
      try write(
        compose(reopen, look: look, mask: nil), name: "reopen-holding-\(look.rawValue)", into: folder,
        manifest: &manifest)
    }

    bound.host.publish(
      EngineSnapshot(
        busy: false, wanted: false, reason: "idle", lidClosed: false, power: .ac(percent: Self.powerPercent)))
    #expect(await waitUntil { bound.model.snapshot?.busy == false })
    for look in Look.allCases {
      let panel = try capture(MenuBarPanelContent(model: bound.model), size: nil, look: look)
      try write(
        compose(panel, look: look, mask: MenuBarPanelController.cornerMask()), name: "panel-idle-\(look.rawValue)",
        into: folder, manifest: &manifest)
    }

    let settingsFolder = try TestFolder()
    let settings = SettingsModel(
      settingsFile: settingsFolder.url.appendingPathComponent("settings.json"), host: FakeEngineHost(),
      environment: [:], homeDirectory: SettingsWindowTests.testHome)
    for pane in SettingsPane.allCases {
      settings.select(pane)
      #expect(settings.selectedPane == pane)
      for look in Look.allCases {
        let window = try capture(SettingsWindow(model: settings), size: SettingsWindow.contentSize, look: look)
        try write(
          compose(window, look: look, mask: nil), name: "settings-\(pane.rawValue)-\(look.rawValue)", into: folder,
          manifest: &manifest)
      }
    }

    #expect(manifest.count == 20)
    let lines = manifest.joined(separator: "\n") + "\n"
    try lines.write(to: folder.appendingPathComponent("manifest.txt"), atomically: true, encoding: .utf8)
  }

  private func holdingSnapshot(_ bound: PanelModelTests.Bound) -> EngineSnapshot {
    let started = bound.started(secondsAgo: 86_400)
    let sessions = [
      SessionSummary(
        pid: 11, cwd: "/Users/dev/api", ttyName: "ttys003", startMono: started,
        workingSince: bound.started(secondsAgo: 3900)),
      SessionSummary(
        pid: 12, cwd: "/opt/web", ttyName: "ttys004", startMono: started, workingSince: bound.started(secondsAgo: 30)),
      SessionSummary(pid: 13, cwd: "/Users/dev/notes", ttyName: "ttys005", startMono: started),
    ]
    return EngineSnapshot(
      busy: true, wanted: true, reason: "busy", lidClosed: false, sessions: sessions,
      wantedSince: bound.started(secondsAgo: Self.heldSeconds), power: .ac(percent: Self.powerPercent))
  }

  private func capture(_ view: some View, size fixed: CGSize?, look: Look) throws -> Capture {
    let hosting = NSHostingView(rootView: view)
    hosting.appearance = look.appearance
    let size = fixed ?? hosting.fittingSize
    let window = NSWindow(
      contentRect: CGRect(origin: Self.offscreenOrigin, size: size), styleMask: [.borderless], backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = look.appearance
    window.contentView = hosting
    hosting.frame = CGRect(origin: .zero, size: size)
    hosting.layoutSubtreeIfNeeded()
    let content = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    hosting.cacheDisplay(in: hosting.bounds, to: content)
    window.contentView = nil
    window.close()
    return Capture(content: content, size: size)
  }

  private func compose(_ capture: Capture, look: Look, mask: NSImage?) throws -> NSBitmapImageRep {
    let scale = CGFloat(capture.content.pixelsWide) / capture.size.width
    let canvasSize = CGSize(
      width: capture.size.width + 2 * Self.margin, height: capture.size.height + 2 * Self.margin)
    let canvasRect = CGRect(origin: .zero, size: canvasSize)
    let rect = CGRect(origin: CGPoint(x: Self.margin, y: Self.margin), size: capture.size)
    let layer = try bitmap(canvasSize, scale: scale)
    try draw(into: layer, look: look) {
      NSColor.windowBackgroundColor.setFill()
      rect.fill()
      capture.content.draw(
        in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
      mask?.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
    }
    let canvas = try bitmap(canvasSize, scale: scale)
    try draw(into: canvas, look: look) {
      look.backdrop.setFill()
      canvasRect.fill()
      layer.draw(in: canvasRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    return canvas
  }

  private func bitmap(_ size: CGSize, scale: CGFloat) throws -> NSBitmapImageRep {
    let rep = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded()),
        pixelsHigh: Int((size.height * scale).rounded()), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    rep.size = size
    return rep
  }

  private func draw(into rep: NSBitmapImageRep, look: Look, _ body: () -> Void) throws {
    let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
    let appearance = try #require(look.appearance)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    appearance.performAsCurrentDrawingAppearance(body)
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
  }

  private func write(_ rep: NSBitmapImageRep, name: String, into folder: URL, manifest: inout [String]) throws {
    let data = try #require(rep.representation(using: .png, properties: [:]))
    #expect(!data.isEmpty)
    try data.write(to: folder.appendingPathComponent("\(name).png"))
    manifest.append("\(name).png \(rep.pixelsWide)x\(rep.pixelsHigh)")
  }
}
