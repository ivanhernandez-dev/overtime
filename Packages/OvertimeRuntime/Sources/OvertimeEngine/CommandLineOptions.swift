import Foundation
import OvertimeCore
import OvertimeSystem

public enum CommandLineError: Error, Equatable {
  case usage(String)
}

public struct SettingsOverrides: Sendable, Equatable {
  public var transcriptRoots: [String]?
  public var ignoredEntrypoints: [String]?
  public var transcriptWindowSeconds: Double?
  public var releaseGraceSeconds: Double?
  public var stuckWindowSeconds: Double?
  public var batteryLowPercent: Int?
  public var batteryResumePercent: Int?
  public var keepDisplayOn: Bool?

  public init() {}

  public func applied(to settings: Settings) -> Settings {
    var result = settings
    if let transcriptRoots { result.transcriptRoots = transcriptRoots }
    if let ignoredEntrypoints { result.ignoredEntrypoints = ignoredEntrypoints }
    if let transcriptWindowSeconds { result.transcriptWindowSeconds = transcriptWindowSeconds }
    if let releaseGraceSeconds { result.releaseGraceSeconds = releaseGraceSeconds }
    if let stuckWindowSeconds { result.stuckWindowSeconds = stuckWindowSeconds }
    if let batteryLowPercent { result.batteryLowPercent = batteryLowPercent }
    if let batteryResumePercent { result.batteryResumePercent = batteryResumePercent }
    if let keepDisplayOn { result.keepDisplayOn = keepDisplayOn }
    return result
  }
}

public struct CtlOptions: Sendable, Equatable {
  public var mode: RunMode
  public var request: CtlRequest

  public init(mode: RunMode = .shadow, request: CtlRequest) {
    self.mode = mode
    self.request = request
  }

  public static func parse(_ arguments: [String]) throws -> CtlOptions {
    var modes: Set<RunMode> = []
    var words: [String] = []
    for argument in arguments {
      switch argument {
      case "--shadow": modes.insert(.shadow)
      case "--live": modes.insert(.live)
      default: words.append(argument)
      }
    }
    let mode = try CommandLineOptions.singleMode(modes)
    guard let command = words.first else { throw CommandLineOptions.usage("ctl needs a command") }
    var remaining = words.dropFirst()
    let request: CtlRequest
    switch command {
    case "pause":
      request = .pause(try pauseSpec(&remaining))
    case "force":
      request = .force(try forceSpec(&remaining))
    case "release-until-idle":
      request = .releaseUntilIdle
    case "resume":
      request = .resume
    case "status":
      request = .status
    default:
      throw CommandLineOptions.usage("unknown ctl command \(command)")
    }
    if let extra = remaining.first {
      throw CommandLineOptions.usage("unknown argument \(extra)")
    }
    return CtlOptions(mode: mode, request: request)
  }

  static func pauseSpec(_ remaining: inout ArraySlice<String>) throws -> PauseSpec {
    guard let flag = remaining.popFirst() else {
      throw CommandLineOptions.usage("pause needs --minutes <n>, --until <ISO 8601> or --indefinite")
    }
    switch flag {
    case "--minutes":
      return .forSeconds(try minutes(&remaining))
    case "--until":
      guard let text = remaining.popFirst(), let date = ControlProtocol.parseDate(text) else {
        throw CommandLineOptions.usage("--until needs an ISO 8601 date such as 2026-09-27T08:00:00Z")
      }
      return .until(date)
    case "--indefinite":
      return .indefinite
    default:
      throw CommandLineOptions.usage("unknown argument \(flag)")
    }
  }

  static func forceSpec(_ remaining: inout ArraySlice<String>) throws -> ForceSpec {
    guard let flag = remaining.popFirst() else {
      throw CommandLineOptions.usage("force needs --minutes <n> or --indefinite")
    }
    switch flag {
    case "--minutes":
      return .forSeconds(try minutes(&remaining))
    case "--indefinite":
      return .indefinite
    default:
      throw CommandLineOptions.usage("unknown argument \(flag)")
    }
  }

  static func minutes(_ remaining: inout ArraySlice<String>) throws -> Double {
    guard let text = remaining.popFirst(), let minutes = Double(text), minutes.isFinite, minutes > 0,
      minutes * 60 <= CtlRequest.maxSeconds
    else {
      throw CommandLineOptions.usage("--minutes needs a positive number of minutes (at most 366 days)")
    }
    return minutes * 60
  }
}

public enum Invocation: Sendable, Equatable {
  case engine(CommandLineOptions)
  case ctl(CtlOptions)
  case status(RunMode)
  case reset
}

public struct CommandLineOptions: Sendable, Equatable {
  public static let usageMessage = """
    usage: overtimed [--shadow|--live] [--once] [--transcript-root <path>]... [--ignore-entrypoint <glob>]...
                     [--transcript-window <s>] [--release-grace <s>] [--stuck-window <s>]
                     [--battery-low <pct>] [--battery-resume <pct>] [--keep-display-on] [--no-network]
           overtimed --status [--shadow|--live]
           overtimed --reset
           overtimed ctl [--shadow|--live] pause (--minutes <n> | --until <ISO 8601> | --indefinite)
           overtimed ctl [--shadow|--live] force (--minutes <n> | --indefinite)
           overtimed ctl [--shadow|--live] (release-until-idle | resume | status)
    """

  public var mode: RunMode
  public var once: Bool
  public var overrides: SettingsOverrides
  public var networkDisabled: Bool

  public init(
    mode: RunMode = .shadow, once: Bool = false, overrides: SettingsOverrides = SettingsOverrides(),
    networkDisabled: Bool = true
  ) {
    self.mode = mode
    self.once = once
    self.overrides = overrides
    self.networkDisabled = networkDisabled
  }

  public static func parse(_ arguments: [String]) throws -> CommandLineOptions {
    var options = CommandLineOptions()
    var modes: Set<RunMode> = []
    var remaining = arguments[...]
    while let argument = remaining.popFirst() {
      switch argument {
      case "--shadow":
        modes.insert(.shadow)
      case "--live":
        modes.insert(.live)
      case "--once":
        options.once = true
      case "--keep-display-on":
        options.overrides.keepDisplayOn = true
      case "--no-network":
        options.networkDisabled = true
      case "--transcript-root":
        let root = try value(for: argument, from: &remaining)
        guard root.hasPrefix("/") else { throw usage("\(argument) needs an absolute path") }
        options.overrides.transcriptRoots = (options.overrides.transcriptRoots ?? []) + [root]
      case "--ignore-entrypoint":
        let pattern = try value(for: argument, from: &remaining)
        options.overrides.ignoredEntrypoints = (options.overrides.ignoredEntrypoints ?? []) + [pattern]
      case "--transcript-window":
        options.overrides.transcriptWindowSeconds = try seconds(for: argument, from: &remaining)
      case "--release-grace":
        options.overrides.releaseGraceSeconds = try seconds(for: argument, from: &remaining)
      case "--stuck-window":
        options.overrides.stuckWindowSeconds = try seconds(for: argument, from: &remaining)
      case "--battery-low":
        options.overrides.batteryLowPercent = try percent(for: argument, from: &remaining)
      case "--battery-resume":
        options.overrides.batteryResumePercent = try percent(for: argument, from: &remaining)
      default:
        throw usage("unknown argument \(argument)")
      }
    }
    options.mode = try singleMode(modes)
    try validate(options.overrides)
    return options
  }

  static func singleMode(_ modes: Set<RunMode>) throws -> RunMode {
    guard modes.count <= 1 else { throw usage("--shadow and --live cannot be used together") }
    return modes.first ?? .shadow
  }

  public static func parseInvocation(_ arguments: [String]) throws -> Invocation {
    if arguments.contains("--reset") {
      guard arguments == ["--reset"] else { throw usage("--reset takes no other arguments") }
      return .reset
    }
    if arguments.contains("--status") {
      var modes: Set<RunMode> = []
      for argument in arguments {
        switch argument {
        case "--status": continue
        case "--shadow": modes.insert(.shadow)
        case "--live": modes.insert(.live)
        default: throw usage("--status takes only --shadow or --live, not \(argument)")
        }
      }
      return .status(try singleMode(modes))
    }
    if arguments.first == "ctl" {
      return .ctl(try CtlOptions.parse(Array(arguments.dropFirst())))
    }
    return .engine(try parse(arguments))
  }

  static func validate(_ overrides: SettingsOverrides) throws {
    if let low = overrides.batteryLowPercent, let resume = overrides.batteryResumePercent, low >= resume {
      throw usage("--battery-low must be below --battery-resume")
    }
    if let window = overrides.transcriptWindowSeconds, let stuck = overrides.stuckWindowSeconds, stuck < window {
      throw usage("--stuck-window must be at least --transcript-window")
    }
  }

  static func usage(_ message: String) -> CommandLineError {
    .usage("overtimed: \(message)\n\(usageMessage)")
  }

  private static func value(for flag: String, from remaining: inout ArraySlice<String>) throws -> String {
    guard let value = remaining.popFirst() else { throw usage("\(flag) needs a value") }
    return value
  }

  private static func seconds(for flag: String, from remaining: inout ArraySlice<String>) throws -> Double {
    let text = try value(for: flag, from: &remaining)
    guard let seconds = Double(text), seconds.isFinite, seconds > 0 else {
      throw usage("\(flag) needs a positive number of seconds")
    }
    return seconds
  }

  private static func percent(for flag: String, from remaining: inout ArraySlice<String>) throws -> Int {
    let text = try value(for: flag, from: &remaining)
    guard let percent = Int(text), (0...100).contains(percent) else {
      throw usage("\(flag) needs a percentage from 0 to 100")
    }
    return percent
  }
}
