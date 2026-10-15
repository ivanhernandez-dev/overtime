import Foundation

public enum Event: Sendable, Equatable {
  case tick(TickFacts)
  case transcriptActivity(TranscriptActivity)
  case power(PowerReading)
  case transcriptRoots([RootHealth])
  case command(UserCommand)
  case launched(LaunchFacts)
  case effectResult(EffectID, EffectOutcome)
  case systemWillSleep
  case systemHasPoweredOn
  case lidChanged(closed: Bool, sleepBit: Bool?, externalDisplays: Int?)
  case sentinelLost
  case screenLock(ScreenLockStatus)
  case netProbeResult(online: Bool)
  case netCycleDone(NetCycleOutcome)
  case stop
  case selfTest(SelfTestFacts)
  case helperFacts(HelperFacts)
}

public struct HelperFacts: Sendable, Equatable {
  public var installed: Bool
  public var reachable: Bool
  public var current: Bool
  public var owns: Bool?
  public var sleepDisabled: Bool?

  public init(installed: Bool, reachable: Bool, current: Bool, owns: Bool? = nil, sleepDisabled: Bool? = nil) {
    self.installed = installed
    self.reachable = reachable
    self.current = current
    self.owns = owns
    self.sleepDisabled = sleepDisabled
  }

  public var ready: Bool {
    installed && reachable && current
  }
}

public struct SelfTestFacts: Sendable, Equatable {
  public var amphetamineRunning: Bool
  public var otherTool: String?
  public var sleepDisabled: Bool?
  public var osBuild: String?

  public init(
    amphetamineRunning: Bool = false, otherTool: String? = nil, sleepDisabled: Bool?, osBuild: String? = nil
  ) {
    self.amphetamineRunning = amphetamineRunning
    self.otherTool = otherTool
    self.sleepDisabled = sleepDisabled
    self.osBuild = osBuild
  }
}

public enum NetCycleOutcome: Sendable, Equatable {
  case succeeded
  case failed
  case refused
  case adminRequired
  case powerUnknown

  public var ran: Bool {
    self == .succeeded || self == .failed
  }
}

public enum EffectOutcome: Sendable, Equatable {
  case succeeded
  case failed(code: Int32)
  case timedOut
}

public enum RootStatus: String, Sendable, Equatable {
  case ok
  case missing
  case unreadable
}

public struct RootHealth: Sendable, Equatable {
  public var path: String
  public var status: RootStatus
  public var origin: RootOrigin

  public init(path: String, status: RootStatus, origin: RootOrigin = .configured) {
    self.path = path
    self.status = status
    self.origin = origin
  }
}

public enum PowerReading: Sendable, Equatable {
  case ac(percent: Int?)
  case battery(percent: Int?)
  case noBattery
}

public struct TickFacts: Sendable, Equatable {
  public var agents: AgentSignals
  public var lidClosed: Bool?
  public var externalDisplays: Int?
  public var fullWake: Bool?
  public var hidIdleSeconds: Double?
  public var coexistence: CoexistenceFacts?
  public var network: NetworkFacts?

  public init(
    agents: AgentSignals = .none, lidClosed: Bool? = nil, externalDisplays: Int? = nil, fullWake: Bool? = nil,
    hidIdleSeconds: Double? = nil, coexistence: CoexistenceFacts? = nil, network: NetworkFacts? = nil
  ) {
    self.network = network
    self.agents = agents
    self.lidClosed = lidClosed
    self.externalDisplays = externalDisplays
    self.fullWake = fullWake
    self.hidIdleSeconds = hidIdleSeconds
    self.coexistence = coexistence
  }
}

public struct ForeignAssertion: Sendable, Hashable {
  public var pid: Int32
  public var type: String
  public var processName: String?
  public var parentName: String?

  public init(pid: Int32, type: String, processName: String? = nil, parentName: String? = nil) {
    self.pid = pid
    self.type = type
    self.processName = processName
    self.parentName = parentName
  }
}

public struct CoexistenceFacts: Sendable, Equatable {
  public var amphetamineRunning: Bool
  public var sleepDisabled: Bool?
  public var foreignAssertions: [ForeignAssertion]

  public init(amphetamineRunning: Bool = false, sleepDisabled: Bool? = nil, foreignAssertions: [ForeignAssertion] = [])
  {
    self.amphetamineRunning = amphetamineRunning
    self.sleepDisabled = sleepDisabled
    self.foreignAssertions = foreignAssertions
  }
}

public struct TranscriptActivity: Sendable, Equatable {
  public var at: Instant
  public var entrypoint: String?

  public init(at: Instant, entrypoint: String? = nil) {
    self.at = at
    self.entrypoint = entrypoint
  }
}
