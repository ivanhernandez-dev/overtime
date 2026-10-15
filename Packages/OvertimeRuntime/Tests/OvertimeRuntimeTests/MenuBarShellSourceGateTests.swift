import Foundation
import Testing

struct MenuBarShellSourceGateTests {
  typealias SourceFile = NetworkSourceGateTests.SourceFile

  static let folder = "Sources/Overtime/"
  static let app = folder + "OvertimeApp.swift"
  static let delegate = folder + "AppDelegate.swift"
  static let statusItem = folder + "MenuBar/StatusItemController.swift"
  static let panel = folder + "MenuBar/MenuBarPanelController.swift"

  static let scene = "MenuBar" + "Extra"
  static let sceneStyle = "menuBar" + "ExtraStyle"
  static let statusBar = "NSStatusBar" + ".system"
  static let activation = "." + "activate("
  static let keyEvents = ["key" + "Down", "key" + "Up", "flags" + "Changed"]
  static let pinnedMask = "static let actionMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]"
  static let pinnedSend = "sendAction(on: Self.actionMask)"
  static let anySend = "sendAction(on:"
  static let nonActivating = "." + "nonactivatingPanel"
  static let staysWhenInactive = "hidesOnDeactivate = false"
  static let hidesWhenInactive = "hidesOnDeactivate = " + "true"
  static let frontRegardless = "orderFrontRegardless()"
  static let escHandler = "override func cancelOperation("
  static let globalMonitor = "addGlobal" + "MonitorForEvents("
  static let localMonitor = "addLocal" + "MonitorForEvents("
  static let monitorRemoval = "NSEvent.removeMonitor("
  static let monitorRemovals = 1

  static func shellSources() throws -> [SourceFile] {
    let root = AppViewSourceGuardTests.appSources.path + "/"
    return try AppViewSourceGuardTests.appSourceFiles().map { file in
      let relative = file.path.hasPrefix(root) ? String(file.path.dropFirst(root.count)) : file.name
      return SourceFile(path: folder + relative, text: file.text)
    }
  }

  static func squeezed(_ text: String) -> String {
    text.filter { !$0.isWhitespace }
  }

  static func count(_ needle: String, in text: String) -> Int {
    squeezed(text).components(separatedBy: squeezed(needle)).count - 1
  }

  static func findings(in files: [SourceFile]) -> [String] {
    var found: [String] = []
    for file in files {
      if count(scene, in: file.text) > 0 {
        found.append("\(file.path) names the SwiftUI menu bar scene")
      }
      if count(sceneStyle, in: file.text) > 0 {
        found.append("\(file.path) names the menu bar scene's style modifier")
      }
      if keyEvents.contains(where: { count($0, in: file.text) > 0 }) {
        found.append("\(file.path) names a key event type")
      }
      if file.path.hasPrefix(folder + "MenuBar/"), count(activation, in: file.text) > 0 {
        found.append("\(file.path) asks the application to activate")
      }
      if file.path != statusItem, count(statusBar, in: file.text) > 0 {
        found.append("\(file.path) builds a second status item")
      }
    }
    return (found + statusItemFindings(in: files) + panelFindings(in: files)).sorted()
  }

  static func statusItemFindings(in files: [SourceFile]) -> [String] {
    guard let file = files.first(where: { $0.path == statusItem }) else {
      return ["\(statusItem) is missing"]
    }
    var found: [String] = []
    if count(statusBar, in: file.text) != 1 {
      found.append("\(file.path) does not build exactly one status item")
    }
    if count(pinnedMask, in: file.text) != 1 {
      found.append("\(file.path) does not pin the left and the right mouse-down as its action mask")
    }
    if count(pinnedSend, in: file.text) != 1 || count(anySend, in: file.text) != 1 {
      found.append("\(file.path) does not send its action on the pinned mask exactly once")
    }
    return found
  }

  static func panelFindings(in files: [SourceFile]) -> [String] {
    guard let file = files.first(where: { $0.path == panel }) else {
      return ["\(panel) is missing"]
    }
    var found: [String] = []
    if count(nonActivating, in: file.text) == 0 {
      found.append("\(file.path) lost the non-activating panel style")
    }
    if count(staysWhenInactive, in: file.text) != 1 || count(hidesWhenInactive, in: file.text) != 0 {
      found.append("\(file.path) does not keep the panel on screen while the app is inactive")
    }
    if count(frontRegardless, in: file.text) == 0 {
      found.append("\(file.path) does not order the panel front regardless of activation")
    }
    if count(escHandler, in: file.text) != 1 {
      found.append("\(file.path) does not override the cancel operation exactly once")
    }
    if count(globalMonitor, in: file.text) != 1 {
      found.append("\(file.path) does not add exactly one global mouse monitor")
    }
    if count(localMonitor, in: file.text) != 1 {
      found.append("\(file.path) does not add exactly one local mouse monitor")
    }
    if count(monitorRemoval, in: file.text) != monitorRemovals {
      found.append("\(file.path) does not remove its monitors in \(monitorRemovals) place")
    }
    return found
  }

  static func planting(
    _ path: String, in files: [SourceFile], _ change: (SourceFile) -> SourceFile
  ) throws -> [SourceFile] {
    _ = try #require(files.first { $0.path == path }, "\(path) is not among the app sources")
    return files.map { $0.path == path ? change($0) : $0 }
  }

  static func expectOneFinding(
    planting path: String, _ change: (SourceFile) -> SourceFile
  ) throws {
    let files = try planting(path, in: try shellSources(), change)
    PublicFaceGateTests.expectOne(findings(in: files), naming: path)
  }

  @Test func theAppSourcesHoldTheShellFilesTheGateReads() throws {
    let files = try Self.shellSources()
    let paths = Set(files.map(\.path))
    for path in [Self.app, Self.delegate, Self.statusItem, Self.panel] {
      #expect(paths.contains(path), "\(path) is not among the app sources")
    }
    #expect(files.count > 40)
    #expect(files.allSatisfy { !$0.text.isEmpty })
  }

  @Test func theLiveShellHasNoFindings() throws {
    #expect(Self.findings(in: try Self.shellSources()) == [])
  }

  @Test func aReturningMenuBarSceneIsReported() throws {
    try Self.expectOneFinding(planting: Self.app) { file in
      PublicFaceGateTests.appending(file, "struct Returned: Scene { var body: some Scene { \(Self.scene) {} } }")
    }
    try Self.expectOneFinding(planting: Self.app) { file in
      PublicFaceGateTests.appending(file, "let style = scene.\(Self.sceneStyle)(.window)")
    }
  }

  @Test func aStatusItemThatStopsListeningToTheRightButtonIsReported() throws {
    try Self.expectOneFinding(planting: Self.statusItem) { file in
      PublicFaceGateTests.replacing(file, "[.leftMouseDown, .rightMouseDown]", with: "[.leftMouseDown]")
    }
    try Self.expectOneFinding(planting: Self.statusItem) { file in
      PublicFaceGateTests.replacing(file, Self.pinnedSend, with: "sendAction(on: [.leftMouseDown])")
    }
  }

  enum PanelDrift: CaseIterable, Sendable {
    case asksForActivation
    case hidesWhenInactive
    case losesTheNonActivatingStyle

    func apply(to file: SourceFile) -> SourceFile {
      switch self {
      case .asksForActivation:
        PublicFaceGateTests.appending(file, "func raise() { NSApp\(activation)) }")
      case .hidesWhenInactive:
        PublicFaceGateTests.replacing(file, staysWhenInactive, with: MenuBarShellSourceGateTests.hidesWhenInactive)
      case .losesTheNonActivatingStyle:
        PublicFaceGateTests.replacing(file, nonActivating, with: ".utilityWindow")
      }
    }
  }

  @Test(arguments: PanelDrift.allCases)
  func aPanelThatNeedsActivationOrHidesWhenInactiveIsReported(drift: PanelDrift) throws {
    try Self.expectOneFinding(planting: Self.panel) { drift.apply(to: $0) }
  }

  enum MonitorDrift: CaseIterable, Sendable {
    case keyMonitor
    case secondGlobalMouseMonitor

    var path: String {
      switch self {
      case .keyMonitor: statusItem
      case .secondGlobalMouseMonitor: panel
      }
    }

    var addition: String {
      switch self {
      case .keyMonitor:
        "let keys = NSEvent.\(localMonitor)matching: .\(keyEvents[0])) { $0 }"
      case .secondGlobalMouseMonitor:
        "let extra = NSEvent.\(globalMonitor)matching: .leftMouseDown) { _ in }"
      }
    }
  }

  @Test(arguments: MonitorDrift.allCases)
  func aKeyMonitorOrAnExtraMouseMonitorIsReported(drift: MonitorDrift) throws {
    try Self.expectOneFinding(planting: drift.path) { PublicFaceGateTests.appending($0, drift.addition) }
  }

  @Test func aSecondStatusItemIsReported() throws {
    try Self.expectOneFinding(planting: Self.delegate) { file in
      PublicFaceGateTests.appending(file, "let second = \(Self.statusBar).statusItem(withLength: 24)")
    }
  }

  @Test func aPanelWithoutItsEscHandlerIsReported() throws {
    try Self.expectOneFinding(planting: Self.panel) { file in
      PublicFaceGateTests.replacing(file, Self.escHandler, with: "func cancelRenamed(")
    }
  }
}
