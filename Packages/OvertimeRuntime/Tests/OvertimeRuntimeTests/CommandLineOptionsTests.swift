import Foundation
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing

struct CommandLineOptionsTests {
  func parse(_ arguments: [String]) throws -> CommandLineOptions {
    try CommandLineOptions.parse(arguments)
  }

  func isUsageError(_ arguments: [String]) -> Bool {
    do {
      _ = try parse(arguments)
      return false
    } catch CommandLineError.usage {
      return true
    } catch {
      return false
    }
  }

  @Test func noArgumentsGiveShadowWithoutOverrides() throws {
    let options = try parse([])
    #expect(options.mode == .shadow)
    #expect(options.once == false)
    #expect(options.overrides == SettingsOverrides())
    #expect(options.overrides.applied(to: Settings()) == Settings())
  }

  @Test func repeatedTranscriptRootsAccumulateInOrder() throws {
    let options = try parse(["--transcript-root", "/A", "--transcript-root", "/B"])
    #expect(options.overrides.transcriptRoots == ["/A", "/B"])
    #expect(options.overrides.applied(to: Settings(transcriptRoots: ["/file"])).transcriptRoots == ["/A", "/B"])
  }

  @Test func ignoreEntrypointReplacesTheList() throws {
    let options = try parse(["--ignore-entrypoint", "x"])
    #expect(options.overrides.applied(to: Settings()).ignoredEntrypoints == ["x"])
    let two = try parse(["--ignore-entrypoint", "x", "--ignore-entrypoint", "sdk-*"])
    #expect(two.overrides.applied(to: Settings()).ignoredEntrypoints == ["x", "sdk-*"])
  }

  @Test func numericAndBooleanFlagsApply() throws {
    let options = try parse([
      "--shadow", "--once",
      "--transcript-window", "90",
      "--release-grace", "30",
      "--stuck-window", "600",
      "--battery-low", "15",
      "--battery-resume", "25",
      "--keep-display-on",
    ])
    #expect(options.once)
    let settings = options.overrides.applied(to: Settings())
    #expect(settings.transcriptWindowSeconds == 90)
    #expect(settings.releaseGraceSeconds == 30)
    #expect(settings.stuckWindowSeconds == 600)
    #expect(settings.batteryLowPercent == 15)
    #expect(settings.batteryResumePercent == 25)
    #expect(settings.keepDisplayOn)
    #expect(settings.ignoredEntrypoints == ["sdk-*"])
  }

  @Test func networkIsDisabledByDefaultAndOnlyNoNetworkIsAccepted() throws {
    #expect(try parse([]).networkDisabled)
    #expect(try parse(["--no-network"]).networkDisabled)
    #expect(try parse(["--live", "--no-network", "--once"]).networkDisabled)
    #expect(isUsageError(["--network"]))
    #expect(isUsageError(["--hotspot", "Phone"]))
    #expect(CommandLineOptions.usageMessage.contains("[--no-network]"))
  }

  @Test func theUsageListsOnlyTheEngineStatusResetAndCtlForms() {
    let prefix = "usage: "
    let forms = CommandLineOptions.usageMessage.components(separatedBy: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .map { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : $0 }
      .filter { $0.hasPrefix("overtimed ") }
      .map { String($0.split(separator: " ").dropFirst().first ?? "") }
    let allowed = ["[--shadow|--live]", "--status", "--reset", "ctl"]
    #expect(forms.count == 6, "\(forms)")
    #expect(forms.allSatisfy { allowed.contains($0) }, "\(forms)")
    #expect(Set(forms) == Set(allowed), "\(forms)")
    #expect(forms.filter { $0 == "ctl" }.count == 3, "\(forms)")
  }

  @Test func invalidCombinationsAreUsageErrors() {
    #expect(isUsageError(["--battery-low", "30", "--battery-resume", "20"]))
    #expect(isUsageError(["--battery-low", "20", "--battery-resume", "20"]))
    #expect(isUsageError(["--transcript-window", "-5"]))
    #expect(isUsageError(["--release-grace", "0"]))
    #expect(isUsageError(["--stuck-window", "nan"]))
    #expect(isUsageError(["--stuck-window", "abc"]))
    #expect(isUsageError(["--battery-low", "101"]))
    #expect(isUsageError(["--battery-resume", "-1"]))
    #expect(isUsageError(["--transcript-window", "600", "--stuck-window", "300"]))
    #expect(isUsageError(["--transcript-root", "relative/path"]))
    #expect(isUsageError(["--release-grace"]))
    #expect(isUsageError(["--frobnicate"]))
    #expect(isUsageError(["--live", "--shadow"]))
    #expect(isUsageError(["--shadow", "--once", "--live"]))
  }

  @Test func liveSelectsLiveModeForTheRunCtlAndStatus() throws {
    #expect(try parse(["--live"]).mode == .live)
    #expect(try parse(["--live", "--once"]).mode == .live)
    #expect(try CommandLineOptions.parseInvocation(["--live", "--once"]) == .engine(parse(["--once", "--live"])))
    #expect(
      try CommandLineOptions.parseInvocation(["ctl", "--live", "status"])
        == .ctl(CtlOptions(mode: .live, request: .status)))
    #expect(try CommandLineOptions.parseInvocation(["--status", "--live"]) == .status(.live))
  }

  @Test func shadowAndLiveTogetherAreUsageErrorsEverywhere() {
    for arguments in [
      ["--shadow", "--live"], ["ctl", "--shadow", "--live", "status"], ["--status", "--live", "--shadow"],
    ] {
      #expect(throws: CommandLineError.self) { try CommandLineOptions.parseInvocation(arguments) }
    }
  }

  @Test func validationRejectsInconsistentMergedSettings() {
    #expect(SettingsStore.validationProblem(Settings()) == nil)
    #expect(SettingsStore.validationProblem(Settings(batteryLowPercent: 30, batteryResumePercent: 20)) != nil)
    #expect(SettingsStore.validationProblem(Settings(transcriptWindowSeconds: 900, stuckWindowSeconds: 600)) != nil)
    #expect(SettingsStore.validationProblem(Settings(transcriptRoots: ["rel"])) != nil)
    #expect(SettingsStore.validationProblem(Settings(releaseGraceSeconds: .infinity)) != nil)
  }

  struct SettingsFile {
    func load(_ contents: String?) throws -> SettingsLoadResult {
      let temp = try TempDirectory()
      let url = temp.url.appendingPathComponent("settings.json")
      if let contents {
        try Data(contents.utf8).write(to: url)
      }
      return SettingsStore.load(from: url)
    }

    func isInvalid(_ result: SettingsLoadResult) -> Bool {
      if case .invalid = result { return true }
      return false
    }

    @Test func missingFileIsReportedAsMissing() throws {
      #expect(try load(nil) == .missing)
    }

    @Test func validFileLoads() throws {
      #expect(
        try load(#"{"releaseGraceSeconds":30,"ignoredEntrypoints":[]}"#)
          == .loaded(Settings(releaseGraceSeconds: 30, ignoredEntrypoints: [])))
      #expect(try load("{}") == .loaded(Settings()))
    }

    @Test func malformedOrOutOfRangeFilesAreInvalid() throws {
      #expect(isInvalid(try load("not json")))
      #expect(isInvalid(try load(#"{"releaseGraceSeconds":"sixty"}"#)))
      #expect(isInvalid(try load(#"{"batteryLowPercent":30,"batteryResumePercent":20}"#)))
      #expect(isInvalid(try load(#"{"transcriptRoots":["relative"]}"#)))
      #expect(isInvalid(try load(#"{"releaseGraceSeconds":0}"#)))
      #expect(isInvalid(try load(#"{"stuckWindowSeconds":60}"#)))
      #expect(isInvalid(try load("[]")))
    }

    @Test func oversizedFileIsInvalid() throws {
      let padding = String(repeating: " ", count: SettingsStore.maxFileBytes + 1)
      #expect(isInvalid(try load("{}" + padding)))
    }
  }
}
