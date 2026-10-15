import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing
import os

struct NetworkLogPrivacyTests {
  static let backslash = "\u{5C}"
  static let stem = ["Z", "o"].joined()
  static let accent = "\u{EB}"
  static let apostrophe = "\u{2019}"
  static let tail = ["s i", "Phone"].joined()
  static let hotspot = stem + accent + apostrophe + tail
  static let joinCode: Int32 = -25

  static var forbiddenForms: [String] {
    [
      hotspot,
      stem + accent,
      stem + backslash + "u00eb",
      stem + backslash + "u00EB",
      stem + backslash + "u{eb}",
      stem + "%C3%AB",
      backslash + "u2019" + tail,
      backslash + "u{2019}" + tail,
      apostrophe + tail,
      "'" + tail,
      stem + "e" + "\u{308}",
    ]
  }

  struct Script: Sendable {
    var lidClosed = false
    var onHotspot = false
    var joins: [String] = []
    var cycles = 0
    var probes = 0
  }

  @Sendable static func facts(_ script: OSAllocatedUnfairLock<Script>, auto: Bool) -> NetworkFacts {
    NetworkFacts(
      wifiInterface: "en0", onHotspot: script.withLock { $0.onHotspot }, wired: false, wifiPowered: true,
      autoHotspot: auto ? hotspot : nil)
  }

  struct Run {
    let temp: TempDirectory
    let paths: Paths
    let clock = FakeClock()
    let recorder: HoldRecorder
    let script = OSAllocatedUnfairLock(initialState: Script())
    let auto: Bool

    init(auto: Bool) throws {
      self.auto = auto
      temp = try TempDirectory()
      paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path], homeDirectory: temp.path)
      try paths.createDirectories()
      recorder = HoldRecorder(stateFile: paths.stateFile(.live))
    }

    var settings: Settings {
      auto ? Settings(hotspot: "", hotspotAutoDetect: true) : Settings(hotspot: NetworkLogPrivacyTests.hotspot)
    }

    var port: ClosureNetworkPort {
      let script = script
      let auto = auto
      return ClosureNetworkPort(
        onFacts: { _ in NetworkLogPrivacyTests.facts(script, auto: auto) },
        onProbe: {
          script.withLock { $0.probes += 1 }
          return false
        },
        onJoin: { name in
          script.withLock { $0.joins.append(name) }
          return .failed(code: NetworkLogPrivacyTests.joinCode)
        },
        onCycle: {
          script.withLock { $0.cycles += 1 }
          return .succeeded
        })
    }

    func interpreter() throws -> LiveInterpreter {
      let recorder = recorder
      let logger = try FileLogger(decisionLog: paths.decisionLog(.live), errorLog: paths.errorLog(.live))
      return LiveInterpreter(
        ports: LivePorts(
          assertions: FakeAssertionPort(), tools: FakeToolPort(), clamshell: FakeClamshellPort(recorder: recorder),
          stateFile: paths.stateFile(.live), makeSentinel: { FakeSentinelPort(recorder: recorder) },
          network: port),
        logger: logger,
        sentinel: FakeSentinelPort(recorder: recorder),
        timeZone: TimeZone(secondsFromGMT: 0)!)
    }

    func engine(_ interpreter: LiveInterpreter) -> Engine {
      let script = script
      let auto = auto
      return Engine(
        mode: .live,
        settings: settings,
        clock: clock,
        interpreter: interpreter,
        sources: EngineSources(
          transcriptSeed: { [] },
          sampleTick: {
            TickFacts(
              lidClosed: script.withLock { $0.lidClosed }, externalDisplays: 0, fullWake: true,
              network: NetworkLogPrivacyTests.facts(script, auto: auto))
          },
          samplesFullWake: true),
        heartbeat: { await interpreter.heartbeat() },
        closeSentinel: { interpreter.closeSentinel() })
    }

    var joins: [String] { script.withLock { $0.joins } }
    var cycles: Int { script.withLock { $0.cycles } }

    func text(_ url: URL) -> String {
      (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    var decisionLog: String { text(paths.decisionLog(.live)) }
    var errorLog: String { text(paths.errorLog(.live)) }
  }

  struct Outcome {
    let decisionLog: String
    let errorLog: String
    let snapshotJSON: [String]
    let journalLines: [String]
    let journalSummary: String?
    let joins: [String]
  }

  static func stepNew(_ collector: NetworkEventCollector, from stepped: inout Int, into engine: Engine) async {
    let events = collector.events
    while stepped < events.count {
      await engine.step(events[stepped])
      stepped += 1
    }
  }

  static func failover(auto: Bool) async throws -> Outcome {
    let run = try Run(auto: auto)
    let interpreter = try run.interpreter()
    let engine = run.engine(interpreter)
    let collector = NetworkEventCollector(try #require(interpreter.networkEvents))
    let snapshots = SnapshotRecorder(await engine.snapshots())
    defer { snapshots.cancel() }
    #expect(await snapshots.wait { !$0.isEmpty })
    let baseline = try #require(snapshots.snapshots.first).events

    _ = await engine.handle(.force(.indefinite))
    #expect(await Engine.bounded(seconds: 5) { await engine.tick() })
    run.script.withLock { $0.lidClosed = true }
    #expect(await Engine.bounded(seconds: 5) { await engine.tick() })
    run.clock.advance(seconds: Timing.lidStableSeconds)

    var stepped = 0
    var probes = 0
    for _ in 0..<40 {
      let before = await engine.state.network.nextProbe
      #expect(await Engine.bounded(seconds: 5) { await engine.tick() })
      if await engine.state.network.nextProbe != before {
        probes += 1
        #expect(await collector.waitFor(count: probes))
      }
      await stepNew(collector, from: &stepped, into: engine)
      if await engine.state.network.phase != .idle { break }
      run.clock.advance(seconds: Timing.tickSeconds)
    }
    #expect(probes == Timing.netFailsNeeded)
    #expect(await OffPool.eventually(seconds: 5) { run.joins.count == 1 })

    run.script.withLock { $0.onHotspot = true }
    run.clock.advance(seconds: Timing.tickSeconds)
    #expect(await Engine.bounded(seconds: 5) { await engine.tick() })
    #expect(await engine.state.persisted.switchedToHotspot)
    #expect(await engine.state.events.hotspotSwitches == baseline.hotspotSwitches + 1)

    for _ in 0..<40 {
      run.clock.advance(seconds: Timing.netEverySeconds)
      let before = await engine.state.network.nextProbe
      #expect(await Engine.bounded(seconds: 5) { await engine.tick() })
      if await engine.state.network.nextProbe != before {
        probes += 1
        #expect(await collector.waitFor(count: probes))
      }
      await stepNew(collector, from: &stepped, into: engine)
      if await engine.state.events.wifiCycles > baseline.wifiCycles { break }
    }
    #expect(await OffPool.eventually(seconds: 5) { run.cycles == 1 })
    #expect(await engine.state.persisted.switchedToHotspot)

    run.script.withLock { $0.lidClosed = false }
    for _ in 0..<10 {
      #expect(await Engine.bounded(seconds: 5) { await engine.tick() })
      if run.cycles == 2 { break }
      run.clock.advance(seconds: Timing.tickSeconds)
    }
    #expect(await OffPool.eventually(seconds: 5) { run.cycles == 2 })
    #expect(await engine.state.persisted.switchedToHotspot)
    run.script.withLock { $0.onHotspot = false }
    run.clock.advance(seconds: Timing.tickSeconds)
    #expect(await Engine.bounded(seconds: 5) { await engine.tick() })
    #expect(await !engine.state.persisted.switchedToHotspot)
    #expect(await collector.waitFor(count: probes + 2))
    await stepNew(collector, from: &stepped, into: engine)
    #expect(await engine.state.events.wifiCycles == baseline.wifiCycles + 1)

    let lidOpened = "Lid opened after switching to hotspot"
    let joinFailure = "ERROR net failed action=joinHotspot result=\(joinCode)"
    #expect(await OffPool.eventually(seconds: 5) { run.decisionLog.contains(lidOpened) })
    #expect(await OffPool.eventually(seconds: 5) { run.errorLog.contains(joinFailure) })
    #expect(await snapshots.wait { $0.last?.network?.switched == false && $0.last?.lidClosed == false })

    var journal = LidClosedJournal.start(baseline: baseline)
    for snapshot in snapshots.snapshots {
      journal.append(from: snapshot)
    }
    let current = await engine.currentSnapshot()
    journal.append(from: current)
    let encoded = (snapshots.snapshots + [current]).map {
      String(decoding: DiagnosticsManifest.snapshotJSON($0), as: UTF8.self)
    }
    withExtendedLifetime(interpreter) {}
    return Outcome(
      decisionLog: run.decisionLog, errorLog: run.errorLog, snapshotJSON: encoded, journalLines: journal.lines(),
      journalSummary: journal.summary()?.body, joins: run.joins)
  }

  static func expectNoFormOfTheName(in outcome: Outcome) {
    let sinks =
      [("decision log", outcome.decisionLog), ("error log", outcome.errorLog)]
      + outcome.snapshotJSON.map { ("snapshot.json", $0) }
      + outcome.journalLines.map { ("journal", $0) }
      + [("summary", outcome.journalSummary ?? "")]
    for (sink, text) in sinks {
      for form in forbiddenForms {
        #expect(!text.contains(form), "\(sink) carries a form of the hotspot name")
      }
    }
  }

  static func expectTheRunReachedEverySink(_ outcome: Outcome, source: String) {
    #expect(outcome.joins == [hotspot])
    let quote = "\""
    let join = " NET join msg=" + quote + NetworkFailover.joiningMessage + quote + " hotspot=" + source
    #expect(outcome.decisionLog.contains(" NET armed hotspot=" + source))
    #expect(outcome.decisionLog.contains(join))
    #expect(outcome.decisionLog.contains(" NET connected "))
    #expect(outcome.decisionLog.components(separatedBy: " NET cycleWifi ").count == 3)
    #expect(outcome.errorLog.contains("ERROR net failed action=joinHotspot result=\(joinCode)"))
    #expect(outcome.snapshotJSON.contains { $0.contains("\"switched\" : true") })
    #expect(outcome.snapshotJSON.last?.contains("\"network\"") == true)
    let lines = [NotificationContent.hotspotSwitchLine, NotificationContent.wifiCycleLine(count: 1)]
    #expect(outcome.journalLines == lines)
    #expect(outcome.journalSummary == lines.joined(separator: "\n"))
  }

  @Test func theFormsAreBuiltFromTheNameTheRunUses() {
    #expect(Self.hotspot.unicodeScalars.map(\.value).contains(0x2019))
    #expect(Self.hotspot.unicodeScalars.map(\.value).contains(0xEB))
    #expect(Settings.isValidSSID(Self.hotspot))
    #expect(Self.forbiddenForms.allSatisfy { !$0.isEmpty })
    #expect(Self.forbiddenForms.filter { Self.hotspot.contains($0) }.count >= 3)
    let asciiEscaped = Self.stem + Self.backslash + "u00eb" + Self.backslash + "u2019" + Self.tail
    #expect(Self.forbiddenForms.filter { asciiEscaped.contains($0) }.count >= 2)
    #expect(!asciiEscaped.contains(Self.hotspot))
  }

  @Test func aConfiguredHotspotFailoverLeavesItsNameInNoLogSnapshotOrJournal() async throws {
    let outcome = try await Self.failover(auto: false)
    Self.expectTheRunReachedEverySink(outcome, source: "configured")
    Self.expectNoFormOfTheName(in: outcome)
  }

  @Test func anAutoDetectedHotspotFailoverLeavesItsNameInNoLogSnapshotOrJournal() async throws {
    let outcome = try await Self.failover(auto: true)
    Self.expectTheRunReachedEverySink(outcome, source: "auto")
    Self.expectNoFormOfTheName(in: outcome)
  }
}
