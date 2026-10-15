import Foundation
import Testing

@testable import OvertimeAppSupport

struct DiagnosticsRedactionTests {
  struct Case: Sendable, CustomTestStringConvertible {
    let input: String
    let output: String

    var testDescription: String {
      input
    }
  }

  static let u = "\\" + "u"
  static let home = "/Users/ivan"
  static let realHome = "/System/Volumes/Data/Users/ivan"
  static let networks = ["Ivan’s iPhone", "Ivan", "Office/5G"]
  static let redactor = DiagnosticsRedactor(homeDirectory: home, realHomeDirectory: realHome, networkNames: networks)

  static let homeCases = [
    Case(input: "/Users/ivan/.claude/projects", output: "~/.claude/projects"),
    Case(input: "cwd=/Users/ivan", output: "cwd=~"),
    Case(input: #""\/Users\/ivan\/.claude\/projects""#, output: #""~\/.claude\/projects""#),
    Case(input: "\(u)002fUsers\(u)002fivan\(u)002f.claude", output: "~\(u)002f.claude"),
    Case(input: "\(u)002FUsers\(u)002Fivan\(u)002F.claude", output: "~\(u)002F.claude"),
    Case(input: "/System/Volumes/Data/Users/ivan/.claude/projects", output: "~/.claude/projects"),
    Case(input: #"\/System\/Volumes\/Data\/Users\/ivan\/x"#, output: #"~\/x"#),
    Case(input: "/Users/ivan and /Users/ivan/Library", output: "~ and ~/Library"),
    Case(input: "/Users/ivanka/Documents", output: "~ka/Documents"),
  ]

  @Test(arguments: homeCases)
  func theHomePathBecomesATildeInItsPlainEscapedAndResolvedForms(_ item: Case) {
    #expect(Self.redactor.redact(item.input) == item.output)
  }

  static let networkCases = [
    Case(input: "joined Ivan’s iPhone", output: "joined <network>"),
    Case(input: #"{"hotspot":"Ivan"# + u + #"2019s iPhone"}"#, output: #"{"hotspot":"<network>"}"#),
    Case(input: "Office/5G", output: "<network>"),
    Case(input: #"Office\/5G"#, output: "<network>"),
    Case(input: "Office\(u)002f5G and Office\(u)002F5G", output: "<network> and <network>"),
    Case(input: "Ivan was here", output: "<network> was here"),
    Case(input: "Ivan’s iPhone and Ivan’s iPad", output: "<network> and <network>’s iPad"),
    Case(input: "Ivan’s iPhone 15", output: "<network> 15"),
  ]

  @Test(arguments: networkCases)
  func aNetworkNameBecomesThePlaceholderInItsPlainAndEscapedFormsAndTheLongerNameWins(_ item: Case) {
    #expect(Self.redactor.redact(item.input) == item.output)
  }

  static let unchanged = [
    "", "WANT on reason=busy", "/Users/someone/.claude/projects", "/Users/iva", "ivan’s iphone", "Office-5G",
    "~ and <network>",
  ]

  @Test(arguments: unchanged)
  func textWithoutAMatchIsUnchanged(_ text: String) {
    #expect(Self.redactor.redact(text) == text)
  }

  @Test func anEmptyNetworkListRedactsOnlyTheHomePath() {
    let redactor = DiagnosticsRedactor(homeDirectory: Self.home, networkNames: [])
    #expect(redactor.redact("joined Ivan’s iPhone at /Users/ivan/x") == "joined Ivan’s iPhone at ~/x")
    #expect(redactor.redact("/System/Volumes/Data/Users/ivan") == "/System/Volumes/Data~")
  }

  @Test func anEmptyNetworkNameAndAHomeOfOneCharacterReplaceNothing() {
    let redactor = DiagnosticsRedactor(homeDirectory: "/", realHomeDirectory: "", networkNames: ["", "Ivan"])
    #expect(redactor.redact("a/b c Ivan") == "a/b c <network>")
    #expect(DiagnosticsRedactor(homeDirectory: "", networkNames: [""]).patterns.isEmpty)
    #expect(DiagnosticsRedactor(homeDirectory: "", networkNames: [""]).redact("a/b") == "a/b")
  }

  @Test func aTrailingSlashOnTheHomeFolderIsIgnored() {
    let redactor = DiagnosticsRedactor(
      homeDirectory: "/Users/ivan/", realHomeDirectory: "/Volumes/Home//", networkNames: [])
    #expect(redactor.redact("/Users/ivan/x and /Users/ivan") == "~/x and ~")
    #expect(redactor.redact("/Volumes/Home/x") == "~/x")
    #expect(DiagnosticsRedactor.trimmedDirectory("/") == "/")
  }

  @Test func aNetworkNameWithAQuoteABackslashOrAnEmojiIsFoundInItsJSONForms() {
    let u = Self.u
    let quoted = #"Bob "the" \net"#
    let redactor = DiagnosticsRedactor(homeDirectory: Self.home, networkNames: [quoted, "🏠 Home", "Café"])
    #expect(redactor.redact(#"a Bob "the" \net b"#) == "a <network> b")
    #expect(redactor.redact(#"{"hotspot":"Bob \"the\" \\net"}"#) == #"{"hotspot":"<network>"}"#)
    #expect(redactor.redact("x 🏠 Home y") == "x <network> y")
    #expect(redactor.redact("x \(u)d83c\(u)dfe0 Home y") == "x <network> y")
    #expect(redactor.redact("x \(u)D83C\(u)DFE0 Home y") == "x <network> y")
    #expect(redactor.redact("Caf\(u)00e9 and Caf\(u)00E9 and Café") == "<network> and <network> and <network>")
    #expect(redactor.redact("Caf\(u)00e and Caf\(u)00E") == "Caf\(u)00e and Caf\(u)00E")
  }

  @Test func aControlCharacterInANameIsFoundInItsEscapedForms() {
    let u = Self.u
    let redactor = DiagnosticsRedactor(homeDirectory: "", networkNames: ["a\tb\u{01}c\nd\re\u{08}f\u{0C}g"])
    #expect(redactor.redact(#"<a\tb"# + u + #"0001c\nd\re\bf\fg>"#) == "<<network>>")
    #expect(DiagnosticsRedactor.escaped("\u{1F}", slash: .plain, asciiOnly: false, upperHex: true) == u + "001F")
    #expect(DiagnosticsRedactor.escaped("\u{1F}", slash: .plain, asciiOnly: false, upperHex: false) == u + "001f")
    #expect(DiagnosticsRedactor.escaped("é~\u{7F}", slash: .plain, asciiOnly: false, upperHex: false) == "é~\u{7F}")
    #expect(
      DiagnosticsRedactor.escaped("é~\u{7F}", slash: .plain, asciiOnly: true, upperHex: false)
        == u + "00e9~" + "\u{7F}")
  }

  @Test func theFormsOfASecretAreItsPlainTextAndEveryJSONEscaping() {
    let u = Self.u
    let forms = DiagnosticsRedactor.forms(of: "a/é").map { String(decoding: $0, as: UTF8.self) }
    #expect(
      Set(forms) == [
        "a/é", #"a\/é"#, "a\(u)002fé", "a\(u)002Fé", "a/\(u)00e9", "a/\(u)00E9", #"a\/"# + "\(u)00e9",
        #"a\/"# + "\(u)00E9", "a\(u)002f\(u)00e9", "a\(u)002F\(u)00E9",
      ])
    #expect(forms.count == 10)
    #expect(forms.first == "a/é")
    #expect(DiagnosticsRedactor.forms(of: "Ivan").map { String(decoding: $0, as: UTF8.self) } == ["Ivan"])
  }

  @Test func replacedTextIsNeverScannedAgain() {
    let redactor = DiagnosticsRedactor(homeDirectory: Self.home, networkNames: ["net", "~", "Ivan"])
    #expect(redactor.redact("/Users/ivan joined Ivan") == "~ joined <network>")
    #expect(redactor.redact("net ~") == "<network> <network>")
  }

  @Test func aHotspotNamedLikeTheAccountDoesNotBreakTheHomePath() {
    let redactor = DiagnosticsRedactor(homeDirectory: "/Users/devonshire", networkNames: ["devon", "Users"])
    #expect(redactor.redact("/Users/devonshire/x and devon in Users") == "~/x and <network> in <network>")
    #expect(redactor.redact(#"\/Users\/devonshire\/x"#) == #"~\/x"#)
  }

  @Test func aNameThatIsAlsoTheHomePathCountsAsTheHomePath() {
    let redactor = DiagnosticsRedactor(homeDirectory: Self.home, networkNames: [Self.home])
    #expect(redactor.redact("/Users/ivan") == "~")
    #expect(redactor.patterns.filter { $0.bytes == Array(Self.home.utf8) }.count == 1)
    let twice = DiagnosticsRedactor(
      homeDirectory: Self.home, realHomeDirectory: Self.home, networkNames: ["Ivan", "Ivan"])
    #expect(twice.patterns.count == 5)
    #expect(Self.redactor.patterns.count == 15)
  }

  @Test func bytesThatAreNotTextPassThroughAroundAMatch() {
    let input =
      Data([0xFF, 0xFE]) + Data("/Users/ivan".utf8) + Data([0x00, 0xC3]) + Data("Ivan".utf8) + Data([0xE2, 0x80])
    let output =
      Data([0xFF, 0xFE]) + Data("~".utf8) + Data([0x00, 0xC3]) + Data("<network>".utf8) + Data([0xE2, 0x80])
    #expect(Self.redactor.redact(input) == output)
    #expect(Self.redactor.redact(Data()) == Data())
  }

  @Test func thePlaceholdersAreTheDocumentedOnes() {
    #expect(DiagnosticsRedactor.homePlaceholder == "~")
    #expect(DiagnosticsRedactor.networkPlaceholder == "<network>")
  }
}
