import Foundation
import OvertimeAppSupport
import OvertimeSystem
import Testing

struct AppPreferencesStoreTests {
  static let allCategories = [
    "keepAwakeFailed", "batteryFloor", "belowFloorAtStart", "lidClosedSummary", "forceReminder",
  ]

  static func file(_ temp: TempDirectory) -> URL {
    temp.url.appendingPathComponent("preferences.json")
  }

  static func plant(_ text: String, at url: URL) throws {
    try Data(text.utf8).write(to: url)
  }

  static func loaded(_ state: AppPreferencesRead) -> AppPreferences? {
    if case .loaded(let preferences) = state { return preferences }
    return nil
  }

  static let at = Date(timeIntervalSince1970: 1_800_000_000)

  @Test func aMissingFileReadsMissingAndDefaultsToEveryCategoryOnAndThreeHours() throws {
    let temp = try TempDirectory()
    let state = AppPreferencesStore.read(at: Self.file(temp))
    #expect(state == .missing)
    let preferences = state.preferences
    #expect(preferences == AppPreferences())
    #expect(AppPreferences.categoryKeys == Self.allCategories)
    for key in Self.allCategories {
      #expect(preferences.notifications[key] == true)
      #expect(preferences.isEnabled(key))
    }
    #expect(preferences.forceReminderHours == 3)
    #expect(preferences.onboarding == nil)
    #expect(preferences.selfTest == nil)
  }

  @Test func aWriteIsOwnerOnlyAndReadsBack() throws {
    let temp = try TempDirectory()
    let url = Self.file(temp)
    var preferences = AppPreferences()
    preferences.notifications["batteryFloor"] = false
    preferences.forceReminderHours = 7
    try AppPreferencesStore.write(preferences, to: url)
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect(AppPreferencesStore.read(at: url) == .loaded(preferences))
  }

  @Test func aWriteReplacesTheFileAtomicallyAndLeavesNoTemporaryFiles() throws {
    let temp = try TempDirectory()
    let url = Self.file(temp)
    try Self.plant("{\"forceReminderHours\": 5}", at: url)
    var preferences = AppPreferences()
    preferences.forceReminderHours = 9
    try AppPreferencesStore.write(preferences, to: url)
    #expect(Self.loaded(AppPreferencesStore.read(at: url))?.forceReminderHours == 9)
    let names = try FileManager.default.contentsOfDirectory(atPath: temp.path)
    #expect(names == ["preferences.json"])
  }

  @Test func aFileWithOnlyTheReminderHoursDecodesWithEverythingElseDefaulted() throws {
    let temp = try TempDirectory()
    let url = Self.file(temp)
    try Self.plant("{\"forceReminderHours\": 5}", at: url)
    var expected = AppPreferences()
    expected.forceReminderHours = 5
    #expect(AppPreferencesStore.read(at: url) == .loaded(expected))
  }

  @Test func aPartialNotificationMapKeepsTheOtherCategoriesOn() throws {
    let temp = try TempDirectory()
    let url = Self.file(temp)
    try Self.plant("{\"notifications\": {\"batteryFloor\": false}}", at: url)
    let preferences = try #require(Self.loaded(AppPreferencesStore.read(at: url)))
    #expect(!preferences.isEnabled("batteryFloor"))
    for key in Self.allCategories where key != "batteryFloor" {
      #expect(preferences.isEnabled(key))
    }
  }

  @Test func aWrongTypedFieldFallsBackToItsDefaultWithoutLosingTheOthers() throws {
    let temp = try TempDirectory()
    let url = Self.file(temp)
    try Self.plant(
      "{\"forceReminderHours\": \"x\", \"notifications\": {\"forceReminder\": false}, \"onboarding\": 4}", at: url)
    let preferences = try #require(Self.loaded(AppPreferencesStore.read(at: url)))
    #expect(preferences.forceReminderHours == 3)
    #expect(!preferences.isEnabled("forceReminder"))
    #expect(preferences.onboarding == nil)
  }

  @Test(arguments: [(0, 3), (-1, 3), (13, 3), (1000, 3), (1, 1), (12, 12), (6, 6)])
  func reminderHoursOutsideOneToTwelveDecodeAsThree(stored: Int, expected: Int) throws {
    let temp = try TempDirectory()
    let url = Self.file(temp)
    try Self.plant("{\"forceReminderHours\": \(stored)}", at: url)
    #expect(Self.loaded(AppPreferencesStore.read(at: url))?.forceReminderHours == expected)
  }

  @Test func aSymlinkIsUnreadableAndNotFollowed() throws {
    let temp = try TempDirectory()
    let target = temp.url.appendingPathComponent("elsewhere.json")
    try Self.plant("{\"forceReminderHours\": 5}", at: target)
    let url = Self.file(temp)
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
    #expect(AppPreferencesStore.read(at: url) == .unreadable)
    #expect(AppPreferencesStore.read(at: url).preferences == AppPreferences())
  }

  @Test func aFileOverFourKilobytesIsUnreadable() throws {
    let temp = try TempDirectory()
    let url = Self.file(temp)
    let padding = String(repeating: " ", count: AppPreferencesStore.maxFileBytes)
    try Self.plant("{\"forceReminderHours\": 5}" + padding, at: url)
    #expect(AppPreferencesStore.read(at: url) == .unreadable)
  }

  @Test func invalidJSONIsUnreadable() throws {
    let temp = try TempDirectory()
    let url = Self.file(temp)
    try Self.plant("{not json", at: url)
    #expect(AppPreferencesStore.read(at: url) == .unreadable)
  }

  @Test func aWriteLargerThanTheReadCapIsRefusedAndKeepsTheOldFile() throws {
    let temp = try TempDirectory()
    let url = Self.file(temp)
    try AppPreferencesStore.write(AppPreferences(), to: url)
    var preferences = AppPreferences()
    preferences.onboarding = OnboardingRecord(
      version: 1, outcome: .completed,
      steps: ["padding": String(repeating: "x", count: AppPreferencesStore.maxFileBytes)], at: Self.at)
    #expect(throws: (any Error).self) { try AppPreferencesStore.write(preferences, to: url) }
    #expect(AppPreferencesStore.read(at: url) == .loaded(AppPreferences()))
  }

  @Test func onboardingAndSelfTestRecordsRoundTripWithISO8601Dates() throws {
    let temp = try TempDirectory()
    let url = Self.file(temp)
    var preferences = AppPreferences()
    preferences.onboarding = OnboardingRecord(
      version: 2, outcome: .dismissed, steps: ["location": "skipped", "loginItem": "done"], at: Self.at)
    preferences.selfTest = SelfTestRecord(
      outcome: .failed, reason: "clamshellFailed", at: Self.at.addingTimeInterval(60), osBuild: "26A428",
      osVersion: "27.0")
    try AppPreferencesStore.write(preferences, to: url)
    #expect(AppPreferencesStore.read(at: url) == .loaded(preferences))
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("\"2027-01-15T08:00:00Z\""))
    #expect(text.contains("\"2027-01-15T08:01:00Z\""))
    #expect(text.contains("\"dismissed\""))
    #expect(text.contains("\"failed\""))
  }

  @Test func everyOutcomeRoundTrips() throws {
    let temp = try TempDirectory()
    let url = Self.file(temp)
    for outcome in [OnboardingOutcome.completed, .dismissed] {
      for result in [SelfTestOutcome.passed, .failed, .skipped] {
        var preferences = AppPreferences()
        preferences.onboarding = OnboardingRecord(version: 1, outcome: outcome, steps: [:], at: Self.at)
        preferences.selfTest = SelfTestRecord(
          outcome: result, reason: nil, at: Self.at, osBuild: "26A428", osVersion: "27.0")
        try AppPreferencesStore.write(preferences, to: url)
        #expect(AppPreferencesStore.read(at: url) == .loaded(preferences))
      }
    }
  }

  @Test func anUpdateChangesOnlyWhatItsClosureTouchesAndReturnsTheStoredValue() throws {
    let temp = try TempDirectory()
    let url = Self.file(temp)
    var existing = AppPreferences()
    existing.notifications["batteryFloor"] = false
    existing.forceReminderHours = 7
    existing.onboarding = OnboardingRecord(version: 2, outcome: .completed, steps: ["login": "done"], at: Self.at)
    try AppPreferencesStore.write(existing, to: url)
    let record = SelfTestRecord(outcome: .passed, reason: nil, at: Self.at, osBuild: "99Z999", osVersion: "99.9")
    let updated = try AppPreferencesStore.update(at: url) { $0.selfTest = record }
    var expected = existing
    expected.selfTest = record
    #expect(updated == expected)
    #expect(AppPreferencesStore.read(at: url) == .loaded(expected))
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  }

  @Test func anUpdateOfAMissingFileStartsFromTheDefaults() throws {
    let temp = try TempDirectory()
    let url = Self.file(temp)
    let updated = try AppPreferencesStore.update(at: url) { $0.forceReminderHours = 9 }
    var expected = AppPreferences()
    expected.forceReminderHours = 9
    #expect(updated == expected)
    #expect(AppPreferencesStore.read(at: url) == .loaded(expected))
  }

  @Test func anUpdateThatCannotBeWrittenThrowsAndKeepsTheOldFile() throws {
    let temp = try TempDirectory()
    let url = Self.file(temp)
    var existing = AppPreferences()
    existing.forceReminderHours = 5
    try AppPreferencesStore.write(existing, to: url)
    #expect(throws: (any Error).self) {
      try AppPreferencesStore.update(at: url) { preferences in
        preferences.notifications[String(repeating: "x", count: AppPreferencesStore.maxFileBytes)] = false
      }
    }
    #expect(AppPreferencesStore.read(at: url) == .loaded(existing))
  }

  static let damagedKept: Comment =
    "S-WR-01: an update never rebuilds a damaged preferences.json from the defaults in place; the damaged file is set aside as preferences.json.unreadable and onboarding stays closed"
  static let ioFailureRefused: Comment =
    "S-WR-01: a file that could not be read because of an I/O error is never replaced; the update throws"

  static func aside(_ temp: TempDirectory) -> URL {
    temp.url.appendingPathComponent("preferences.json.unreadable")
  }

  static let damagedFiles = [
    "{not json", "[1, 2]", "{\"onboarding\": 5", "{\"forceReminderHours\": 5}" + String(repeating: " ", count: 4_096),
  ]

  @Test(arguments: damagedFiles)
  func anUpdateOfADamagedFileSetsItAsideAndKeepsOnboardingClosed(_ text: String) throws {
    let temp = try TempDirectory()
    let url = Self.file(temp)
    try Self.plant(text, at: url)
    let before = try Data(contentsOf: url)
    #expect(OnboardingFlow.recordState(at: url) == .unreadable)
    let updated = try AppPreferencesStore.update(at: url) { $0.forceReminderHours = 9 }
    #expect(try Data(contentsOf: Self.aside(temp)) == before, Self.damagedKept)
    #expect(AppPreferencesStore.read(at: url) == .loaded(updated))
    #expect(updated.forceReminderHours == 9)
    #expect(updated.onboarding?.outcome == .dismissed, Self.damagedKept)
    #expect(updated.onboarding?.version == OnboardingFlow.version)
    #expect(!OnboardingFlow.shouldOpen(record: OnboardingFlow.recordState(at: url)), Self.damagedKept)
    _ = try AppPreferencesStore.update(at: url) { $0.forceReminderHours = 4 }
    #expect(try Data(contentsOf: Self.aside(temp)) == before)
    #expect(Self.loaded(AppPreferencesStore.read(at: url))?.onboarding == updated.onboarding)
  }

  @Test func anUpdateOfASymlinkSetsTheLinkAsideAndNeverWritesThroughIt() throws {
    let temp = try TempDirectory()
    let target = temp.url.appendingPathComponent("elsewhere.json")
    try Self.plant("{\"forceReminderHours\": 5}", at: target)
    let url = Self.file(temp)
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
    _ = try AppPreferencesStore.update(at: url) { $0.forceReminderHours = 9 }
    #expect(try String(contentsOf: target, encoding: .utf8) == "{\"forceReminderHours\": 5}")
    let link = try FileManager.default.destinationOfSymbolicLink(atPath: Self.aside(temp).path(percentEncoded: false))
    #expect(link == target.path(percentEncoded: false), Self.damagedKept)
    #expect(Self.loaded(AppPreferencesStore.read(at: url))?.forceReminderHours == 9)
    #expect(!OnboardingFlow.shouldOpen(record: OnboardingFlow.recordState(at: url)), Self.damagedKept)
  }

  @Test func aDamagedOnboardingRecordInAReadableFileKeepsTheOtherPreferencesAndOnboardingClosed() throws {
    let temp = try TempDirectory()
    let url = Self.file(temp)
    try Self.plant(
      "{\"forceReminderHours\": 7, \"notifications\": {\"batteryFloor\": false}, \"onboarding\": {\"version\": \"x\"}}",
      at: url)
    #expect(OnboardingFlow.recordState(at: url) == .unreadable)
    let updated = try AppPreferencesStore.update(at: url) { $0.notifications["forceReminder"] = false }
    #expect(updated.forceReminderHours == 7)
    #expect(updated.isEnabled("batteryFloor") == false)
    #expect(updated.isEnabled("forceReminder") == false)
    #expect(updated.onboarding?.outcome == .dismissed, Self.damagedKept)
    #expect(!OnboardingFlow.shouldOpen(record: OnboardingFlow.recordState(at: url)), Self.damagedKept)
  }

  @Test func anUpdateOfAFileThatCannotBeReadThrowsAndLeavesItAlone() throws {
    let temp = try TempDirectory()
    let url = Self.file(temp)
    var existing = AppPreferences()
    existing.forceReminderHours = 5
    try AppPreferencesStore.write(existing, to: url)
    let path = url.path(percentEncoded: false)
    #expect(chmod(path, 0o000) == 0)
    defer { _ = chmod(path, 0o600) }
    #expect(throws: (any Error).self, Self.ioFailureRefused) {
      try AppPreferencesStore.update(at: url) { $0.forceReminderHours = 9 }
    }
    #expect(chmod(path, 0o600) == 0)
    #expect(AppPreferencesStore.read(at: url) == .loaded(existing), Self.ioFailureRefused)
    #expect(!FileManager.default.fileExists(atPath: Self.aside(temp).path(percentEncoded: false)))
  }

  @Test func aValidFileIsNeverSetAside() throws {
    let temp = try TempDirectory()
    let url = Self.file(temp)
    _ = try AppPreferencesStore.update(at: url) { $0.forceReminderHours = 2 }
    _ = try AppPreferencesStore.update(at: url) { $0.forceReminderHours = 3 }
    #expect(!FileManager.default.fileExists(atPath: Self.aside(temp).path(percentEncoded: false)))
    #expect(Self.loaded(AppPreferencesStore.read(at: url))?.onboarding == nil)
  }

  @Test func updatesFromManyThreadsAtOnceLoseNothing() async throws {
    let temp = try TempDirectory()
    let url = Self.file(temp)
    let writers = 48
    await withTaskGroup(of: Void.self) { group in
      for index in 0..<writers {
        group.addTask {
          _ = try? AppPreferencesStore.update(at: url) { $0.notifications["writer\(index)"] = false }
        }
      }
    }
    let stored = try #require(Self.loaded(AppPreferencesStore.read(at: url)))
    let written = (0..<writers).filter { stored.notifications["writer\($0)"] == false }
    #expect(written.count == writers)
  }
}
