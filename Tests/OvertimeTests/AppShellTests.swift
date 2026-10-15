import AppKit
import Foundation
import Security
import Testing

@testable import Overtime

@MainActor
struct AppShellTests {
  @Test func theAppRunsAsAnInertTestHost() {
    #expect(AppMode.current == .testHost)
  }

  @Test func theDelegateComposedNoHost() throws {
    let delegate = try #require(AppDelegate.shared)
    #expect(!delegate.composedHost)
    #expect(!delegate.notificationsAttached)
    #expect(!delegate.selfTestRecorderAttached)
    #expect(!delegate.helperMonitorAttached)
    #expect(!delegate.networkPortAttached)
    #expect(delegate.helperPane == nil)
    #expect(delegate.model.host == nil)
    #expect(delegate.model.snapshot == nil)
    #expect(delegate.model.emergency == nil)
  }

  @Test func noStatusItemIsInserted() {
    let statusWindows = NSApp.windows.filter { String(describing: type(of: $0)).contains("StatusBar") }
    #expect(statusWindows.isEmpty)
  }

  @Test func theDebugBundleIdentifierIsTheDevVariant() {
    #expect(Bundle.main.bundleIdentifier == "io.github.ivanhernandez-dev.overtime.dev")
  }

  @Test func reopenInTheTestHostOpensNoWindow() throws {
    let delegate = try #require(AppDelegate.shared)
    let before = NSApp.windows.filter(\.isVisible).count
    #expect(!delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
    #expect(NSApp.windows.filter(\.isVisible).count == before)
  }

  @Test func terminateInTheTestHostIsImmediate() throws {
    let delegate = try #require(AppDelegate.shared)
    #expect(delegate.applicationShouldTerminate(NSApp) == .terminateNow)
  }

  @Test func auxiliaryWindowsCannotBeMinimized() {
    #expect(AuxiliaryWindowController.styleMask == [.titled, .closable])
    #expect(!AuxiliaryWindowController.styleMask.contains(.miniaturizable))
  }

  @Test func theSentinelIsEmbeddedAndExecutable() {
    let sentinel = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/overtime-sentinel")
    #expect(FileManager.default.isExecutableFile(atPath: sentinel.path(percentEncoded: false)))
  }

  static let hardenedRuntimeFlag: UInt32 = 0x10000
  static let libraryValidationKey = "com.apple.security.cs.disable-library-validation"

  static func signing(of url: URL) throws -> (entitlements: [String: Any], flags: UInt32) {
    var created: SecStaticCode?
    try #require(SecStaticCodeCreateWithPath(url as CFURL, [], &created) == errSecSuccess)
    let code = try #require(created)
    var copied: CFDictionary?
    try #require(
      SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &copied) == errSecSuccess)
    let information = try #require(copied as? [String: Any])
    let flags = try #require(information[kSecCodeInfoFlags as String] as? UInt32)
    return (information[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:], flags)
  }

  @Test func theEmbeddedHelperIsHardenedAndCarriesNoEntitlements() throws {
    let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/OvertimeHelper")
    #expect(FileManager.default.isExecutableFile(atPath: helper.path(percentEncoded: false)))
    let app = try Self.signing(of: Bundle.main.bundleURL)
    #expect(app.entitlements[Self.libraryValidationKey] as? Bool == true)
    let signed = try Self.signing(of: helper)
    #expect(signed.entitlements.keys.sorted() == [])
    #expect(signed.flags & Self.hardenedRuntimeFlag != 0)
  }
}
