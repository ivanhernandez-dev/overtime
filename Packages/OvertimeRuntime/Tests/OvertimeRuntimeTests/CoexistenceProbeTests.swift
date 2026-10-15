import Foundation
import OvertimeCore
import OvertimeSystem
import Testing

struct CoexistenceProbeTests {
  static let listedNames = [
    "Caffeine", "KeepingYouAwake", "Lungo", "Theine", "Coca", "Owly", "Jolt of Caffeine", "InsomniaX", "NoSleep",
    "Sleep Control Center", "Lidless",
  ]
  static let skippingNames = [
    "Amphetamine", "Coca", "Owly", "Jolt of Caffeine", "InsomniaX", "NoSleep", "Sleep Control Center", "Lidless",
  ]

  @Test func sleepDisabledIsReadableOnThisMac() {
    #expect(RegistryReader().sleepDisabled() != nil)
  }

  @Test func theTableFilterKeepsOnlyActiveWatchedTypesOfOtherProcesses() {
    let table: [Int32: [[String: Any]]] = [
      10: [
        ["AssertLevel": NSNumber(value: 255), "AssertType": "PreventUserIdleSystemSleep", "Process Name": "Lungo"],
        ["AssertLevel": NSNumber(value: 0), "AssertType": "PreventSystemSleep", "Process Name": "Lungo"],
        ["AssertLevel": NSNumber(value: 255), "AssertType": "PreventUserIdleDisplaySleep", "Process Name": "Lungo"],
      ],
      11: [["AssertLevel": NSNumber(value: 255), "AssertType": "PreventSystemSleep", "Process Name": "Theine"]],
      12: [
        ["AssertLevel": NSNumber(value: 255), "AssertType": "PreventUserIdleSystemSleep", "Process Name": "Caffeine"]
      ],
      13: [["AssertLevel": NSNumber(value: 255), "AssertType": "PreventSystemSleep"]],
      14: [
        ["AssertLevel": NSNumber(value: 255), "AssertType": "PreventUserIdleSystemSleep", "Process Name": "Keeper"]
      ],
    ]
    #expect(
      CoexistenceProbe.foreignAssertions(in: table, excluding: [12]) == [
        ForeignAssertion(pid: 10, type: "PreventUserIdleSystemSleep", processName: "Lungo"),
        ForeignAssertion(pid: 11, type: "PreventSystemSleep", processName: "Theine"),
      ])
  }

  @Test func onlyWholeListedNamesInAnyLetterCaseAreKept() {
    let listed = Self.listedNames
    let kept: [String?] =
      listed.map { $0 } + listed.map { $0.lowercased() } + listed.map { $0.uppercased() }
      + ["Amphetamine", "amphetamine"]
    let dropped: [String?] = [
      "Caffeine Helper", "Caffeinated", "Lungo2", " Lungo", "NoSleepCtl", "powerd", "Example Browser", "Keeper", "",
      nil,
    ]
    var table: [Int32: [[String: Any]]] = [:]
    for (offset, name) in (kept + dropped).enumerated() {
      var assertion: [String: Any] = [
        "AssertLevel": NSNumber(value: 255), "AssertType": "PreventUserIdleSystemSleep",
      ]
      if let name { assertion["Process Name"] = name }
      table[Int32(100 + offset)] = [assertion]
    }
    #expect(CoexistenceProbe.foreignAssertions(in: table, excluding: []).map(\.processName) == kept)
  }

  @Test func aCaffeinateIsKeptByItsWholeNameUnlessItsPIDIsExcluded() {
    let names: [(pid: Int32, name: String)] = [
      (200, "caffeinate"), (201, "Caffeinate"), (202, "CAFFEINATE"), (203, "caffeinate"), (204, "caffeinated"),
      (205, "caffeinate-helper"),
    ]
    var table: [Int32: [[String: Any]]] = [:]
    for entry in names {
      table[entry.pid] = [
        ["AssertLevel": NSNumber(value: 255), "AssertType": "PreventUserIdleSystemSleep", "Process Name": entry.name]
      ]
    }
    #expect(
      CoexistenceProbe.foreignAssertions(in: table, excluding: [203]) == [
        ForeignAssertion(pid: 200, type: "PreventUserIdleSystemSleep", processName: "caffeinate"),
        ForeignAssertion(pid: 201, type: "PreventUserIdleSystemSleep", processName: "Caffeinate"),
        ForeignAssertion(pid: 202, type: "PreventUserIdleSystemSleep", processName: "CAFFEINATE"),
      ])
  }

  @Test func theKnownToolListIsPinned() {
    #expect(CoexistenceProbe.knownToolProcessNames == Self.listedNames)
  }

  @Test func theIdleOnlyListIsPinnedAndNamesOnlyCountedTools() {
    let idleOnly = CoexistenceProbe.idleOnlyToolProcessNames
    #expect(idleOnly == ["caffeinate", "Caffeine", "KeepingYouAwake", "Lungo", "Theine"])
    let counted = Set((["Amphetamine", "caffeinate"] + CoexistenceProbe.knownToolProcessNames).map { $0.lowercased() })
    let idleOnlyLowered = Set(idleOnly.map { $0.lowercased() })
    let skippingLowered = Set(Self.skippingNames.map { $0.lowercased() })
    #expect(idleOnlyLowered.isSubset(of: counted))
    #expect(idleOnlyLowered.isDisjoint(with: skippingLowered))
    #expect(idleOnlyLowered.union(skippingLowered) == counted)
  }

  @Test func onlyIdleOnlyToolsInAnyLetterCaseAreIdleOnly() {
    let idleOnly = ["caffeinate", "Caffeine", "KeepingYouAwake", "Lungo", "Theine"]
    func cases(_ names: [String]) -> [String] {
      names + names.map { $0.lowercased() } + names.map { $0.uppercased() }
    }
    func assertion(_ name: String?) -> ForeignAssertion {
      ForeignAssertion(pid: 1, type: "PreventUserIdleSystemSleep", processName: name)
    }
    for name in cases(idleOnly) {
      #expect(CoexistenceProbe.isIdleOnly(assertion(name)), "\(name)")
    }
    let notIdleOnly: [String?] =
      cases(Self.skippingNames).map { $0 } + ["Keeper", "Caffeinated", "caffeinate-helper", " Lungo", "", nil]
    for name in notIdleOnly {
      #expect(!CoexistenceProbe.isIdleOnly(assertion(name)), "\(name ?? "nil")")
    }
  }

  @Test func amphetamineIsRecognizedByItsExecutablePath() {
    let running = ProcessRecord(
      pid: 20, ppid: 1, uid: 501, comm: "Amphetamine",
      pidPath: "/Applications/Amphetamine.app/Contents/MacOS/Amphetamine")
    let lookalike = ProcessRecord(pid: 21, ppid: 1, uid: 501, comm: "Amphetamine", pidPath: "/tmp/Amphetamine")
    #expect(CoexistenceProbe.amphetamineRunning(in: [running]))
    #expect(!CoexistenceProbe.amphetamineRunning(in: [lookalike]))
  }

  @Test func onlyCaffeinatesWhoseParentIsClaudeAreExcluded() {
    let claude = ProcessRecord(pid: 30, ppid: 1, uid: 501, comm: "claude", argv0: "claude")
    let shell = ProcessRecord(pid: 31, ppid: 1, uid: 501, comm: "zsh", argv0: "-zsh")
    let ours = ProcessRecord(pid: 32, ppid: 30, uid: 501, comm: "caffeinate")
    let theirs = ProcessRecord(pid: 33, ppid: 31, uid: 501, comm: "caffeinate")
    #expect(CoexistenceProbe.claudeCaffeinatePIDs(in: [claude, shell, ours, theirs]) == [32])
  }

  @Test func aForeignCaffeinateIsNamedWithTheProcessThatStartedIt() {
    let processes = [
      ProcessRecord(pid: 40, ppid: 1, uid: 501, comm: "python3"),
      ProcessRecord(pid: 41, ppid: 40, uid: 501, comm: "caffeinate"),
    ]
    let assertion = ForeignAssertion(pid: 41, type: "PreventUserIdleSystemSleep", processName: "caffeinate")
    #expect(
      CoexistenceProbe.namingParents([assertion], from: processes) == [
        ForeignAssertion(pid: 41, type: "PreventUserIdleSystemSleep", processName: "caffeinate", parentName: "python3")
      ])
  }

  @Test func onlyACaffeinateWhoseParentIsInTheListIsNamed() {
    let processes = [
      ProcessRecord(pid: 40, ppid: 1, uid: 501, comm: "python3"),
      ProcessRecord(pid: 42, ppid: 40, uid: 501, comm: "KeepingYouAwake"),
      ProcessRecord(pid: 43, ppid: 99, uid: 501, comm: "caffeinate"),
      ProcessRecord(pid: 45, ppid: 40, uid: 501, comm: "CAFFEINATE"),
      ProcessRecord(pid: 46, ppid: 47, uid: 501, comm: "caffeinate"),
      ProcessRecord(pid: 47, ppid: 1, uid: 501, comm: "  "),
    ]
    func assertion(_ pid: Int32, _ name: String) -> ForeignAssertion {
      ForeignAssertion(pid: pid, type: "PreventUserIdleSystemSleep", processName: name)
    }
    let input = [
      assertion(42, "KeepingYouAwake"), assertion(43, "caffeinate"), assertion(44, "caffeinate"),
      assertion(45, "CAFFEINATE"), assertion(46, "caffeinate"),
    ]
    var expected = input
    expected[3].parentName = "python3"
    #expect(CoexistenceProbe.namingParents(input, from: processes) == expected)
  }

  @Test func aCaffeinateStartedByClaudeIsExcludedAndTheOtherIsNamed() {
    let processes = [
      ProcessRecord(pid: 30, ppid: 1, uid: 501, comm: "claude", argv0: "claude"),
      ProcessRecord(pid: 31, ppid: 1, uid: 501, comm: "backup-tool"),
      ProcessRecord(pid: 32, ppid: 30, uid: 501, comm: "caffeinate"),
      ProcessRecord(pid: 33, ppid: 31, uid: 501, comm: "caffeinate"),
    ]
    let held: [String: Any] = [
      "AssertLevel": NSNumber(value: 255), "AssertType": "PreventUserIdleSystemSleep", "Process Name": "caffeinate",
    ]
    let table: [Int32: [[String: Any]]] = [32: [held], 33: [held]]
    let foreign = CoexistenceProbe.foreignAssertions(
      in: table, excluding: CoexistenceProbe.claudeCaffeinatePIDs(in: processes))
    #expect(
      CoexistenceProbe.namingParents(foreign, from: processes) == [
        ForeignAssertion(
          pid: 33, type: "PreventUserIdleSystemSleep", processName: "caffeinate", parentName: "backup-tool")
      ])
  }

  @Test func theProbeSourceOnlyReadsAssertions() throws {
    let source = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Sources/OvertimeSystem/CoexistenceProbe.swift")
    let text = try String(contentsOf: source, encoding: .utf8)
    #expect(text.contains("IOPMCopyAssertionsByProcess"))
    for forbidden in [
      "IOPMAssertionCreate", "IOPMAssertionRelease", "IOPMAssertionSetProperty", "IOPMAssertionDeclare",
    ] {
      #expect(!text.contains(forbidden))
    }
  }
}
