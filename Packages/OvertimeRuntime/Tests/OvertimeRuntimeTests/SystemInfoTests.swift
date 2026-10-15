import Foundation
import Testing

@testable import OvertimeSystem

struct SystemInfoTests {
  @Test func theOSBuildIsANonEmptyStringWithNoWhitespace() throws {
    let build = try #require(SystemInfo.osBuild())
    #expect(!build.isEmpty)
    #expect(build.unicodeScalars.allSatisfy { !CharacterSet.whitespacesAndNewlines.contains($0) })
    #expect(build.utf8.count <= 32)
  }

  @Test func theHardwareModelIsANonEmptyString() throws {
    let model = try #require(SystemInfo.hardwareModel())
    #expect(!model.isEmpty)
    #expect(!model.contains("\0"))
  }

  @Test func theOSVersionMatchesProcessInfo() {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    let expected =
      version.patchVersion == 0
      ? "\(version.majorVersion).\(version.minorVersion)"
      : "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    #expect(SystemInfo.osVersion() == expected)
  }

  @Test(arguments: [
    (OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0), "27.0"),
    (OperatingSystemVersion(majorVersion: 15, minorVersion: 7, patchVersion: 9), "15.7.9"),
    (OperatingSystemVersion(majorVersion: 14, minorVersion: 4, patchVersion: 0), "14.4"),
  ])
  func aZeroPatchVersionIsLeftOut(_ version: OperatingSystemVersion, _ expected: String) {
    #expect(SystemInfo.osVersion(version) == expected)
  }

  @Test func anUnknownKeyReadsAsNothing() {
    #expect(SystemInfo.string(forKey: "overtime.no.such.key") == nil)
  }
}
