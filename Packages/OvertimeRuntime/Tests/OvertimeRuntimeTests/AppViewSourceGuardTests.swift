import Foundation
import OvertimeAppSupport
import Testing

struct AppViewSourceGuardTests {
  struct SourceFile {
    let name: String
    let path: String
    let text: String
  }

  static let appSources = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources/Overtime")

  static let packageSources = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources")

  static func appSourceFiles() throws -> [SourceFile] {
    try sourceFiles(under: appSources)
  }

  static func packageSourceFiles() throws -> [SourceFile] {
    try sourceFiles(under: packageSources)
  }

  static func sourceFiles(under root: URL) throws -> [SourceFile] {
    let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
    var urls: [URL] = []
    for case let url as URL in enumerator where url.pathExtension == "swift" {
      urls.append(url)
    }
    return try urls.sorted { $0.path < $1.path }.map { url in
      SourceFile(name: url.lastPathComponent, path: url.path, text: try String(contentsOf: url, encoding: .utf8))
    }
  }

  static func lineNumbers(in source: String, where matches: (String) -> Bool) -> [Int] {
    source.components(separatedBy: "\n").enumerated().compactMap { index, line in
      matches(line) ? index + 1 : nil
    }
  }

  static func literalIndentLines(in source: String) -> [Int] {
    lineNumbers(in: source) { $0.contains(".padding(.leading, 20)") }
  }

  @Test func theIndentFinderSeesAPlantedLiteralAndIgnoresTheConstant() {
    let planted = ["Text(title)", "  .padding(.leading, 20)", "Text(caption)"].joined(separator: "\n")
    #expect(Self.literalIndentLines(in: planted) == [2])
    let clean = ["Text(title)", "  .padding(.leading, StatusRowLayout.textInset)", "  .padding(.leading, 24)"]
      .joined(separator: "\n")
    #expect(Self.literalIndentLines(in: clean).isEmpty)
  }

  @Test func noAppViewIndentsByALiteral20Points() throws {
    let files = try Self.appSourceFiles()
    let names = Set(files.map(\.name))
    for expected in ["DiagnosticsPane.swift", "SleepDisabledRow.swift", "OnboardingCheckRows.swift"] {
      #expect(names.contains(expected), "the app source population is missing \(expected)")
    }
    for file in files {
      for line in Self.literalIndentLines(in: file.text) {
        Issue.record("\(file.path):\(line) indents by a literal 20 pt; use StatusRowLayout.textInset")
      }
    }
  }

  @Test func theStatusRowTextInsetIsDeclaredOnceAsTheIconColumnPlusItsGap() throws {
    let files = try Self.appSourceFiles()
    #expect(!files.isEmpty)
    let declarations = files.flatMap { file in
      file.text.components(separatedBy: "\n").filter { $0.contains("static let textInset") }
    }
    #expect(declarations.count == 1, "textInset declarations: \(declarations)")
    #expect(declarations.allSatisfy { $0.contains("iconWidth + iconGap") })
  }

  static let emptyFallback = "?? \"\")"

  static func emptyFallbackLines(in source: String) -> [Int] {
    lineNumbers(in: source) { line in
      (line.contains("accessibilityHint(") || line.contains(".help(")) && line.contains(emptyFallback)
    }
  }

  @Test func theEmptyFallbackFinderSeesEveryFormAndIgnoresInPlaceHints() {
    let reported = [
      "  .accessibilityHint(message ?? \"\")",
      "  .help(model.selfTestHelp ?? \"\")",
      "  .accessibilityHint(Text(caption?.text ?? \"\"))",
    ]
    for line in reported {
      #expect(Self.emptyFallbackLines(in: line) == [1], "not reported: \(line)")
    }
    let ignored = [
      "  .accessibilityHint(ifPresent: message)",
      "  .help(ifPresent: model.selfTestHelp)",
      "  .accessibilityValue(model.status ?? \"\")",
      "  .accessibilityHint(Text(Self.keepDisplayOnCaption))",
    ]
    for line in ignored {
      #expect(Self.emptyFallbackLines(in: line).isEmpty, "reported: \(line)")
    }
  }

  @Test func noAppViewAttachesAnEmptyHintOrHelpTag() throws {
    let files = try Self.appSourceFiles().filter { $0.name != "OptionalAccessibility.swift" }
    let names = Set(files.map(\.name))
    for expected in ["ControlsSection.swift", "SettingsRows.swift", "LoginItemSection.swift"] {
      #expect(names.contains(expected), "the app source population is missing \(expected)")
    }
    for file in files {
      for line in Self.emptyFallbackLines(in: file.text) {
        Issue.record("\(file.path):\(line) attaches an empty hint or help tag; use the ifPresent: forms")
      }
    }
  }

  @Test func everyChecklistRowIsTheSharedStepRowOnTheStatusRowTokens() throws {
    let files = try Self.appSourceFiles()
    let row = try #require(files.first { $0.name == "StepRow.swift" })
    #expect(row.text.contains(".frame(width: StatusRowLayout.iconWidth)"))
    #expect(row.text.contains("spacing: StatusRowLayout.iconGap"))
    #expect(!row.text.contains(".frame(width: 16)"))
    #expect(!row.text.contains("alignment: .firstTextBaseline, spacing: 4)"))
    for file in files {
      if file.name != "StepRow.swift" {
        #expect(!file.text.contains("StepIcon(status:"), "\(file.path) draws a step icon outside StepRow")
      }
    }
    let sheet = try #require(files.first { $0.name == "UninstallSheet.swift" })
    #expect(sheet.text.contains("StepRow("))
  }

  @Test func theLaunchRegistersTheLoginItemBeforeItOpensOnboardingAndRunAgainShowsIt() throws {
    let files = try Self.appSourceFiles()
    let delegate = try #require(files.first { $0.name == "AppDelegate.swift" })
    let lines = delegate.text.components(separatedBy: "\n")
    let launchLines = Self.lineNumbers(in: delegate.text) { $0.contains("Self.openOnboardingAtLaunch(") }
    #expect(launchLines.count == 1, "AppDelegate.swift calls Self.openOnboardingAtLaunch( on lines \(launchLines)")
    if let launch = launchLines.first {
      let rest = lines[(launch - 1)...]
      let end = rest.firstIndex { $0.contains("startSelfTest(engineHost:") } ?? lines.endIndex
      let span = lines[(launch - 1)..<end].joined(separator: "\n")
      #expect(end < lines.endIndex, "no startSelfTest(engineHost: follows the launch-time onboarding call")
      #expect(span.contains("applyFirstRunLogin(host: host)"), "the launch-time onboarding call does not register")
    }
    let againLines = Self.lineNumbers(in: delegate.text) { $0.contains("Self.runOnboardingAgain(") }
    #expect(againLines.count == 1, "AppDelegate.swift calls Self.runOnboardingAgain( on lines \(againLines)")
    let showLines = Self.lineNumbers(in: delegate.text) { $0.contains("func showOnboarding()") }
    #expect(showLines.count == 1)
    if let again = againLines.first, let show = showLines.first {
      #expect(again > show, "Self.runOnboardingAgain( is called before func showOnboarding()")
      let between = again > show ? lines[show..<(again - 1)] : []
      #expect(!between.contains("  }"), "Self.runOnboardingAgain( is called outside func showOnboarding()")
    }
    let applies = files.reduce(0) { $0 + $1.text.components(separatedBy: "FirstRunLogin.apply(").count - 1 }
    #expect(applies == 1, "the app sources call FirstRunLogin.apply( \(applies) times")
  }

  static let statusChipFile = "StatusLinesSection.swift"
  static let statusChipCounts: [(String, Int)] = [
    (".frame(width: StatusRowLayout.iconWidth)", 1),
    ("spacing: StatusRowLayout.iconGap", 1),
    ("multilineTextAlignment(.leading)", 1),
    ("multilineTextAlignment(.trailing)", 0),
    ("alignment: .trailing", 0),
    (".padding(.leading, StatusRowLayout.textInset)", 0),
    ("ViewThatFits(in: .horizontal)", 1),
    ("Capsule()", 1),
    (".accessibilityLabel(chip.accessibilityText)", 1),
    (".help(chip.help)", 1),
  ]
  static let statusChipPanelCounts: [(String, Int)] = [
    ("StatusChipRow(", 1),
    ("StatusDetailsSection(", 1),
    ("StatusLinesSection(", 0),
  ]

  @Test func thePanelStatusDetailsSitInTheIconColumn() throws {
    let files = try Self.appSourceFiles()
    let section = try #require(files.first { $0.name == Self.statusChipFile })
    for (literal, expected) in Self.statusChipCounts {
      let count = Self.occurrences(of: literal, in: section.text)
      #expect(count == expected, "\(section.path) holds \(count) of \(literal), expected \(expected)")
    }
    let panel = try #require(files.first { $0.name == Self.panelFile })
    for (literal, expected) in Self.statusChipPanelCounts {
      let count = Self.occurrences(of: literal, in: panel.text)
      #expect(count == expected, "\(panel.path) holds \(count) of \(literal), expected \(expected)")
    }
  }

  static let sessionsFile = "SessionsSection.swift"
  static let sessionCounts = [
    "Text(PanelContent.header)", "placeholder.heading", "placeholder.body", "list.summaryText",
    ".padding(.leading, StatusRowLayout.textInset)", "Image(systemName: PanelContent.sessionIcon)",
    ".frame(width: StatusRowLayout.iconWidth)", "Color(nsColor: .systemGray)", ".help(row.fullPath)",
    ".truncationMode(.middle)", ".accessibilityLabel(row.accessibilityText)", ".foregroundStyle(Color.green)",
  ]
  static let sessionCopy = [
    PanelContent.header, SessionPlaceholder.noSessions.heading, SessionPlaceholder.noneWorking.heading,
    SessionPlaceholder.transcriptOnly.heading,
  ]

  @Test func theSessionRowsKeepTheirCopyOnTheTerminalTile() throws {
    let section = try #require(try Self.appSourceFiles().first { $0.name == Self.sessionsFile })
    for literal in Self.sessionCounts {
      let count = Self.occurrences(of: literal, in: section.text)
      #expect(count == 1, "\(section.path) holds \(count) of \(literal), expected 1")
    }
    #expect(Self.sessionCopy.count == 4)
    for copy in Self.sessionCopy {
      #expect(!copy.isEmpty)
      #expect(!section.text.contains(copy), "\(section.path) spells the session copy \(copy)")
    }
  }

  static let actionsFile = "ControlsSection.swift"
  static let restingTileFill = ".background(.quinary, in: CornerShapes.actionTile)"
  static let panelActionCounts: [(needle: String, expected: Int, what: String)] = [
    ("PanelActions.tiles(", 1, "reads the action tiles"),
    ("ForEach(PauseChoice.allCases", 1, "lists the pause choices"),
    ("ForEach(KeepAwakeChoice.allCases", 1, "lists the keep-awake choices"),
    (".menuIndicator(.hidden)", 1, "hides the system menu indicator"),
    (".menuIndicator(.visible)", 0, "shows the system menu indicator"),
    ("PanelRowChrome(", 3, "applies the row chrome"),
    (restingTileFill, 1, "draws the resting tile fill"),
    ("PanelActions.menuSymbol", 1, "draws the menu chevron"),
    (".keyboardShortcut(.cancelAction)", 1, "binds the cancel action"),
  ]

  static func panelActionFindings(in files: [SourceFile]) -> [String] {
    guard let file = files.first(where: { $0.name == actionsFile }) else { return [missing(actionsFile)] }
    var findings: [String] = []
    for count in panelActionCounts {
      let found = occurrences(of: count.needle, in: file.text)
      if found != count.expected {
        findings.append("\(file.name) \(count.what) \(found) times, expected \(count.expected)")
      }
    }
    return findings
  }

  static let plantedTileChrome = "configuration.label.modifier(PanelRowChrome(pressed: configuration.isPressed))"
  static let plantedPauseChoices = "ForEach(PauseChoice.allCases, id: \\.self) { choice in"
  static let plantedActions = [
    "let tiles = PanelActions.tiles(model.controls, confirmingSleep: model.sleepConfirmation.isConfirming)",
    plantedPauseChoices,
    "ForEach(KeepAwakeChoice.allCases, id: \\.self) { choice in",
    "Image(systemName: PanelActions.menuSymbol)",
    "Button(SleepConfirmation.cancelLabel) { model.keepWorking() }",
    "  .keyboardShortcut(.cancelAction)",
    plantedTileChrome,
    plantedTileChrome + ".panelTileFill()",
    ".menuIndicator(.hidden)",
    ".modifier(PanelRowChrome())",
    restingTileFill,
  ]

  enum PanelActionsDrift: CaseIterable, Sendable {
    case systemMenuIndicatorReturns
    case pauseMenuLosesItsTimedChoices
    case tileStyleWithoutTheRowChrome
    case secondRestingFill

    var change: (old: String, new: String) {
      let fill = AppViewSourceGuardTests.restingTileFill
      let chrome = AppViewSourceGuardTests.plantedTileChrome + ".panelTileFill()"
      return switch self {
      case .systemMenuIndicatorReturns: (".menuIndicator(.hidden)", ".menuIndicator(.visible)")
      case .pauseMenuLosesItsTimedChoices:
        (AppViewSourceGuardTests.plantedPauseChoices, "Button(ControlMapping.pauseLabel) { model.trigger(.pause) }")
      case .tileStyleWithoutTheRowChrome: (chrome, "configuration.label.panelTileFill()")
      case .secondRestingFill: (fill, fill + "\n" + fill)
      }
    }

    var phrase: String {
      switch self {
      case .systemMenuIndicatorReturns: "ControlsSection.swift shows the system menu indicator 1 times, expected 0"
      case .pauseMenuLosesItsTimedChoices: "ControlsSection.swift lists the pause choices 0 times, expected 1"
      case .tileStyleWithoutTheRowChrome: "ControlsSection.swift applies the row chrome 2 times, expected 3"
      case .secondRestingFill: "ControlsSection.swift draws the resting tile fill 2 times, expected 1"
      }
    }
  }

  @Test func thePanelActionsAreThreeTilesWithTheRowFeedback() throws {
    let files = try Self.appSourceFiles()
    #expect(files.contains { $0.name == Self.actionsFile })
    #expect(Self.panelActionFindings(in: files) == [])
  }

  @Test func theUndriftedPlantedPanelActionsHaveNoFindings() {
    #expect(Self.panelActionFindings(in: []) == [Self.missing(Self.actionsFile)])
    #expect(Self.panelActionFindings(in: [Self.planted(Self.actionsFile, Self.plantedActions)]) == [])
  }

  @Test(arguments: PanelActionsDrift.allCases)
  func aDriftedPanelActionsSourceIsReported(drift: PanelActionsDrift) throws {
    #expect(PanelActionsDrift.allCases.count == 4)
    let text = Self.plantedActions.joined(separator: "\n")
    let change = drift.change
    let range = try #require(text.range(of: change.old), "the planted source does not hold \(change.old)")
    let drifted = Self.planted(Self.actionsFile, [text.replacingCharacters(in: range, with: change.new)])
    let findings = Self.panelActionFindings(in: [drifted])
    #expect(findings.contains { $0.contains(drift.phrase) }, "\(findings)")
  }

  static let uninstallSheetScrollCounts: [(String, Int)] = [
    ("ViewThatFits", 0),
    ("ScrollView", 1),
    ("UninstallSheetBody(", 1),
    ("Self.scrollHeight(", 1),
    (".scrollBounceBehavior(.basedOnSize)", 1),
    ("onGeometryChange(for: CGFloat.self", 3),
  ]

  @Test func theUninstallSheetBodyAlwaysScrollsUnderAnExplicitBound() throws {
    let sheet = try #require(try Self.appSourceFiles().first { $0.name == "UninstallSheet.swift" })
    for (literal, expected) in Self.uninstallSheetScrollCounts {
      let count = sheet.text.components(separatedBy: literal).count - 1
      #expect(count == expected, "\(sheet.path) holds \(count) of \(literal), expected \(expected)")
    }
  }

  @Test func theAboutSwitchCaptionIsReadOnceAsItsHint() throws {
    let pane = try #require(try Self.appSourceFiles().first { $0.name == "AboutPane.swift" })
    let start = try #require(pane.text.range(of: "struct AboutSwitchRow"))
    let row = String(pane.text[start.lowerBound...]).filter { !$0.isWhitespace }
    let hidden = "SettingsSectionCaption(text:caption).accessibilityHidden(true)"
    #expect(row.components(separatedBy: ".accessibilityHint(Text(caption))").count - 1 == 1)
    #expect(row.components(separatedBy: hidden).count - 1 == 1)
  }

  @Test func theRunSelfTestReasonShowsUnderTheButtonAndIsReadOnceAsItsHint() throws {
    let pane = try #require(try Self.appSourceFiles().first { $0.name == "DiagnosticsPane.swift" })
    let text = pane.text.filter { !$0.isWhitespace }
    let caption = "ifletreason=model.selfTestHelp{SettingsSectionCaption(text:reason).accessibilityHidden(true)}"
    let literals = [caption, ".accessibilityHint(ifPresent:model.selfTestHelp)", ".help(ifPresent:model.selfTestHelp)"]
    for literal in literals {
      let count = text.components(separatedBy: literal).count - 1
      #expect(count == 1, "\(pane.path) holds \(count) of \(literal), expected 1")
    }
    let button = try #require(text.range(of: "SelfTestPresentation.runButtonTitle"))
    let shown = try #require(text.range(of: caption))
    let header = try #require(text.range(of: "SelfTestPresentation.sectionTitle"))
    #expect(button.upperBound <= shown.lowerBound)
    #expect(shown.upperBound <= header.lowerBound)
  }

  @Test func theAboutIdentityIconIsDecorativeAtTheReservedSize() throws {
    let pane = try #require(try Self.appSourceFiles().first { $0.name == "AboutPane.swift" })
    let start = try #require(pane.text.range(of: "struct AboutIdentity"))
    let rest = pane.text[start.upperBound...]
    let end = rest.range(of: "struct ")?.lowerBound ?? rest.endIndex
    let identity = String(rest[..<end]).filter { !$0.isWhitespace }
    let image = "Image(nsImage:Self.applicationIcon())"
    let frame = ".frame(width:AboutModel.iconSide,height:AboutModel.iconSide).accessibilityHidden(true)"
    #expect(identity.components(separatedBy: image).count - 1 == 1)
    #expect(identity.components(separatedBy: frame).count - 1 == 1)
    let squeezed = pane.text.filter { !$0.isWhitespace }
    for named in ["Image(\"", "NSImage(named:", "image(forResource:", "ImageResource"] {
      #expect(!squeezed.contains(named), "\(pane.path) builds an image from a catalog name: \(named)")
    }
  }

  static let statusGlyphCall = "StatusGlyphView(label:StatusItemLabel(presentation)).equatable()"
  static let symbolImage = "Image(systemName:"
  static let imageLookups = ["NSImage(", "image(forResource:", "Image(\"", "ImageResource"]

  static func statusBlockFindings(in source: String) -> [String] {
    guard let start = source.range(of: "struct StatusBlock") else {
      return ["the panel declares no StatusBlock"]
    }
    let rest = source[start.upperBound...]
    let end = rest.range(of: "\nstruct ")?.lowerBound ?? rest.endIndex
    let block = String(rest[..<end]).filter { !$0.isWhitespace }
    var findings: [String] = []
    let drawn = block.components(separatedBy: statusGlyphCall).count - 1
    if drawn != 1 {
      findings.append("the status block draws the shared status glyph view \(drawn) times, not once")
    }
    if block.contains(symbolImage) {
      findings.append("the status block builds an SF Symbol image of its own")
    }
    let squeezed = source.filter { !$0.isWhitespace }
    for lookup in imageLookups where squeezed.contains(lookup) {
      findings.append("the panel resolves an image outside the shared resolver: \(lookup)")
    }
    return findings
  }

  static let plantedGlyphLines = [
    "    StatusGlyphView(label: StatusItemLabel(presentation))",
    "      .equatable()",
  ]

  static func plantedPanel(block: [String], blockName: String = "StatusBlock") -> String {
    let lines =
      [
        "struct PanelBody: View {",
        "  var body: some View { Image(systemName: \"info.circle\") }",
        "}",
        "",
        "struct \(blockName): View {",
        "  var body: some View {",
      ] + block + [
        "  }",
        "}",
        "",
        "struct Footer: View {",
        "  var body: some View { Image(systemName: \"gearshape\") }",
        "}",
      ]
    return lines.joined(separator: "\n")
  }

  enum StatusBlockDrift: CaseIterable, Sendable {
    case symbolInsteadOfTheView
    case symbolBesideTheView
    case viewRemoved
    case viewDrawnTwice
    case viewNotEquatable
    case ownImageLookup
    case blockRenamed

    var source: String {
      let glyph = AppViewSourceGuardTests.plantedGlyphLines
      let block: [String] =
        switch self {
        case .symbolInsteadOfTheView: ["    Image(systemName: StatusItemLabel.resolvedGlyph(presentation))"]
        case .symbolBesideTheView: glyph + ["    Image(systemName: \"moon\")"]
        case .viewRemoved: ["    Text(presentation.title)"]
        case .viewDrawnTwice: glyph + glyph
        case .viewNotEquatable: [glyph[0]]
        case .ownImageLookup: glyph + ["    Image(nsImage: NSImage(named: \"StatusIdle\") ?? NSImage())"]
        case .blockRenamed: glyph
        }
      return AppViewSourceGuardTests.plantedPanel(
        block: block, blockName: self == .blockRenamed ? "HeaderBlock" : "StatusBlock")
    }

    var phrase: String {
      switch self {
      case .symbolInsteadOfTheView, .symbolBesideTheView: "builds an SF Symbol image of its own"
      case .viewRemoved, .viewNotEquatable: "draws the shared status glyph view 0 times"
      case .viewDrawnTwice: "draws the shared status glyph view 2 times"
      case .ownImageLookup: "resolves an image outside the shared resolver: NSImage("
      case .blockRenamed: "declares no StatusBlock"
      }
    }
  }

  @Test func thePanelStatusBlockDrawsTheSharedStatusGlyphView() throws {
    let panel = try #require(try Self.appSourceFiles().first { $0.name == "PanelView.swift" })
    #expect(panel.text.contains("struct StatusBlock"))
    #expect(Self.statusBlockFindings(in: panel.text) == [], "\(panel.path)")
  }

  @Test func theUndriftedPlantedStatusBlockHasNoFindings() {
    #expect(Self.statusBlockFindings(in: Self.plantedPanel(block: Self.plantedGlyphLines)) == [])
  }

  @Test(arguments: StatusBlockDrift.allCases)
  func aStatusBlockThatDrawsAGlyphOfItsOwnIsReported(drift: StatusBlockDrift) {
    let findings = Self.statusBlockFindings(in: drift.source)
    #expect(findings.contains { $0.contains(drift.phrase) }, "\(findings)")
  }

  static let iconColumnCounts: [(String, Int)] = [
    (".frame(width: 16)", 0),
    (".frame(width: StatusRowLayout.iconWidth)", 1),
    ("spacing: StatusRowLayout.iconGap", 1),
    ("spacing: 4)", 0),
  ]

  @Test func theRowsThisPhaseTouchedDrawTheIconColumnFromStatusRowLayout() throws {
    let files = try Self.appSourceFiles()
    for name in ["AttentionRow.swift", "SettingsWindow.swift"] {
      let file = try #require(files.first { $0.name == name })
      for (literal, expected) in Self.iconColumnCounts {
        let count = file.text.components(separatedBy: literal).count - 1
        #expect(count == expected, "\(file.path) holds \(count) of \(literal), expected \(expected)")
      }
    }
  }

  static func occurrences(of needle: String, in text: String) -> Int {
    let squeezed = text.filter { !$0.isWhitespace }
    return squeezed.components(separatedBy: needle.filter { !$0.isWhitespace }).count - 1
  }

  static func missing(_ name: String) -> String {
    "\(name) is not among the app sources"
  }

  static let iconColumnFiles = [
    "ControlsSection.swift", "HintsSection.swift", "LoginItemSection.swift", "SessionsSection.swift",
    "DetectionPane.swift", "UnplugProtectionPane.swift", "OnboardingSteps.swift",
  ]
  static let literalIconFrames = [".frame(width: 16)", ".frame(width: 16,"]
  static let iconColumnTokens = ["StatusRowLayout.iconWidth", "StatusRowLayout.iconGap"]

  static func iconColumnFindings(in files: [SourceFile]) -> [String] {
    var findings: [String] = []
    for file in files where literalIconFrames.contains(where: { occurrences(of: $0, in: file.text) > 0 }) {
      findings.append("\(file.name) draws an icon in a literal 16 pt column")
    }
    for name in iconColumnFiles {
      guard let file = files.first(where: { $0.name == name }) else {
        findings.append(missing(name))
        continue
      }
      for token in iconColumnTokens where occurrences(of: token, in: file.text) == 0 {
        findings.append("\(name) does not read \(token)")
      }
    }
    return findings
  }

  static let rowChromeFile = "ControlsSection.swift"
  static let rowHighlightFills = ["quinary", "quaternary"]
  static let rowHighlightRadius = "CornerShapes.rowHighlight("
  static let literalRowRadii = ["cornerRadius: 4)", "cornerRadius: 4,"]
  static let statusCard = ".background(.quaternary, in: RoundedRectangle(cornerRadius: 8))"

  static func rowHighlightFindings(in files: [SourceFile]) -> [String] {
    guard let file = files.first(where: { $0.name == rowChromeFile }) else { return [missing(rowChromeFile)] }
    var findings: [String] = []
    for style in rowHighlightFills {
      let fills = occurrences(of: ".fill(.\(style))", in: file.text)
      if fills != 1 {
        findings.append("\(file.name) fills with the \(style) style \(fills) times, not once")
      }
    }
    if occurrences(of: ".tertiary", in: file.text) > 0 {
      findings.append("\(file.name) uses the tertiary style")
    }
    if occurrences(of: rowHighlightRadius, in: file.text) == 0 {
      findings.append("\(file.name) does not shape the row highlight with CornerShapes.rowHighlight")
    }
    if literalRowRadii.contains(where: { occurrences(of: $0, in: file.text) > 0 }) {
      findings.append("\(file.name) holds a literal corner radius of 4")
    }
    return findings
  }

  static let hairlineFile = "MenuBarPanelController.swift"
  static let hairlineStroke =
    ".strokeBorder(Color(nsColor: .separatorColor), lineWidth: MenuBarPanelController.hairlineWidth)"
  static let anyStroke = [".strokeBorder(", ".stroke("]
  static let borderedContent = "MenuBarPanelContent("
  static let hostedBorderedContent = "NSHostingController(rootView: MenuBarPanelContent("

  static func hairlineFindings(in files: [SourceFile]) -> [String] {
    guard let controller = files.first(where: { $0.name == hairlineFile }) else { return [missing(hairlineFile)] }
    var findings: [String] = []
    let hairlines = occurrences(of: hairlineStroke, in: controller.text)
    if hairlines != 1 {
      findings.append("\(controller.name) strokes the separator-colour hairline \(hairlines) times, not once")
    }
    let strokes = anyStroke.reduce(0) { $0 + occurrences(of: $1, in: controller.text) }
    if strokes != hairlines {
      findings.append("\(controller.name) strokes a border that is not the hairline")
    }
    let hosted = occurrences(of: hostedBorderedContent, in: controller.text)
    if hosted != 1 || occurrences(of: borderedContent, in: controller.text) != 1 {
      findings.append("\(controller.name) does not host the bordered panel content exactly once")
    }
    for file in files where file.name != hairlineFile && occurrences(of: borderedContent, in: file.text) > 0 {
      findings.append("\(file.name) builds the bordered panel content")
    }
    return findings
  }

  static let copyLinkFiles = ["HintsSection.swift", "SleepDisabledRow.swift"]
  static let confirmingButton = "CopyCommandButton("
  static let copyLabel = "SleepDisabledClearing.copyLabel"
  static let confirmingCopyLabel = "CopyCommandButton(label: SleepDisabledClearing.copyLabel"

  static func copyLinkFindings(in files: [SourceFile]) -> [String] {
    var findings: [String] = []
    for name in copyLinkFiles {
      guard let file = files.first(where: { $0.name == name }) else {
        findings.append(missing(name))
        continue
      }
      let built = occurrences(of: confirmingButton, in: file.text)
      if built != 1 {
        findings.append("\(name) builds the confirming copy button \(built) times, not once")
      }
    }
    for file in files
    where occurrences(of: copyLabel, in: file.text) != occurrences(of: confirmingCopyLabel, in: file.text) {
      findings.append("\(file.name) builds a plain button from the copy label")
    }
    return findings
  }

  static func panelChromeFindings(in files: [SourceFile]) -> [String] {
    iconColumnFindings(in: files) + rowHighlightFindings(in: files) + hairlineFindings(in: files)
      + copyLinkFindings(in: files)
  }

  @Test func noAppSourceDrawsAnIconInALiteralSixteenPointColumn() throws {
    let files = try Self.appSourceFiles()
    #expect(files.count > 40)
    #expect(Self.iconColumnFindings(in: files) == [])
  }

  @Test func theStatusCardIsThePrismCardAndTheRowHighlightIsRoundedBySix() throws {
    let files = try Self.appSourceFiles()
    let panel = try #require(files.first { $0.name == Self.panelFile })
    #expect(Self.occurrences(of: Self.cardCall, in: panel.text) == 1)
    #expect(Self.occurrences(of: Self.indicatorCall, in: panel.text) == 1)
    #expect(Self.occurrences(of: Self.litRule, in: panel.text) == 1)
    #expect(Self.occurrences(of: Self.statusCard, in: panel.text) == 0)
    let card = try #require(files.first { $0.name == Self.cardFile })
    #expect(Self.occurrences(of: "controlBackgroundColor", in: card.text) > 0)
    #expect(Self.occurrences(of: "separatorColor", in: card.text) > 0)
    #expect(Self.rowHighlightFindings(in: files) == [])
  }

  @Test func onlyTheMenuBarPanelDrawsTheHairlineEdge() throws {
    let files = try Self.appSourceFiles()
    #expect(files.contains { $0.name == "ReopenWindow.swift" })
    #expect(Self.hairlineFindings(in: files) == [])
  }

  @Test func everyCopyCommandLinkGoesThroughTheConfirmingButton() throws {
    let files = try Self.appSourceFiles()
    #expect(files.contains { $0.name == "UninstallSheet.swift" })
    #expect(Self.copyLinkFindings(in: files) == [])
  }

  static func planted(_ name: String, _ lines: [String]) -> SourceFile {
    SourceFile(name: name, path: "Sources/Overtime/" + name, text: lines.joined(separator: "\n"))
  }

  static let plantedIconRow = [
    "HStack(alignment: .firstTextBaseline, spacing: StatusRowLayout.iconGap) {",
    "  Image(systemName: icon)",
    "    .frame(width: StatusRowLayout.iconWidth)",
    "}",
  ]
  static let plantedHighlight = [
    "let shape = CornerShapes.rowHighlight(corners, container: containerRadius)",
    "shape",
    "  .fill(.quinary)",
    "shape",
    "  .fill(.quaternary)",
  ]
  static let plantedHintCopy = ["CopyCommandButton(label: action.label) { perform(action) }"]
  static let plantedRowCopy = ["CopyCommandButton(label: SleepDisabledClearing.copyLabel, copy: copy)"]
  static let plantedController = [
    "let hosting = NSHostingController(rootView: MenuBarPanelContent(model: model))",
    "RoundedRectangle(cornerRadius: MenuBarPanelController.cornerRadius)",
    "  .strokeBorder(Color(nsColor: .separatorColor), lineWidth: MenuBarPanelController.hairlineWidth)",
  ]
  static let plantedReopenWindow = ["PanelView(model: model, banner: Self.banner)"]

  static func plantedChrome() -> [SourceFile] {
    let rows = iconColumnFiles.map { name in
      switch name {
      case rowChromeFile: planted(name, plantedIconRow + plantedHighlight)
      case "HintsSection.swift": planted(name, plantedIconRow + plantedHintCopy)
      default: planted(name, plantedIconRow)
      }
    }
    return rows + [
      planted("SleepDisabledRow.swift", plantedRowCopy),
      planted(hairlineFile, plantedController),
      planted("ReopenWindow.swift", plantedReopenWindow),
    ]
  }

  enum PanelChromeDrift: CaseIterable, Sendable {
    case literalIconFrameReturns
    case fileLosesTheWidthToken
    case fileLosesTheGapToken
    case tertiaryFillReturns
    case pressedFillRemoved
    case literalRadiusReturns
    case hairlineInALiteralWidth
    case reopenWindowBuildsTheBorderedContent
    case copyLinkIsAPlainButton
    case hintCopyLinkIsAPlainButton

    var file: String {
      switch self {
      case .literalIconFrameReturns: "SessionsSection.swift"
      case .fileLosesTheWidthToken: "LoginItemSection.swift"
      case .fileLosesTheGapToken: "DetectionPane.swift"
      case .tertiaryFillReturns, .pressedFillRemoved, .literalRadiusReturns: AppViewSourceGuardTests.rowChromeFile
      case .hairlineInALiteralWidth: AppViewSourceGuardTests.hairlineFile
      case .reopenWindowBuildsTheBorderedContent: "ReopenWindow.swift"
      case .copyLinkIsAPlainButton: "SleepDisabledRow.swift"
      case .hintCopyLinkIsAPlainButton: "HintsSection.swift"
      }
    }

    var change: (old: String, new: String) {
      let borderedView = "MenuBarPanelContent(model: model)"
      let plain = "Button(SleepDisabledClearing.copyLabel, action: copy)"
      return switch self {
      case .literalIconFrameReturns: (".frame(width: StatusRowLayout.iconWidth)", ".frame(width: 16)")
      case .fileLosesTheWidthToken: (".frame(width: StatusRowLayout.iconWidth)", ".frame(width: 24)")
      case .fileLosesTheGapToken: ("spacing: StatusRowLayout.iconGap", "spacing: 4")
      case .tertiaryFillReturns: (".fill(.quinary)", ".fill(.tertiary)")
      case .pressedFillRemoved: (".fill(.quaternary)", ".fill(.quinary)")
      case .literalRadiusReturns:
        ("CornerShapes.rowHighlight(corners, container: containerRadius)", "RoundedRectangle(cornerRadius: 4)")
      case .hairlineInALiteralWidth: ("lineWidth: MenuBarPanelController.hairlineWidth", "lineWidth: 1")
      case .reopenWindowBuildsTheBorderedContent: ("PanelView(model: model, banner: Self.banner)", borderedView)
      case .copyLinkIsAPlainButton: ("CopyCommandButton(label: SleepDisabledClearing.copyLabel, copy: copy)", plain)
      case .hintCopyLinkIsAPlainButton: ("CopyCommandButton(label: action.label)", "Button(action.label)")
      }
    }

    var phrase: String {
      switch self {
      case .literalIconFrameReturns: "SessionsSection.swift draws an icon in a literal 16 pt column"
      case .fileLosesTheWidthToken: "LoginItemSection.swift does not read StatusRowLayout.iconWidth"
      case .fileLosesTheGapToken: "DetectionPane.swift does not read StatusRowLayout.iconGap"
      case .tertiaryFillReturns: "uses the tertiary style"
      case .pressedFillRemoved: "fills with the quaternary style 0 times"
      case .literalRadiusReturns: "holds a literal corner radius of 4"
      case .hairlineInALiteralWidth: "strokes a border that is not the hairline"
      case .reopenWindowBuildsTheBorderedContent: "ReopenWindow.swift builds the bordered panel content"
      case .copyLinkIsAPlainButton: "SleepDisabledRow.swift builds a plain button from the copy label"
      case .hintCopyLinkIsAPlainButton: "HintsSection.swift builds the confirming copy button 0 times"
      }
    }
  }

  @Test func theUndriftedPlantedPanelChromeHasNoFindings() {
    let files = Self.plantedChrome()
    #expect(Set(files.map(\.name)).count == Self.iconColumnFiles.count + 3)
    #expect(Self.panelChromeFindings(in: files) == [])
  }

  @Test(arguments: PanelChromeDrift.allCases)
  func aDriftedPanelChromeIsReported(drift: PanelChromeDrift) throws {
    let files = Self.plantedChrome()
    let target = try #require(files.first { $0.name == drift.file })
    let change = drift.change
    let drifted = target.text.replacingOccurrences(of: change.old, with: change.new)
    #expect(drifted != target.text, "the planted source does not hold \(change.old)")
    let changed = files.map { file in
      file.name == drift.file ? SourceFile(name: file.name, path: file.path, text: drifted) : file
    }
    let findings = Self.panelChromeFindings(in: changed)
    #expect(findings.contains { $0.contains(drift.phrase) }, "\(findings)")
  }

  static let interactionFile = "PanelInteraction.swift"
  static let panelFile = "PanelView.swift"
  static let onboardingFile = "OnboardingWindow.swift"
  static let settingsFile = "SettingsWindow.swift"
  static let reopenFile = "ReopenWindow.swift"

  static let animationCall = ".animation("
  static let policyAnimationCall = ".animation(Motion.animation("
  static let animationCalls: [String: Int] = [rowChromeFile: 2, panelFile: 1, onboardingFile: 1]
  static let transitionCall = ".transition("
  static let opacityTransition = ".transition(.opacity)"
  static let transitionCalls: [String: Int] = [panelFile: 1, onboardingFile: 1]
  static let animationType = "Animation."
  static let easeOutBuilder = ".easeOut("
  static let policyAnimation = "Animation.easeOut(duration:"
  static let otherAnimationBuilders = [
    ".easeIn(", ".easeInOut(", ".linear(", ".spring(", ".bouncy", ".snappy", ".smooth", ".interactiveSpring(",
    ".interpolatingSpring(", ".timingCurve(",
  ]
  static let animationContext = "NSAnimation" + "Context"
  static let animationBehaviourNone = "animationBehavior = .none"
  static let reduceMotion = "accessibilityReduceMotion"
  static let workspaceReduceMotion = "accessibilityDisplayShouldReduceMotion"
  static let clearedAnimation = ".transaction { $0.animation = nil }"
  static let clearedAnimations = 13
  static let forbiddenMotion: [(needle: String, name: String)] = [
    ("with" + "Animation", "an explicit animation block"),
    ("symbol" + "Effect", "a symbol effect"),
    ("content" + "Transition", "a content transition"),
    ("repeat" + "Forever", "a repeating animation"),
    ("repeat" + "Count", "a repeating animation"),
    ("phase" + "Animator", "a phase animation"),
    ("Phase" + "Animator", "a phase animation"),
    ("keyframe" + "Animator", "a keyframe animation"),
    ("Keyframe" + "Animator", "a keyframe animation"),
    ("matched" + "GeometryEffect", "a matched geometry effect"),
    ("Display" + "Link", "a display link"),
    ("CA" + "Animation", "a Core Animation animation"),
    ("CA" + "BasicAnimation", "a Core Animation animation"),
    ("CA" + "KeyframeAnimation", "a Core Animation animation"),
    ("CA" + "SpringAnimation", "a Core Animation animation"),
    ("CA" + "Transaction", "a Core Animation animation"),
    ("TimelineView(" + ".animation", "a timeline driven by animation"),
  ]

  static func motionFindings(in files: [SourceFile]) -> [String] {
    var findings: [String] = []
    let required = Set(animationCalls.keys).union(transitionCalls.keys).union([interactionFile, hairlineFile])
    for name in required.sorted() where !files.contains(where: { $0.name == name }) {
      findings.append(missing(name))
    }
    var cleared = 0
    for file in files {
      cleared += lineNumbers(in: file.text) { $0.trimmingCharacters(in: .whitespaces) == clearedAnimation }.count
      let fromPolicy = occurrences(of: policyAnimationCall, in: file.text)
      let animations = occurrences(of: animationCall, in: file.text) - fromPolicy
      if animations != fromPolicy {
        findings.append("\(file.name) animates with an animation that does not come from the motion policy")
      }
      let expectedAnimations = animationCalls[file.name] ?? 0
      if animations != expectedAnimations {
        findings.append("\(file.name) holds \(animations) animation calls, expected \(expectedAnimations)")
      }
      let transitions = occurrences(of: transitionCall, in: file.text)
      if transitions != occurrences(of: opacityTransition, in: file.text) {
        findings.append("\(file.name) uses a transition that is not the opacity transition")
      }
      let expectedTransitions = transitionCalls[file.name] ?? 0
      if transitions != expectedTransitions {
        findings.append("\(file.name) holds \(transitions) transitions, expected \(expectedTransitions)")
      }
      let animates = animations > 0 || transitions > 0 || expectedAnimations > 0
      if animates, occurrences(of: reduceMotion, in: file.text) == 0 {
        findings.append("\(file.name) animates without reading Reduce Motion")
      }
      findings += animationValueFindings(in: file) + animationContextFindings(in: file)
      for motion in forbiddenMotion where occurrences(of: motion.needle, in: file.text) > 0 {
        findings.append("\(file.name) names \(motion.name)")
      }
    }
    if cleared != clearedAnimations {
      findings.append(
        "the app sources hold \(cleared) transaction lines that clear the animation, expected \(clearedAnimations)")
    }
    return findings
  }

  static func animationValueFindings(in file: SourceFile) -> [String] {
    var findings: [String] = []
    let types = occurrences(of: animationType, in: file.text)
    let easeOuts = occurrences(of: easeOutBuilder, in: file.text)
    let others = otherAnimationBuilders.filter { occurrences(of: $0, in: file.text) > 0 }
    if file.name == interactionFile {
      if occurrences(of: policyAnimation, in: file.text) != 1 || types != 1 || easeOuts != 1 {
        findings.append("\(file.name) does not build exactly one ease-out animation")
      }
      for builder in others {
        findings.append("\(file.name) builds an animation that is not ease-out: \(builder)")
      }
    } else {
      let builders = (types > 0 ? [animationType] : []) + (easeOuts > 0 ? [easeOutBuilder] : []) + others
      for builder in builders {
        findings.append("\(file.name) builds an animation value of its own: \(builder)")
      }
    }
    return findings
  }

  static func animationContextFindings(in file: SourceFile) -> [String] {
    let named = occurrences(of: animationContext, in: file.text)
    guard file.name == hairlineFile else {
      return named > 0 ? ["\(file.name) names the AppKit animation context"] : []
    }
    var findings: [String] = []
    if named == 0 {
      findings.append("\(file.name) does not fade the panel through the AppKit animation context")
    }
    if occurrences(of: animationBehaviourNone, in: file.text) != 1 {
      findings.append("\(file.name) does not set the panel's animation behaviour to none exactly once")
    }
    if occurrences(of: workspaceReduceMotion, in: file.text) == 0 {
      findings.append("\(file.name) fades the panel without reading Reduce Motion")
    }
    return findings
  }

  static let keyEquivalentCall = ".keyboardShortcut("
  static let standardKeyEquivalents = [".keyboardShortcut(.defaultAction)", ".keyboardShortcut(.cancelAction)"]
  static let cancelKeyEquivalent = ".keyboardShortcut(.cancelAction)"
  static let closeKeyEquivalent = ".keyboardShortcut(\"w\")"
  static let closeKeyFiles = [settingsFile, onboardingFile, reopenFile]
  static let genericKeyEquivalent = "self.keyboardShortcut(shortcut.keyboardShortcut)"
  static let keyEquivalentBuilders = ["KeyEquivalent(", "KeyboardShortcut("]

  static func boundShortcut(_ name: String) -> String {
    ".panelShortcut(.\(name))"
  }

  static func keyEquivalentFindings(in files: [SourceFile], cases: [String]) -> [String] {
    var findings: [String] = []
    for name in closeKeyFiles + [interactionFile] where !files.contains(where: { $0.name == name }) {
      findings.append(missing(name))
    }
    for file in files {
      let isHelper = file.name == interactionFile
      let standard = standardKeyEquivalents.reduce(0) { $0 + occurrences(of: $1, in: file.text) }
      let closes = occurrences(of: closeKeyEquivalent, in: file.text)
      let generic = isHelper ? occurrences(of: genericKeyEquivalent, in: file.text) : 0
      if occurrences(of: keyEquivalentCall, in: file.text) != standard + closes + generic {
        findings.append(
          "\(file.name) binds a key equivalent that is neither a standard action, Command-W nor a panel shortcut")
      }
      let expectedCloses = closeKeyFiles.contains(file.name) ? 1 : 0
      if closes != expectedCloses {
        findings.append("\(file.name) binds Command-W \(closes) times, expected \(expectedCloses)")
      }
      if isHelper, generic != 1 {
        findings.append("\(file.name) does not hold the one generic key equivalent")
      }
      if !isHelper, keyEquivalentBuilders.contains(where: { occurrences(of: $0, in: file.text) > 0 }) {
        findings.append("\(file.name) builds a key equivalent outside the panel shortcut helper")
      }
    }
    for name in cases where !files.contains(where: { occurrences(of: boundShortcut(name), in: $0.text) > 0 }) {
      findings.append("nothing binds the panel shortcut \(name)")
    }
    return findings
  }

  static let confirmationCondition = "if !model.sleepConfirmation.isConfirming {"

  static func reopenFindings(in files: [SourceFile]) -> [String] {
    guard let file = files.first(where: { $0.name == reopenFile }) else { return [missing(reopenFile)] }
    var findings: [String] = []
    let cancels = occurrences(of: cancelKeyEquivalent, in: file.text)
    if cancels != 1 {
      findings.append("\(file.name) binds the cancel action \(cancels) times, not once")
    }
    let closes = occurrences(of: closeKeyEquivalent, in: file.text)
    if closes != 1 {
      findings.append("\(file.name) closes on Command-W \(closes) times, not once")
    }
    let squeezed = file.text.filter { !$0.isWhitespace }
    let condition = confirmationCondition.filter { !$0.isWhitespace }
    var guarded = false
    if let start = squeezed.range(of: condition),
      let cancel = squeezed.range(of: cancelKeyEquivalent, range: start.upperBound..<squeezed.endIndex)
    {
      guarded = !squeezed[start.upperBound..<cancel.lowerBound].contains("}")
    }
    if !guarded {
      findings.append("\(file.name) binds the cancel action outside the condition on the sleep confirmation")
    }
    return findings
  }

  static let versionLineCall = "PanelContent.versionLine("
  static let brandingWords = "Not affiliated"
  static let loginSectionRule = "model.showsLoginItemSection"
  static let loginItemNilTest = "loginItem != nil"

  static func footerFindings(in files: [SourceFile]) -> [String] {
    guard let file = files.first(where: { $0.name == panelFile }) else { return [missing(panelFile)] }
    var findings: [String] = []
    let lines = occurrences(of: versionLineCall, in: file.text)
    if lines != 1 {
      findings.append("\(file.name) draws the version line \(lines) times, not once")
    }
    if file.text.contains(brandingWords) {
      findings.append("\(file.name) holds the branding sentence")
    }
    let rules = occurrences(of: loginSectionRule, in: file.text)
    if rules != 1 {
      findings.append("\(file.name) reads the login section rule \(rules) times, not once")
    }
    if occurrences(of: loginItemNilTest, in: file.text) > 0 {
      findings.append("\(file.name) tests the login item for nil")
    }
    return findings
  }

  static let shortcutCases = PanelShortcut.allCases.map(\.rawValue)

  static func interactionFindings(in files: [SourceFile]) -> [String] {
    motionFindings(in: files) + keyEquivalentFindings(in: files, cases: shortcutCases) + reopenFindings(in: files)
      + footerFindings(in: files)
  }

  @Test func everyAnimationInTheAppIsOneOfTheFourTransitions() throws {
    let files = try Self.appSourceFiles()
    #expect(files.count > 40)
    #expect(Self.animationCalls.values.reduce(0, +) == MotionTransition.allCases.count)
    #expect(Self.transitionCalls.count == 2)
    #expect(Self.motionFindings(in: files) == [])
  }

  @Test func everyKeyEquivalentIsAStandardActionOrAPanelShortcut() throws {
    let files = try Self.appSourceFiles()
    #expect(Self.shortcutCases.count == 7)
    #expect(Self.closeKeyFiles.count == 3)
    #expect(Self.keyEquivalentFindings(in: files, cases: Self.shortcutCases) == [])
  }

  @Test func theReopenWindowClosesOnEscOnlyOutsideTheSleepConfirmation() throws {
    #expect(Self.reopenFindings(in: try Self.appSourceFiles()) == [])
  }

  @Test func thePanelFooterShowsOneLineAndNoBranding() throws {
    #expect(Self.footerFindings(in: try Self.appSourceFiles()) == [])
  }

  static let plantedReduceMotion = "@Environment(\\.accessibilityReduceMotion) private var reduceMotion"
  static let plantedHoverAnimation =
    "  .animation(Motion.animation(.rowHighlight, reduceMotion: reduceMotion), value: showsHover)"
  static let plantedGlyphAnimation =
    ".animation(Motion.animation(.statusGlyph, reduceMotion: reduceMotion), value: presentation.glyph)"
  static let plantedPolicyAnimation =
    "duration(transition, reduceMotion: reduceMotion).map { Animation.easeOut(duration: $0) }"
  static let plantedWorkspaceRead = "let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion"
  static let plantedLoginRule = "if model.showsLoginItemSection {"
  static let plantedBranding = "Text(\"Works with Claude Code. Not affiliated with Anthropic.\")"

  static func plantedInteraction() -> [SourceFile] {
    [
      planted(
        rowChromeFile,
        [
          plantedReduceMotion,
          "RoundedRectangle(cornerRadius: PanelRowLayout.highlightRadius)",
          plantedHoverAnimation,
          "RoundedRectangle(cornerRadius: PanelRowLayout.highlightRadius)",
          "  .animation(Motion.animation(.rowHighlight, reduceMotion: reduceMotion), value: showsPressed)",
          "Button(SleepConfirmation.cancelLabel) { model.keepWorking() }",
          "  .keyboardShortcut(.cancelAction)",
          "  .panelShortcut(.pause)",
          "  .panelShortcut(.keepAwake)",
          "  .panelShortcut(.releaseUntilIdle)",
          "  .panelShortcut(.sleepNow)",
          "  .panelShortcut(.restore)",
          "  .panelShortcut(shortcut)",
          clearedAnimation,
        ]),
      planted(
        panelFile,
        [
          plantedReduceMotion,
          plantedLoginRule,
          "StatusGlyphView(label: StatusItemLabel(presentation))",
          "  .equatable()",
          "  .id(presentation.glyph)",
          "  .transition(.opacity)",
          plantedGlyphAnimation,
          "Text(PanelContent.versionLine(version))",
          "  .panelShortcut(.settings)",
          "  .panelShortcut(.quit)",
          clearedAnimation,
        ]),
      planted(
        onboardingFile,
        [
          plantedReduceMotion,
          ".id(step)",
          ".transition(.opacity)",
          ".animation(Motion.animation(.onboardingStep, reduceMotion: reduceMotion), value: step)",
          ".keyboardShortcut(\"w\")",
          ".keyboardShortcut(.defaultAction)",
          clearedAnimation,
        ]),
      planted(settingsFile, [".keyboardShortcut(\"w\")", clearedAnimation]),
      planted(
        reopenFile,
        [
          "Button(Self.closeLabel, action: close)",
          "  .keyboardShortcut(\"w\")",
          confirmationCondition,
          "  Button(Self.closeLabel, action: close)",
          "    .keyboardShortcut(.cancelAction)",
          "}",
        ]),
      planted(
        interactionFile,
        [
          "KeyboardShortcut(KeyEquivalent(key), modifiers: EventModifiers(modifiers.map { $0.eventModifier }))",
          genericKeyEquivalent,
          plantedPolicyAnimation,
        ]),
      planted(
        hairlineFile,
        [
          "panel.animationBehavior = .none",
          plantedWorkspaceRead,
          animationContext + ".runAnimationGroup { context in",
        ]),
      planted("Panes.swift", Array(repeating: clearedAnimation, count: clearedAnimations - 4)),
    ]
  }

  enum InteractionDrift: CaseIterable, Sendable {
    case fifthAnimationCall
    case animationNotFromThePolicy
    case fileAnimatesWithoutReadingReduceMotion
    case transactionLineRemoved
    case explicitAnimationBlock
    case letterKeyEquivalentOtherThanW
    case shortcutCaseThatNothingBinds
    case transitionThatIsNotOpacity
    case animationValueOutsideThePolicy
    case policyAnimationThatIsNotEaseOut
    case fadeWithoutReadingReduceMotion
    case panelAnimationBehaviourChanged
    case animationContextOutsideTheController
    case escOutsideTheConfirmationCondition
    case reopenWindowLosesCommandW
    case brandingReturnsToThePanel
    case loginItemTestedForNil
    case keyEquivalentBuiltOutsideTheHelper

    var file: String {
      switch self {
      case .fifthAnimationCall, .animationValueOutsideThePolicy, .keyEquivalentBuiltOutsideTheHelper:
        AppViewSourceGuardTests.rowChromeFile
      case .animationNotFromThePolicy, .explicitAnimationBlock, .letterKeyEquivalentOtherThanW,
        .shortcutCaseThatNothingBinds, .brandingReturnsToThePanel, .loginItemTestedForNil:
        AppViewSourceGuardTests.panelFile
      case .fileAnimatesWithoutReadingReduceMotion, .transitionThatIsNotOpacity:
        AppViewSourceGuardTests.onboardingFile
      case .transactionLineRemoved, .animationContextOutsideTheController: AppViewSourceGuardTests.settingsFile
      case .policyAnimationThatIsNotEaseOut: AppViewSourceGuardTests.interactionFile
      case .fadeWithoutReadingReduceMotion, .panelAnimationBehaviourChanged: AppViewSourceGuardTests.hairlineFile
      case .escOutsideTheConfirmationCondition, .reopenWindowLosesCommandW: AppViewSourceGuardTests.reopenFile
      }
    }

    var change: (old: String, new: String) {
      let hover = AppViewSourceGuardTests.plantedHoverAnimation
      let glyph = AppViewSourceGuardTests.plantedGlyphAnimation
      let cleared = AppViewSourceGuardTests.clearedAnimation
      let block = "with" + "Animation { model.refreshAttention() }"
      let context = AppViewSourceGuardTests.animationContext + ".runAnimationGroup { _ in }"
      let ownKey = ".keyboardShortcut(KeyboardShortcut(\"p\", modifiers: [.control, .command]))"
      let quit = "  .panelShortcut(.quit)"
      let condition = AppViewSourceGuardTests.confirmationCondition
      return switch self {
      case .fifthAnimationCall: (hover, hover + "\n" + hover)
      case .animationNotFromThePolicy: (glyph, ".animation(.default, value: presentation.glyph)")
      case .fileAnimatesWithoutReadingReduceMotion:
        (AppViewSourceGuardTests.plantedReduceMotion, "private let reduceMotion = false")
      case .transactionLineRemoved: (cleared, "")
      case .explicitAnimationBlock: (cleared, cleared + "\n" + block)
      case .letterKeyEquivalentOtherThanW: (quit, quit + "\n  .keyboardShortcut(\"q\")")
      case .shortcutCaseThatNothingBinds: (quit, "  .help(PanelContent.quitHelp)")
      case .transitionThatIsNotOpacity: (".transition(.opacity)", ".transition(.slide)")
      case .animationValueOutsideThePolicy: (cleared, "let quick = Animation.linear(duration: 1)\n" + cleared)
      case .policyAnimationThatIsNotEaseOut: ("Animation.easeOut(duration: $0)", "Animation.spring(duration: $0)")
      case .fadeWithoutReadingReduceMotion: (AppViewSourceGuardTests.plantedWorkspaceRead, "let reduce = false")
      case .panelAnimationBehaviourChanged: ("animationBehavior = .none", "animationBehavior = .utilityWindow")
      case .animationContextOutsideTheController: (cleared, cleared + "\n" + context)
      case .escOutsideTheConfirmationCondition: (condition, "if model.isPanelVisible {")
      case .reopenWindowLosesCommandW: ("  .keyboardShortcut(\"w\")", "  .keyboardShortcut(.defaultAction)")
      case .brandingReturnsToThePanel:
        (cleared, AppViewSourceGuardTests.plantedBranding + "\n" + cleared)
      case .loginItemTestedForNil: (AppViewSourceGuardTests.plantedLoginRule, "if model.loginItem != nil {")
      case .keyEquivalentBuiltOutsideTheHelper: (cleared, ownKey + "\n" + cleared)
      }
    }

    var phrase: String {
      switch self {
      case .fifthAnimationCall: "ControlsSection.swift holds 3 animation calls, expected 2"
      case .animationNotFromThePolicy:
        "PanelView.swift animates with an animation that does not come from the motion policy"
      case .fileAnimatesWithoutReadingReduceMotion: "OnboardingWindow.swift animates without reading Reduce Motion"
      case .transactionLineRemoved: "hold 12 transaction lines that clear the animation, expected 13"
      case .explicitAnimationBlock: "PanelView.swift names an explicit animation block"
      case .letterKeyEquivalentOtherThanW: "PanelView.swift binds a key equivalent that is neither a standard action"
      case .shortcutCaseThatNothingBinds: "nothing binds the panel shortcut quit"
      case .transitionThatIsNotOpacity: "OnboardingWindow.swift uses a transition that is not the opacity transition"
      case .animationValueOutsideThePolicy: "ControlsSection.swift builds an animation value of its own: .linear("
      case .policyAnimationThatIsNotEaseOut: "PanelInteraction.swift does not build exactly one ease-out animation"
      case .fadeWithoutReadingReduceMotion: "MenuBarPanelController.swift fades the panel without reading Reduce Motion"
      case .panelAnimationBehaviourChanged: "does not set the panel's animation behaviour to none exactly once"
      case .animationContextOutsideTheController: "SettingsWindow.swift names the AppKit animation context"
      case .escOutsideTheConfirmationCondition:
        "ReopenWindow.swift binds the cancel action outside the condition on the sleep confirmation"
      case .reopenWindowLosesCommandW: "ReopenWindow.swift closes on Command-W 0 times, not once"
      case .brandingReturnsToThePanel: "PanelView.swift holds the branding sentence"
      case .loginItemTestedForNil: "PanelView.swift tests the login item for nil"
      case .keyEquivalentBuiltOutsideTheHelper:
        "ControlsSection.swift builds a key equivalent outside the panel shortcut helper"
      }
    }
  }

  @Test func theUndriftedPlantedInteractionSourcesHaveNoFindings() {
    let files = Self.plantedInteraction()
    #expect(Set(files.map(\.name)).count == 8)
    #expect(Self.interactionFindings(in: files) == [])
  }

  @Test(arguments: InteractionDrift.allCases)
  func aDriftedInteractionSourceIsReported(drift: InteractionDrift) throws {
    let files = Self.plantedInteraction()
    #expect(Self.interactionFindings(in: files) == [])
    let target = try #require(files.first { $0.name == drift.file })
    let change = drift.change
    let range = try #require(target.text.range(of: change.old), "the planted source does not hold \(change.old)")
    let drifted = target.text.replacingCharacters(in: range, with: change.new)
    let changed = files.map { file in
      file.name == drift.file ? SourceFile(name: file.name, path: file.path, text: drifted) : file
    }
    let findings = Self.interactionFindings(in: changed)
    #expect(findings.contains { $0.contains(drift.phrase) }, "\(findings)")
  }

  static let applicationIconCall = "AboutIdentity.applicationIcon()"
  static let welcomeIcon =
    "Image(nsImage: AboutIdentity.applicationIcon()).resizable()"
    + ".frame(width: Self.side, height: Self.side).accessibilityHidden(true)"
  static let welcomeIconCondition = "if step == .welcome {"
  static let stepIconSide = "static let side: CGFloat = 48"
  static let catalogLookups = ["Image(\"", "NSImage(named:", "image(forResource:", "ImageResource"]

  static func welcomeIconFindings(in source: String) -> [String] {
    var findings: [String] = []
    let drawn = occurrences(of: applicationIconCall, in: source)
    if drawn != 1 {
      findings.append("the onboarding window draws the application icon \(drawn) times, not once")
    }
    if occurrences(of: welcomeIcon, in: source) != 1 {
      findings.append("the application icon is not drawn resized to its place and hidden from accessibility")
    }
    if occurrences(of: welcomeIconCondition, in: source) != 1 {
      findings.append("the application icon is not drawn for the welcome step alone")
    }
    if occurrences(of: stepIconSide, in: source) != 1 {
      findings.append("the step icon place is not 48 pt")
    }
    for lookup in catalogLookups where occurrences(of: lookup, in: source) > 0 {
      findings.append("the onboarding window resolves an image by a catalog name: \(lookup)")
    }
    return findings
  }

  @Test func theWelcomeStepShowsTheApplicationIcon() throws {
    let window = try #require(try Self.appSourceFiles().first { $0.name == Self.onboardingFile })
    #expect(Self.welcomeIconFindings(in: window.text) == [])
  }

  static func slice(of text: String, from start: String, to end: String) throws -> String {
    let begin = try #require(text.range(of: start))
    let rest = text[begin.upperBound...]
    let stop = rest.range(of: end)?.lowerBound ?? rest.endIndex
    return String(rest[..<stop])
  }

  @Test func theHotspotStepShowsTheSettingsPickerAndExplainsLocationAboveItsStatusRow() throws {
    let files = try Self.appSourceFiles()
    let steps = try #require(files.first { $0.name == "OnboardingSteps.swift" })
    let pane = try #require(files.first { $0.name == "NetworkPane.swift" })
    let text = steps.text.filter { !$0.isWhitespace }
    let step = try Self.slice(of: text, from: "structOnboardingLocationStep:View{", to: "struct")
    let picker = try #require(step.range(of: "HotspotPickerField(model:settings)"))
    let rows = try #require(step.range(of: "OnboardingInfoRows(rows:OnboardingFlow.locationRows)"))
    let status = try #require(step.range(of: "StatusRow("))
    #expect(picker.upperBound <= rows.lowerBound)
    #expect(rows.upperBound <= status.lowerBound)
    let paneText = pane.text.filter { !$0.isWhitespace }
    #expect(Self.occurrences(of: "HotspotPickerField(model:model)", in: paneText) == 1)
  }

  @Test func theOnboardingSharesTheSettingsModelOfTheSettingsWindow() throws {
    let delegate = try #require(try Self.appSourceFiles().first { $0.name == "AppDelegate.swift" })
    let text = delegate.text.filter { !$0.isWhitespace }
    #expect(Self.occurrences(of: "onboarding.makeSettings=", in: text) == 1)
    #expect(Self.occurrences(of: "=SettingsModel(", in: text) == 1)
    let show = try Self.slice(of: text, from: "funcshowSettings(", to: "func")
    #expect(Self.occurrences(of: "makeSettingsModel()", in: show) == 1)
    let shared = try Self.slice(of: text, from: "funconboardingSettingsModel()", to: "func")
    #expect(shared.hasPrefix("->SettingsModel?{guard!AppMode.current.isTestHostelse{returnnil}"))
    let made = try #require(shared.range(of: "makeSettingsModel()"))
    let synced = try #require(shared.range(of: "syncSettingsHost()"))
    #expect(made.upperBound <= synced.lowerBound)
  }

  @Test func theStepBodyComesFromTheModel() throws {
    let window = try #require(try Self.appSourceFiles().first { $0.name == Self.onboardingFile })
    let text = window.text.filter { !$0.isWhitespace }
    #expect(text.components(separatedBy: "Text(model.stepBody)").count - 1 == 1)
    #expect(!text.contains("Text(step.body)"))
  }

  @Test func theLastStepShowsWhereOvertimeLivesBelowItsTestRow() throws {
    let steps = try #require(try Self.appSourceFiles().first { $0.name == "OnboardingSteps.swift" })
    let text = steps.text.filter { !$0.isWhitespace }
    let start = try #require(text.range(of: "structOnboardingSelfTestStep:View{"))
    let rest = text[start.upperBound...]
    let end = rest.range(of: "struct")?.lowerBound ?? rest.endIndex
    let step = String(rest[..<end])
    let testRow = "SelfTestRowView(row:model.selfTestRow)"
    let finishRow = "OnboardingInfoRow(row:OnboardingFlow.finishRow)"
    #expect(step.components(separatedBy: testRow).count - 1 == 1)
    #expect(step.components(separatedBy: finishRow).count - 1 == 1)
    let shownTest = try #require(step.range(of: testRow))
    let shownFinish = try #require(step.range(of: finishRow))
    #expect(shownTest.upperBound <= shownFinish.lowerBound)
    #expect(text.components(separatedBy: "OnboardingInfoRows(rows:OnboardingFlow.welcomeRows)").count - 1 == 1)
  }

  static let plantedStepIcon = [
    "struct OnboardingStepIcon: View {",
    "  static let side: CGFloat = 48",
    "  let step: OnboardingStep",
    "  var body: some View {",
    "    if step == .welcome {",
    "      Image(nsImage: AboutIdentity.applicationIcon())",
    "        .resizable()",
    "        .frame(width: Self.side, height: Self.side)",
    "        .accessibilityHidden(true)",
    "    } else {",
    "      Image(systemName: step.symbol)",
    "        .accessibilityHidden(true)",
    "    }",
    "  }",
    "}",
  ].joined(separator: "\n")

  struct WelcomeIconDrift: Sendable, CustomTestStringConvertible {
    let name: String
    let old: String
    let new: String
    let phrase: String

    var testDescription: String { name }
  }

  static let welcomeIconDrifts = [
    WelcomeIconDrift(
      name: "no application icon", old: "Image(nsImage: AboutIdentity.applicationIcon())",
      new: "Image(systemName: step.symbol)", phrase: "draws the application icon 0 times"),
    WelcomeIconDrift(
      name: "read by VoiceOver",
      old: ".frame(width: Self.side, height: Self.side)\n        .accessibilityHidden(true)",
      new: ".frame(width: Self.side, height: Self.side)", phrase: "hidden from accessibility"),
    WelcomeIconDrift(
      name: "not resized", old: "        .resizable()\n", new: "", phrase: "resized to its place"),
    WelcomeIconDrift(
      name: "on every step", old: "if step == .welcome {", new: "if step != .selfTest {",
      phrase: "for the welcome step alone"),
    WelcomeIconDrift(
      name: "another size", old: "static let side: CGFloat = 48", new: "static let side: CGFloat = 64",
      phrase: "is not 48 pt"),
    WelcomeIconDrift(
      name: "a catalog image", old: "Image(systemName: step.symbol)", new: "Image(\"Welcome\")",
      phrase: "by a catalog name"),
  ]

  @Test func theUndriftedPlantedStepIconHasNoFindings() {
    #expect(Self.welcomeIconFindings(in: Self.plantedStepIcon) == [])
  }

  @Test(arguments: welcomeIconDrifts)
  func aWelcomeStepThatDriftsFromTheApplicationIconIsReported(drift: WelcomeIconDrift) throws {
    let range = try #require(Self.plantedStepIcon.range(of: drift.old), "the planted source lacks \(drift.old)")
    let drifted = Self.plantedStepIcon.replacingCharacters(in: range, with: drift.new)
    let findings = Self.welcomeIconFindings(in: drifted)
    #expect(findings.contains { $0.contains(drift.phrase) }, "\(findings)")
  }

  static let paletteFile = "PrismStyle.swift"
  static let cardFile = "PrismCard.swift"
  static let indicatorFile = "PrismIndicator.swift"
  static let settingsTileFile = "SettingsTile.swift"
  static let settingsHeaderFile = "SettingsPaneHeader.swift"
  static let paletteFiles = [cardFile, indicatorFile]
  static let gradientFiles = [cardFile, settingsTileFile]
  static let prismCardSites: [String: Int] = [panelFile: 1, settingsHeaderFile: 1]
  static let prismIndicatorSites: [String: Int] = [panelFile: 1]
  static let plainSurfaces = [
    rowChromeFile, settingsFile, interactionFile, onboardingFile, "OnboardingSteps.swift", "OnboardingCheckRows.swift",
    "StepRow.swift", reopenFile, "SessionsSection.swift", "StatusLinesSection.swift",
  ]
  static let prismHexes = ["FF2FB9", "8A5CFF", "19D3FF"]
  static let paletteName = "PrismPalette"
  static let cardCall = "PrismCard("
  static let indicatorCall = "PrismIndicator("
  static let litRule = "HeroStatus.isLit("
  static let gradientStem = "radient"
  static let gradientConstruction = "gradient("
  static let glowGradient = "radialgradient("
  static let indicatorShape = "Circle()"
  static let shadowCall = ".shadow("
  static let gradientMember = ".gradient"
  static let gradientShorthands = [
    ".linearGradient(", ".radialGradient(", ".angularGradient(", ".ellipticalGradient(", ".conicGradient(",
  ]
  static let cardReads = [
    "accessibilityReduceTransparency", "colorSchemeContrast", "\\.colorScheme)", "PrismLook.resolve(",
  ]

  static func gradientCounts(in text: String) -> (shorthands: Int, members: Int, others: Int) {
    let lower = text.lowercased()
    let shorthands = gradientShorthands.reduce(0) { $0 + occurrences(of: $1.lowercased(), in: lower) }
    let members = occurrences(of: gradientMember, in: lower)
    let stems = occurrences(of: gradientStem, in: lower)
    return (shorthands, members, stems - shorthands - members)
  }

  static func prismFindings(app: [SourceFile], package: [SourceFile]) -> [String] {
    var findings: [String] = []
    for name in [cardFile, indicatorFile, panelFile] + plainSurfaces where !app.contains(where: { $0.name == name }) {
      findings.append(missing(name))
    }
    let palette = package.first { $0.name == paletteFile }
    if palette == nil {
      findings.append("\(paletteFile) is not among the package sources")
    }
    for file in app {
      let named = occurrences(of: paletteName, in: file.text)
      if named > 0, !paletteFiles.contains(file.name) {
        findings.append("\(file.name) names the prism palette")
      }
      var gradients = 0
      if !gradientFiles.contains(file.name) {
        let counts = gradientCounts(in: file.text)
        gradients = counts.shorthands + counts.members + counts.others
        if counts.others > 0 {
          findings.append("\(file.name) builds a gradient")
        }
        if counts.shorthands > 0 {
          findings.append("\(file.name) uses a gradient shape style")
        }
        if counts.members > 0 {
          findings.append("\(file.name) uses the gradient member of a colour")
        }
      }
      let cards = occurrences(of: cardCall, in: file.text)
      let expectedCards = prismCardSites[file.name] ?? 0
      if cards != expectedCards {
        findings.append("\(file.name) draws the prism card \(cards) times, expected \(expectedCards)")
      }
      let indicators = occurrences(of: indicatorCall, in: file.text)
      let expectedIndicators = prismIndicatorSites[file.name] ?? 0
      if indicators != expectedIndicators {
        findings.append("\(file.name) draws the prism indicator \(indicators) times, expected \(expectedIndicators)")
      }
      if plainSurfaces.contains(file.name), named + gradients + cards + indicators > 0 {
        findings.append("\(file.name) is a plain surface and draws the prism")
      }
    }
    for file in app + package.filter({ $0.name != paletteFile }) {
      let upper = file.text.uppercased()
      for hex in prismHexes where upper.contains(hex) {
        findings.append("\(file.name) spells the prism colour \(hex)")
      }
    }
    if let palette {
      let upper = palette.text.uppercased()
      for hex in prismHexes where !upper.contains(hex) {
        findings.append("\(paletteFile) does not declare the prism colour \(hex)")
      }
    }
    if let card = app.first(where: { $0.name == cardFile }) {
      let counts = gradientCounts(in: card.text)
      let lower = card.text.lowercased()
      let constructions = occurrences(of: gradientConstruction, in: lower) - occurrences(of: glowGradient, in: lower)
      if counts.shorthands + counts.members + constructions > 0 {
        findings.append("\(cardFile) builds a gradient other than the glow")
      }
      for read in cardReads where occurrences(of: read, in: card.text) == 0 {
        findings.append("\(cardFile) does not read \(read)")
      }
    }
    if let indicator = app.first(where: { $0.name == indicatorFile }) {
      if occurrences(of: indicatorShape, in: indicator.text) == 0 {
        findings.append("\(indicatorFile) does not draw a circle")
      }
      if occurrences(of: shadowCall, in: indicator.text) > 0 {
        findings.append("\(indicatorFile) casts a shadow")
      }
      for read in cardReads where occurrences(of: read, in: indicator.text) == 0 {
        findings.append("\(indicatorFile) does not read \(read)")
      }
    }
    return findings
  }

  @Test func thePrismGradientStaysInsideTheGlowCards() throws {
    let app = try Self.appSourceFiles()
    let package = try Self.packageSourceFiles()
    #expect(app.count > 40)
    #expect(package.count > 40)
    #expect(Self.prismFindings(app: app, package: package) == [])
  }

  static let plantedCard = [
    "@Environment(\\.accessibilityReduceTransparency) private var reduceTransparency",
    "@Environment(\\.colorSchemeContrast) private var contrast",
    "@Environment(\\.colorScheme) private var colorScheme",
    "let look = PrismLook.resolve(lit: lit, appearance: .dark, reduceTransparency: true, increaseContrast: false)",
    "RadialGradient(colors: [PrismPalette.magenta.color, .clear], center: .top, startRadius: 0, endRadius: 150)",
  ]
  static let plantedIndicator = [
    "@Environment(\\.accessibilityReduceTransparency) private var reduceTransparency",
    "@Environment(\\.colorSchemeContrast) private var contrast",
    "@Environment(\\.colorScheme) private var colorScheme",
    "let look = PrismLook.resolve(lit: lit, appearance: .dark, reduceTransparency: true, increaseContrast: false)",
    "Circle()",
    "  .fill(PrismPalette.indicatorColor(look.indicator)?.color ?? Color(nsColor: .systemGray))",
  ]
  static let plantedPalette = [
    "public static let magenta = PrismColor(hex: 0xFF2FB9)",
    "public static let violet = PrismColor(hex: 0x8A5CFF)",
    "public static let cyan = PrismColor(hex: 0x19D3FF)",
  ]
  static let plantedHero = [
    "let lit = HeroStatus.isLit(presentation.state)",
    "PrismCard(lit: lit, shape: CornerShapes.heroCard(container: containerRadius)) {",
    "  PrismIndicator(lit: lit) {",
    "    StatusGlyphView(label: StatusItemLabel(presentation))",
    "  }",
    "}",
  ]
  static let plainAnchor = "Text(title)"

  static func plantedPrism() -> (app: [SourceFile], package: [SourceFile]) {
    let surfaces = plainSurfaces.map { name in
      planted(name, [plainAnchor, "  .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))"])
    }
    let settings = [
      planted(settingsTileFile, plantedSettingsTile), planted(settingsHeaderFile, plantedSettingsHeader),
    ]
    let prism = [
      planted(cardFile, plantedCard), planted(indicatorFile, plantedIndicator), planted(panelFile, plantedHero),
    ]
    let app = prism + settings + surfaces
    let package = [
      SourceFile(
        name: paletteFile, path: "Packages/OvertimeRuntime/Sources/OvertimeAppSupport/" + paletteFile,
        text: plantedPalette.joined(separator: "\n"))
    ]
    return (app, package)
  }

  enum PrismDrift: CaseIterable, Sendable {
    case gradientBackgroundOnAControl
    case paletteNamedInSettings
    case gradientShapeStyleInOnboarding
    case secondCardInTheReopenWindow
    case prismHexInControls
    case cardReadsReduceMotionInsteadOfReduceTransparency
    case indicatorInControls
    case gradientMemberOnAControl
    case paletteNamedInTheSettingsTile
    case gradientOnTheSettingsSelection
    case gradientOnTheIndicator
    case shadowOnTheIndicator
    case linearGradientInTheCard

    var file: String {
      switch self {
      case .gradientBackgroundOnAControl, .prismHexInControls, .indicatorInControls, .gradientMemberOnAControl:
        AppViewSourceGuardTests.rowChromeFile
      case .paletteNamedInSettings, .gradientOnTheSettingsSelection: AppViewSourceGuardTests.settingsFile
      case .paletteNamedInTheSettingsTile: AppViewSourceGuardTests.settingsTileFile
      case .gradientShapeStyleInOnboarding: AppViewSourceGuardTests.onboardingFile
      case .secondCardInTheReopenWindow: AppViewSourceGuardTests.reopenFile
      case .cardReadsReduceMotionInsteadOfReduceTransparency, .linearGradientInTheCard:
        AppViewSourceGuardTests.cardFile
      case .gradientOnTheIndicator, .shadowOnTheIndicator: AppViewSourceGuardTests.indicatorFile
      }
    }

    var change: (old: String, new: String) {
      let anchor = AppViewSourceGuardTests.plainAnchor
      let linear = "LinearGradient(colors: [.pink, .purple], startPoint: .leading, endPoint: .trailing)"
      let vertical = "LinearGradient(colors: [.pink, .purple], startPoint: .top, endPoint: .bottom)"
      let circle = AppViewSourceGuardTests.indicatorShape
      let glow = AppViewSourceGuardTests.plantedCard[4]
      return switch self {
      case .gradientBackgroundOnAControl: (anchor, anchor + "\n  .background(" + linear + ")")
      case .paletteNamedInSettings: (anchor, anchor + "\n  .foregroundStyle(PrismPalette.violet.color)")
      case .gradientShapeStyleInOnboarding:
        (anchor, anchor + "\n  .fill(.linearGradient(colors: [.blue, .purple], startPoint: .top, endPoint: .bottom))")
      case .secondCardInTheReopenWindow: (anchor, "PrismCard(lit: true, cornerRadius: 14) { " + anchor + " }")
      case .prismHexInControls: (anchor, anchor + "\nlet pink = 0xFF2FB9")
      case .cardReadsReduceMotionInsteadOfReduceTransparency:
        ("accessibilityReduceTransparency", "accessibilityReduceMotion")
      case .indicatorInControls: (anchor, "PrismIndicator(lit: true) { " + anchor + " }")
      case .gradientMemberOnAControl: (anchor, anchor + "\n  .background(Color.accentColor.gradient)")
      case .paletteNamedInTheSettingsTile:
        (AppViewSourceGuardTests.plantedTileFill, "  .fill(PrismPalette.violet.color)")
      case .gradientOnTheSettingsSelection: (anchor, anchor + "\n  .listRowBackground(" + linear + ")")
      case .gradientOnTheIndicator: (circle, circle + "\n  .fill(" + vertical + ")")
      case .shadowOnTheIndicator: (circle, circle + "\n  .shadow(color: .black, radius: 4)")
      case .linearGradientInTheCard: (glow, glow + "\n" + vertical)
      }
    }

    var phrase: String {
      switch self {
      case .gradientBackgroundOnAControl: "ControlsSection.swift builds a gradient"
      case .paletteNamedInSettings: "SettingsWindow.swift names the prism palette"
      case .gradientShapeStyleInOnboarding: "OnboardingWindow.swift uses a gradient shape style"
      case .secondCardInTheReopenWindow: "ReopenWindow.swift draws the prism card 1 times, expected 0"
      case .prismHexInControls: "ControlsSection.swift spells the prism colour FF2FB9"
      case .cardReadsReduceMotionInsteadOfReduceTransparency:
        "PrismCard.swift does not read accessibilityReduceTransparency"
      case .indicatorInControls: "ControlsSection.swift draws the prism indicator 1 times, expected 0"
      case .gradientMemberOnAControl: "ControlsSection.swift uses the gradient member of a colour"
      case .paletteNamedInTheSettingsTile: "SettingsTile.swift names the prism palette"
      case .gradientOnTheSettingsSelection: "SettingsWindow.swift builds a gradient"
      case .gradientOnTheIndicator: "PrismIndicator.swift builds a gradient"
      case .shadowOnTheIndicator: "PrismIndicator.swift casts a shadow"
      case .linearGradientInTheCard: "PrismCard.swift builds a gradient other than the glow"
      }
    }
  }

  @Test func theUndriftedPlantedPrismSourcesHaveNoFindings() {
    let planted = Self.plantedPrism()
    #expect(Set(planted.app.map(\.name)).count == Self.plainSurfaces.count + 5)
    #expect(Self.prismFindings(app: planted.app, package: planted.package) == [])
  }

  @Test(arguments: PrismDrift.allCases)
  func aDriftedPrismSourceIsReported(drift: PrismDrift) throws {
    #expect(PrismDrift.allCases.count == 13)
    let planted = Self.plantedPrism()
    #expect(Self.prismFindings(app: planted.app, package: planted.package) == [])
    let target = try #require(planted.app.first { $0.name == drift.file })
    let change = drift.change
    let range = try #require(target.text.range(of: change.old), "the planted source does not hold \(change.old)")
    let drifted = target.text.replacingCharacters(in: range, with: change.new)
    let changed = planted.app.map { file in
      file.name == drift.file ? SourceFile(name: file.name, path: file.path, text: drifted) : file
    }
    let findings = Self.prismFindings(app: changed, package: planted.package)
    #expect(findings.contains { $0.contains(drift.phrase) }, "\(findings)")
  }

  static let systemImageLabel = "Label(pane.title, systemImage:"
  static let sidebarTile = "SettingsTile(pane: pane, size: .sidebar)"
  static let paneHeaderCall = "SettingsPaneHeader(pane: model.selectedPane)"
  static let headerTile = "SettingsTile(pane: pane, size: .header)"
  static let headerTrait = ".accessibilityAddTraits(.isHeader)"
  static let tileColorRead = "pane.tileColor"
  static let hiddenFromVoiceOver = ".accessibilityHidden(true)"
  static let paneHeaderCounts: [(needle: String, what: String)] = [
    (cardCall, "the prism card"), (headerTile, "the header tile"), (headerTrait, "the header trait"),
  ]
  static let nativeSelectionCounts: [(needle: String, expected: Int, what: String)] = [
    ("List(selection:", 1, "the sidebar list"),
    (".listStyle(.sidebar)", 1, "the sidebar style"),
    (".listRowBackground(", 0, "a row background"),
    (".listItemTint(", 0, "a list item tint"),
    (".tint(", 0, "a tint"),
    (".accentColor(", 0, "an accent colour"),
  ]

  static func settingsTileFindings(in files: [SourceFile]) -> [String] {
    var findings: [String] = []
    let window = files.first { $0.name == settingsFile }
    let tile = files.first { $0.name == settingsTileFile }
    let header = files.first { $0.name == settingsHeaderFile }
    let expected = [(settingsFile, window), (settingsTileFile, tile), (settingsHeaderFile, header)]
    for (name, file) in expected where file == nil {
      findings.append(missing(name))
    }
    if let window {
      if occurrences(of: systemImageLabel, in: window.text) > 0 {
        findings.append("\(settingsFile) builds a sidebar label from a system image")
      }
      if occurrences(of: sidebarTile, in: window.text) == 0 {
        findings.append("\(settingsFile) does not draw the sidebar tile")
      }
      let headers = occurrences(of: paneHeaderCall, in: window.text)
      if headers != 1 {
        findings.append("\(settingsFile) draws the pane header \(headers) times, expected 1")
      }
    }
    if let header {
      for item in paneHeaderCounts {
        let count = occurrences(of: item.needle, in: header.text)
        if count != 1 {
          findings.append("\(settingsHeaderFile) holds \(item.what) \(count) times, expected 1")
        }
      }
    }
    if let tile {
      if occurrences(of: tileColorRead, in: tile.text) == 0 {
        findings.append("\(settingsTileFile) does not read the tile colour of its pane")
      }
      if occurrences(of: hiddenFromVoiceOver, in: tile.text) == 0 {
        findings.append("\(settingsTileFile) does not hide the tile from VoiceOver")
      }
    }
    return findings
  }

  static func nativeSelectionFindings(in source: String) -> [String] {
    nativeSelectionCounts.compactMap { item in
      let count = occurrences(of: item.needle, in: source)
      guard count != item.expected else { return nil }
      return "\(settingsFile) sets \(item.what) \(count) times, expected \(item.expected)"
    }
  }

  static func settingsFindings(in files: [SourceFile]) -> [String] {
    let window = files.first { $0.name == settingsFile }
    return settingsTileFindings(in: files) + (window.map { nativeSelectionFindings(in: $0.text) } ?? [])
  }

  @Test func theSettingsSidebarAndHeadersDrawTheSharedTile() throws {
    let files = try Self.appSourceFiles()
    #expect(files.count > 40)
    #expect(Self.settingsTileFindings(in: files) == [])
  }

  @Test func theSettingsSidebarKeepsTheNativeSelection() throws {
    let window = try #require(try Self.appSourceFiles().first { $0.name == Self.settingsFile })
    #expect(Self.nativeSelectionFindings(in: window.text) == [])
  }

  static let plantedSidebarLabel = "Label { Text(pane.title) } icon: { SettingsTile(pane: pane, size: .sidebar) }"
  static let plantedSettingsWindow = [
    "List(selection: selection) {",
    "  ForEach(SettingsPane.allCases) { pane in",
    "    " + plantedSidebarLabel,
    "  }",
    "}",
    ".listStyle(.sidebar)",
    "VStack(spacing: 0) {",
    "  SettingsPaneHeader(pane: model.selectedPane)",
    "  paneContent",
    "}",
  ]
  static let plantedTileFill = "  .fill(Color(nsColor: pane.tileColor.nsColor))"
  static let plantedSettingsTile = [
    "RoundedRectangle(cornerRadius: CGFloat(size.cornerRadius), style: .continuous)",
    plantedTileFill,
    "  .overlay { LinearGradient(colors: [.white.opacity(PaneTile.highlightOpacity), .white.opacity(0)],",
    "    startPoint: .top, endPoint: .bottom) }",
    "  .accessibilityHidden(true)",
  ]
  static let plantedHeaderCard = "PrismCard(lit: true, cornerRadius: CGFloat(PrismLayout.headerCornerRadius)) {"
  static let plantedSettingsHeader = [
    plantedHeaderCard,
    "  HStack(spacing: 12) {",
    "    SettingsTile(pane: pane, size: .header)",
    "    Text(pane.title)",
    "  }",
    "}",
    ".accessibilityAddTraits(.isHeader)",
  ]

  static func plantedSettings() -> [SourceFile] {
    [
      planted(settingsFile, plantedSettingsWindow), planted(settingsTileFile, plantedSettingsTile),
      planted(settingsHeaderFile, plantedSettingsHeader),
    ]
  }

  enum SettingsTileDrift: CaseIterable, Sendable {
    case sidebarLabelReturnsToItsSystemImage
    case headerLosesItsCard
    case headerTileIsReadByVoiceOver
    case rowBackgroundTintsTheSelection

    var file: String {
      switch self {
      case .sidebarLabelReturnsToItsSystemImage, .rowBackgroundTintsTheSelection:
        AppViewSourceGuardTests.settingsFile
      case .headerLosesItsCard: AppViewSourceGuardTests.settingsHeaderFile
      case .headerTileIsReadByVoiceOver: AppViewSourceGuardTests.settingsTileFile
      }
    }

    var change: (old: String, new: String) {
      let label = AppViewSourceGuardTests.plantedSidebarLabel
      return switch self {
      case .sidebarLabelReturnsToItsSystemImage: (label, "Label(pane.title, systemImage: pane.symbol)")
      case .headerLosesItsCard: (AppViewSourceGuardTests.plantedHeaderCard, "VStack(alignment: .leading) {")
      case .headerTileIsReadByVoiceOver: (".accessibilityHidden(true)", ".accessibilityLabel(pane.title)")
      case .rowBackgroundTintsTheSelection: (label, label + "\n    .listRowBackground(Color.accentColor)")
      }
    }

    var phrase: String {
      switch self {
      case .sidebarLabelReturnsToItsSystemImage: "SettingsWindow.swift builds a sidebar label from a system image"
      case .headerLosesItsCard: "SettingsPaneHeader.swift holds the prism card 0 times, expected 1"
      case .headerTileIsReadByVoiceOver: "SettingsTile.swift does not hide the tile from VoiceOver"
      case .rowBackgroundTintsTheSelection: "SettingsWindow.swift sets a row background 1 times, expected 0"
      }
    }
  }

  @Test func theUndriftedPlantedSettingsTilesHaveNoFindings() {
    #expect(Self.settingsFindings(in: Self.plantedSettings()) == [])
    #expect(
      Self.settingsTileFindings(in: []) == [
        Self.missing(Self.settingsFile), Self.missing(Self.settingsTileFile), Self.missing(Self.settingsHeaderFile),
      ])
  }

  @Test(arguments: SettingsTileDrift.allCases)
  func aDriftedSettingsTileSourceIsReported(drift: SettingsTileDrift) throws {
    #expect(SettingsTileDrift.allCases.count == 4)
    let planted = Self.plantedSettings()
    let target = try #require(planted.first { $0.name == drift.file })
    let change = drift.change
    let range = try #require(target.text.range(of: change.old), "the planted source does not hold \(change.old)")
    let drifted = target.text.replacingCharacters(in: range, with: change.new)
    let changed = planted.map { file in
      file.name == drift.file ? SourceFile(name: file.name, path: file.path, text: drifted) : file
    }
    let findings = Self.settingsFindings(in: changed)
    #expect(findings.contains { $0.contains(drift.phrase) }, "\(findings)")
  }
}
