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
struct ReadmeScreenshotTests {
  nonisolated static let directory = ProcessInfo.processInfo.environment["OVERTIME_SCREENSHOT_DIR"]
  static let scale: CGFloat = 2
  static let margin: CGFloat = 40
  static let shadowBlur: CGFloat = 24
  static let shadowOffset: CGFloat = 8
  static let windowRadius = CGFloat(CornerGeometry.windowRadius(.macOS26AndLater))
  static let offscreenOrigin = CGPoint(x: -20_000, y: -20_000)
  static let heldSeconds: Double = 5025
  static let powerPercent = 82
  static let batteryCelsius = 31
  static let byteLimit = 409_600
  static let patchPoints: CGFloat = 2
  static let rowProbeInset: CGFloat = 14
  static let switchProbeFraction: CGFloat = 0.3
  static let hairlineWidth: CGFloat = 0.5
  static let hairlineAlpha: CGFloat = 0.1
  static let accentChroma = 0.30
  static let accentBrightness = 0.40
  static let closeRedMargin = 0.30
  static let labelStart = 0.25
  static let labelEnd = 0.45
  static let labelBand = 6
  static let labelWhite = 0.9

  enum Look: String {
    case light
    case dark

    var appearance: NSAppearance? {
      NSAppearance(named: self == .light ? .aqua : .darkAqua)
    }

    var shadowAlpha: CGFloat {
      self == .light ? 0.25 : 0.5
    }
  }

  enum Outline {
    case panel
    case window
  }

  enum ProbeKind {
    case selectedRow
    case loginSwitch
    case closeButton
  }

  final class ActiveRenderWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    @objc func hasKeyAppearance() -> Bool {
      true
    }
  }

  struct Capture {
    let content: NSBitmapImageRep
    let size: CGSize
  }

  struct Colour {
    let red: Double
    let green: Double
    let blue: Double
  }

  struct Measured {
    let id: String
    let value: Double
    let pass: Bool

    var verdict: String {
      "\(id) \(String(format: "%.2f", value)) \(pass ? "pass" : "fail")"
    }
  }

  struct Report {
    var images: [String] = []
    var probes: [(stem: String, measured: Measured)] = []
    var controls: [Measured] = []
    var bytes: [(name: String, count: Int)] = []

    var text: String {
      let lines =
        images + probes.map { "probe \($0.stem) \($0.measured.verdict)" } + controls.map { "control \($0.verdict)" }
      return lines.joined(separator: "\n") + "\n"
    }
  }

  @Test(
    .enabled(
      if: ReadmeScreenshotTests.directory != nil,
      "writes the README screenshots only when OVERTIME_SCREENSHOT_DIR names a folder outside the repository"))
  func rendersTheReadmeScreenshots() async throws {
    let folder = URL(fileURLWithPath: try #require(Self.directory), isDirectory: true)
    var report = Report()

    let panelBound = PanelModelTests.Bound()
    panelBound.host.publish(holdingSnapshot(panelBound))
    #expect(await waitUntil { panelBound.model.snapshot?.sessions.count == 3 })
    for look in [Look.dark] {
      let (capture, _) = try plainCapture(
        MenuBarPanelContent(model: panelBound.model), size: nil, look: look, kinds: [])
      try write(
        compose(capture, look: look, outline: .panel), name: "panel-holding-\(look.rawValue)", into: folder,
        report: &report)
    }

    let store = try TestFolder()
    let settingsBound = PanelModelTests.Bound()
    settingsBound.model.attachLoginItem(PanelModelTests.FakeLoginItem(status: .enabled))
    let notRegistered = HelperMonitorState(installer: .notRegistered)
    let helper = HelperPaneModel(
      panel: settingsBound.model, source: HelperPaneTests.FakeHelperSource(notRegistered))
    helper.apply(notRegistered)
    let settings = SettingsModel(
      settingsFile: store.url.appendingPathComponent("settings.json"), host: FakeEngineHost(),
      panel: settingsBound.model, notifications: SettingsWindowTests.FakeNotificationPort(.authorized),
      helper: helper, environment: [:], homeDirectory: SettingsWindowTests.testHome)
    await settings.refreshNotificationAuthorization()
    #expect(settings.notificationAuthorization == .authorized)
    #expect(settings.launchAtLogin)
    #expect(settings.helperPane.uiState == .off)
    #expect(SettingsPane.allCases.allSatisfy { settings.sidebarBadge(for: $0) == nil })

    settings.select(.general)
    #expect(settings.selectedPane == .general)
    let general = try await activeCapture(
      SettingsWindow(model: settings), title: SettingsPane.general.title, size: SettingsWindow.contentSize,
      kinds: [.selectedRow, .loginSwitch, .closeButton])
    try record(general, stem: "settings-general-dark", into: folder, report: &report)

    let (_, controls) = try plainCapture(
      SettingsWindow(model: settings), size: SettingsWindow.contentSize, look: .dark,
      kinds: [.selectedRow, .loginSwitch])
    report.controls = controls

    settings.select(.unplugProtection)
    #expect(settings.selectedPane == .unplugProtection)
    let unplug = try await activeCapture(
      SettingsWindow(model: settings), title: SettingsPane.unplugProtection.title, size: SettingsWindow.contentSize,
      kinds: [.selectedRow, .closeButton])
    try record(unplug, stem: "settings-unplug-protection-dark", into: folder, report: &report)

    settingsBound.host.publish(idleSnapshot(settingsBound))
    #expect(await waitUntil { settings.batteryTemperatureText == "\(Self.batteryCelsius)°C" })
    #expect(settings.batteryProtectionEnabled)
    #expect(!settings.temperatureProtectionEnabled)
    #expect(!settings.helperInstalled)
    #expect(SettingsPane.allCases.allSatisfy { settings.sidebarBadge(for: $0) == nil })
    settings.select(.battery)
    #expect(settings.selectedPane == .battery)
    let battery = try await activeCapture(
      SettingsWindow(model: settings), title: SettingsPane.battery.title, size: SettingsWindow.contentSize,
      kinds: [.selectedRow, .closeButton])
    try record(battery, stem: "settings-battery-dark", into: folder, report: &report)

    let onboardingBound = PanelModelTests.Bound()
    onboardingBound.model.attachLoginItem(PanelModelTests.FakeLoginItem(status: .enabled))
    let onboarding = OnboardingModel(
      panel: onboardingBound.model, preferencesFile: store.url.appendingPathComponent("preferences.json"))
    onboarding.begin()
    #expect(onboarding.currentStep == .welcome)
    let iconName = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String)
    NSApplication.shared.applicationIconImage = NSImage(named: iconName)
    defer { NSApplication.shared.applicationIconImage = nil }
    let welcome = try await activeCapture(
      OnboardingWindow(model: onboarding), title: OnboardingWindow.title, size: OnboardingWindow.contentSize,
      kinds: [.closeButton])
    try record(welcome, stem: "onboarding-dark", into: folder, report: &report)

    let hotspot = try OnboardingWindowTests.Fixture(location: .notDetermined, hotspot: .autoDetect, networks: [])
    let hotspotSettings = hotspot.settings
    hotspot.model.begin()
    hotspot.walk(to: .location)
    #expect(hotspot.model.currentStep == .location)
    #expect(await waitUntil { hotspotSettings.knownNetworksRead })
    #expect(hotspotSettings.hotspotCaption == nil)
    #expect(hotspot.model.locationRow == LocationRow.for(.notDetermined))
    #expect(hotspot.model.defaultButton.action == .allowLocation)
    let location = try await activeCapture(
      OnboardingWindow(model: hotspot.model), title: OnboardingWindow.title, size: OnboardingWindow.contentSize,
      kinds: [.closeButton])
    try record(location, stem: "onboarding-hotspot-dark", into: folder, report: &report)

    let setup = try OnboardingWindowTests.Fixture(login: .enabled)
    setup.model.begin()
    setup.walk(to: .selfTest)
    #expect(setup.model.currentStep == .selfTest)
    #expect(setup.model.shownSelfTest == .waiting)
    #expect(!setup.model.canStartSelfTest)
    #expect(setup.model.defaultButton.action == .finish)
    let complete = try await activeCapture(
      OnboardingWindow(model: setup.model), title: OnboardingWindow.title, size: OnboardingWindow.contentSize,
      kinds: [.closeButton])
    #expect(setup.model.shownSelfTest == .waiting)
    try record(complete, stem: "onboarding-complete-dark", into: folder, report: &report)

    try report.text.write(to: folder.appendingPathComponent("checks.txt"), atomically: true, encoding: .utf8)

    #expect(report.images.count == 7)
    #expect(report.probes.count == 17)
    #expect(report.controls.count == 2)
    for probe in report.probes {
      #expect(probe.measured.pass, "probe \(probe.stem) \(probe.measured.verdict)")
    }
    for control in report.controls {
      #expect(!control.pass, "control \(control.verdict)")
    }
    for image in report.bytes {
      #expect(image.count <= Self.byteLimit, "\(image.name) is \(image.count) bytes")
    }
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

  private func idleSnapshot(_ bound: PanelModelTests.Bound) -> EngineSnapshot {
    EngineSnapshot(
      busy: false, wanted: false, reason: "idle", lidClosed: false, power: .ac(percent: Self.powerPercent),
      batteryTemperature: .celsius(Self.batteryCelsius))
  }

  private func record(
    _ result: (capture: Capture, measured: [Measured]), stem: String, into folder: URL, report: inout Report
  ) throws {
    for measured in result.measured {
      report.probes.append((stem, measured))
    }
    try write(compose(result.capture, look: .dark, outline: .window), name: stem, into: folder, report: &report)
  }

  private func activeCapture(
    _ view: some View, title: String, size: CGSize, kinds: [ProbeKind]
  ) async throws -> (capture: Capture, measured: [Measured]) {
    let appearance = Look.dark.appearance
    let window = ActiveRenderWindow(
      contentRect: CGRect(origin: Self.offscreenOrigin, size: size), styleMask: AuxiliaryWindowController.styleMask,
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = title
    window.appearance = appearance
    let hosting = NSHostingView(rootView: activeRoot(view))
    hosting.appearance = appearance
    window.contentView = hosting
    window.setContentSize(size)
    let frameView = try #require(hosting.superview)
    frameView.layoutSubtreeIfNeeded()
    for row in allViews(frameView).compactMap({ $0 as? NSTableRowView }) {
      row.isEmphasized = true
    }
    if let row = selectedRow(in: hosting) {
      #expect(await waitUntil { labelIsEmphasized(row) })
      frameView.layoutSubtreeIfNeeded()
    }
    let capture = try cache(frameView)
    let measured = try kinds.map { kind in
      try measure(kind, root: hosting, captured: frameView, rep: capture.content, window: window)
    }
    window.contentView = nil
    window.close()
    return (capture, measured)
  }

  private func selectedRow(in root: NSView) -> NSTableRowView? {
    allViews(root).compactMap { $0 as? NSTableRowView }.first { $0.isSelected }
  }

  private func labelIsEmphasized(_ row: NSTableRowView) -> Bool {
    guard let rep = row.bitmapImageRepForCachingDisplay(in: row.bounds) else { return false }
    row.cacheDisplay(in: row.bounds, to: rep)
    let middle = rep.pixelsHigh / 2
    let from = Int(Double(rep.pixelsWide) * Self.labelStart)
    let to = Int(Double(rep.pixelsWide) * Self.labelEnd)
    for x in from..<to {
      for y in (middle - Self.labelBand)...(middle + Self.labelBand) {
        guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
        if min(colour.redComponent, colour.greenComponent, colour.blueComponent) > Self.labelWhite { return true }
      }
    }
    return false
  }

  private func activeRoot(_ view: some View) -> AnyView {
    if #available(macOS 15, *) {
      return AnyView(view.environment(\.appearsActive, true))
    }
    return AnyView(view)
  }

  private func plainCapture(
    _ view: some View, size fixed: CGSize?, look: Look, kinds: [ProbeKind]
  ) throws -> (capture: Capture, measured: [Measured]) {
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
    let capture = try cache(hosting)
    let measured = try kinds.map { kind in
      try measure(kind, root: hosting, captured: hosting, rep: capture.content, window: nil)
    }
    window.contentView = nil
    window.close()
    return (capture, measured)
  }

  private func cache(_ view: NSView) throws -> Capture {
    let size = view.bounds.size
    let rep = try bitmap(size)
    view.cacheDisplay(in: view.bounds, to: rep)
    return Capture(content: rep, size: size)
  }

  private func bitmap(_ size: CGSize) throws -> NSBitmapImageRep {
    let rep = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int((size.width * Self.scale).rounded()),
        pixelsHigh: Int((size.height * Self.scale).rounded()), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    rep.size = size
    try #require(CGFloat(rep.pixelsWide) == size.width * Self.scale)
    try #require(CGFloat(rep.pixelsHigh) == size.height * Self.scale)
    return rep
  }

  private func allViews(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap { allViews($0) }
  }

  private func measure(
    _ kind: ProbeKind, root: NSView, captured: NSView, rep: NSBitmapImageRep, window: NSWindow?
  ) throws -> Measured {
    switch kind {
    case .selectedRow:
      let row = try #require(selectedRow(in: root))
      let rect = row.convert(row.bounds, to: captured)
      let colour = try patch(rep, at: CGPoint(x: rect.maxX - Self.rowProbeInset, y: rect.midY), in: captured)
      return accent("selected-row", colour)
    case .loginSwitch:
      let control = try #require(allViews(root).compactMap { $0 as? NSSwitch }.first { $0.state == .on })
      let rect = control.convert(control.bounds, to: captured)
      let colour = try patch(
        rep, at: CGPoint(x: rect.minX + Self.switchProbeFraction * rect.width, y: rect.midY), in: captured)
      return accent("login-switch", colour)
    case .closeButton:
      let button = try #require(window?.standardWindowButton(.closeButton))
      let rect = button.convert(button.bounds, to: captured)
      let colour = try patch(rep, at: CGPoint(x: rect.midX, y: rect.midY), in: captured)
      let value = colour.red - max(colour.green, colour.blue)
      return Measured(id: "close-button", value: value, pass: value >= Self.closeRedMargin)
    }
  }

  private func accent(_ id: String, _ colour: Colour) -> Measured {
    let high = max(colour.red, colour.green, colour.blue)
    let chroma = high - min(colour.red, colour.green, colour.blue)
    return Measured(id: id, value: chroma, pass: chroma >= Self.accentChroma && high >= Self.accentBrightness)
  }

  private func patch(_ rep: NSBitmapImageRep, at point: CGPoint, in view: NSView) throws -> Colour {
    let top = view.isFlipped ? point.y : view.bounds.height - point.y
    let centreX = Int((point.x * Self.scale).rounded())
    let centreY = Int((top * Self.scale).rounded())
    let half = Int(Self.patchPoints * Self.scale / 2)
    var red = 0.0
    var green = 0.0
    var blue = 0.0
    var count = 0.0
    for x in (centreX - half)..<(centreX + half) {
      for y in (centreY - half)..<(centreY + half) {
        let colour = try #require(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        red += colour.redComponent
        green += colour.greenComponent
        blue += colour.blueComponent
        count += 1
      }
    }
    return Colour(red: red / count, green: green / count, blue: blue / count)
  }

  private func compose(_ capture: Capture, look: Look, outline: Outline) throws -> NSBitmapImageRep {
    let rect = CGRect(origin: .zero, size: capture.size)
    let layer = try bitmap(capture.size)
    try draw(into: layer, look: look) {
      switch outline {
      case .panel:
        NSColor.windowBackgroundColor.setFill()
        rect.fill()
        capture.content.draw(
          in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        MenuBarPanelController.cornerMask().draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
      case .window:
        NSBezierPath(cgPath: windowShape(in: rect, radius: Self.windowRadius)).addClip()
        NSColor.windowBackgroundColor.setFill()
        rect.fill()
        capture.content.draw(
          in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let inset = Self.hairlineWidth / 2
        let hairline = NSBezierPath(
          cgPath: windowShape(in: rect.insetBy(dx: inset, dy: inset), radius: Self.windowRadius - inset))
        hairline.lineWidth = Self.hairlineWidth
        NSColor.black.withAlphaComponent(Self.hairlineAlpha).setStroke()
        hairline.stroke()
      }
    }
    let canvasSize = CGSize(
      width: capture.size.width + 2 * Self.margin, height: capture.size.height + 2 * Self.margin)
    let canvas = try bitmap(canvasSize)
    try draw(into: canvas, look: look) {
      let shadow = NSShadow()
      shadow.shadowBlurRadius = Self.shadowBlur * Self.scale
      shadow.shadowOffset = NSSize(width: 0, height: -Self.shadowOffset * Self.scale)
      shadow.shadowColor = NSColor.black.withAlphaComponent(look.shadowAlpha)
      shadow.set()
      layer.draw(
        in: CGRect(origin: CGPoint(x: Self.margin, y: Self.margin), size: capture.size), from: .zero,
        operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    return canvas
  }

  private func windowShape(in rect: CGRect, radius: CGFloat) -> CGPath {
    RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
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

  private func write(_ canvas: NSBitmapImageRep, name: String, into folder: URL, report: inout Report) throws {
    let data = try #require(canvas.representation(using: .png, properties: [:]))
    try data.write(to: folder.appendingPathComponent("\(name).png"))
    let points = canvas.size
    report.images.append(
      "image \(name).png \(canvas.pixelsWide)x\(canvas.pixelsHigh) px \(Int(points.width))x\(Int(points.height)) pt")
    report.bytes.append((name, data.count))
    let alpha = try #require(canvas.colorAt(x: 0, y: 0)).alphaComponent
    report.probes.append((name, Measured(id: "transparent-corner", value: alpha, pass: alpha == 0)))
  }
}
