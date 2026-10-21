import Foundation
import OvertimeAppSupport
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing

@testable import Overtime

@MainActor
struct AutomationResponderTests {
  final class Logged {
    var decisions: [Decision] = []
  }

  static let forced = EngineSnapshot(wanted: true, reason: "force", force: .indefinite)

  static let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }()

  static func responder(
    host: FakeEngineHost?, awaitingEngine: Bool = false, scheme: String = AutomationURL.releaseScheme
  ) -> (AutomationResponder, PanelModel, Logged) {
    let model = PanelModel()
    model.amphetamineLocator = .absent
    if let host { model.bind(to: host) }
    let logged = Logged()
    let responder = AutomationResponder(
      model: model, awaitingEngine: awaitingEngine, scheme: scheme, calendar: utc,
      log: { logged.decisions.append($0) })
    return (responder, model, logged)
  }

  static func menuRequest(_ choice: KeepAwakeChoice, host: FakeEngineHost) -> CtlRequest {
    ControlMapping.request(for: .keepAwake(choice), now: host.clock.wall(), calendar: utc)
  }

  @Test func minutesSendsTheRequestOfTheKeepAwakeMenu() async {
    let host = FakeEngineHost()
    let (responder, _, logged) = Self.responder(host: host)
    let outcome = await responder.receive("overtime://keep-awake?minutes=90")
    #expect(outcome == .sent(.keepAwake(minutes: 90)))
    #expect(host.requests == [Self.menuRequest(.timed(minutes: 90), host: host)])
    #expect(host.requests == [.force(.forSeconds(5400))])
    #expect(logged.decisions == [outcome.decision])
  }

  @Test func noParameterIsUntilStoppedLikeTheShortcut() async {
    let host = FakeEngineHost()
    let (responder, _, _) = Self.responder(host: host)
    let outcome = await responder.receive("overtime://keep-awake")
    #expect(outcome == .sent(.keepAwakeUntilStopped))
    #expect(host.requests == [Self.menuRequest(.untilStopped, host: host)])
    #expect(host.requests == [.force(.indefinite)])
  }

  @Test(arguments: [("09:30", 5400.0), ("08:00", 24 * 3600.0), ("07:00", 23 * 3600.0), ("00:15", 16.25 * 3600)])
  func untilKeepsAwakeUntilTheNextLocalTime(time: String, seconds: Double) async {
    let host = FakeEngineHost()
    let (responder, _, _) = Self.responder(host: host)
    let outcome = await responder.receive("overtime://keep-awake?until=\(time)")
    guard case .sent(.keepAwakeUntil) = outcome else {
      Issue.record("expected a sent until command, got \(outcome)")
      return
    }
    #expect(host.requests == [.force(.forSeconds(seconds))])
  }

  @Test func stopWhileKeepingAwakeSendsTheStopKeepingAwakeRequest() async {
    let host = FakeEngineHost()
    host.scriptProbe(Self.forced)
    let (responder, _, _) = Self.responder(host: host)
    let outcome = await responder.receive("overtime://stop-keep-awake")
    #expect(outcome == .sent(.stopKeepAwake))
    #expect(
      host.requests == [ControlMapping.request(for: .stopKeepingAwake, now: host.clock.wall(), calendar: Self.utc)])
    #expect(host.requests == [.resume])
  }

  @Test(arguments: [EngineSnapshot(wanted: false, reason: "paused", pause: .indefinite), EngineSnapshot(), nil])
  func stopWithoutKeepAwakeOnSendsNothingAndKeepsAPause(_ probed: EngineSnapshot?) async {
    let host = FakeEngineHost()
    host.scriptProbe(probed)
    let (responder, _, logged) = Self.responder(host: host)
    let outcome = await responder.receive("overtime://stop-keep-awake")
    #expect(outcome == .nothingToStop)
    #expect(host.requests.isEmpty)
    #expect(logged.decisions == [AutomationOutcome.nothingToStop.decision])
  }

  @Test(arguments: [
    "overtime://keep-awake?minutes=0", "overtime://keep-awake?minutes=abc", "overtime://keep-awake?until=25:00",
    "overtime://keep-awake?minute=30", "overtime://sleep-now", "overtime://stop-keep-awake?minutes=5", "",
    "https://example.com/keep-awake",
  ])
  func anInvalidURLReachesNoEngineAndIsLogged(_ url: String) async {
    let host = FakeEngineHost()
    host.scriptProbe(Self.forced)
    let (responder, _, logged) = Self.responder(host: host)
    let outcome = await responder.receive(url)
    guard case .rejected = outcome else {
      Issue.record("expected a rejection, got \(outcome)")
      return
    }
    #expect(host.requests.isEmpty)
    #expect(host.probes == 0)
    #expect(logged.decisions.map(\.keyword) == [.warn])
  }

  @Test func theDevelopmentBuildIgnoresTheReleaseScheme() async {
    let host = FakeEngineHost()
    let (responder, _, _) = Self.responder(host: host, scheme: AutomationURL.debugScheme)
    #expect(await responder.receive("overtime://keep-awake") == .rejected(.wrongScheme))
    #expect(host.requests.isEmpty)
    #expect(await responder.receive("overtime-dev://keep-awake") == .sent(.keepAwakeUntilStopped))
  }

  @Test func theAppAnswersTheSchemeOfItsBuild() {
    #if DEBUG
      #expect(AutomationResponder.scheme == AutomationURL.debugScheme)
    #else
      #expect(AutomationResponder.scheme == AutomationURL.releaseScheme)
    #endif
  }

  @Test func aURLThatArrivesBeforeTheEngineRunsOnceItStartsAndTheLatestWins() async {
    let host = FakeEngineHost()
    let (responder, model, logged) = Self.responder(host: nil, awaitingEngine: true)
    #expect(await responder.receive("overtime://keep-awake?minutes=30") == .waitingForEngine(.keepAwake(minutes: 30)))
    #expect(await responder.receive("overtime://keep-awake?minutes=45") == .waitingForEngine(.keepAwake(minutes: 45)))
    #expect(responder.pending == .keepAwake(minutes: 45))
    #expect(host.requests.isEmpty)
    model.bind(to: host)
    await responder.engineStarted().value
    #expect(responder.pending == nil)
    #expect(host.requests == [.force(.forSeconds(2700))])
    #expect(logged.decisions.last == AutomationOutcome.sent(.keepAwake(minutes: 45)).decision)
    await responder.engineStarted().value
    #expect(host.requests.count == 1)
  }

  @Test func aURLWaitingForAnEngineThatCannotStartIsDroppedAndLogged() async {
    let (responder, _, logged) = Self.responder(host: nil, awaitingEngine: true)
    #expect(await responder.receive("overtime://keep-awake") == .waitingForEngine(.keepAwakeUntilStopped))
    responder.engineFailed()
    #expect(responder.pending == nil)
    #expect(logged.decisions.last == AutomationOutcome.failed(.keepAwakeUntilStopped).decision)
  }

  @Test func withNoEngineAndNoneStartingTheCommandFails() async {
    let (responder, _, _) = Self.responder(host: nil)
    #expect(await responder.receive("overtime://keep-awake?minutes=5") == .failed(.keepAwake(minutes: 5)))
  }

  @Test func whileUninstallingTheEngineControlsStayOff() async {
    let host = FakeEngineHost()
    host.scriptProbe(Self.forced)
    let (responder, model, _) = Self.responder(host: host)
    model.uninstalling = true
    #expect(await responder.receive("overtime://keep-awake") == .controlsUnavailable(.keepAwakeUntilStopped))
    #expect(await responder.receive("overtime://stop-keep-awake") == .controlsUnavailable(.stopKeepAwake))
    #expect(host.requests.isEmpty)
  }

  @Test func aRefusedRequestIsLoggedAsAFailure() async {
    let host = FakeEngineHost()
    host.respond(with: CtlResponse.failure("refused"))
    let (responder, _, logged) = Self.responder(host: host)
    #expect(await responder.receive("overtime://keep-awake?minutes=10") == .failed(.keepAwake(minutes: 10)))
    #expect(logged.decisions.map(\.keyword) == [.error])
  }

  @Test func urlsRunOneAtATimeInTheOrderTheyArrived() async {
    let host = FakeEngineHost()
    host.scriptProbe(Self.forced)
    let (responder, _, _) = Self.responder(host: host)
    responder.enqueue("overtime://stop-keep-awake")
    await responder.enqueue("overtime://keep-awake?minutes=60").value
    #expect(host.requests == [.resume, .force(.forSeconds(3600))])
  }

  @Test func urlsDriveARealEngineThroughThePanelsKeepAwake() async throws {
    let folder = try TestFolder()
    let paths = Paths.resolve(environment: ["OVERTIME_HOME": folder.path], homeDirectory: "/Users/dev")
    try paths.createDirectories()
    let logger = try FileLogger(decisionLog: paths.decisionLog(.shadow), errorLog: paths.errorLog(.shadow))
    let clock = SystemClock()
    let engine = Engine(
      mode: .shadow,
      settings: Settings(),
      clock: clock,
      interpreter: RecordingInterpreter(logger: logger, timeZone: TimeZone(secondsFromGMT: 0)!),
      sources: EngineSources(transcriptSeed: { [] }, sampleTick: { TickFacts(agents: .none) })
    )
    let model = PanelModel()
    model.amphetamineLocator = .absent
    let responder = AutomationResponder(
      model: model, awaitingEngine: true, scheme: AutomationURL.releaseScheme, log: { _ in })
    #expect(await responder.receive("overtime://keep-awake?minutes=30") == .waitingForEngine(.keepAwake(minutes: 30)))
    model.bind(to: LiveEngineHost(engine: engine, clock: clock))
    await engine.tick()
    await responder.engineStarted().value
    #expect(await waitUntil { model.presentation.state == .override })
    #expect(model.controls.keepAwakeRow == .stopKeepingAwake)
    #expect(model.snapshot?.force != nil)

    #expect(await responder.receive("overtime://stop-keep-awake") == .sent(.stopKeepAwake))
    #expect(await waitUntil { model.presentation.state == .idle })
    #expect(await responder.receive("overtime://stop-keep-awake") == .nothingToStop)

    #expect(await responder.receive("overtime://keep-awake") == .sent(.keepAwakeUntilStopped))
    #expect(await waitUntil { model.presentation.state == .override })
  }

  @Test func onlyTheLiveAppWaitsForItsEngine() {
    #expect(!AppDelegate.awaitsEngine(for: .testHost))
    #expect(!AppDelegate.awaitsEngine(for: .blocked(.storageUnavailable)))
  }
}
