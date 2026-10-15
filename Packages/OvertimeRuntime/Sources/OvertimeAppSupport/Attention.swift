import OvertimeEngine

public enum AttentionItem: Int, CaseIterable, Sendable, Hashable {
  case selfTestFailed = 1
  case detectionHealth
  case helperReapprove
  case helperStale
  case loginApproval
  case notificationsDenied
  case locationMissing
  case updateAvailable

  public var priority: Int {
    rawValue
  }

  public var shortText: String {
    switch self {
    case .selfTestFailed: "The keep-awake self-test failed."
    case .detectionHealth: "Overtime may be missing Claude activity."
    case .helperReapprove: "Unplug protection needs your approval again."
    case .helperStale: "Unplug protection is out of date."
    case .loginApproval: "Launch at login needs your approval."
    case .notificationsDenied: "Notifications are off for Overtime."
    case .locationMissing:
      "Location access is off. Failover still works, but with Location, Overtime can join the hotspot directly."
    case .updateAvailable: "An update to Overtime is available."
    }
  }

  public var pane: SettingsPane {
    switch self {
    case .selfTestFailed, .detectionHealth: .diagnostics
    case .helperReapprove, .helperStale: .unplugProtection
    case .loginApproval, .notificationsDenied: .general
    case .locationMissing: .network
    case .updateAvailable: .about
    }
  }
}

public struct AttentionInputs: Sendable, Equatable {
  public var selfTestFailed: Bool
  public var detectionWarnings: [DetectionWarning]
  public var helperReapprove: Bool
  public var helperStale: Bool
  public var loginItem: LoginItemStatus?
  public var notifications: NotificationAuthorization?
  public var location: LocationAuthorization?
  public var hotspotChoice: HotspotChoice
  public var panelInErrorState: Bool
  public var updateWaiting: Bool

  public init(
    selfTestFailed: Bool = false, detectionWarnings: [DetectionWarning] = [], helperReapprove: Bool = false,
    helperStale: Bool = false, loginItem: LoginItemStatus? = nil, notifications: NotificationAuthorization? = nil,
    location: LocationAuthorization? = nil, hotspotChoice: HotspotChoice = .none, panelInErrorState: Bool = false,
    updateWaiting: Bool = false
  ) {
    self.selfTestFailed = selfTestFailed
    self.detectionWarnings = detectionWarnings
    self.helperReapprove = helperReapprove
    self.helperStale = helperStale
    self.loginItem = loginItem
    self.notifications = notifications
    self.location = location
    self.hotspotChoice = hotspotChoice
    self.panelInErrorState = panelInErrorState
    self.updateWaiting = updateWaiting
  }
}

public enum Attention {
  public static func items(_ inputs: AttentionInputs, forPanel: Bool) -> [AttentionItem] {
    AttentionItem.allCases.filter { item in
      guard applies(item, to: inputs) else { return false }
      return !(forPanel && item == .selfTestFailed && inputs.panelInErrorState)
    }
  }

  static func applies(_ item: AttentionItem, to inputs: AttentionInputs) -> Bool {
    switch item {
    case .selfTestFailed:
      inputs.selfTestFailed
    case .detectionHealth:
      !inputs.detectionWarnings.isEmpty
    case .helperReapprove:
      inputs.helperReapprove
    case .helperStale:
      inputs.helperStale
    case .loginApproval:
      inputs.loginItem == .requiresApproval
    case .notificationsDenied:
      inputs.notifications == .denied
    case .locationMissing:
      !inputs.hotspotChoice.isNone && inputs.location != nil && inputs.location != .authorized
    case .updateAvailable:
      inputs.updateWaiting
    }
  }

  public static func helperItem(for shown: HelperUIState?) -> AttentionItem? {
    switch shown {
    case .needsApprovalAgain:
      .helperReapprove
    case .outOfDate:
      .helperStale
    case nil, .checking, .off, .installing, .waitingForApproval, .onStandingBy, .onHolding, .updating, .error,
      .removing:
      nil
    }
  }

  public static func panelText(_ items: [AttentionItem]) -> String? {
    switch items.count {
    case 0: nil
    case 1: items[0].shortText
    default: countText(items.count)
    }
  }

  public static func countText(_ count: Int) -> String {
    "\(count) things need your attention."
  }

  public static func badges(_ items: [AttentionItem]) -> [SettingsPane: [String]] {
    var result: [SettingsPane: [String]] = [:]
    for item in items.sorted(by: { $0.priority < $1.priority }) {
      result[item.pane, default: []].append(item.shortText)
    }
    return result
  }
}
