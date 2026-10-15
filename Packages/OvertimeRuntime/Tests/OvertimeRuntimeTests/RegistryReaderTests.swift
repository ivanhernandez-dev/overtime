import Foundation
import OvertimeSystem
import Testing

struct RegistryReaderTests {
  static let onPhysicalMac: Bool = {
    var present: Int32 = 0
    var size = MemoryLayout<Int32>.size
    return sysctlbyname("kern.hv_vmm_present", &present, &size, nil, 0) != 0 || present == 0
  }()

  @Test(.enabled(if: onPhysicalMac, "a virtual Mac has no lid"))
  func lidStateIsReadableOnThisMac() {
    #expect(RegistryReader().lidClosed() != nil)
  }

  @Test func theExternalDisplayCountIsReadableOnThisMac() throws {
    let count = try #require(RegistryReader().externalDisplayCount())
    #expect(count >= 0)
  }

  @Test func theHIDIdleTimeIsReadableOnThisMac() throws {
    let seconds = try #require(RegistryReader().hidIdleSeconds())
    #expect(seconds >= 0)
  }

  @Test func theReaderNeverReadsTheClamshellCausesSleepKey() throws {
    let source = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Sources/OvertimeSystem/RegistryReader.swift")
    let text = try String(contentsOf: source, encoding: .utf8)
    #expect(text.contains("AppleClamshellState"))
    #expect(!text.contains("AppleClamshell" + "CausesSleep"))
  }
}
