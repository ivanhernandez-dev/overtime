import Foundation
import OvertimeAppSupport
import OvertimeHelperCore
import ServiceManagement
import os

nonisolated struct SMAppServiceDaemon: HelperInstallerService {
  #if DEBUG
    static let identity = HelperIdentity.dev
  #else
    static let identity = HelperIdentity.release
  #endif

  let plistName: String

  init(identity: HelperIdentity = SMAppServiceDaemon.identity) {
    plistName = identity.plistName
  }

  private var daemon: SMAppService {
    SMAppService.daemon(plistName: plistName)
  }

  var status: HelperInstallerStatus {
    switch daemon.status {
    case .enabled: .enabled
    case .requiresApproval: .requiresApproval
    case .notRegistered: .notRegistered
    case .notFound: .notFound
    @unknown default: .notFound
    }
  }

  func register() throws {
    try daemon.register()
  }

  func unregister() throws {
    try daemon.unregister()
  }

  func unregisterAndWait(timeoutSeconds: Double) -> Bool {
    let reported = DispatchSemaphore(value: 0)
    let errorCode = OSAllocatedUnfairLock<Int?>(initialState: nil)
    daemon.unregister { error in
      errorCode.withLock { $0 = error.map { ($0 as NSError).code } }
      reported.signal()
    }
    guard reported.wait(timeout: .now() + max(0, timeoutSeconds)) == .success else { return false }
    return Self.unregisterSucceeded(errorCode: errorCode.withLock { $0 })
  }

  static func unregisterSucceeded(errorCode: Int?) -> Bool {
    guard let errorCode else { return true }
    return errorCode == kSMErrorJobNotFound
  }

  func openSystemSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }
}
