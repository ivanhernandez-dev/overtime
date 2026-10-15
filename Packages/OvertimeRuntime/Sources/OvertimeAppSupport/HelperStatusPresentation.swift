import Foundation
import OvertimeHelperCore

public enum HelperStatusTone: Sendable, Equatable {
  case secondary
  case success
  case warning
  case error
}

public enum HelperStatusIcon: Sendable, Equatable {
  case progress
  case symbol(String, HelperStatusTone)
}

public enum HelperStatusAction: Sendable, Equatable {
  public enum Style: Sendable, Equatable {
    case bordered
    case link
  }

  case install
  case openLoginItems
  case remove
  case reconnect

  public var label: String {
    switch self {
    case .install: "Install Unplug Protection…"
    case .openLoginItems: "Open Login Items"
    case .remove: "Remove Unplug Protection…"
    case .reconnect: "Reconnect Helper"
    }
  }

  public var style: Style {
    self == .openLoginItems ? .link : .bordered
  }

  public var isDestructive: Bool {
    self == .remove
  }
}

public enum HelperUIState: Sendable, Equatable, CaseIterable {
  case checking
  case off
  case installing
  case waitingForApproval
  case onStandingBy
  case onHolding
  case needsApprovalAgain
  case updating
  case outOfDate
  case error
  case removing

  public var icon: HelperStatusIcon {
    switch self {
    case .checking, .installing, .updating, .removing:
      .progress
    case .off:
      .symbol(HelperStatusPresentation.offSymbol, .secondary)
    case .waitingForApproval:
      .symbol(HelperStatusPresentation.waitingSymbol, .warning)
    case .onStandingBy, .onHolding:
      .symbol(HelperStatusPresentation.onSymbol, .success)
    case .needsApprovalAgain, .outOfDate:
      .symbol(HelperStatusPresentation.warningSymbol, .warning)
    case .error:
      .symbol(HelperStatusPresentation.warningSymbol, .error)
    }
  }

  public var title: String {
    switch self {
    case .checking: HelperStatusPresentation.checkingTitle
    case .off: HelperStatusPresentation.offTitle
    case .installing: HelperStatusPresentation.installingTitle
    case .waitingForApproval: HelperStatusPresentation.waitingTitle
    case .onStandingBy: HelperStatusPresentation.onTitle
    case .onHolding: HelperStatusPresentation.holdingTitle
    case .needsApprovalAgain: HelperStatusPresentation.reapproveTitle
    case .updating: HelperStatusPresentation.updatingTitle
    case .outOfDate: HelperStatusPresentation.outOfDateTitle
    case .error: HelperStatusPresentation.errorTitle
    case .removing: HelperStatusPresentation.removingTitle
    }
  }

  public var caption: String? {
    switch self {
    case .checking, .installing, .updating, .removing: nil
    case .off: HelperStatusPresentation.offCaption
    case .waitingForApproval: HelperStatusPresentation.waitingCaption
    case .onStandingBy: HelperStatusPresentation.onCaption
    case .onHolding: HelperStatusPresentation.holdingCaption
    case .needsApprovalAgain: HelperStatusPresentation.reapproveCaption
    case .outOfDate: HelperStatusPresentation.outOfDateCaption
    case .error: HelperStatusPresentation.errorCaption
    }
  }

  public var actions: [HelperStatusAction] {
    switch self {
    case .checking, .installing, .updating, .removing: []
    case .off: [.install]
    case .waitingForApproval, .needsApprovalAgain: [.openLoginItems, .remove]
    case .onStandingBy, .onHolding, .outOfDate: [.remove]
    case .error: [.reconnect, .remove]
    }
  }
}

public enum HelperStatusPresentation {
  public static let offSymbol = "shield"
  public static let waitingSymbol = "clock"
  public static let onSymbol = "checkmark.shield.fill"
  public static let warningSymbol = "exclamationmark.triangle.fill"

  public static let checkingTitle = "Checking unplug protection…"
  public static let offTitle = "Off"
  public static let offCaption = "With the lid closed, unplugging power or a display can still let the Mac sleep."
  public static let installingTitle = "Installing…"
  public static let waitingTitle = "Waiting for your approval"
  public static let waitingCaption =
    "Turn on Overtime under Allow in the Background in System Settings > General > Login Items & Extensions."
  public static let onTitle = "On"
  public static let onCaption = "It turns system sleep off only while Claude works with the lid closed."
  public static let holdingTitle = "On, holding now"
  public static let holdingCaption = "System sleep is off until the lid opens or Claude finishes."
  public static let reapproveTitle = "Needs your approval again"
  public static let reapproveCaption =
    "macOS stopped the helper, usually after an update. In System Settings > General > Login Items & Extensions, turn Overtime off and on again under Allow in the Background."
  public static let updatingTitle = "Updating the helper…"
  public static let outOfDateTitle = "Out of date"
  public static let outOfDateCaption =
    "The installed helper is older than this version of Overtime. Remove unplug protection, then install it again."
  public static let errorTitle = "Unplug protection isn't working"
  public static let errorCaption =
    "Overtime couldn't talk to the helper. Keep-awake still works without it. Try again, or remove and reinstall it."
  public static let removingTitle = "Removing…"

  public static let aboutNotes = [
    "Installing it needs one approval in System Settings. While you approve it, Overtime's login item may briefly show that it needs approval too.",
    "It runs as an administrator and does one thing: it turns system sleep off while Claude works with the lid closed, and back on afterwards.",
    "While it holds the Mac on battery, macOS can't put the Mac to sleep in an emergency. The helper lets go at 10% battery or if the Mac gets too hot.",
    "Turning it off in System Settings also quits Overtime. Open Overtime again afterwards.",
  ]

  public static let removeConfirmationTitle = "Remove unplug protection?"
  public static let removeConfirmationMessage =
    "With the lid closed, unplugging power or a display can let the Mac sleep again."
  public static let removeConfirmationConfirm = "Remove Unplug Protection"
  public static let removeConfirmationKeep = "Keep Unplug Protection"

  public static func derive(
    installer: HelperInstallerStatus?, reachability: HelperReachability, inFlight: HelperInFlight?, engaged: Bool,
    staleAttempts: Int, lastError: String?
  ) -> HelperUIState {
    switch inFlight {
    case .installing: return .installing
    case .removing: return .removing
    case nil: break
    }
    guard let installer else { return lastError == nil ? .checking : .error }
    guard lastError == nil else { return .error }
    switch installer {
    case .notRegistered, .notFound:
      return .off
    case .requiresApproval:
      return .waitingForApproval
    case .enabled:
      return enabled(reachability: reachability, engaged: engaged, staleAttempts: staleAttempts)
    }
  }

  public static func derive(_ state: HelperMonitorState, engaged: Bool) -> HelperUIState {
    derive(
      installer: state.installer, reachability: state.reachability, inFlight: state.inFlight, engaged: engaged,
      staleAttempts: state.staleAttempts, lastError: state.lastError)
  }

  public static func detail(status: HelperStatus?) -> String? {
    guard let status else { return nil }
    let version = "Helper version \(status.helperVersion)."
    guard let sleepDisabled = status.sleepDisabled else { return version }
    return version + " System sleep: " + (sleepDisabled ? "off." : "on.")
  }

  public static func detail(for state: HelperMonitorState) -> String? {
    guard state.installer == .enabled, state.reachability == .reachable else { return nil }
    return detail(status: state.status)
  }

  private static func enabled(reachability: HelperReachability, engaged: Bool, staleAttempts: Int) -> HelperUIState {
    switch reachability {
    case .unknown:
      return .checking
    case .unreachable:
      return .needsApprovalAgain
    case .reachable:
      if staleAttempts > 1 { return .outOfDate }
      if staleAttempts == 1 { return .updating }
      return engaged ? .onHolding : .onStandingBy
    }
  }
}
