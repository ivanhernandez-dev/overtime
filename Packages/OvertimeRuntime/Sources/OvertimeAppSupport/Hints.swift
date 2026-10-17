import Foundation
import OvertimeCore

public enum HelperHintState: Sendable, Equatable {
  case notInstalled
  case installedNotReady
  case ready

  public static func derive(_ shown: HelperUIState?) -> HelperHintState {
    switch shown {
    case nil, .off:
      .notInstalled
    case .onStandingBy, .onHolding:
      .ready
    case .checking, .installing, .waitingForApproval, .needsApprovalAgain, .updating, .outOfDate, .error, .removing:
      .installedNotReady
    }
  }
}

public struct HintInputs: Sendable, Equatable {
  public var sleepDisabledLeftover: Bool
  public var amphetamineRunning: Bool
  public var otherTools: [String]
  public var amphetamineInstalled: Bool
  public var keepAwakeWanted: Bool
  public var helper: HelperHintState
  public var helperOwnsSleepDisabled: Bool
  public var lidClosedKeepAwake: LidClosedKeepAwake
  public var lidClosedHoldAllowed: Bool

  public init(
    sleepDisabledLeftover: Bool = false, amphetamineRunning: Bool = false, otherTools: [String] = [],
    amphetamineInstalled: Bool = false, keepAwakeWanted: Bool = false, helper: HelperHintState = .notInstalled,
    helperOwnsSleepDisabled: Bool = false, lidClosedKeepAwake: LidClosedKeepAwake = .always,
    lidClosedHoldAllowed: Bool = true
  ) {
    self.sleepDisabledLeftover = sleepDisabledLeftover
    self.amphetamineRunning = amphetamineRunning
    self.otherTools = otherTools
    self.amphetamineInstalled = amphetamineInstalled
    self.keepAwakeWanted = keepAwakeWanted
    self.helper = helper
    self.helperOwnsSleepDisabled = helperOwnsSleepDisabled
    self.lidClosedKeepAwake = lidClosedKeepAwake
    self.lidClosedHoldAllowed = lidClosedHoldAllowed
  }
}

public enum HintTint: Sendable, Equatable {
  case warning
  case info
}

public enum HintAction: Sendable, Equatable {
  case copyCommand
  case setUpUnplugProtection
  case reviewUnplugProtection

  public var label: String {
    switch self {
    case .copyCommand: "Copy Command"
    case .setUpUnplugProtection: "Set Up Unplug Protection…"
    case .reviewUnplugProtection: "Review Unplug Protection…"
    }
  }
}

public struct Hint: Sendable, Equatable, Identifiable {
  public var priority: Int
  public var icon: String
  public var tint: HintTint
  public var text: String
  public var action: HintAction?

  public var id: Int { priority }

  public init(priority: Int, icon: String, tint: HintTint, text: String, action: HintAction? = nil) {
    self.priority = priority
    self.icon = icon
    self.tint = tint
    self.text = text
    self.action = action
  }
}

public enum Hints {
  public static let maxVisible = 3
  public static let sleepDisabledCommand = "sudo pmset -a disablesleep 0"
  public static let rootlessLimitation =
    "With the lid closed, unplugging power or a display can still let the Mac sleep."
  public static let unplugProtectionOn =
    "Unplug protection is on. Unplugging power or a display with the lid closed won't let the Mac sleep."
  public static let displayLimitation =
    "With the lid closed, connecting or disconnecting a display can still let the Mac sleep."
  public static let unplugProtectionOnForDisplays =
    "Unplug protection is on. Connecting or disconnecting a display with the lid closed won't let the Mac sleep."
  static let warningIcon = "exclamationmark.triangle.fill"
  static let infoIcon = "info.circle"
  static let protectedIcon = "checkmark.shield"

  public static func visible(_ inputs: HintInputs) -> [Hint] {
    var hints: [Hint] = []
    if inputs.sleepDisabledLeftover && !inputs.helperOwnsSleepDisabled {
      hints.append(
        Hint(
          priority: 1, icon: warningIcon, tint: .warning,
          text: "Sleep is turned off system-wide (SleepDisabled). The Mac can't sleep until you run: "
            + sleepDisabledCommand,
          action: .copyCommand))
    }
    if inputs.amphetamineRunning {
      hints.append(
        Hint(
          priority: 3, icon: warningIcon, tint: .warning,
          text: "Amphetamine is running. Quit it so the two apps don't fight over lid-close sleep."))
    } else if let tool = preferredTool(inputs.otherTools) {
      hints.append(
        Hint(
          priority: 3, icon: warningIcon, tint: .warning,
          text: "\(tool) is also managing sleep. Running both is unsupported."))
    }
    if inputs.amphetamineInstalled && !inputs.amphetamineRunning {
      hints.append(
        Hint(
          priority: 4, icon: infoIcon, tint: .info,
          text: "Amphetamine is installed. Keep it quit while Overtime runs."))
    }
    if inputs.keepAwakeWanted && inputs.lidClosedHoldAllowed {
      hints.append(unplugProtection(inputs.helper, displaysOnly: inputs.lidClosedKeepAwake == .onPowerAdapter))
    }
    return Array(hints.prefix(maxVisible))
  }

  static func preferredTool(_ tools: [String]) -> String? {
    let sorted = tools.sorted()
    guard let first = sorted.first else { return nil }
    return sorted.first { $0.hasPrefix(first + " (started by ") } ?? first
  }

  static func unplugProtection(_ helper: HelperHintState, displaysOnly: Bool = false) -> Hint {
    let limitation = displaysOnly ? displayLimitation : rootlessLimitation
    switch helper {
    case .notInstalled:
      return Hint(priority: 5, icon: infoIcon, tint: .info, text: limitation, action: .setUpUnplugProtection)
    case .installedNotReady:
      return Hint(priority: 5, icon: infoIcon, tint: .info, text: limitation, action: .reviewUnplugProtection)
    case .ready:
      return Hint(
        priority: 5, icon: protectedIcon, tint: .info,
        text: displaysOnly ? unplugProtectionOnForDisplays : unplugProtectionOn)
    }
  }

  public static func keepAwakeWanted(_ state: PanelState) -> Bool {
    switch state {
    case .holding, .lidClosedHolding, .grace, .override: true
    case .starting, .idle, .paused, .releasedUntilIdle, .batteryFloor, .uninstalling, .error: false
    }
  }
}
