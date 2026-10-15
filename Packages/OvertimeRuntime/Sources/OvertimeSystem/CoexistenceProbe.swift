import Foundation
import IOKit.pwr_mgt
import OvertimeCore

public struct CoexistenceProbe: Sendable {
  public typealias AssertionTable = [Int32: [[String: Any]]]

  public static let amphetamineExecutableMarker = "/Amphetamine.app/Contents/MacOS/"
  public static let amphetamineProcessName = "Amphetamine"
  public static let knownToolProcessNames: [String] = [
    "Caffeine", "KeepingYouAwake", "Lungo", "Theine", "Coca", "Owly", "Jolt of Caffeine", "InsomniaX", "NoSleep",
    "Sleep Control Center", "Lidless",
  ]
  public static let caffeinateProcessName = "caffeinate"
  public static let idleOnlyToolProcessNames: [String] = [
    caffeinateProcessName, "Caffeine", "KeepingYouAwake", "Lungo", "Theine",
  ]
  static let idleOnlyProcessNames = Set(idleOnlyToolProcessNames.map { $0.lowercased() })
  static let countedProcessNames = Set(
    ([amphetamineProcessName, caffeinateProcessName] + knownToolProcessNames).map { $0.lowercased() })
  public static let watchedTypes: Set<String> = ["PreventUserIdleSystemSleep", "PreventSystemSleep"]
  static let levelKey = "AssertLevel"
  static let typeKey = "AssertType"
  static let processNameKey = "Process Name"

  private let registry: RegistryReader

  public init() {
    registry = RegistryReader()
  }

  public func read(processes: [ProcessRecord], excludingPIDs: Set<Int32>) -> CoexistenceFacts {
    CoexistenceFacts(
      amphetamineRunning: Self.amphetamineRunning(in: processes),
      sleepDisabled: registry.sleepDisabled(),
      foreignAssertions: Self.namingParents(
        Self.foreignAssertions(in: Self.assertionTable(), excluding: excludingPIDs), from: processes)
    )
  }

  public static func amphetamineRunning(in processes: [ProcessRecord]) -> Bool {
    processes.contains { $0.pidPath?.contains(amphetamineExecutableMarker) == true }
  }

  public static func claudeCaffeinatePIDs(in processes: [ProcessRecord]) -> Set<Int32> {
    var byPID: [Int32: ProcessRecord] = [:]
    for record in processes {
      byPID[record.pid] = record
    }
    return Set(
      processes.compactMap { record in
        guard record.comm == "caffeinate", let parent = byPID[record.ppid], ClaudeCodeDetector.isClaude(parent) else {
          return nil
        }
        return record.pid
      })
  }

  public static func isIdleOnly(_ assertion: ForeignAssertion) -> Bool {
    guard let name = assertion.processName else { return false }
    return idleOnlyProcessNames.contains(name.lowercased())
  }

  public static func namingParents(_ assertions: [ForeignAssertion], from processes: [ProcessRecord])
    -> [ForeignAssertion]
  {
    func isCaffeinate(_ assertion: ForeignAssertion) -> Bool {
      assertion.processName?.lowercased() == caffeinateProcessName
    }
    guard assertions.contains(where: isCaffeinate) else { return assertions }
    var byPID: [Int32: ProcessRecord] = [:]
    for record in processes {
      byPID[record.pid] = record
    }
    return assertions.map { assertion in
      guard isCaffeinate(assertion), let own = byPID[assertion.pid], let parent = byPID[own.ppid],
        !parent.comm.trimmingCharacters(in: .whitespaces).isEmpty
      else { return assertion }
      var named = assertion
      named.parentName = parent.comm
      return named
    }
  }

  public static func foreignAssertions(in table: AssertionTable, excluding: Set<Int32>) -> [ForeignAssertion] {
    var result: [ForeignAssertion] = []
    for (pid, assertions) in table where !excluding.contains(pid) {
      for assertion in assertions {
        guard (assertion[levelKey] as? NSNumber)?.intValue ?? 0 > 0,
          let type = assertion[typeKey] as? String, watchedTypes.contains(type),
          let name = assertion[processNameKey] as? String, countedProcessNames.contains(name.lowercased())
        else { continue }
        result.append(ForeignAssertion(pid: pid, type: type, processName: name))
      }
    }
    return result.sorted { ($0.pid, $0.type) < ($1.pid, $1.type) }
  }

  static func assertionTable() -> AssertionTable {
    var byProcess: Unmanaged<CFDictionary>?
    guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
      let table = byProcess?.takeRetainedValue() as NSDictionary?
    else { return [:] }
    var result: AssertionTable = [:]
    for (key, value) in table {
      guard let pid = (key as? NSNumber)?.int32Value, let list = value as? [[String: Any]] else { continue }
      result[pid] = list
    }
    return result
  }
}
