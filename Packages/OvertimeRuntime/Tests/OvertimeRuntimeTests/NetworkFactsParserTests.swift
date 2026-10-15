import Foundation
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing
import os

struct SyntheticNetworkCase: Sendable, CustomTestStringConvertible {
  let name: String
  let expected: NetworkFacts

  var testDescription: String { name }

  init(_ name: String, wifi: String? = "en0", onHotspot: Bool?, wired: Bool, powered: Bool?) {
    self.name = name
    expected = NetworkFacts(wifiInterface: wifi, onHotspot: onHotspot, wired: wired, wifiPowered: powered)
  }

  static let all: [SyntheticNetworkCase] = [
    SyntheticNetworkCase("hotspotOnly", onHotspot: true, wired: false, powered: true),
    SyntheticNetworkCase("hotspotWithVPN", onHotspot: true, wired: false, powered: true),
    SyntheticNetworkCase("usbTethering", onHotspot: false, wired: true, powered: true),
    SyntheticNetworkCase("wifiOff", onHotspot: nil, wired: false, powered: false),
    SyntheticNetworkCase("noWifi", wifi: nil, onHotspot: nil, wired: false, powered: nil),
    SyntheticNetworkCase("linkLocal", onHotspot: false, wired: false, powered: true),
    SyntheticNetworkCase("routerMismatch", onHotspot: false, wired: false, powered: true),
    SyntheticNetworkCase("wrongMask", onHotspot: false, wired: false, powered: true),
    SyntheticNetworkCase("hostOutOfRange", onHotspot: false, wired: false, powered: true),
    SyntheticNetworkCase("bridgeOnly", onHotspot: false, wired: false, powered: true),
    SyntheticNetworkCase("emptyStore", onHotspot: nil, wired: false, powered: nil),
    SyntheticNetworkCase("ethernetTypedVirtualName", onHotspot: nil, wired: false, powered: true),
    SyntheticNetworkCase("bridgeTypedHardwareName", onHotspot: nil, wired: false, powered: true),
  ]
}

enum NetworkFixturePrivacy {
  static let storeKeyShapes = [
    #"^State:/Network/Interface$"#,
    #"^State:/Network/Interface/[a-z]+[0-9]+/IPv4$"#,
    #"^State:/Network/Interface/[a-z]+[0-9]+/AirPort$"#,
    #"^State:/Network/Service/service-[0-9]+/IPv4$"#,
  ]
  static let bsdNameShape = #"^[a-z]+[0-9]+$"#
  static let interfaceTypes: Set<String> = [
    "IEEE80211", "Ethernet", "Bridge", "FireWire", "Bond", "VLAN", "Bluetooth", "PPP", "IPSec", "L2TP", "6to4", "WWAN",
  ]
  static let hardwareAddressShape = #"[0-9A-Fa-f]{1,2}([:-][0-9A-Fa-f]{1,2}){5}"#
  static let uuidShape = #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#
  static let dateShape = #"[0-9]{4}-[0-9]{2}-[0-9]{2}"#
  static let dottedQuadShape = #"[0-9]{1,3}(\.[0-9]{1,3}){3}"#
  static let forbiddenWords = ["SSID", "BSSID", "NetworkSignature", "ARPResolved"]

  static func matches(_ text: String, _ pattern: String) -> [String] {
    var found: [String] = []
    var rest = text[...]
    while let range = rest.range(of: pattern, options: .regularExpression) {
      found.append(String(rest[range]))
      rest = rest[range.upperBound...]
    }
    return found
  }

  static func octets(_ quad: String) -> [Int]? {
    let parts = quad.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
    guard parts.count == 4, parts.allSatisfy({ ($0 ?? -1) >= 0 && ($0 ?? 256) <= 255 }) else { return nil }
    return parts.compactMap { $0 }
  }

  static func isAllowedAddress(_ quad: String) -> Bool {
    guard let o = octets(quad) else { return false }
    let redacted = o[0] == 10 && o[1] == 0 && o[2] == 0 && (1...254).contains(o[3])
    return redacted || (o[0] == 169 && o[1] == 254) || (o[0] == 172 && o[1] == 20 && o[2] == 10 && o[3] < 16)
  }

  static func isMask(_ quad: String) -> Bool {
    guard let o = octets(quad) else { return false }
    let bits = o.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    return bits != 0 && (~bits & (~bits &+ 1)) == 0
  }

  static func cases(_ object: [String: Any]) -> [String: [String: Any]] {
    if object["interfaces"] != nil { return ["capture": object] }
    return object.compactMapValues { $0 as? [String: Any] }
  }

  static func problems(inFixtureText text: String) -> [String] {
    guard let data = text.data(using: .utf8),
      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return ["the fixture is not a JSON object"] }
    var problems: [String] = []
    var masks: Set<String> = []
    let cases = cases(object)
    if cases.isEmpty { problems.append("the fixture holds no case") }
    for (name, entry) in cases.sorted(by: { $0.key < $1.key }) {
      problems += Self.problems(inCase: entry, named: name, masks: &masks)
    }
    for word in forbiddenWords where text.contains(word) {
      problems.append("the text carries \(word)")
    }
    for (label, shape) in [("hardware address", hardwareAddressShape), ("UUID", uuidShape), ("date", dateShape)] {
      for token in matches(text, shape) {
        problems.append("the text carries a \(label) shape: \(token)")
      }
    }
    for quad in matches(text, dottedQuadShape) where !isAllowedAddress(quad) && !masks.contains(quad) {
      problems.append("the text carries an address outside the documentation ranges: \(quad)")
    }
    return problems
  }

  static func problems(inCase entry: [String: Any], named name: String, masks: inout Set<String>) -> [String] {
    var problems: [String] = []
    guard let interfaces = entry["interfaces"] as? [[String: Any]], let store = entry["store"] as? [String: Any],
      Set(entry.keys) == ["interfaces", "store"]
    else { return ["\(name): not in the capture shape"] }
    for interface in interfaces {
      guard Set(interface.keys) == ["bsdName", "type"], let bsd = interface["bsdName"] as? String,
        let type = interface["type"] as? String
      else {
        problems.append("\(name): an interface entry is not bsdName and type")
        continue
      }
      if matches(bsd, bsdNameShape).isEmpty { problems.append("\(name): interface name \(bsd)") }
      if !interfaceTypes.contains(type) { problems.append("\(name): interface type \(type)") }
    }
    for (key, value) in store {
      if !storeKeyShapes.contains(where: { !matches(key, $0).isEmpty }) {
        problems.append("\(name): store key \(key)")
      }
      guard let fields = value as? [String: Any] else {
        problems.append("\(name): \(key) is not a dictionary")
        continue
      }
      for (field, fieldValue) in fields {
        guard NetworkFactsParser.allowedKeys.contains(field) else {
          problems.append("\(name): \(key) carries \(field)")
          continue
        }
        problems += Self.problems(inField: field, value: fieldValue, at: "\(name): \(key)", masks: &masks)
      }
    }
    return problems
  }

  static func problems(inField field: String, value: Any, at place: String, masks: inout Set<String>) -> [String] {
    switch field {
    case "Interfaces", "InterfaceName":
      let names = (value as? [String]) ?? (value as? String).map { [$0] } ?? []
      if names.isEmpty { return ["\(place) \(field) is empty"] }
      return names.filter { matches($0, bsdNameShape).isEmpty }.map { "\(place) \(field) \($0)" }
    case "Addresses", "Router":
      let quads = (value as? [String]) ?? (value as? String).map { [$0] } ?? []
      if quads.isEmpty { return ["\(place) \(field) is empty"] }
      return quads.filter { !isAllowedAddress($0) }.map { "\(place) \(field) \($0)" }
    case "SubnetMasks":
      let quads = (value as? [String]) ?? []
      masks.formUnion(quads)
      return quads.filter { !isMask($0) }.map { "\(place) mask \($0)" }
    default:
      return value is Bool ? [] : ["\(place) \(field) is not a Bool"]
    }
  }
}

struct NetworkFactsParserTests {
  static let dockedFacts = NetworkFacts(wifiInterface: "en0", onHotspot: false, wired: true, wifiPowered: true)

  static func fixtureText(_ name: String) throws -> String {
    try String(contentsOf: try NetworkFixture.url(name), encoding: .utf8)
  }

  @Test(arguments: SyntheticNetworkCase.all)
  func eachSyntheticCaseParsesAsTheHotspotAndWiredRulesSay(_ entry: SyntheticNetworkCase) throws {
    let fixture = try #require(try NetworkFixture.synthetic()[entry.name], "no synthetic case \(entry.name)")
    #expect(fixture.facts == entry.expected)
  }

  @Test func theCaseTableCoversEverySyntheticFixtureAndNoOther() throws {
    let names = Set(try NetworkFixture.synthetic().keys)
    #expect(names.count == 13)
    #expect(names == Set(SyntheticNetworkCase.all.map(\.name)))
  }

  @Test func theFixtureFolderHoldsTheCaptureAndTheSyntheticCasesUnderUndatedNames() throws {
    let urls = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: "network") ?? []
    let names = urls.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    #expect(names == ["capture", "synthetic"])
    for name in names {
      #expect(NetworkFixturePrivacy.matches(name, NetworkFixturePrivacy.dateShape).isEmpty)
    }
  }

  @Test(arguments: ["capture", "synthetic"])
  func eachNetworkFixtureCarriesNothingPrivate(_ name: String) throws {
    let text = try Self.fixtureText(name)
    #expect(!text.isEmpty)
    #expect(NetworkFixturePrivacy.problems(inFixtureText: text) == [])
  }

  static let cleanFixture = """
    {"interfaces": [{"bsdName": "en0", "type": "IEEE80211"}], "store": {
    "State:/Network/Interface/en0/IPv4": {"Addresses": ["172.20.10.3"], "SubnetMasks": ["255.255.255.240"]},
    "State:/Network/Service/service-1/IPv4": {"InterfaceName": "en0", "Router": "172.20.10.1"},
    "State:/Network/Interface/en0/AirPort": {"Power Status": true}}}
    """

  static func planted(_ old: String, _ new: String) -> String {
    cleanFixture.replacingOccurrences(of: old, with: new)
  }

  static var plantedLeaks: [(String, String)] {
    let hardware = Array(repeating: "0a", count: 6).joined(separator: ":")
    let uuid = [8, 4, 4, 4, 12].map { String(repeating: "c", count: $0) }.joined(separator: "-")
    let year = String(repeating: "1", count: 4)
    let power = "\"Power Status\": true"
    return [
      ("hardware address in a field", planted(power, power + ", \"Note\": \"\(hardware)\"")),
      ("hardware address as a name", planted("\"bsdName\": \"en0\"", "\"bsdName\": \"\(hardware)\"")),
      ("service UUID", planted("service-1", uuid)),
      ("public address", planted("172.20.10.3", "203.0.113.7")),
      ("private address the redactor never writes", planted("172.20.10.3", "10.20.30.40")),
      ("router on another private network", planted("\"Router\": \"172.20.10.1\"", "\"Router\": \"10.0.1.1\"")),
      ("router outside the ranges", planted("\"Router\": \"172.20.10.1\"", "\"Router\": \"192.0.2.1\"")),
      ("SSID key", planted("\"Power Status\": true", "\"Power Status\": true, \"SSID_STR\": \"x\"")),
      ("network signature", planted("\"Router\"", "\"NetworkSignature\": \"x\", \"Router\"")),
      ("date", planted("service-1", "service-\(year)-11-11")),
      ("global key", planted("State:/Network/Service/service-1/IPv4", "State:/Network/Global/IPv4")),
      ("named interface", planted("\"InterfaceName\": \"en0\"", "\"InterfaceName\": \"Office VPN\"")),
      ("unknown type", planted("IEEE80211", "Office")),
      ("not a mask", planted("255.255.255.240", "255.0.255.0")),
    ]
  }

  @Test func thePrivacyGuardPassesTheCleanControlAndRejectsEachPlantedLeak() {
    #expect(NetworkFixturePrivacy.problems(inFixtureText: Self.cleanFixture) == [])
    for (label, text) in Self.plantedLeaks {
      #expect(!NetworkFixturePrivacy.problems(inFixtureText: text).isEmpty, "the guard missed the planted \(label)")
    }
  }

  @Test func theRedactedCaptureOfThisMacReadsWiredOnWiFiEn0AndNotOnTheHotspot() throws {
    let facts = try NetworkFixture.capture().facts
    #expect(facts == Self.dockedFacts)
    #expect(facts.autoHotspot == nil)
  }

  @Test func theLiveEngineCarriesTheMonitoredCaptureIntoTheReducerAndStandsDownOnTheWiredDock() async throws {
    let capture = try NetworkFixture.capture()
    let monitor = NetworkMonitor(source: FakeNetworkStore(capture), knownNetworks: { nil })
    #expect(monitor.start())
    let temp = try TempDirectory()
    let paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path], homeDirectory: temp.path)
    let recorder = HoldRecorder(stateFile: paths.stateFile(.live))
    let lids = OSAllocatedUnfairLock<[Bool?]>(initialState: [])
    let port = ClosureNetworkPort(onFacts: { lidClosed in
      lids.withLock { $0.append(lidClosed) }
      return monitor.facts(lidClosed: lidClosed)
    })
    let engine = try Composition.makeLiveEngine(
      paths: paths,
      settings: Settings(transcriptRoots: [temp.path + "/projects"]),
      ports: LivePorts(
        assertions: FakeAssertionPort(), tools: FakeToolPort(), clamshell: FakeClamshellPort(recorder: recorder),
        stateFile: paths.stateFile(.live), makeSentinel: { [recorder] in FakeSentinelPort(recorder: recorder) },
        network: port),
      environment: [:],
      homeDirectory: temp.path,
      once: true,
      clock: FakeClock(),
      externalDisplays: { 0 }
    )
    await engine.tick()
    let state = await engine.state
    #expect(lids.withLock { $0 } == [RegistryReader().lidClosed()])
    #expect(state.network.facts == capture.facts)
    #expect(state.network.facts == Self.dockedFacts)
    #expect(NetworkFailover.readiness(state, settings: Settings(hotspot: "Test iPhone")) == .off(.wired))
  }
}
