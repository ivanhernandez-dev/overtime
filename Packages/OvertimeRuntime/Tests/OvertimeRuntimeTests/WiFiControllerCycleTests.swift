import Foundation
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing
import os

final class PauseRecorder: Sendable {
  struct Pause: Sendable, Equatable {
    var seconds: Double
    var marker: Data?
    var mode: mode_t?
  }

  private let recorded = OSAllocatedUnfairLock<[Pause]>(initialState: [])
  private let hook = OSAllocatedUnfairLock<(@Sendable (Double) -> Void)?>(initialState: nil)
  private let clock: FakeClock
  private let markerURL: URL

  init(clock: FakeClock, markerURL: URL) {
    self.clock = clock
    self.markerURL = markerURL
  }

  func onPause(_ body: @escaping @Sendable (Double) -> Void) {
    hook.withLock { $0 = body }
  }

  var pauses: [Pause] {
    recorded.withLock { $0 }
  }

  var seconds: [Double] {
    pauses.map(\.seconds)
  }

  var sleep: @Sendable (Double) -> Void {
    { [self] seconds in
      let path = markerURL.path(percentEncoded: false)
      var info = stat()
      let mode = lstat(path, &info) == 0 ? info.st_mode & 0o777 : nil
      let data = FileManager.default.contents(atPath: path)
      recorded.withLock { $0.append(Pause(seconds: seconds, marker: data, mode: mode)) }
      clock.advance(seconds: seconds)
      hook.withLock { $0 }?(seconds)
    }
  }
}

struct CycleFixture {
  static let interface = "en0"

  let temp: TempDirectory
  let clock = FakeClock()
  let marker: WiFiCycleMarker
  let radio: FakeWiFiRadio
  let tools: ToolFactoryRecorder
  let pauses: PauseRecorder
  let controller: WiFiController

  init(
    _ script: FakeWiFiRadio.Script = FakeWiFiRadio.Script(),
    configured: Bool = true,
    markerName: String = "wifi-cycle.json",
    known: [String]? = [WiFiControllerJoinTests.hotspot],
    output: ToolOutcome = .finished(exitCode: 0, stdout: "", stderr: ""),
    toolSwitchesPower: Bool = false,
    waitSeconds: Double = WiFiController.actuationWaitSeconds
  ) throws {
    temp = try TempDirectory()
    marker = WiFiCycleMarker(url: temp.url.appendingPathComponent(markerName))
    var script = script
    script.markerURL = marker.url
    let radio = FakeWiFiRadio(script, clock: clock)
    self.radio = radio
    let switchPower: FakeToolPort.Responder = { _, arguments in
      if arguments.first == WiFiController.powerVerb, let state = arguments.last {
        let on = state == "on"
        radio.update { $0.powered = on }
      }
      return nil
    }
    tools = ToolFactoryRecorder(FakeToolPort(outcome: output, responder: toolSwitchesPower ? switchPower : nil))
    pauses = PauseRecorder(clock: clock, markerURL: marker.url)
    controller = WiFiController(
      radio: radio, knownNetworks: { known }, locationAuthorized: { false }, clock: clock, makeTools: tools.make,
      marker: configured ? marker : nil, sleep: pauses.sleep, actuationWaitSeconds: waitSeconds)
  }

  var toolCalls: [FakeToolPort.Call] {
    tools.tool.calls
  }

  var markerExists: Bool {
    FakeWiFiRadio.exists(marker.url) ?? false
  }

  func plantMarker(interface: String = CycleFixture.interface) {
    #expect(marker.write(interface: interface, startedAt: clock.wall()))
  }

  func plant(_ planted: WiFiControllerCycleTests.Planted, interface: String = CycleFixture.interface) throws {
    let url = marker.url
    switch planted {
    case .absent:
      break
    case .present:
      plantMarker(interface: interface)
    case .garbage:
      try Data("not a marker".utf8).write(to: url)
    case .oversized:
      let valid = #"{"interface":"en0","startedAt":0,"version":1}"#
      let padding = String(repeating: " ", count: WiFiCycleMarker.maxBytes + 1 - valid.utf8.count)
      try Data((valid + padding).utf8).write(to: url)
    case .symlink:
      let target = temp.url.appendingPathComponent("elsewhere.json")
      #expect(WiFiCycleMarker(url: target).write(interface: interface, startedAt: clock.wall()))
      try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
    case .wrongInterface:
      try Data(#"{"interface":"utun1","startedAt":0,"version":1}"#.utf8).write(to: url)
    case .directory:
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }
  }

  func folderEntries() -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? []).sorted()
  }

  static func power(_ on: Bool) -> FakeWiFiRadio.Call {
    .setPower(interface: interface, on: on)
  }

  static func powerTool(_ on: Bool) -> FakeToolPort.Call {
    FakeToolPort.Call(
      executable: "/usr/sbin/networksetup", arguments: ["-setairportpower", interface, on ? "on" : "off"])
  }

  static let readPower = FakeWiFiRadio.Call.powerOn(interface: interface)
  static let refusalChecks: [FakeWiFiRadio.Call] = [.interfaceName, .adminRequirements(interface: interface)]
  static let checks: [FakeWiFiRadio.Call] = refusalChecks + [readPower]
  static let failure = Result<Void, RadioError>.failure(.coreWLAN(code: 82))
  static let toolError = ToolOutcome.finished(exitCode: 0, stdout: "Error: the operation failed.\n", stderr: "")
}

struct WiFiControllerCycleTests {
  @Test func aCycleThroughTheLaneHoldsTheMarkerAroundTheOffPeriodAndRemovesItOnceOnIsConfirmed() async throws {
    let fixture = try CycleFixture()
    let controller = fixture.controller
    let port = ClosureNetworkPort(
      onJoin: { _ in WiFiController.Code.notKnown.outcome }, onCycle: { controller.cycleWifi() })
    let harness = try NetworkLaneHarness(port: port, bounds: .standard)
    _ = harness.enqueue([.net(.cycleWifi), .net(.joinHotspot(WiFiControllerJoinTests.hotspot))])
    #expect(await harness.logged(" ERROR net failed action=joinHotspot result=-23"))
    let entries = fixture.radio.entries
    #expect(
      entries.map(\.call)
        == CycleFixture.checks + [CycleFixture.power(false), CycleFixture.power(true), CycleFixture.readPower])
    #expect(entries.map(\.markerExists) == [false, false, false, true, true, true])
    let off = try #require(entries.first { $0.call == CycleFixture.power(false) }?.at)
    let on = try #require(entries.first { $0.call == CycleFixture.power(true) }?.at)
    #expect(on.seconds(since: off) == WiFiController.offSeconds)
    #expect(fixture.pauses.seconds == [3])
    #expect(!fixture.markerExists)
    #expect(fixture.folderEntries().isEmpty)
    #expect(fixture.toolCalls.isEmpty)
    #expect(harness.netLines.count == 1)
    #expect(harness.netLines.allSatisfy { $0.hasSuffix("action=joinHotspot result=-23") })
    #expect(!harness.lines.contains { $0.contains("cycleWifi") })
    withExtendedLifetime(harness.interpreter) {}
  }

  @Test func theMarkerHoldsOnlyItsVersionTheInterfaceAndTheStartTimeInAPrivateFile() throws {
    let fixture = try CycleFixture()
    let started = fixture.clock.wall()
    #expect(fixture.controller.cycleWifi() == .succeeded)
    let pause = try #require(fixture.pauses.pauses.first)
    #expect(pause.mode == 0o600)
    let data = try #require(pause.marker)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(object.keys) == ["version", "interface", "startedAt"])
    #expect(object["version"] as? Int == 1)
    #expect(object["interface"] as? String == "en0")
    #expect(object["startedAt"] as? Int == Int(started.timeIntervalSince1970.rounded(.down)))
    #expect(!String(decoding: data, as: UTF8.self).contains("iPhone"))
  }

  static let hotspot = WiFiControllerJoinTests.hotspot
  static let checks = CycleFixture.checks
  static let readPower = CycleFixture.readPower
  static let joinChecks: [FakeWiFiRadio.Call] = [
    .interfaceName, .adminRequirements(interface: CycleFixture.interface),
    .savedSecurity(interface: CycleFixture.interface, ssid: hotspot),
  ]

  static func power(_ on: Bool) -> FakeWiFiRadio.Call {
    CycleFixture.power(on)
  }

  struct CycleRefusal: Sendable, CustomTestStringConvertible {
    let label: String
    let interface: String?
    let admin: AdminRequirements?
    let configured: Bool
    let markerName: String
    let powered: Bool?
    let code: WiFiController.Code

    var testDescription: String { label }

    init(
      _ label: String, interface: String? = CycleFixture.interface,
      admin: AdminRequirements? = AdminRequirements(power: false, association: false), configured: Bool = true,
      markerName: String = "wifi-cycle.json", powered: Bool? = true, code: WiFiController.Code
    ) {
      self.label = label
      self.interface = interface
      self.admin = admin
      self.configured = configured
      self.markerName = markerName
      self.powered = powered
      self.code = code
    }
  }

  static let refusals: [CycleRefusal] = [
    CycleRefusal("no Wi-Fi interface", interface: nil, code: .invalidInterface),
    CycleRefusal("not a Wi-Fi interface name", interface: "utun1", code: .invalidInterface),
    CycleRefusal(
      "power needs an administrator", admin: AdminRequirements(power: true, association: false),
      code: .adminRequired),
    CycleRefusal("administrator flags unreadable", admin: nil, code: .powerUnknown),
    CycleRefusal("no marker configured", configured: false, code: .markerFailed),
    CycleRefusal("marker folder missing", markerName: "missing/wifi-cycle.json", code: .markerFailed),
    CycleRefusal("Wi-Fi already off", powered: false, code: .wifiOff),
    CycleRefusal("Wi-Fi power unreadable", powered: nil, code: .powerUnknown),
  ]

  @Test(arguments: refusals) func aCycleRefusesBeforeAnyWrite(_ refusal: CycleRefusal) throws {
    let script = FakeWiFiRadio.Script(interface: refusal.interface, admin: refusal.admin, powered: refusal.powered)
    let fixture = try CycleFixture(script, configured: refusal.configured, markerName: refusal.markerName)
    #expect(fixture.controller.cycleWifi() == refusal.code.outcome)
    #expect(fixture.radio.writes.isEmpty)
    #expect(fixture.toolCalls.isEmpty)
    #expect(fixture.pauses.seconds.isEmpty)
    #expect(fixture.folderEntries().isEmpty)
  }

  @Test func theAssociationFlagAloneDoesNotBlockACycle() throws {
    let fixture = try CycleFixture(FakeWiFiRadio.Script(admin: AdminRequirements(power: false, association: true)))
    #expect(fixture.controller.cycleWifi() == .succeeded)
    #expect(fixture.radio.writes == [Self.power(false), Self.power(true)])
  }

  @Test func aRadioOffThatFailsFallsBackToTheToolWithAFiveSecondBound() throws {
    let fixture = try CycleFixture(FakeWiFiRadio.Script(setPowerResults: [CycleFixture.failure]))
    #expect(fixture.controller.cycleWifi() == .succeeded)
    #expect(fixture.toolCalls == [CycleFixture.powerTool(false)])
    #expect(fixture.tools.timeouts == [5])
    #expect(fixture.radio.calls == Self.checks + [Self.power(false), Self.power(true), Self.readPower])
    #expect(!fixture.markerExists)
  }

  @Test func aRadioOnThatFailsFallsBackToTheTool() throws {
    let fixture = try CycleFixture(
      FakeWiFiRadio.Script(setPowerResults: [.success(()), CycleFixture.failure]), toolSwitchesPower: true)
    #expect(fixture.controller.cycleWifi() == .succeeded)
    #expect(fixture.toolCalls == [CycleFixture.powerTool(true)])
    #expect(fixture.radio.calls == Self.checks + [Self.power(false), Self.power(true), Self.readPower])
    #expect(!fixture.markerExists)
  }

  @Test func bothOffStepsFailingStillTurnWiFiOnAndRemoveTheMarker() throws {
    let fixture = try CycleFixture(
      FakeWiFiRadio.Script(setPowerResults: [CycleFixture.failure]), output: CycleFixture.toolError)
    #expect(fixture.controller.cycleWifi() == WiFiController.Code.offFailed.outcome)
    #expect(fixture.toolCalls == [CycleFixture.powerTool(false)])
    #expect(fixture.radio.calls == Self.checks + [Self.power(false), Self.power(true), Self.readPower])
    #expect(fixture.pauses.seconds == [3])
    #expect(!fixture.markerExists)
  }

  @Test func anOffThatTimedOutAndMayStillLandKeepsTheMarkerUntilTheCallHasReturned() throws {
    let script = FakeWiFiRadio.Script(setPowerResults: [.failure(.timedOut)], powerCallPending: true)
    let fixture = try CycleFixture(script, toolSwitchesPower: true)
    let radio = fixture.radio
    fixture.pauses.onPause { seconds in
      if seconds == WiFiController.settleSeconds { radio.update { $0.powered = false } }
    }
    _ = fixture.controller.cycleWifi()
    #expect(fixture.toolCalls == [CycleFixture.powerTool(false)])
    #expect(fixture.marker.read() == .present(interface: CycleFixture.interface))
    radio.update { script in
      script.powered = false
      script.powerCallPending = false
    }
    #expect(fixture.controller.recoverIfLeftOff(waitSeconds: 1) == .succeeded)
    #expect(radio.powered == true)
    #expect(!fixture.markerExists)
  }

  @Test func onThatDoesNotReadOnIsRetriedOnceThroughTheRadio() throws {
    let fixture = try CycleFixture(FakeWiFiRadio.Script(poweredAnswers: [true, false, true]))
    #expect(fixture.controller.cycleWifi() == .succeeded)
    #expect(
      fixture.radio.calls
        == Self.checks + [Self.power(false), Self.power(true), Self.readPower, Self.power(true), Self.readPower])
    #expect(fixture.toolCalls.isEmpty)
    #expect(!fixture.markerExists)
  }

  @Test func aRetryWhoseRadioCallFailsUsesTheTool() throws {
    let script = FakeWiFiRadio.Script(
      poweredAnswers: [true, false], setPowerResults: [.success(()), .success(()), CycleFixture.failure])
    let fixture = try CycleFixture(script, toolSwitchesPower: true)
    #expect(fixture.controller.cycleWifi() == .succeeded)
    #expect(
      fixture.radio.calls
        == Self.checks + [Self.power(false), Self.power(true), Self.readPower, Self.power(true), Self.readPower])
    #expect(fixture.toolCalls == [CycleFixture.powerTool(true)])
    #expect(!fixture.markerExists)
  }

  @Test(arguments: [false, nil] as [Bool?])
  func onThatIsStillNotConfirmedAfterTheRetryKeepsTheMarker(_ reading: Bool?) throws {
    let script = FakeWiFiRadio.Script(powered: reading, poweredAnswers: [true], powerFollowsWrites: false)
    let fixture = try CycleFixture(script)
    #expect(fixture.controller.cycleWifi() == WiFiController.Code.stillOff.outcome)
    #expect(
      fixture.radio.calls
        == Self.checks + [
          Self.power(false), Self.power(true), Self.readPower, Self.power(true), Self.readPower, Self.readPower,
        ])
    #expect(fixture.toolCalls == [CycleFixture.powerTool(true)])
    #expect(fixture.marker.read() == .present(interface: CycleFixture.interface))
  }

  @Test func withFewerThanSevenSecondsLeftTheOffFallbackIsSkippedButOnStillRuns() throws {
    var script = FakeWiFiRadio.Script(setPowerResults: [CycleFixture.failure, CycleFixture.failure])
    script.seconds = [.setPower: 15.5]
    let fixture = try CycleFixture(script, toolSwitchesPower: true)
    #expect(fixture.controller.cycleWifi() == WiFiController.Code.offFailed.outcome)
    #expect(fixture.toolCalls == [CycleFixture.powerTool(true)])
    #expect(!fixture.markerExists)
  }

  @Test func withSevenSecondsLeftTheOffFallbackStillRuns() throws {
    var script = FakeWiFiRadio.Script(setPowerResults: [CycleFixture.failure, CycleFixture.failure])
    script.seconds = [.setPower: 15]
    let fixture = try CycleFixture(script, toolSwitchesPower: true)
    #expect(fixture.controller.cycleWifi() == .succeeded)
    #expect(fixture.toolCalls == [CycleFixture.powerTool(false), CycleFixture.powerTool(true)])
    #expect(!fixture.markerExists)
  }

  @Test func noOnStepIsSkippedWhateverTheTime() throws {
    var script = FakeWiFiRadio.Script(
      poweredAnswers: [true, false], setPowerResults: [.success(()), CycleFixture.failure, CycleFixture.failure])
    script.seconds = [.setPower: 40, .powerOn: 40]
    let fixture = try CycleFixture(script, toolSwitchesPower: true)
    #expect(fixture.controller.cycleWifi() == .succeeded)
    #expect(fixture.toolCalls == [CycleFixture.powerTool(true), CycleFixture.powerTool(true)])
    #expect(
      fixture.radio.calls
        == Self.checks + [Self.power(false), Self.power(true), Self.readPower, Self.power(true), Self.readPower])
    #expect(!fixture.markerExists)
  }

  enum Planted: String, Sendable, CaseIterable {
    case absent
    case present
    case garbage
    case oversized
    case symlink
    case wrongInterface
    case directory
  }

  enum PowerState: String, Sendable, CaseIterable {
    case on
    case off
    case unknown

    var reading: Bool? {
      switch self {
      case .on: true
      case .off: false
      case .unknown: nil
      }
    }
  }

  static let leftMarkers: [Planted] = [.present, .garbage, .oversized, .symlink, .wrongInterface]

  @Test(arguments: PowerState.allCases)
  func withNoMarkerRecoveryMakesNoRadioCall(_ power: PowerState) throws {
    let fixture = try CycleFixture(FakeWiFiRadio.Script(powered: power.reading))
    #expect(fixture.controller.recoverIfLeftOff(waitSeconds: 1) == .succeeded)
    #expect(fixture.radio.calls.isEmpty)
    #expect(fixture.toolCalls.isEmpty)
  }

  @Test(arguments: leftMarkers, PowerState.allCases)
  func aMarkerThatIsPresentOrUnreadableTurnsWiFiOnUnlessItReadsOn(_ planted: Planted, _ power: PowerState) throws {
    let fixture = try CycleFixture(FakeWiFiRadio.Script(powered: power.reading))
    try fixture.plant(planted)
    #expect(fixture.controller.recoverIfLeftOff(waitSeconds: 1) == .succeeded)
    let turnOn = power == .on ? [] : [Self.power(true), Self.readPower]
    #expect(fixture.radio.calls == [.interfaceName, Self.readPower] + turnOn)
    #expect(fixture.toolCalls.isEmpty)
    #expect(!fixture.markerExists)
  }

  @Test func aRecoveryWhoseRadioOnFailsUsesTheTool() throws {
    let script = FakeWiFiRadio.Script(powered: false, setPowerResults: [CycleFixture.failure])
    let fixture = try CycleFixture(script, toolSwitchesPower: true)
    fixture.plantMarker()
    #expect(fixture.controller.recoverIfLeftOff(waitSeconds: 1) == .succeeded)
    #expect(fixture.toolCalls == [CycleFixture.powerTool(true)])
    #expect(fixture.radio.calls == [.interfaceName, Self.readPower, Self.power(true), Self.readPower])
    #expect(!fixture.markerExists)
  }

  @Test func aRecoveryThatCannotConfirmOnKeepsTheMarker() throws {
    let fixture = try CycleFixture(FakeWiFiRadio.Script(powered: false, powerFollowsWrites: false))
    fixture.plantMarker()
    #expect(fixture.controller.recoverIfLeftOff(waitSeconds: 1) == WiFiController.Code.stillOff.outcome)
    #expect(
      fixture.radio.calls == [
        .interfaceName, Self.readPower, Self.power(true), Self.readPower, Self.power(true), Self.readPower,
        Self.readPower,
      ])
    #expect(fixture.toolCalls == [CycleFixture.powerTool(true)])
    #expect(fixture.marker.read() == .present(interface: CycleFixture.interface))
  }

  @Test(arguments: [nil, "utun1"] as [String?])
  func whenTheRadioCannotNameTheInterfaceTheMarkersInterfaceIsUsed(_ radioInterface: String?) throws {
    let fixture = try CycleFixture(FakeWiFiRadio.Script(interface: radioInterface, powered: false))
    try fixture.plant(.present, interface: "en1")
    #expect(fixture.controller.recoverIfLeftOff(waitSeconds: 1) == .succeeded)
    #expect(
      fixture.radio.calls == [
        .interfaceName, .powerOn(interface: "en1"), .setPower(interface: "en1", on: true), .powerOn(interface: "en1"),
      ])
    #expect(!fixture.markerExists)
  }

  @Test func anUnreadableMarkerAndNoInterfaceLeaveTheMarkerForTheNextAttempt() throws {
    let fixture = try CycleFixture(FakeWiFiRadio.Script(interface: nil, powered: false))
    try fixture.plant(.garbage)
    #expect(fixture.controller.recoverIfLeftOff(waitSeconds: 1) == WiFiController.Code.invalidInterface.outcome)
    #expect(fixture.radio.calls == [.interfaceName])
    #expect(fixture.markerExists)
  }

  @Test(arguments: [AdminRequirements(power: true, association: true), nil] as [AdminRequirements?])
  func recoveryTurnsWiFiOnWhateverTheAdministratorFlagsSay(_ admin: AdminRequirements?) throws {
    let fixture = try CycleFixture(FakeWiFiRadio.Script(admin: admin, powered: false))
    fixture.plantMarker()
    #expect(fixture.controller.recoverIfLeftOff(waitSeconds: 1) == .succeeded)
    #expect(fixture.radio.calls == [.interfaceName, Self.readPower, Self.power(true), Self.readPower])
    #expect(!fixture.markerExists)
  }

  @Test func aMarkerThatCannotBeRemovedIsReportedOnceWiFiIsOn() throws {
    let fixture = try CycleFixture(FakeWiFiRadio.Script(powered: false))
    try fixture.plant(.directory)
    #expect(fixture.controller.recoverIfLeftOff(waitSeconds: 1) == WiFiController.Code.markerFailed.outcome)
    #expect(fixture.radio.calls == [.interfaceName, Self.readPower, Self.power(true), Self.readPower])
    #expect(fixture.radio.powered == true)
  }

  @Test func withNoMarkerConfiguredRecoveryHasNothingToDo() throws {
    let fixture = try CycleFixture(FakeWiFiRadio.Script(powered: false), configured: false)
    try fixture.plant(.present)
    #expect(fixture.controller.recoverIfLeftOff(waitSeconds: 1) == .succeeded)
    #expect(fixture.radio.calls.isEmpty)
  }

  @Test func aRecoveryWhileACycleHoldsTheLockWaitsItsBoundAndLeavesTheMarkerToTheCycle() async throws {
    let fixture = try CycleFixture(FakeWiFiRadio.Script(holdNext: .setPower))
    defer { fixture.radio.release() }
    let controller = fixture.controller
    let cycle = Task { await OffPool.bounded(seconds: 10) { controller.cycleWifi() } }
    #expect(await OffPool.eventually { fixture.radio.isHolding })
    #expect(fixture.markerExists)
    let before = fixture.radio.entries.count
    let started = ContinuousClock.now
    let recovered = await OffPool.bounded(seconds: 5) { controller.recoverIfLeftOff(waitSeconds: 0.2) }
    #expect(recovered == WiFiController.Code.busy.outcome)
    #expect(ContinuousClock.now - started >= .milliseconds(150))
    #expect(fixture.radio.entries.count == before)
    #expect(fixture.marker.read() == .present(interface: CycleFixture.interface))
    fixture.radio.release()
    #expect(await cycle.value == .succeeded)
    #expect(!fixture.markerExists)
  }

  @Test func aJoinTurnsWiFiBackOnFirstWhenAnEarlierCycleLeftItOff() async throws {
    let fixture = try CycleFixture(FakeWiFiRadio.Script(powered: false))
    fixture.plantMarker()
    let controller = fixture.controller
    #expect(await OffPool.run { controller.joinHotspot(Self.hotspot) } == .succeeded)
    #expect(
      fixture.radio.calls == [.interfaceName, Self.readPower, Self.power(true), Self.readPower] + Self.joinChecks)
    #expect(fixture.toolCalls == [WiFiControllerJoinTests.joinCall(CycleFixture.interface, Self.hotspot)])
    #expect(!fixture.markerExists)
  }

  @Test func aJoinDoesNotRunWhileWiFiCannotBeTurnedBackOn() throws {
    let fixture = try CycleFixture(FakeWiFiRadio.Script(powered: false, powerFollowsWrites: false))
    fixture.plantMarker()
    #expect(fixture.controller.joinHotspot(Self.hotspot) == WiFiController.Code.stillOff.outcome)
    #expect(fixture.toolCalls == [CycleFixture.powerTool(true)])
    #expect(!fixture.radio.calls.contains { $0.kind == .adminRequirements || $0.kind == .joinSaved })
    #expect(fixture.markerExists)
  }

  @Test func aJoinStillRunsWhenOnlyTheMarkerCannotBeRemoved() async throws {
    let fixture = try CycleFixture()
    try fixture.plant(.directory)
    let controller = fixture.controller
    #expect(await OffPool.run { controller.joinHotspot(Self.hotspot) } == .succeeded)
    #expect(fixture.radio.calls == [.interfaceName, Self.readPower] + Self.joinChecks)
    #expect(fixture.toolCalls == [WiFiControllerJoinTests.joinCall(CycleFixture.interface, Self.hotspot)])
  }

  @Test func aCycleFirstTurnsBackOnWiFiAnEarlierCycleLeftOffEvenWhenItIsThenRefused() throws {
    let script = FakeWiFiRadio.Script(admin: AdminRequirements(power: true, association: false), powered: false)
    let fixture = try CycleFixture(script)
    fixture.plantMarker()
    #expect(fixture.controller.cycleWifi() == WiFiController.Code.adminRequired.outcome)
    #expect(
      fixture.radio.calls
        == [.interfaceName, Self.readPower, Self.power(true), Self.readPower] + CycleFixture.refusalChecks)
    #expect(fixture.radio.powered == true)
    #expect(!fixture.markerExists)
    #expect(fixture.pauses.seconds.isEmpty)
  }

  @Test func aCycleAfterALeftOverMarkerWithWiFiOnClearsItAndCyclesNormally() throws {
    let fixture = try CycleFixture()
    fixture.plantMarker()
    #expect(fixture.controller.cycleWifi() == .succeeded)
    #expect(
      fixture.radio.calls
        == [.interfaceName, Self.readPower] + Self.checks + [Self.power(false), Self.power(true), Self.readPower])
    #expect(fixture.radio.entries.map(\.markerExists) == [true, true, false, false, false, true, true, true])
    #expect(!fixture.markerExists)
  }

  @Test func aJoinStartedDuringACycleWaitsForItAndTheirCallsNeverInterleave() async throws {
    let fixture = try CycleFixture(FakeWiFiRadio.Script(holdNext: .setPower), waitSeconds: 30)
    defer { fixture.radio.release() }
    let controller = fixture.controller
    let cycle = Task { await OffPool.bounded(seconds: 60) { controller.cycleWifi() } }
    #expect(await OffPool.eventually { fixture.radio.isHolding })
    let entered = OSAllocatedUnfairLock(initialState: false)
    let returned = OSAllocatedUnfairLock(initialState: false)
    let join = Task {
      await OffPool.bounded(seconds: 60) {
        entered.withLock { $0 = true }
        let outcome = controller.joinHotspot(Self.hotspot)
        returned.withLock { $0 = true }
        return outcome
      }
    }
    #expect(await OffPool.eventually { entered.withLock { $0 } })
    try await Task.sleep(for: .seconds(1))
    #expect(fixture.radio.isHolding)
    #expect(!returned.withLock { $0 })
    #expect(fixture.radio.calls == Self.checks + [Self.power(false)])
    fixture.radio.release()
    #expect(await cycle.value == .succeeded)
    #expect(await join.value == .succeeded)
    #expect(
      fixture.radio.calls
        == Self.checks + [Self.power(false), Self.power(true), Self.readPower] + Self.joinChecks)
  }

  @Test func aCycleThatCannotTakeTheLockReturnsBusyWithNoWrite() async throws {
    let fixture = try CycleFixture(FakeWiFiRadio.Script(holdNext: .adminRequirements), waitSeconds: 0.2)
    defer { fixture.radio.release() }
    let controller = fixture.controller
    let join = Task { await OffPool.bounded(seconds: 10) { controller.joinHotspot(Self.hotspot) } }
    #expect(await OffPool.eventually { fixture.radio.isHolding })
    let cycled = await OffPool.bounded(seconds: 5) { controller.cycleWifi() }
    #expect(cycled == WiFiController.Code.busy.outcome)
    #expect(!fixture.markerExists)
    #expect(fixture.radio.writes.isEmpty)
    #expect(fixture.pauses.seconds.isEmpty)
    fixture.radio.release()
    #expect(await join.value == .succeeded)
  }

  @Test func aJoinThatCannotTakeTheLockReturnsBusyWithNoCall() async throws {
    let fixture = try CycleFixture(FakeWiFiRadio.Script(holdNext: .setPower), waitSeconds: 0.2)
    defer { fixture.radio.release() }
    let controller = fixture.controller
    let cycle = Task { await OffPool.bounded(seconds: 10) { controller.cycleWifi() } }
    #expect(await OffPool.eventually { fixture.radio.isHolding })
    let joined = await OffPool.bounded(seconds: 5) { controller.joinHotspot(Self.hotspot) }
    #expect(joined == WiFiController.Code.busy.outcome)
    #expect(fixture.radio.calls == Self.checks + [Self.power(false)])
    #expect(fixture.toolCalls.isEmpty)
    fixture.radio.release()
    #expect(await cycle.value == .succeeded)
  }

  @Test func onlyEmptyToolOutputCountsAsAPowerChange() {
    #expect(WiFiController.powerToolSucceeded(.finished(exitCode: 0, stdout: "", stderr: "")))
    #expect(WiFiController.powerToolSucceeded(.finished(exitCode: 1, stdout: "\n", stderr: " ")))
    #expect(!WiFiController.powerToolSucceeded(.finished(exitCode: 0, stdout: "Error\n", stderr: "")))
    #expect(!WiFiController.powerToolSucceeded(.finished(exitCode: 0, stdout: "", stderr: "requires admin")))
    #expect(!WiFiController.powerToolSucceeded(.timedOut))
    #expect(!WiFiController.powerToolSucceeded(.launchFailed("")))
  }
}
