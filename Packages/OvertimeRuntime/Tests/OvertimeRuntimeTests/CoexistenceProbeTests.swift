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

  static let terminal: UInt32 = 0x1000_0003
  static let terminalHost = ProcessRecord(pid: 28, ppid: 1, uid: 501, comm: "term-app")
  static let loginShell = ProcessRecord(pid: 29, ppid: 28, uid: 501, comm: "zsh", ttyDevice: terminal, argv0: "-zsh")
  static let claudeSession = ProcessRecord(
    pid: 30, ppid: 29, uid: 501, comm: "2.1.302", ttyDevice: terminal, argv0: "/Users/dev/.local/bin/claude",
    execPath: "/Users/dev/.local/bin/claude", pidPath: "/Users/dev/.local/share/claude/versions/2.1.302")
  static let commandShell = ProcessRecord(
    pid: 34, ppid: 30, uid: 501, comm: "zsh", ttyDevice: terminal, argv0: "/bin/zsh", argv1: "-c")

  static func caffeinate(_ pid: Int32, parent: Int32, uid: UInt32 = 501) -> ProcessRecord {
    ProcessRecord(pid: pid, ppid: parent, uid: uid, comm: "caffeinate")
  }

  @Test func aCaffeinateStartedByACommandClaudeRunsIsExcluded() {
    let processes = [
      Self.terminalHost, Self.loginShell, Self.claudeSession, Self.commandShell,
      Self.caffeinate(35, parent: 34), Self.caffeinate(36, parent: 30),
    ]
    #expect(CoexistenceProbe.claudeCaffeinatePIDs(in: processes) == [35, 36])
  }

  @Test(arguments: 1...9)
  func theWalkReachesAClaudeAncestorUpToItsDepthBound(steps: Int) {
    var processes = [ProcessRecord(pid: 100, ppid: 1, uid: 501, comm: "claude", argv0: "claude")]
    for offset in 1..<steps {
      processes.append(
        ProcessRecord(pid: Int32(100 + offset), ppid: Int32(99 + offset), uid: 501, comm: "zsh", argv0: "/bin/zsh"))
    }
    processes.append(Self.caffeinate(200, parent: Int32(99 + steps)))
    #expect(CoexistenceProbe.claudeAncestorDepth == 8)
    #expect(CoexistenceProbe.claudeCaffeinatePIDs(in: processes) == (steps <= 8 ? [200] : []))
  }

  @Test func aCaffeinateWithoutAClaudeAncestorStillCounts() {
    let shell = ProcessRecord(pid: 40, ppid: 29, uid: 501, comm: "zsh", ttyDevice: Self.terminal, argv0: "/bin/zsh")
    let processes = [
      Self.terminalHost, Self.loginShell, shell, Self.caffeinate(41, parent: 40), Self.caffeinate(42, parent: 29),
      Self.caffeinate(43, parent: 28),
    ]
    #expect(CoexistenceProbe.claudeCaffeinatePIDs(in: processes).isEmpty)
  }

  @Test func anAncestorThatCannotBeClassifiedCountsAsNotClaude() {
    let processes = [
      ProcessRecord(pid: 50, ppid: 1, uid: 501, comm: "2.1.302"),
      ProcessRecord(pid: 51, ppid: 50, uid: 501, comm: "zsh", argv0: "/bin/zsh"),
      ProcessRecord(pid: 54, ppid: 1, uid: 501, comm: "claude"),
      ProcessRecord(pid: 55, ppid: 54, uid: 501, comm: "zsh"),
      Self.caffeinate(52, parent: 51), Self.caffeinate(53, parent: 50), Self.caffeinate(56, parent: 55),
      Self.caffeinate(57, parent: 54),
    ]
    #expect(CoexistenceProbe.claudeCaffeinatePIDs(in: processes).isEmpty)
  }

  @Test func aCycleOrAMissingParentEndsTheWalk() {
    let processes = [
      ProcessRecord(pid: 60, ppid: 61, uid: 501, comm: "zsh", argv0: "/bin/zsh"),
      ProcessRecord(pid: 61, ppid: 60, uid: 501, comm: "zsh", argv0: "/bin/zsh"),
      ProcessRecord(pid: 64, ppid: 64, uid: 501, comm: "zsh", argv0: "/bin/zsh"),
      Self.caffeinate(62, parent: 60), Self.caffeinate(63, parent: 999), Self.caffeinate(65, parent: 64),
      ProcessRecord(pid: 66, ppid: 66, uid: 501, comm: "caffeinate"),
    ]
    #expect(CoexistenceProbe.claudeCaffeinatePIDs(in: processes).isEmpty)
  }

  @Test func anAncestorOfAnotherUserEndsTheWalk() {
    let processes = [
      ProcessRecord(pid: 70, ppid: 1, uid: 502, comm: "claude", argv0: "claude"),
      ProcessRecord(pid: 71, ppid: 70, uid: 501, comm: "zsh", argv0: "/bin/zsh"),
      Self.caffeinate(72, parent: 71), Self.caffeinate(73, parent: 70),
    ]
    #expect(CoexistenceProbe.claudeCaffeinatePIDs(in: processes).isEmpty)
  }

  @Test func theWalkStopsAtLaunchd() {
    let processes = [
      ProcessRecord(pid: 1, ppid: 0, uid: 501, comm: "claude", argv0: "claude"),
      ProcessRecord(pid: 80, ppid: 1, uid: 501, comm: "zsh", argv0: "/bin/zsh"),
      Self.caffeinate(81, parent: 80), Self.caffeinate(82, parent: 1),
    ]
    #expect(CoexistenceProbe.claudeCaffeinatePIDs(in: processes).isEmpty)
  }

  @Test func busyDetectionStillCountsOnlyDirectChildren() {
    let processes = [
      Self.terminalHost, Self.loginShell, Self.claudeSession, Self.commandShell, Self.caffeinate(35, parent: 34),
    ]
    #expect(ClaudeCodeDetector.busySessionPIDs(in: processes).isEmpty)
    #expect(ClaudeCodeDetector(userID: 501).signals(from: processes).busyProcessCount == 0)
    let direct = processes + [Self.caffeinate(36, parent: 30)]
    #expect(ClaudeCodeDetector.busySessionPIDs(in: direct) == [30])
    #expect(ClaudeCodeDetector(userID: 501).signals(from: direct).busyProcessCount == 1)
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
