import Foundation
import OvertimeAppSupport
import OvertimeClamshell
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing

@Suite(.serialized)
struct EmergencyEngineTests {
  struct Harness {
    let temp: TempDirectory
    let paths: Paths
    let clock = FakeClock()
    let registry = AssertionRegistry()
    let recorder: HoldRecorder
    let clamshell: FakeClamshellPort
    let sentinels: SentinelFactory
    let emergencyRecorder = EmergencyRecorder()

    init() throws {
      temp = try TempDirectory()
      paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path], homeDirectory: temp.path)
      recorder = HoldRecorder(stateFile: paths.stateFile(.live))
      clamshell = FakeClamshellPort(recorder: recorder)
      sentinels = SentinelFactory(recorder: recorder)
    }

    func engine() throws -> Engine {
      let sentinels = sentinels
      return try Composition.makeLiveEngine(
        paths: paths,
        settings: Settings(transcriptRoots: [temp.path + "/projects"]),
        ports: LivePorts(
          assertions: IOPMAssertionBackend(syscalls: FakeAssertionSyscalls(), registry: registry),
          tools: NoTools(), clamshell: clamshell, stateFile: paths.stateFile(.live),
          makeSentinel: { sentinels.make() }),
        environment: [:],
        homeDirectory: temp.path,
        once: true,
        clock: clock
      )
    }

    func reset(logTo engine: Engine) -> EmergencyReset {
      let selector = FakeEmergencySelector(recorder: emergencyRecorder, stateFile: paths.stateFile(.live))
      let emergencyRecorder = emergencyRecorder
      return EmergencyReset(
        opener: { selector },
        registry: registry,
        release: { id in
          emergencyRecorder.append("release \(id)")
          return 0
        },
        log: { engine.logImmediately($0) }
      )
    }

    func lines() -> [String] {
      guard let text = try? String(contentsOf: paths.decisionLog(.live), encoding: .utf8) else { return [] }
      return text.split(separator: "\n").map(String.init)
    }

    func sentinelLines(_ line: String) -> Int {
      recorder.all.filter {
        if case .sentinel(line, _) = $0 { return true }
        return false
      }.count
    }
  }

  @Test func theResetFinishesWhileTheEngineWriteIsHungAndTheEngineKeepsItsSentinel() async throws {
    let harness = try Harness()
    let engine = try harness.engine()
    await engine.step(.tick(TickFacts(fullWake: true)))
    #expect(await engine.handle(.force(.indefinite)).ok)
    #expect(await EffectOrderTests.poll(within: 5) { await engine.state.hold.lidClose == .held })
    #expect(harness.recorder.all.contains(.sentinel("ARM", fileOwnsHold: true)))
    #expect(harness.recorder.all.contains(.clamshell(on: true, fileOwnsHold: true)))
    let held = harness.registry.snapshot().count
    #expect(held > 0)

    harness.clamshell.holdNextWrite()
    defer { harness.clamshell.releaseHeldWrites() }
    let release = Task { await engine.handle(.releaseUntilIdle) }
    #expect(
      await EffectOrderTests.poll(within: 5) {
        harness.recorder.all.contains(.clamshell(on: false, fileOwnsHold: true))
      })

    let outcome = await harness.reset(logTo: engine).run()
    #expect(
      harness.clamshell.heldWritesReturned == 0, "the reset finished while the engine's own write is still blocked")
    #expect(outcome == .restored(released: held, helperCleared: true))
    guard case .state(let afterReset) = StateStore.read(at: harness.paths.stateFile(.live)) else {
      Issue.record("state.json is missing after the emergency")
      return
    }
    #expect(afterReset.ownsHold)
    #expect(harness.emergencyRecorder.actions.first?.hasPrefix("clear") == true)
    #expect(harness.sentinelLines("DISARM") == 0)
    #expect(!harness.sentinels.first.closed)

    harness.clamshell.releaseHeldWrites()
    #expect(await release.value.ok)
    #expect(await EffectOrderTests.poll(within: 5) { await engine.state.hold.lidClose == .released })
    #expect(await EffectOrderTests.poll(within: 5) { harness.sentinelLines("DISARM") == 1 })
    #expect(harness.sentinels.first.delivered.last { $0 == "ARM" || $0 == "DISARM" } == "DISARM")

    let armsBefore = harness.sentinelLines("ARM")
    #expect(await engine.handle(.force(.indefinite)).ok)
    #expect(await EffectOrderTests.poll(within: 5) { await engine.state.hold.lidClose == .held })
    #expect(
      await EffectOrderTests.poll(within: 5) {
        harness.recorder.all.filter { $0 == .clamshell(on: true, fileOwnsHold: true) }.count == 2
      })
    #expect(harness.sentinelLines("ARM") == armsBefore + 1)
    #expect(harness.sentinels.count == 1)
    let delivered = harness.sentinels.first.delivered
    #expect((delivered.lastIndex(of: "ARM") ?? -1) > (delivered.lastIndex(of: "DISARM") ?? Int.max))
    #expect(harness.recorder.all.filter { $0 == .clamshell(on: true, fileOwnsHold: true) }.count == 2)
    #expect(!harness.sentinels.first.closed)
    #expect(!harness.recorder.all.contains(.sentinelClose))
    #expect(!harness.recorder.all.contains(.sentinelRetire))
    #expect(harness.lines().contains { $0.contains(" HOLD emergency clear=succeeded released=\(held)") })
    await engine.stop()
  }

  struct OrderedEmergencySelector: ClamshellSelector {
    static let entry = "emergency clear"

    let order: HelperCallOrder

    func write(on: Bool) -> kern_return_t {
      order.append(on ? "emergency set" : Self.entry)
      return KERN_SUCCESS
    }
  }

  @Test func theResetReleasesAHelperThatAnEngineThatStoppedTickingStillHoldsAndLeavesTheEngineAlone() async throws {
    let harness = try EngineHelperTests.Harness()
    let helper = InProcessHelper(order: harness.order)
    defer { helper.stop() }
    let engine = try harness.engine(helper: XPCHelperPort(client: helper.client()))
    await harness.engage(engine)
    #expect(harness.order.all == EngineHelperTests.engaged)
    #expect(helper.fake.sleepDisabled == true)
    #expect(helper.connectionsMade == 1)
    helper.fake.forget()
    let engineSide = harness.recorder.all
    #expect(engineSide.contains(.sentinel("ARM", fileOwnsHold: true)))

    let order = harness.order
    let short = helper.client()
    let reset = EmergencyReset(
      opener: { OrderedEmergencySelector(order: order) },
      registry: AssertionRegistry(),
      release: { _ in 0 },
      log: { engine.logImmediately($0) },
      helperClear: AppHost.emergencyHelperClear(installer: FakeHelperInstaller(status: .enabled)) { short }
    )
    #expect(await reset.run() == .restored(released: 0, helperCleared: true))
    #expect(
      harness.order.all
        == EngineHelperTests.engaged + [
          OrderedHelperSystem.clearEntry, OrderedHelperSystem.edgeEntry, OrderedEmergencySelector.entry,
        ], EmergencyResetTests.helperFirst)
    #expect(helper.fake.sleepDisabled == false)
    #expect(helper.fake.storedRecord?.owns == false)
    #expect(helper.statusCalls == 0, "The emergency client must only send a clear and never call status (T-03-19)")
    #expect(helper.connectionsMade == 2)
    #expect(await OffPool.eventually { helper.connections == 1 })
    #expect(harness.recorder.all == engineSide, EmergencyResetTests.touchesNothing)
    #expect(await engine.state.helper.phase == .engaged, EmergencyResetTests.touchesNothing)
    #expect(await engine.state.hold.lidClose == .held, EmergencyResetTests.touchesNothing)
    #expect(harness.logged(" HOLD emergency clear=succeeded released=0"))
    #expect(!harness.logged(" ERROR emergency helper clear=failed"))
    await engine.stop()
  }

  @Test func theLiveHostProbeReturnsTheEngineSnapshot() async throws {
    let harness = try Harness()
    let engine = try harness.engine()
    let host = LiveEngineHost(engine: engine, clock: harness.clock, boundSeconds: 30)
    let snapshot = await host.probe()
    #expect(snapshot == (await engine.currentSnapshot()))
    await engine.stop()
  }
}
