import Foundation
import IOKit.pwr_mgt
import OvertimeCore
import OvertimeSystem
import Testing

struct AssertionBackendLiveTests {
  static func ownAssertionNames() -> [String] {
    var dictionary: Unmanaged<CFDictionary>?
    guard IOPMCopyAssertionsByProcess(&dictionary) == kIOReturnSuccess,
      let byProcess = dictionary?.takeRetainedValue() as NSDictionary?
    else { return [] }
    let entries = (byProcess[NSNumber(value: getpid())] as? [[String: Any]]) ?? []
    return entries.compactMap { $0[kIOPMAssertionNameKey] as? String }
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["OVERTIME_LIVE_IOKIT"] == "1"))
  func aRealTimedIdleAssertionIsCreatedFoundAndReleased() {
    let backend = IOPMAssertionBackend(syscalls: RealAssertionSyscalls())
    #expect(backend.acquireOrRenew(.preventUserIdleSystemSleep, timeoutSeconds: 10) == .succeeded)
    #expect(Self.ownAssertionNames().contains(IOPMAssertionBackend.assertionName))
    #expect(backend.release(.preventUserIdleSystemSleep) == .succeeded)
    #expect(!Self.ownAssertionNames().contains(IOPMAssertionBackend.assertionName))
  }
}
