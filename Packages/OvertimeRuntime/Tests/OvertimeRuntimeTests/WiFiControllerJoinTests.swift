import Foundation
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing

struct WiFiControllerJoinTests {
  static let hotspot = "Zoë’s iPhone"

  struct Fixture {
    let clock = FakeClock()
    let radio: FakeWiFiRadio
    let tools: ToolFactoryRecorder
    let controller: WiFiController

    init(
      _ script: FakeWiFiRadio.Script = FakeWiFiRadio.Script(),
      known: [String]? = [WiFiControllerJoinTests.hotspot],
      location: Bool = false,
      output: ToolOutcome = .finished(exitCode: 0, stdout: "", stderr: "")
    ) {
      radio = FakeWiFiRadio(script, clock: clock)
      tools = ToolFactoryRecorder(FakeToolPort(outcome: output))
      controller = WiFiController(
        radio: radio, knownNetworks: { known }, locationAuthorized: { location }, clock: clock,
        makeTools: tools.make)
    }

    var toolCalls: [FakeToolPort.Call] {
      tools.tool.calls
    }

    func join(_ name: String) async -> EffectOutcome {
      let controller = controller
      return await OffPool.run { controller.joinHotspot(name) }
    }
  }

  static func joinCall(_ interface: String, _ name: String) -> FakeToolPort.Call {
    FakeToolPort.Call(executable: "/usr/sbin/networksetup", arguments: ["-setairportnetwork", interface, name])
  }

  @Test func aFailoverJoinRunsTheFallbackThroughTheLaneAndLogsOnlyTheActionAndACode() async throws {
    let fixture = Fixture(
      output: .finished(exitCode: 0, stdout: "Could not find network \(Self.hotspot).\n", stderr: ""))
    let controller = fixture.controller
    let port = ClosureNetworkPort(onJoin: { controller.joinHotspot($0) })
    let harness = try NetworkLaneHarness(port: port, bounds: .standard)
    _ = harness.enqueue([.net(.joinHotspot(Self.hotspot))])
    #expect(await harness.logged(" ERROR net failed action=joinHotspot result=-25"))
    #expect(fixture.toolCalls == [Self.joinCall("en0", Self.hotspot)])
    #expect(!harness.lines.contains { $0.contains("Zoë") || $0.contains("iPhone") })
    #expect(harness.collector.events.isEmpty)
    withExtendedLifetime(harness.interpreter) {}
  }

  @Test func emptyToolOutputSucceedsAndWithoutLocationTheRadioNeverJoins() async {
    let fixture = Fixture()
    #expect(await fixture.join(Self.hotspot) == .succeeded)
    #expect(fixture.toolCalls == [Self.joinCall("en0", Self.hotspot)])
    #expect(!fixture.radio.calls.contains { $0.kind == .joinSaved })
    #expect(fixture.radio.writes.isEmpty)
  }

  struct Refusal: Sendable, CustomTestStringConvertible {
    let label: String
    let name: String
    let interface: String?
    let admin: AdminRequirements?
    let known: [String]?
    let code: WiFiController.Code

    var testDescription: String { label }

    init(
      _ label: String, name: String = WiFiControllerJoinTests.hotspot, interface: String? = "en0",
      admin: AdminRequirements? = AdminRequirements(power: false, association: false),
      known: [String]? = [WiFiControllerJoinTests.hotspot], code: WiFiController.Code
    ) {
      self.label = label
      self.name = name
      self.interface = interface
      self.admin = admin
      self.known = known
      self.code = code
    }
  }

  static let refusals: [Refusal] = [
    Refusal("empty name", name: "", code: .invalidName),
    Refusal("33-byte name", name: String(repeating: "a", count: 33), code: .invalidName),
    Refusal("bell in the name", name: "Test\u{07}iPhone", code: .invalidName),
    Refusal("no interface", interface: nil, code: .invalidInterface),
    Refusal("tunnel interface", interface: "utun3", code: .invalidInterface),
    Refusal("interface with an option", interface: "en0 -x", code: .invalidInterface),
    Refusal(
      "association needs an administrator", admin: AdminRequirements(power: false, association: true),
      code: .adminRequired),
    Refusal("admin flags unreadable", admin: nil, code: .adminRequired),
    Refusal("not a known network", known: ["Home", "Office"], code: .notKnown),
    Refusal("known networks unreadable", known: nil, code: .notKnown),
  ]

  @Test(arguments: refusals)
  func everyRefusalComesBeforeAnyWrite(_ refusal: Refusal) async {
    var script = FakeWiFiRadio.Script()
    script.interface = refusal.interface
    script.admin = refusal.admin
    let fixture = Fixture(script, known: refusal.known, location: true)
    #expect(await fixture.join(refusal.name) == .failed(code: refusal.code.rawValue))
    #expect(fixture.radio.writes.isEmpty)
    #expect(fixture.toolCalls.isEmpty)
    #expect(fixture.tools.timeouts.isEmpty)
  }

  static let refusedProfiles: [SavedProfileSecurity?] =
    CoreWLANRadio.refusedSecurityValues.sorted().map { .security(rawValue: $0) } + [.absent, nil]

  @Test func theRefusedSavedSecuritiesAreOpenOWEOWETransitionAndUnknown() {
    #expect(CoreWLANRadio.refusedSecurityValues == [0, 14, 15, Int.max])
    #expect(!CoreWLANRadio.acceptsSaved(nil))
    #expect(!CoreWLANRadio.acceptsSaved(.absent))
    for rawValue in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13] {
      #expect(CoreWLANRadio.acceptsSaved(.security(rawValue: rawValue)), "\(rawValue)")
    }
  }

  @Test(arguments: refusedProfiles, [true, false])
  func aSavedProfileThatIsNotSecureRefusesBothJoinPaths(_ saved: SavedProfileSecurity?, _ location: Bool) async {
    var script = FakeWiFiRadio.Script()
    script.saved = saved
    let fixture = Fixture(script, location: location)
    #expect(await fixture.join(Self.hotspot) == .failed(code: WiFiController.Code.insecureProfile.rawValue))
    #expect(fixture.radio.calls.contains(.savedSecurity(interface: "en0", ssid: Self.hotspot)))
    #expect(fixture.radio.writes.isEmpty)
    #expect(fixture.toolCalls.isEmpty)
    #expect(fixture.tools.timeouts.isEmpty)
  }

  @Test(arguments: [2, 4, 11, 13])
  func aSecureSavedProfileReachesTheSavedJoinAndThenTheTool(_ rawValue: Int) async {
    var script = FakeWiFiRadio.Script()
    script.saved = .security(rawValue: rawValue)
    script.joinResult = .failure(.notFound)
    let located = Fixture(script, location: true)
    #expect(await located.join(Self.hotspot) == .succeeded)
    #expect(located.radio.writes == [.joinSaved(interface: "en0", ssid: Self.hotspot)])
    #expect(located.toolCalls == [Self.joinCall("en0", Self.hotspot)])
    let unlocated = Fixture(script, location: false)
    #expect(await unlocated.join(Self.hotspot) == .succeeded)
    #expect(unlocated.toolCalls == [Self.joinCall("en0", Self.hotspot)])
  }

  @Test func theProfileIsReadOnceForTheKnownEntrysOwnBytesBeforeAnyWrite() async {
    let listed = "Zoe\u{308}’s iPhone"
    let fixture = Fixture(known: [listed], location: true)
    #expect(await fixture.join("Zo\u{EB}’s iPhone") == .succeeded)
    let reads = fixture.radio.calls.compactMap { call -> String? in
      if case .savedSecurity(_, let ssid) = call { ssid } else { nil }
    }
    #expect(reads.map { Array($0.utf8) } == [Array(listed.utf8)])
    #expect(fixture.radio.calls.map(\.kind) == [.interfaceName, .adminRequirements, .savedSecurity, .joinSaved])
  }

  @Test func aPowerAdministratorFlagAloneDoesNotBlockAJoin() async {
    var script = FakeWiFiRadio.Script()
    script.admin = AdminRequirements(power: true, association: false)
    let fixture = Fixture(script)
    #expect(await fixture.join(Self.hotspot) == .succeeded)
    #expect(fixture.toolCalls == [Self.joinCall("en0", Self.hotspot)])
  }

  @Test func withLocationASavedJoinSucceedsWithoutTheTool() async {
    let fixture = Fixture(location: true)
    #expect(await fixture.join(Self.hotspot) == .succeeded)
    #expect(fixture.radio.writes == [.joinSaved(interface: "en0", ssid: Self.hotspot)])
    #expect(fixture.toolCalls.isEmpty)
    #expect(fixture.tools.timeouts.isEmpty)
  }

  struct BudgetCase: Sendable, CustomTestStringConvertible {
    let label: String
    let error: RadioError
    let seconds: Double
    let toolTimeout: Double?

    var testDescription: String { label }
  }

  static let budgetCases: [BudgetCase] = [
    BudgetCase(label: "not found after 2 s", error: .notFound, seconds: 2, toolTimeout: 10),
    BudgetCase(label: "failed after 5 s", error: .coreWLAN(code: -3930), seconds: 5, toolTimeout: 7),
    BudgetCase(label: "timed out after 10 s", error: .timedOut, seconds: 10, toolTimeout: nil),
  ]

  @Test(arguments: budgetCases)
  func aFailedSavedJoinFallsBackOnlyWithinTheBudget(_ budget: BudgetCase) async {
    var script = FakeWiFiRadio.Script()
    script.joinResult = .failure(budget.error)
    script.seconds = [.joinSaved: budget.seconds]
    let fixture = Fixture(script, location: true)
    let outcome = await fixture.join(Self.hotspot)
    #expect(fixture.radio.writes == [.joinSaved(interface: "en0", ssid: Self.hotspot)])
    if let toolTimeout = budget.toolTimeout {
      #expect(outcome == .succeeded)
      #expect(fixture.tools.timeouts == [toolTimeout])
      #expect(fixture.toolCalls == [Self.joinCall("en0", Self.hotspot)])
    } else {
      #expect(outcome == .failed(code: WiFiController.Code.budget.rawValue))
      #expect(fixture.tools.timeouts.isEmpty)
      #expect(fixture.toolCalls.isEmpty)
    }
  }

  @Test func withoutLocationTheFallbackRunsAtOnceWithTheFullToolBound() async {
    let fixture = Fixture(location: false)
    #expect(await fixture.join(Self.hotspot) == .succeeded)
    #expect(fixture.tools.timeouts == [12])
    #expect(fixture.radio.writes.isEmpty)
  }

  @Test func slowChecksSkipTheSavedJoinThatNoLongerFitsAndShortenTheTool() async {
    var script = FakeWiFiRadio.Script()
    script.seconds = [.interfaceName: 3, .adminRequirements: 2]
    let fixture = Fixture(script, location: true)
    #expect(await fixture.join(Self.hotspot) == .succeeded)
    #expect(fixture.radio.writes.isEmpty)
    #expect(fixture.tools.timeouts == [7])
    #expect(fixture.toolCalls == [Self.joinCall("en0", Self.hotspot)])
  }

  @Test func checksThatUseTheWholeBudgetEndInABudgetFailureWithNoWrite() async {
    var script = FakeWiFiRadio.Script()
    script.seconds = [.interfaceName: 5, .adminRequirements: 5]
    let fixture = Fixture(script, location: true)
    #expect(await fixture.join(Self.hotspot) == .failed(code: WiFiController.Code.budget.rawValue))
    #expect(fixture.radio.writes.isEmpty)
    #expect(fixture.toolCalls.isEmpty)
  }

  @Test func aKnownNetworksReadThatOutlivesItsBoundRefusesWithNoWrite() async {
    let release = DispatchSemaphore(value: 0)
    let clock = FakeClock()
    let radio = FakeWiFiRadio(clock: clock)
    let tools = ToolFactoryRecorder()
    let controller = WiFiController(
      radio: radio,
      knownNetworks: {
        _ = release.wait(timeout: .now() + 5)
        return [Self.hotspot]
      },
      locationAuthorized: { true }, clock: clock, makeTools: tools.make, readTimeoutSeconds: 0.1)
    let outcome = await OffPool.bounded(seconds: 3) { controller.joinHotspot(Self.hotspot) }
    release.signal()
    #expect(outcome == .failed(code: WiFiController.Code.notKnown.rawValue))
    #expect(radio.writes.isEmpty)
    #expect(tools.tool.calls.isEmpty)
  }

  @Test func theKnownEntrysOwnBytesReachTheRadioAndTheTool() async {
    let stored = "Zo\u{EB}’s iPhone"
    let listed = "Zoe\u{308}’s iPhone"
    #expect(stored == listed)
    #expect(Array(stored.utf8) != Array(listed.utf8))
    var script = FakeWiFiRadio.Script()
    script.joinResult = .failure(.notFound)
    let fixture = Fixture(script, known: ["Home", listed], location: true)
    #expect(await fixture.join(stored) == .succeeded)
    let joined = fixture.radio.writes.compactMap { call -> String? in
      if case .joinSaved(_, let ssid) = call { ssid } else { nil }
    }
    #expect(joined.map { Array($0.utf8) } == [Array(listed.utf8)])
    #expect(fixture.toolCalls.map { Array($0.arguments[2].utf8) } == [Array(listed.utf8)])
  }

  struct OutputCase: Sendable, CustomTestStringConvertible {
    let label: String
    let outcome: ToolOutcome
    let expected: EffectOutcome

    var testDescription: String { label }

    static func printed(_ text: String, exit: Int32 = 0, _ expected: EffectOutcome) -> OutputCase {
      OutputCase(
        label: text.isEmpty ? "empty, exit \(exit)" : text,
        outcome: .finished(exitCode: exit, stdout: text, stderr: ""), expected: expected)
    }
  }

  static func failed(_ code: WiFiController.Code) -> EffectOutcome {
    .failed(code: code.rawValue)
  }

  static let outputs: [OutputCase] = [
    .printed("", .succeeded),
    .printed("", exit: 1, .succeeded),
    OutputCase(
      label: "only a line break", outcome: .finished(exitCode: 0, stdout: "\n", stderr: " \n"), expected: .succeeded),
    .printed("Could not find network X.", failed(.notFound)),
    .printed("Failed to join network X.", failed(.joinFailed)),
    .printed("Command requires admin privileges.", failed(.adminRequired)),
    .printed("You cannot join a network when Wi-Fi power is off.", failed(.wifiOff)),
    .printed("something else", failed(.toolFailed)),
    OutputCase(
      label: "on stderr", outcome: .finished(exitCode: 0, stdout: "", stderr: "Could not find network X.\n"),
      expected: failed(.notFound)),
    OutputCase(label: "timed out", outcome: .timedOut, expected: .timedOut),
    OutputCase(label: "launch failed", outcome: .launchFailed("x"), expected: failed(.toolFailed)),
  ]

  @Test(arguments: outputs)
  func theToolOutputMapsToACodeOnly(_ output: OutputCase) {
    #expect(WiFiController.joinOutcome(output.outcome) == output.expected)
  }

  @Test func everyToolCallCarriesTheVerbTheInterfaceAndTheNameAndNothingElse() async {
    let listed = "Zoe\u{308}’s iPhone"
    var failedSaved = FakeWiFiRadio.Script()
    failedSaved.joinResult = .failure(.notFound)
    var otherInterface = FakeWiFiRadio.Script()
    otherInterface.interface = "en12"
    let fixtures = [
      Fixture(),
      Fixture(failedSaved, location: true),
      Fixture(otherInterface),
      Fixture(failedSaved, known: [listed], location: true),
    ]
    let names = [Self.hotspot, Self.hotspot, Self.hotspot, "Zo\u{EB}’s iPhone"]
    for (fixture, name) in zip(fixtures, names) {
      _ = await fixture.join(name)
    }
    let calls = fixtures.flatMap(\.toolCalls)
    #expect(calls.count == 4)
    for call in calls {
      #expect(call.executable == WiFiController.networksetup)
      #expect(call.arguments.count == 3)
      #expect(call.arguments.first == WiFiController.joinVerb)
      #expect(!call.arguments.contains { $0.lowercased().contains("password") })
    }
    #expect(calls.map { $0.arguments[1] } == ["en0", "en0", "en12", "en0"])
  }

  @Test(arguments: ["en0", "en1", "en12"])
  func aWiFiInterfaceNameIsEnAndDigits(_ name: String) {
    #expect(WiFiController.isValidInterface(name))
  }

  static let notInterfaceNames = [
    "", "en", "utun3", "en0 -x", "EN0", "en0\n", "en-1", "aen0", "en٣", "bridge0", "en0x", "enx", "en:0",
  ]

  @Test(arguments: notInterfaceNames)
  func anythingElseIsNotAWiFiInterfaceName(_ name: String) {
    #expect(!WiFiController.isValidInterface(name))
  }
}
