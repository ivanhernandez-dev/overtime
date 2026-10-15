import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeSystem
import Testing

struct SettingsEditorTests {
  static func rejected(_ result: Result<Settings, SettingsValidationError>) -> String? {
    guard case .failure(let error) = result else { return nil }
    return error.message
  }

  static func accepted(_ result: Result<Settings, SettingsValidationError>) -> Settings? {
    guard case .success(let settings) = result else { return nil }
    return settings
  }

  static func flaggedByTheCore(_ settings: Settings) -> Bool {
    SettingsStore.validationProblem(settings) != nil || !settings.validated().adjustments.isEmpty
  }

  static func settings(low: Int = 10, resume: Int = 20) -> Settings {
    Settings(batteryLowPercent: low, batteryResumePercent: resume)
  }

  @Test(arguments: ["20", "  20 ", "\t7\n", "020"])
  func parseWholeNumberAcceptsTrimmedDigits(_ text: String) {
    #expect(SettingsEditor.parseWholeNumber(text) == Int(text.trimmingCharacters(in: .whitespacesAndNewlines)))
  }

  @Test(arguments: ["", "   ", "abc", "12.5", "-3", "1e3", "+4", "2 0", "٣", "99999999999999999999999"])
  func parseWholeNumberRejectsAnythingButDigits(_ text: String) {
    #expect(SettingsEditor.parseWholeNumber(text) == nil)
  }

  @Test(arguments: ["0", "51", "", "abc", "12.5"])
  func releaseAtOutsideOneToFiftyIsRejected(_ text: String) {
    let result = SettingsEditor.validate(.batteryLowPercent, text: text, in: Self.settings())
    #expect(Self.rejected(result) == "Enter a whole percentage from 1 to 50.")
  }

  @Test func releaseAtEqualToResumeAtIsRejected() {
    let result = SettingsEditor.validate(.batteryLowPercent, text: "20", in: Self.settings(resume: 20))
    #expect(Self.rejected(result) == "Must be lower than the resume level (20%).")
  }

  @Test func resumeAtEqualToReleaseAtIsRejected() {
    let result = SettingsEditor.validate(.batteryResumePercent, text: "10", in: Self.settings(low: 10, resume: 20))
    #expect(Self.rejected(result) == "Enter a whole percentage from 11 to 100.")
  }

  @Test func resumeAtAboveOneHundredIsRejected() {
    let result = SettingsEditor.validate(.batteryResumePercent, text: "101", in: Self.settings())
    #expect(Self.rejected(result) == "Enter a whole percentage from 11 to 100.")
  }

  @Test func resumeAtOneHundredIsAccepted() throws {
    let result = try #require(
      Self.accepted(SettingsEditor.validate(.batteryResumePercent, text: "100", in: Self.settings())))
    #expect(result.batteryResumePercent == 100)
  }

  @Test func aValidReleaseAtBuildsTheCandidate() throws {
    let base = Self.settings(low: 10, resume: 30)
    let result = try #require(Self.accepted(SettingsEditor.validate(.batteryLowPercent, text: " 20 ", in: base)))
    var expected = base
    expected.batteryLowPercent = 20
    #expect(result == expected)
  }

  @Test func theSaveFailureCopyMatchesTheUISpec() {
    #expect(
      SettingsEditor.saveFailedMessage
        == "Couldn't save your settings. The change wasn't applied. Try again, or export diagnostics if it keeps happening."
    )
  }

  static let batteryRows: [(SettingsField, String, Int, Int)] = [
    (.batteryLowPercent, "0", 10, 20),
    (.batteryLowPercent, "51", 10, 60),
    (.batteryLowPercent, "20", 10, 20),
    (.batteryLowPercent, "1", 10, 20),
    (.batteryLowPercent, "50", 10, 60),
    (.batteryLowPercent, "19", 10, 20),
    (.batteryResumePercent, "10", 10, 20),
    (.batteryResumePercent, "11", 10, 20),
    (.batteryResumePercent, "100", 10, 20),
    (.batteryResumePercent, "101", 10, 20),
    (.batteryResumePercent, "0", 10, 20),
  ]

  @Test func everyRejectedBatteryCandidateIsOneTheCoreFlagsAndEveryAcceptedOnePasses() {
    for (field, text, low, resume) in Self.batteryRows {
      let base = Self.settings(low: low, resume: resume)
      let value = SettingsEditor.parseWholeNumber(text) ?? -1
      var raw = base
      if field == .batteryLowPercent {
        raw.batteryLowPercent = value
      } else {
        raw.batteryResumePercent = value
      }
      switch SettingsEditor.validate(field, text: text, in: base) {
      case .success(let candidate):
        #expect(candidate == raw, "\(field) \(text)")
        #expect(!Self.flaggedByTheCore(candidate), "\(field) \(text)")
      case .failure:
        #expect(Self.flaggedByTheCore(raw), "\(field) \(text)")
      }
    }
  }

  static func timing(window: Double = 120, stuck: Double = 1800) -> Settings {
    Settings(transcriptWindowSeconds: window, stuckWindowSeconds: stuck)
  }

  static func validity(_ result: Result<Settings, SettingsValidationError>) -> Bool {
    guard let settings = accepted(result) else { return false }
    return SettingsEditor.isValid(settings)
  }

  @Test(arguments: ["10", "3600"])
  func transcriptWindowAtTheBoundsIsAccepted(_ text: String) throws {
    let result = SettingsEditor.validate(.transcriptWindowSeconds, text: text, in: Self.timing(stuck: 3600))
    let settings = try #require(Self.accepted(result))
    #expect(settings.transcriptWindowSeconds == Double(text))
    #expect(Self.validity(result))
  }

  @Test(arguments: ["9", "3601", "", "1.5"])
  func transcriptWindowOutsideTheRangeIsRejected(_ text: String) {
    let result = SettingsEditor.validate(.transcriptWindowSeconds, text: text, in: Self.timing(stuck: 14_400))
    #expect(Self.rejected(result) == "Enter a whole number of seconds from 10 to 3600.")
  }

  @Test func releaseGraceOfOneIsAcceptedAndZeroIsRejected() {
    #expect(Self.validity(SettingsEditor.validate(.releaseGraceSeconds, text: "1", in: Self.timing())))
    #expect(Self.validity(SettingsEditor.validate(.releaseGraceSeconds, text: "3600", in: Self.timing())))
    let zero = SettingsEditor.validate(.releaseGraceSeconds, text: "0", in: Self.timing())
    #expect(Self.rejected(zero) == "Enter a whole number of seconds from 1 to 3600.")
    let above = SettingsEditor.validate(.releaseGraceSeconds, text: "3601", in: Self.timing())
    #expect(Self.rejected(above) == "Enter a whole number of seconds from 1 to 3600.")
  }

  @Test func stuckLimitBoundsAreAcceptedWhenNotShorterThanTheWindow() throws {
    let one = SettingsEditor.validate(.stuckWindowMinutes, text: "1", in: Self.timing(window: 60))
    #expect(try #require(Self.accepted(one)).stuckWindowSeconds == 60)
    #expect(Self.validity(one))
    let most = SettingsEditor.validate(.stuckWindowMinutes, text: "240", in: Self.timing())
    #expect(try #require(Self.accepted(most)).stuckWindowSeconds == 14_400)
    #expect(Self.validity(most))
  }

  @Test(arguments: ["0", "241", "", "abc"])
  func stuckLimitOutsideTheRangeIsRejected(_ text: String) {
    let result = SettingsEditor.validate(.stuckWindowMinutes, text: text, in: Self.timing(window: 10))
    #expect(Self.rejected(result) == "Enter a whole number of minutes from 1 to 240.")
  }

  @Test func aStuckLimitEqualToTheTranscriptWindowIsAccepted() throws {
    let result = SettingsEditor.validate(.stuckWindowMinutes, text: "2", in: Self.timing(window: 120))
    #expect(try #require(Self.accepted(result)).stuckWindowSeconds == 120)
    #expect(Self.validity(result))
  }

  @Test func aStuckLimitShorterThanTheWindowNamesTheWindowInMinutesRoundedUp() {
    let result = SettingsEditor.validate(.stuckWindowMinutes, text: "2", in: Self.timing(window: 121))
    #expect(Self.rejected(result) == "Must be at least as long as the transcript window (3 minutes).")
    let twoMinutes = SettingsEditor.validate(.stuckWindowMinutes, text: "1", in: Self.timing(window: 120))
    #expect(Self.rejected(twoMinutes) == "Must be at least as long as the transcript window (2 minutes).")
  }

  @Test func aWindowLongerThanTheStuckLimitNamesTheLimit() {
    let result = SettingsEditor.validate(.transcriptWindowSeconds, text: "1801", in: Self.timing(stuck: 1800))
    #expect(Self.rejected(result) == "Must not be longer than the stuck-session limit (30 minutes).")
  }

  @Test func oneMinuteIsSingular() {
    let result = SettingsEditor.validate(.transcriptWindowSeconds, text: "61", in: Self.timing(window: 30, stuck: 60))
    #expect(Self.rejected(result) == "Must not be longer than the stuck-session limit (1 minute).")
  }

  static let timingRows: [(SettingsField, String, Double, Double)] = [
    (.transcriptWindowSeconds, "9", 120, 1800),
    (.transcriptWindowSeconds, "10", 120, 1800),
    (.transcriptWindowSeconds, "3600", 120, 3600),
    (.transcriptWindowSeconds, "3601", 120, 14_400),
    (.transcriptWindowSeconds, "1801", 120, 1800),
    (.releaseGraceSeconds, "0", 120, 1800),
    (.releaseGraceSeconds, "1", 120, 1800),
    (.releaseGraceSeconds, "3601", 120, 1800),
    (.stuckWindowMinutes, "0", 10, 1800),
    (.stuckWindowMinutes, "1", 60, 1800),
    (.stuckWindowMinutes, "2", 121, 1800),
    (.stuckWindowMinutes, "2", 120, 1800),
    (.stuckWindowMinutes, "240", 120, 1800),
    (.stuckWindowMinutes, "241", 120, 1800),
  ]

  @Test func everyRejectedTimingCandidateIsOneTheCoreFlagsAndEveryAcceptedOnePasses() {
    for (field, text, window, stuck) in Self.timingRows {
      let base = Self.timing(window: window, stuck: stuck)
      let value = Double(SettingsEditor.parseWholeNumber(text) ?? -1)
      var raw = base
      switch field {
      case .transcriptWindowSeconds: raw.transcriptWindowSeconds = value
      case .releaseGraceSeconds: raw.releaseGraceSeconds = value
      case .stuckWindowMinutes: raw.stuckWindowSeconds = value * 60
      case .batteryLowPercent, .batteryResumePercent: Issue.record("not a timing field")
      }
      switch SettingsEditor.validate(field, text: text, in: base) {
      case .success(let candidate):
        #expect(candidate == raw, "\(field) \(text)")
        #expect(!Self.flaggedByTheCore(candidate), "\(field) \(text)")
      case .failure:
        #expect(Self.flaggedByTheCore(raw), "\(field) \(text)")
      }
    }
  }

  @Test(arguments: ["", "   "])
  func anEmptyEntrypointIsRejected(_ pattern: String) {
    let result = SettingsEditor.addEntrypoint(pattern, to: Settings(ignoredEntrypoints: []))
    #expect(Self.rejected(result) == "Enter a pattern, such as sdk-*.")
  }

  @Test(arguments: ["sdk ts", String(repeating: "a", count: 65), "sdk/ts", "sdk-é", "a?b", "[sdk]"])
  func anEntrypointOutsideTheCharsetOrTooLongIsRejected(_ pattern: String) {
    let result = SettingsEditor.addEntrypoint(pattern, to: Settings(ignoredEntrypoints: []))
    #expect(Self.rejected(result) == "Use only letters, digits, and - _ . * (up to 64 characters).")
  }

  @Test func anEntrypointOfSixtyFourAllowedCharactersIsAccepted() throws {
    let pattern = String(repeating: "a", count: 60) + "-_.*"
    let result = SettingsEditor.addEntrypoint(pattern, to: Settings(ignoredEntrypoints: []))
    #expect(try #require(Self.accepted(result)).ignoredEntrypoints == [pattern])
  }

  @Test func aDuplicateEntrypointIsRejectedByName() {
    let result = SettingsEditor.addEntrypoint("sdk-*", to: Settings())
    #expect(Self.rejected(result) == "sdk-* is already in the list.")
    let other = SettingsEditor.addEntrypoint("cli-*", to: Settings(ignoredEntrypoints: ["sdk-*", "cli-*"]))
    #expect(Self.rejected(other) == "cli-* is already in the list.")
  }

  @Test func entrypointsKeepTheOrderTheUserAddedThem() throws {
    let first = try #require(Self.accepted(SettingsEditor.addEntrypoint("zeta-*", to: Settings())))
    let second = try #require(Self.accepted(SettingsEditor.addEntrypoint("alpha", to: first)))
    #expect(second.ignoredEntrypoints == ["sdk-*", "zeta-*", "alpha"])
    #expect(SettingsEditor.isValid(second))
  }

  @Test func removingEveryEntrypointLeavesAValidEmptyList() {
    let removed = SettingsEditor.removeEntrypoint("sdk-*", from: Settings())
    #expect(removed.ignoredEntrypoints.isEmpty)
    #expect(SettingsEditor.isValid(removed))
    #expect(SettingsEditor.problem(in: removed) == nil)
  }

  @Test func removingAnEntrypointKeepsTheOthersInOrder() {
    let removed = SettingsEditor.removeEntrypoint("b", from: Settings(ignoredEntrypoints: ["a", "b", "c"]))
    #expect(removed.ignoredEntrypoints == ["a", "c"])
  }

  @Test func restoreDefaultEntrypointsYieldsSdkStar() {
    let restored = SettingsEditor.restoreDefaultEntrypoints(Settings(ignoredEntrypoints: ["a", "b"]))
    #expect(restored.ignoredEntrypoints == ["sdk-*"])
    #expect(SettingsEditor.isValid(restored))
  }

  @Test(arguments: ["relative/path", "", "~/projects"])
  func aFolderThatIsNotAFullPathIsRejected(_ path: String) {
    let result = SettingsEditor.addFolder(path, to: Settings())
    #expect(Self.rejected(result) == "Transcript folders must be full paths.")
  }

  @Test func foldersKeepTheOrderTheUserAddedThem() throws {
    let temp = try TempDirectory()
    let a = temp.path + "/a"
    let b = temp.path + "/b"
    let first = try #require(Self.accepted(SettingsEditor.addFolder(a, to: Settings())))
    #expect(first.transcriptRoots == [a])
    let second = try #require(Self.accepted(SettingsEditor.addFolder(b, to: first)))
    #expect(second.transcriptRoots == [a, b])
    #expect(SettingsEditor.isValid(second))
  }

  @Test func aDuplicateFolderIsRejectedAfterCanonicalization() throws {
    let temp = try TempDirectory()
    let real = temp.url.appendingPathComponent("real", isDirectory: true)
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    let link = temp.url.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    let settings = Settings(transcriptRoots: [real.path(percentEncoded: false)])
    let viaLink = SettingsEditor.addFolder(link.path(percentEncoded: false), to: settings)
    #expect(Self.rejected(viaLink) == "That folder is already in the list.")
    let same = SettingsEditor.addFolder(real.path(percentEncoded: false), to: settings)
    #expect(Self.rejected(same) == "That folder is already in the list.")
  }

  @Test func removingTheOnlyCustomFolderReturnsToTheDefault() {
    let removed = SettingsEditor.removeFolder("/tmp/only", from: Settings(transcriptRoots: ["/tmp/only"]))
    #expect(removed.transcriptRoots == nil)
    #expect(SettingsEditor.isValid(removed))
  }

  @Test func removingOneOfSeveralFoldersKeepsTheRestInOrder() {
    let removed = SettingsEditor.removeFolder("/b", from: Settings(transcriptRoots: ["/a", "/b", "/c"]))
    #expect(removed.transcriptRoots == ["/a", "/c"])
  }

  @Test func useDefaultFolderClearsTheCustomFolders() {
    let reset = SettingsEditor.useDefaultFolder(Settings(transcriptRoots: ["/a", "/b"]))
    #expect(reset.transcriptRoots == nil)
    #expect(SettingsEditor.isValid(reset))
  }

  @Test func aHandEditedRelativeFolderIsReportedAsNotAFullPath() {
    let settings = Settings(transcriptRoots: ["relative"])
    #expect(
      SettingsEditor.problem(in: settings) == SettingsValidationError(message: "Transcript folders must be full paths.")
    )
  }
}
