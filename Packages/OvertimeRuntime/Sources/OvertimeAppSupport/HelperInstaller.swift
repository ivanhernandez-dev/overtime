import Foundation

public enum HelperInstallerStatus: Sendable, Equatable {
  case enabled
  case requiresApproval
  case notRegistered
  case notFound

  public var isInstalled: Bool {
    self == .enabled || self == .requiresApproval
  }
}

public protocol HelperInstallerService: Sendable {
  var status: HelperInstallerStatus { get }
  func register() throws
  func unregister() throws
  func openSystemSettings()
}
