import Foundation
import Testing

struct CornerShapeGateTests {
  typealias SourceFile = AppViewSourceGuardTests.SourceFile

  static let shapesFile = "CornerShapes.swift"
  static let geometryFile = "CornerGeometry.swift"
  static let pendingFiles: [String] = []
  static let nonCornerRadii = ["magentaRadius", "cyanRadius"]
  static let roundedRectangle = "RoundedRectangle("
  static let continuousStyle = ".continuous"
  static let systemShapes = ["ConcentricRectangle(", ".containerShape(", "ContainerRelativeShape"]
  static let circularPaths = ["NSBezierPath(roundedRect:", "xRadius:"]
  static let shapesTokens = ["#available(macOS 26", "ConcentricRectangle(", ".containerShape(", ".concentric(minimum:"]
  static let cornerReaders: [(file: String, tokens: [String])] = [
    ("MenuBarPanelController.swift", ["CornerShapes.panel", ".cornerContainer("]),
    (
      "PanelView.swift",
      ["CornerShapes.heroCard(", "CornerGeometry.panelPadding", "PanelRowButtonStyle(corners: .lastRow)"]
    ),
    ("ControlsSection.swift", ["CornerShapes.rowHighlight(", "CornerShapes.actionTile"]),
    ("SessionsSection.swift", ["CornerShapes.sessionTile"]),
    ("StatusLinesSection.swift", ["CornerGeometry.chipVerticalPadding", "CornerGeometry.chipHorizontalPadding"]),
    (
      "SettingsPaneHeader.swift",
      ["CornerShapes.paneHeaderCard", "CornerGeometry.paneHeaderTilePadding", ".cornerContainer("]
    ),
    ("SettingsTile.swift", ["CornerShapes.sidebarTile", "CornerShapes.paneHeaderTile"]),
  ]
  static let literalLimit =
    "the literal finder sees numbers only: a radius computed by an expression or passed through another name is"
    + " not seen, and the table test pins those values"
  static let bodyLineLimit = 12
  static let number = #"-?[0-9]+(\.[0-9]+)?"#
  static let namedRadiusLiteral =
    #"(cornerRadius|CornerRadius|LeadingRadius|TrailingRadius|xRadius|yRadius)\s*(:\s*(CGFloat|Double)\s*=|:|=)\s*[0-9]"#
  static let modifierLiteral = #"(\.cornerRadius|\.fixed)\(\s*[0-9]"#
  static let radiusDeclaration = #"\b(let|var)\s+([A-Za-z_][A-Za-z0-9_]*(Radius|Radii))\b(.*)$"#
  static let declarationGivesANumber = #"(=|\{|\breturn)\s*"# + number
  static let bareNumber = #"^\s*(return\s+)?"# + number + #"\s*\}?\s*$"#
  static let caseEndsInANumber = #"^\s*case\b.*[^A-Za-z0-9_.]"# + number + #"\s*$"#

  static func matches(_ pattern: String, _ line: String) -> Bool {
    line.range(of: pattern, options: .regularExpression) != nil
  }

  static func radiusName(in line: String) -> (name: String, rest: Substring)? {
    guard let regex = try? Regex(radiusDeclaration), let match = line.firstMatch(of: regex),
      let name = match.output[2].substring, let rest = match.output[4].substring
    else { return nil }
    return (String(name), rest)
  }

  static func literalRadiusLines(in text: String) -> [Int] {
    let lines = text.components(separatedBy: "\n")
    var found: [Int] = []
    for (index, line) in lines.enumerated() {
      if matches(namedRadiusLiteral, line) || matches(modifierLiteral, line) {
        found.append(index + 1)
        continue
      }
      guard let declaration = radiusName(in: line), !nonCornerRadii.contains(declaration.name) else { continue }
      if matches(declarationGivesANumber, String(declaration.rest)) {
        found.append(index + 1)
        continue
      }
      var depth = line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
      var offset = index + 1
      while depth > 0, offset < lines.count, offset - index <= bodyLineLimit {
        let body = lines[offset]
        if matches(bareNumber, body) || matches(caseEndsInANumber, body) {
          found.append(index + 1)
          break
        }
        depth += body.filter { $0 == "{" }.count - body.filter { $0 == "}" }.count
        offset += 1
      }
    }
    return found
  }

  static func occurrences(of needle: String, in text: String) -> Int {
    AppViewSourceGuardTests.occurrences(of: needle, in: text)
  }

  static func cornerFindings(app: [SourceFile], package: [SourceFile]) -> [String] {
    var findings: [String] = []
    if !package.contains(where: { $0.name == geometryFile }) {
      findings.append("\(geometryFile) is not among the package sources")
    }
    for file in app {
      let exempt = file.name == shapesFile || pendingFiles.contains(file.name)
      if !exempt, occurrences(of: roundedRectangle, in: file.text) > 0 {
        findings.append("\(file.name) builds a rounded rectangle outside \(shapesFile)")
      }
      if file.name != shapesFile, systemShapes.contains(where: { occurrences(of: $0, in: file.text) > 0 }) {
        findings.append("\(file.name) builds a concentric or container shape outside \(shapesFile)")
      }
      if circularPaths.contains(where: { occurrences(of: $0, in: file.text) > 0 }) {
        findings.append("\(file.name) draws a circular rounded path")
      }
    }
    for file in app + package where file.name != geometryFile && !pendingFiles.contains(file.name) {
      if let line = literalRadiusLines(in: file.text).first {
        findings.append("\(file.name) holds a literal corner radius (line \(line))")
      }
    }
    if let shapes = app.first(where: { $0.name == shapesFile }) {
      if occurrences(of: continuousStyle, in: shapes.text) < occurrences(of: roundedRectangle, in: shapes.text) {
        findings.append("\(shapesFile) draws a rounded rectangle without the continuous style")
      }
      for token in shapesTokens where occurrences(of: token, in: shapes.text) == 0 {
        findings.append("\(shapesFile) does not read \(token)")
      }
    } else {
      findings.append(AppViewSourceGuardTests.missing(shapesFile))
    }
    for reader in cornerReaders {
      guard let file = app.first(where: { $0.name == reader.file }) else {
        findings.append(AppViewSourceGuardTests.missing(reader.file))
        continue
      }
      for token in reader.tokens where occurrences(of: token, in: file.text) == 0 {
        findings.append("\(reader.file) does not read \(token)")
      }
    }
    return findings
  }

  @Test func everyRoundedSurfaceComesFromTheCornerShapes() throws {
    let app = try AppViewSourceGuardTests.appSourceFiles()
    let package = try AppViewSourceGuardTests.packageSourceFiles()
    #expect(app.count > 40)
    #expect(package.count > 40)
    #expect(!Self.literalLimit.isEmpty)
    #expect(Self.cornerFindings(app: app, package: package) == [])
  }

  static let plantedShapes = [
    "static var actionTile: RoundedRectangle {",
    "  RoundedRectangle(cornerRadius: CGFloat(CornerGeometry.tileRadius), style: .continuous)",
    "}",
    "if #available(macOS 26, *) {",
    "  return AnyShape(ConcentricRectangle(",
    "    uniformTopCorners: .fixed(CGFloat(CornerGeometry.rowRadius)),",
    "    uniformBottomCorners: .concentric(minimum: .fixed(CGFloat(CornerGeometry.rowRadius)))))",
    "}",
    "content.containerShape(shape)",
  ]
  static let plantedController = ["PanelView(model: model)", "  .cornerContainer(CornerShapes.panel)"]
  static let plantedPanel = [
    "PrismCard(lit: lit, shape: CornerShapes.heroCard(container: containerRadius)) {",
    ".padding(CGFloat(CornerGeometry.panelPadding))",
    ".buttonStyle(PanelRowButtonStyle(corners: .lastRow))",
  ]
  static let plantedControls = [
    "let shape = CornerShapes.rowHighlight(corners, container: containerRadius)",
    "self.background(.quinary, in: CornerShapes.actionTile)",
  ]
  static let plantedSessions = [".background(Color(nsColor: .systemGray), in: CornerShapes.sessionTile)"]
  static let plantedChips = [
    ".padding(.horizontal, CGFloat(CornerGeometry.chipHorizontalPadding))",
    ".padding(.vertical, CGFloat(CornerGeometry.chipVerticalPadding))",
  ]
  static let plantedHeader = [
    "static let cardPadding = EdgeInsets(top: CGFloat(CornerGeometry.paneHeaderTilePadding))",
    "PrismCard(lit: true, shape: AnyShape(CornerShapes.paneHeaderCard), padding: Self.cardPadding) {",
    "}",
    ".cornerContainer(CornerShapes.paneHeaderCard)",
  ]
  static let plantedTile = [
    "switch size {",
    "case .sidebar: AnyShape(CornerShapes.sidebarTile)",
    "case .header: CornerShapes.paneHeaderTile",
    "}",
  ]
  static let plantedGeometry = ["public static let panelRadius = 24.0"]
  static let plantedPalette = ["public static let cardPadding = 12.0"]

  static func plantedCorners() -> (app: [SourceFile], package: [SourceFile]) {
    let planted = AppViewSourceGuardTests.planted
    let app = [
      planted(shapesFile, plantedShapes), planted("MenuBarPanelController.swift", plantedController),
      planted("PanelView.swift", plantedPanel), planted("ControlsSection.swift", plantedControls),
      planted("SessionsSection.swift", plantedSessions), planted("StatusLinesSection.swift", plantedChips),
      planted("SettingsPaneHeader.swift", plantedHeader), planted("SettingsTile.swift", plantedTile),
    ]
    let root = "Packages/OvertimeRuntime/Sources/OvertimeAppSupport/"
    let palette = "PrismStyle.swift"
    let package = [
      SourceFile(name: geometryFile, path: root + geometryFile, text: plantedGeometry.joined(separator: "\n")),
      SourceFile(name: palette, path: root + palette, text: plantedPalette.joined(separator: "\n")),
    ]
    return (app, package)
  }

  enum CornerDrift: CaseIterable, Sendable {
    case roundedRectangleInTheControls
    case continuousStyleDropped
    case circularPathInTheController
    case concentricShapeInThePanelView
    case literalRadiusProperty
    case literalFixedCorner
    case cornerRadiusModifier
    case computedRadiusProperty
    case availabilityGateLowered
    case chipPaddingLiteral
    case headerTileDropsItsConcentricShape

    var file: String {
      switch self {
      case .roundedRectangleInTheControls, .computedRadiusProperty: "ControlsSection.swift"
      case .continuousStyleDropped, .literalFixedCorner, .availabilityGateLowered: CornerShapeGateTests.shapesFile
      case .circularPathInTheController: "MenuBarPanelController.swift"
      case .concentricShapeInThePanelView: "PanelView.swift"
      case .literalRadiusProperty, .cornerRadiusModifier: "SessionsSection.swift"
      case .chipPaddingLiteral: "StatusLinesSection.swift"
      case .headerTileDropsItsConcentricShape: "SettingsTile.swift"
      }
    }

    var change: (old: String, new: String) {
      let sessionAnchor = CornerShapeGateTests.plantedSessions[0]
      let controlsAnchor = CornerShapeGateTests.plantedControls[0]
      let controllerAnchor = CornerShapeGateTests.plantedController[0]
      let panelAnchor = CornerShapeGateTests.plantedPanel[1]
      let roundedTile = "RoundedRectangle(cornerRadius: CGFloat(CornerGeometry.tileRadius), style: .continuous)"
      let circularPath = "NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()"
      return switch self {
      case .roundedRectangleInTheControls: ("CornerShapes.actionTile", roundedTile)
      case .continuousStyleDropped: (", style: .continuous", "")
      case .circularPathInTheController: (controllerAnchor, controllerAnchor + "\n" + circularPath)
      case .concentricShapeInThePanelView: (panelAnchor, panelAnchor + "\nConcentricRectangle(corners: .concentric)")
      case .literalRadiusProperty: (sessionAnchor, "static let tileCornerRadius: CGFloat = 5\n" + sessionAnchor)
      case .literalFixedCorner: (".fixed(CGFloat(CornerGeometry.rowRadius))", ".fixed(6)")
      case .cornerRadiusModifier: (sessionAnchor, sessionAnchor + "\n.cornerRadius(5)")
      case .computedRadiusProperty: (controlsAnchor, controlsAnchor + "\nstatic var tileRadius: CGFloat {\n  10\n}")
      case .availabilityGateLowered: ("#available(macOS 26, *)", "#available(macOS 15, *)")
      case .chipPaddingLiteral: ("CornerGeometry.chipVerticalPadding", "4")
      case .headerTileDropsItsConcentricShape: ("CornerShapes.paneHeaderTile", "AnyShape(CornerShapes.sidebarTile)")
      }
    }

    var phrase: String {
      switch self {
      case .roundedRectangleInTheControls: "ControlsSection.swift builds a rounded rectangle outside CornerShapes.swift"
      case .continuousStyleDropped: "CornerShapes.swift draws a rounded rectangle without the continuous style"
      case .circularPathInTheController: "MenuBarPanelController.swift draws a circular rounded path"
      case .concentricShapeInThePanelView:
        "PanelView.swift builds a concentric or container shape outside CornerShapes.swift"
      case .literalRadiusProperty, .cornerRadiusModifier: "SessionsSection.swift holds a literal corner radius"
      case .literalFixedCorner: "CornerShapes.swift holds a literal corner radius"
      case .computedRadiusProperty: "ControlsSection.swift holds a literal corner radius"
      case .availabilityGateLowered: "CornerShapes.swift does not read #available(macOS 26"
      case .chipPaddingLiteral: "StatusLinesSection.swift does not read CornerGeometry.chipVerticalPadding"
      case .headerTileDropsItsConcentricShape: "SettingsTile.swift does not read CornerShapes.paneHeaderTile"
      }
    }
  }

  @Test func theUndriftedPlantedCornerSourcesHaveNoFindings() {
    let planted = Self.plantedCorners()
    #expect(Set(planted.app.map(\.name)).count == Self.cornerReaders.count + 1)
    #expect(Self.cornerFindings(app: planted.app, package: planted.package) == [])
    let withoutGeometry = planted.package.filter { $0.name != Self.geometryFile }
    #expect(
      Self.cornerFindings(app: planted.app, package: withoutGeometry) == [
        "\(Self.geometryFile) is not among the package sources"
      ])
  }

  @Test(arguments: CornerDrift.allCases)
  func aDriftedCornerSourceIsReported(drift: CornerDrift) throws {
    #expect(CornerDrift.allCases.count == 11)
    let planted = Self.plantedCorners()
    let target = try #require(planted.app.first { $0.name == drift.file })
    let change = drift.change
    let range = try #require(target.text.range(of: change.old), "the planted source does not hold \(change.old)")
    let drifted = target.text.replacingCharacters(in: range, with: change.new)
    let changed = planted.app.map { file in
      file.name == drift.file ? SourceFile(name: file.name, path: file.path, text: drifted) : file
    }
    let findings = Self.cornerFindings(app: changed, package: planted.package)
    #expect(findings.contains { $0.contains(drift.phrase) }, "\(findings)")
  }
}
