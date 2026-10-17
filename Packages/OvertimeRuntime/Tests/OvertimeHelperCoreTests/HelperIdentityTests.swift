import Foundation
import IOKit.pwr_mgt
import OvertimeHelperCore
import Testing

struct HelperIdentityTests {
  static let pinnedRoot = #" and certificate root = H"9c54a8e3e576cc8e7eb6d5a2dc63aa7607b821ce""#
  static let bundledProgram = "Contents/MacOS/OvertimeHelper"
  static let launchDaemons = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/LaunchDaemons", isDirectory: true)

  @Test func theReleaseIdentityMatchesADR0003() {
    let identity = HelperIdentity.release
    #expect(identity.label == "io.github.ivanhernandez-dev.overtime.helper")
    #expect(identity.machService == "io.github.ivanhernandez-dev.overtime.helper")
    #expect(identity.plistName == "io.github.ivanhernandez-dev.overtime.helper.plist")
    #expect(identity.appIdentifier == "io.github.ivanhernandez-dev.overtime")
    #expect(identity.helperIdentifier == "io.github.ivanhernandez-dev.overtime.helper")
    #expect(
      identity.appRequirement
        == #"identifier "io.github.ivanhernandez-dev.overtime""# + Self.pinnedRoot)
    #expect(
      identity.helperRequirement
        == #"identifier "io.github.ivanhernandez-dev.overtime.helper""# + Self.pinnedRoot)
    #expect(identity.supportDirectory == "/Library/Application Support/Overtime")
    #expect(identity.logDirectory == "/Library/Logs/Overtime")
  }

  @Test func theDevIdentityUsesItsOwnLabelsAndFoldersWithTheSameRoot() {
    let identity = HelperIdentity.dev
    #expect(identity.label == "io.github.ivanhernandez-dev.overtime.dev.helper")
    #expect(identity.machService == "io.github.ivanhernandez-dev.overtime.dev.helper")
    #expect(identity.plistName == "io.github.ivanhernandez-dev.overtime.dev.helper.plist")
    #expect(identity.appIdentifier == "io.github.ivanhernandez-dev.overtime.dev")
    #expect(identity.helperIdentifier == "io.github.ivanhernandez-dev.overtime.dev.helper")
    #expect(
      identity.appRequirement
        == #"identifier "io.github.ivanhernandez-dev.overtime.dev""# + Self.pinnedRoot)
    #expect(
      identity.helperRequirement
        == #"identifier "io.github.ivanhernandez-dev.overtime.dev.helper""# + Self.pinnedRoot)
    #expect(identity.supportDirectory == "/Library/Application Support/Overtime Dev")
    #expect(identity.logDirectory == "/Library/Logs/Overtime Dev")
  }

  @Test func theRequirementIsOneLineOfPlainASCIIWithNoStrayQuoting() {
    for identity in [HelperIdentity.release, HelperIdentity.dev] {
      for requirement in [identity.appRequirement, identity.helperRequirement] {
        #expect(requirement.allSatisfy { $0.isASCII && !$0.isNewline })
        #expect(requirement.filter { $0 == "\"" }.count == 4)
        #expect(requirement.hasSuffix(Self.pinnedRoot))
      }
    }
  }

  @Test func theTwoIdentitiesShareNoLabelServicePlistRequirementOrFolder() {
    let release = HelperIdentity.release
    let dev = HelperIdentity.dev
    #expect(release.label != dev.label)
    #expect(release.machService != dev.machService)
    #expect(release.plistName != dev.plistName)
    #expect(release.appRequirement != dev.appRequirement)
    #expect(release.helperRequirement != dev.helperRequirement)
    #expect(release.appRequirement != dev.helperRequirement)
    #expect(release.helperRequirement != dev.appRequirement)
    #expect(release.supportDirectory != dev.supportDirectory)
    #expect(release.logDirectory != dev.logDirectory)
  }

  @Test func theAppAndTheHelperRequirementsOfOneIdentityDiffer() {
    for identity in [HelperIdentity.release, HelperIdentity.dev] {
      #expect(identity.appRequirement != identity.helperRequirement)
    }
  }

  @Test func theHelperVersionAndTheCertificateRootArePinned() {
    #expect(HelperIdentity.version == 2)
    #expect(HelperIdentity.certificateRoot == "9c54a8e3e576cc8e7eb6d5a2dc63aa7607b821ce")
  }

  @Test func theOnlyCommandIsPmsetWithAFixedArgumentList() {
    #expect(HelperCommands.pmset == "/usr/bin/pmset")
    #expect(HelperCommands.arguments(disable: true) == ["-a", "disablesleep", "1"])
    #expect(HelperCommands.arguments(disable: false) == ["-a", "disablesleep", "0"])
  }

  @Test(arguments: [HelperIdentity.release, HelperIdentity.dev])
  func theBundledLaunchdPlistStartsTheHelperUnderTheIdentitysLabelAndService(_ identity: HelperIdentity) throws {
    let data = try Data(contentsOf: Self.launchDaemons.appendingPathComponent(identity.plistName))
    let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? NSDictionary
    let expected: NSDictionary = [
      "Label": identity.label,
      "BundleProgram": Self.bundledProgram,
      "MachServices": [identity.machService: true],
      "RunAtLoad": true,
      "KeepAlive": true,
      "AssociatedBundleIdentifiers": [identity.appIdentifier],
    ]
    #expect(plist == expected)
  }

  @Test func theRepositoryCarriesOneLaunchdPlistPerIdentityAndNoOther() throws {
    let names = try FileManager.default.contentsOfDirectory(atPath: Self.launchDaemons.path(percentEncoded: false))
    #expect(Set(names) == [HelperIdentity.release.plistName, HelperIdentity.dev.plistName])
  }

  @Test func theClamshellSelectorIsTheOneTheSDKNames() {
    #expect(HelperCommands.clamshellSleepSelector == 12)
    #expect(HelperCommands.clamshellSleepSelector == UInt32(kPMSetClamshellSleepState))
  }
}
