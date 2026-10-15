import Foundation
import Testing

@testable import OvertimeAppSupport

struct DiagnosticsPowerRedactorTests {
  struct Case: Sendable, CustomTestStringConvertible {
    let input: String
    let expected: String

    init(_ input: String, _ expected: String) {
      self.input = input
      self.expected = expected
    }

    var testDescription: String {
      input
    }
  }

  static let tab = "\t"
  static let carriageReturn = "\r"
  static let address = "A4-5E-60-1B-2C-3D"
  static let uuid = "0FA1B2C3-D4E5-4F60-8A1B-2C3D4E5F6071"
  static let keyboard = "Lorem Keyboard K9"
  static let hub = "Ipsum Hub 7"
  static let microphone = "AppleUSBAudioEngine:Dolor Audio:Dolor Mic USB:14200000:1"
  static let tickle = "com.apple.iohideventsystem.queue.tickle serviceID:100000abc service:ExampleHIDKeyboardDriver"
  static let kernelRow =
    "   id=501  level=255 0x4=USB creat=1/1/26, 9:00 description=com.apple.usb.externaldevice.01100000"
  static let acks = "2026-09-27 10:00:00 +0200 Kernel Client Acks  " + tab + "Delays to Sleep notifications: "
  static let idle = "PreventUserIdleSystemSleep"

  static func redact(_ text: String) -> String {
    DiagnosticsPowerRedactor.redact(text)
  }

  static func same(_ text: String) -> Case {
    Case(text, text)
  }

  static func audioName(_ device: String, _ kind: String = "preventuseridlesleep") -> String {
    "\"com.apple.audio.\(device).context.\(kind)\""
  }

  static func row(_ pid: Int, _ process: String, _ type: String, _ name: String) -> String {
    "   pid \(pid)(\(process)): [0x0000000100000001] 00:00:10 \(type) named: \"\(name)\"  "
  }

  static let addresses = [
    Case(address, "<address>"),
    Case("a4:5e:60:1b:2c:3d", "<address>"),
    Case("A4:5E-60:1b-2C:3D", "<address>"),
    Case("A4-5E-60-1B-2C-3D-4E-5F", "<address>"),
    Case("x \(address) y a4:5e:60:1b:2c:3d z", "x <address> y <address> z"),
    Case("\(address)\n\(address)", "<address>\n<address>"),
    Case("g\(address)g", "g<address>g"),
    Case("\(address)-4EF", "<address>-4EF"),
    Case("123-\(address)", "123-<address>"),
    Case("\(address):input", "<address>:input"),
    Case("\(address):adapter", "<address>:adapter"),
    Case("\(address).\(address)", "<address>.<address>"),
  ]

  static let notAddresses = [
    "A4-5E-60-1B-2C", "12:34:56", "2026-09-27 10:00:00 +0200", "FA4-5E-60-1B-2C-3D", "A4-5E-60-1B-2C-3D4",
    "1-2-3-4-5-6", "G4-5E-60-1B-2C-3D", "A4-5E-60-1B-2C-3G", "A4_5E_60_1B_2C_3D", "A4 5E 60 1B 2C 3D", "A45E601B2C3D",
    "A4--5E-60-1B-2C-3D", "A4-5E-60-1B-2C-", "00:00:10  id:0x0xd00008123",
  ]

  static let uuids = [
    Case(uuid, "<uuid>"),
    Case(uuid.lowercased(), "<uuid>"),
    Case("UUID: \(uuid)", "UUID: <uuid>"),
    Case("DASActivity:1:com.example.sync.\(uuid)", "DASActivity:1:com.example.sync.<uuid>"),
    Case("\(uuid) \(uuid)", "<uuid> <uuid>"),
    Case("g\(uuid)g", "g<uuid>g"),
    Case("\(uuid)-AB", "<uuid>-AB"),
    Case("\(uuid)\n\(uuid)\n", "<uuid>\n<uuid>\n"),
    Case("\(uuid) \(address)", "<uuid> <address>"),
  ]

  static let notUUIDs = [
    "0FA1B2C3-D4E5-4F60-8A1B-2C3D4E5F607", "10FA1B2C3-D4E5-4F60-8A1B-2C3D4E5F6071",
    "0FA1B2C3-D4E5-4F60-8A1B-2C3D4E5F60710", "0FA1B2C3-D4E5-4F60-8A1B_2C3D4E5F6071",
    "0FA1B2C3-D4E5-4F60-8A1G-2C3D4E5F6071", "0FA1B2C3D4E54F608A1B2C3D4E5F6071", "0FA1B2C3-D4E5-4F60-8A1B",
    "0FA1B2C-3D4E5-4F60-8A1B-2C3D4E5F6071",
  ]

  static let products = [
    Case(
      "named: \"\(tickle) product:\(keyboard) eventType:3\"  ", "named: \"\(tickle) product:<device> eventType:3\"  "),
    Case("x \"a product:\(keyboard)\" y", "x \"a product:<device>\" y"),
    Case("product:\(keyboard)", "product:<device>"),
    Case("product:\(keyboard)  " + tab, "product:<device>  " + tab),
    Case(
      "\"a product:\(keyboard) eventType:3\" \"b product:\(hub) eventType:11\"",
      "\"a product:<device> eventType:3\" \"b product:<device> eventType:11\""),
    Case("\"a product:\(keyboard)\" \"b eventType:3\"", "\"a product:<device> eventType:3\""),
    Case(
      "named: \"\(tickle) product:Ana 27\" Dock eventType:3\"  ", "named: \"\(tickle) product:<device> eventType:3\"  "),
    Case("named: \"\(tickle) product:Ana 27\" Dock\" 00:00:10", "named: \"\(tickle) product:<device>\" 00:00:10"),
    Case(
      "\"a product:Ana 27\" Dock eventType:3\" \"b product:\(hub) eventType:11\"",
      "\"a product:<device> eventType:3\" \"b product:<device> eventType:11\""),
    Case("product:Ana 27\" Dock eventType:3", "product:<device> eventType:3"),
    Case("named: \"\(tickle) product:Ana 27\" Dock eventType:3", "named: \"\(tickle) product:<device> eventType:3"),
    Case("named: \"\(tickle) product:Ana 27\"Dock", "named: \"\(tickle) product:<device>"),
    Case("product:(null) eventType:3", "product:<device> eventType:3"),
    Case("product:\(address) eventType:3", "product:<device> eventType:3"),
    Case("product:\(keyboard)\nproduct:\(hub)\n", "product:<device>\nproduct:<device>\n"),
    same("product: eventType:3"),
    same("product: eventType:"),
    same("\"a product:\""),
    same("product:"),
    same("product:  "),
    same("a byproduct of sleep"),
  ]

  static let owners = [
    Case("\(kernelRow) owner=\(hub)", "\(kernelRow) owner=<device>"),
    Case("owner=\(hub) " + tab, "owner=<device> " + tab),
    Case("owner=\(hub)\nowner=\(keyboard)\n", "owner=<device>\nowner=<device>\n"),
    Case("owner=a owner=b", "owner=<device>"),
    Case("owner=\(hub)" + carriageReturn + "\n", "owner=<device>" + carriageReturn + "\n"),
    Case("owner=\(uuid)", "owner=<device>"),
    same("owner="),
    same("owner=  "),
    same("the owner is \(hub)"),
  ]

  static let audio = [
    Case("named: " + audioName(microphone) + "  ", "named: " + audioName("<device>") + "  "),
    Case(tab + "Resources: audio-in \(microphone) ", tab + "Resources: audio-in <device> "),
    Case(tab + "Resources: audio-out \(microphone)", tab + "Resources: audio-out <device>"),
    Case("Resources: audio-in \(microphone)", "Resources: audio-in <device>"),
    Case(audioName(address + ":output"), audioName("<address>:output")),
    Case(tab + "Resources: audio-in \(address):input ", tab + "Resources: audio-in <address>:input "),
    Case(audioName(uuid), audioName("<uuid>")),
    Case(tab + "Resources: audio-in \(uuid) ", tab + "Resources: audio-in <uuid> "),
    Case(audioName("LoremVirtualMic_UID"), audioName("<device>")),
    Case(
      audioName(microphone, "a") + " " + audioName("LoremVirtualMic_UID", "b"),
      audioName("<device>", "a") + " " + audioName("<device>", "b")),
    Case(
      audioName("BuiltInSpeakerDevice", "a") + " " + audioName("LoremVirtualMic_UID", "b"),
      audioName("BuiltInSpeakerDevice", "a") + " " + audioName("<device>", "b")),
    Case("com.apple.audio.Lorem Mic.context.x", "com.apple.audio.<device>.context.x"),
    Case(audioName("\(uuid):LoremMic"), audioName("<device>")),
    Case(audioName("\(address):LoremMic"), audioName("<device>")),
    Case(audioName("\(address):inputs"), audioName("<device>")),
    Case(audioName("BuiltIn Lorem"), audioName("<device>")),
    Case(audioName("BuiltIn-Lorem"), audioName("<device>")),
    Case(audioName("LoremBuiltIn"), audioName("<device>")),
    Case(audioName("BuiltLoremDevice"), audioName("<device>")),
    Case("\"com.apple.audio.LoremMic.contexts\"", "\"com.apple.audio.<device>.contexts\""),
    same("\"net.example.apple.audio.LoremMic.context.x\""),
    Case("\"com.apple.audio.LoremMic.contex\"", "\"com.apple.audio.<device>\""),
    Case(
      audioName("AppleUSBAudioEngine:ACME:Ana \"Pro\" Mic:SN123:1"), audioName("<device>")),
    Case("\"com.apple.audio.ACME Mic SN123\" 00:00:10", "\"com.apple.audio.<device>\" 00:00:10"),
    Case("named: \"com.apple.audio.ACME:Ana \"Pro Mic:SN1", "named: \"com.apple.audio.<device>"),
    Case("com.apple.audio.ACME:Ana \"Pro Mic:SN1  " + tab, "com.apple.audio.<device>  " + tab),
    Case("com.apple.audio.ACME Mic SN123  " + tab, "com.apple.audio.<device>  " + tab),
    Case(
      "\"com.apple.audio.ACME Mic SN123\" " + audioName("LoremVirtualMic_UID"),
      "\"com.apple.audio.<device>com.apple.audio.<device>.context.preventuseridlesleep\""),
    same("\"com.apple.audio.context313\""),
    same("com.apple.audio.context7.preventuseridlesleep"),
    same("Resources audio-in Lorem Mic"),
    Case(audioName(address), audioName("<address>")),
    Case(audioName(address + ":input"), audioName("<address>:input")),
    Case(tab + "Resources: audio-in \(address) ", tab + "Resources: audio-in <address> "),
    Case(
      tab + "Resources: audio-in BuiltInMicrophoneDevice audio-out Lorem Mic", tab + "Resources: audio-in <device>"),
    Case("Resources: audio-out Lorem Mic audio-in BuiltInMicrophoneDevice", "Resources: audio-out <device>"),
    Case("  Resources: audio-out Lorem Mic", "  Resources: audio-out <device>"),
    Case(
      "\"com.apple.audio.context313.preventuseridlesleep\" " + audioName("LoremVirtualMic_UID"),
      "\"com.apple.audio.context313.preventuseridlesleep\" " + audioName("<device>")),
    same(audioName("BuiltInSpeakerDevice", "preventuseridledisplaysleep")),
    same(audioName("BuiltInMicrophoneDevice")),
    same(tab + "Resources: audio-out BuiltInSpeakerDevice "),
    same("\"com.apple.audio.context313.preventuseridlesleep\""),
    Case("\"com.apple.audio.Lorem\" then \".context.x\"", "\"com.apple.audio.<device>.context.x\""),
    same("\"com.apple.audio..context.x\""),
    same("Details: audio-in Lorem Mic"),
    same("named: \"plays audio-out Lorem Mic\""),
    same("see Resources: audio-in Lorem Mic"),
    same("Resources: video-in Lorem Cam"),
    same("Resources: audio-in "),
    same("Resources: audio-in   "),
  ]

  static let drivers = [
    Case(
      acks + "[ExampleWLANDriver driver is slow(msg: SetState to 0)(1108 ms)] "
        + "[\(hub) driver is slow(msg: WillChangeState to 0)(303 ms)] ",
      acks + "[<driver> driver is slow(msg: SetState to 0)(1108 ms)] "
        + "[<driver> driver is slow(msg: WillChangeState to 0)(303 ms)] "),
    Case("[a] [\(hub) driver is slow(x)]", "[a] [<driver> driver is slow(x)]"),
    Case("[ExampleDriver(ANS2) driver is slow(x)]", "[<driver> driver is slow(x)]"),
    Case(
      "[\(hub) driver is slow(x)]\n[\(keyboard) driver is slow(y)]",
      "[<driver> driver is slow(x)]\n[<driver> driver is slow(y)]"),
    Case("[\(hub) driver is slow]", "[<driver> driver is slow]"),
    Case("[\(hub) driver is slow", "[<driver> driver is slow"),
    Case("[\(hub) driver is slower(x)]", "[<driver> driver is slower(x)]"),
    same("[com.example.daemon is slow(3000 ms)]"),
    same("[\(hub) driver was slow(x)]"),
    same("[\(hub) driver is fast(x)]"),
    same("\(hub) driver is slow(x)"),
    same("[a] \(hub) driver is slow(x)"),
    same("[ driver is slow(x)]"),
    same("[a] driver is slow"),
  ]

  static let kept = [
    row(88, "ExampleMeet", "NoDisplaySleepAssertion", "ExampleMeet call"),
    "2026-09-27 10:00:00 +0200 Assertions          " + tab
      + "PID 88(ExampleMeet) Created NoDisplaySleepAssertion \"ExampleMeet call\" 00:00:00  id:0x0xd00008123 [System: kDisp]",
    " sleep                1 (sleep prevented by ExampleMeet, powerd)",
    " SleepDisabled" + tab + tab + "1",
    " hibernatefile        /var/vm/sleepimage",
    "\"com.apple.iohideventsystem.queue.tickle.nxevent service:IOHIDSystem pid:123 process:ExampleDock\"",
    "Kernel Assertions: 0x4=USB",
    kernelRow,
    "DriverReason:USB-C_plug - DriverDetails:",
    tab + "Created for PID: 3123. ",
    tab + "Timeout will fire in 271 secs Action=TimeoutActionRelease",
    "Wake from Deep Idle [CDNVA] : due to smc.sysState.Wake(0x1) USB2_wake/HID Activity Using AC (Charge:80%)",
    "PID 357(powerd) Created UserIsActive \"ExampleUSBHostHIDDevice:kIOHIDSystemActivityTickle NX_HARDWARE\"",
  ]

  static let table = [
    "2026-09-27 10:00:00 +0200 ",
    "Assertion status system-wide:",
    "   PreventUserIdleSystemSleep     1",
    "Listed by owning process:",
    row(77, "coreaudiod", idle, "com.apple.audio.\(address):input.context.preventuseridlesleep"),
    tab + "Created for PID: 3123. ",
    tab + "Resources: audio-in \(address):input ",
    row(77, "coreaudiod", idle, "com.apple.audio.\(microphone).context.preventuseridlesleep"),
    tab + "Resources: audio-in \(microphone) ",
    row(88, "ExampleMeet", "NoDisplaySleepAssertion", "ExampleMeet call \(uuid)"),
    row(99, "WindowServer", "UserIsActive", "\(tickle) product:\(keyboard) eventType:3"),
    tab + "Timeout will fire in 600 secs Action=TimeoutActionRelease",
    "Kernel Assertions: 0x4=USB",
    "\(kernelRow) owner=\(hub)",
    "\(kernelRow) owner=\(keyboard)",
  ]

  static let redactedTable = [
    "2026-09-27 10:00:00 +0200 ",
    "Assertion status system-wide:",
    "   PreventUserIdleSystemSleep     1",
    "Listed by owning process:",
    row(77, "coreaudiod", idle, "com.apple.audio.<address>:input.context.preventuseridlesleep"),
    tab + "Created for PID: 3123. ",
    tab + "Resources: audio-in <address>:input ",
    row(77, "coreaudiod", idle, "com.apple.audio.<device>.context.preventuseridlesleep"),
    tab + "Resources: audio-in <device> ",
    row(88, "ExampleMeet", "NoDisplaySleepAssertion", "ExampleMeet call <uuid>"),
    row(99, "WindowServer", "UserIsActive", "\(tickle) product:<device> eventType:3"),
    tab + "Timeout will fire in 600 secs Action=TimeoutActionRelease",
    "Kernel Assertions: 0x4=USB",
    "\(kernelRow) owner=<device>",
    "\(kernelRow) owner=<device>",
  ]

  static let settings = [
    "System-wide power settings:",
    " SleepDisabled" + tab + tab + "1",
    "Currently in use:",
    " standby              1",
    " hibernatefile        /var/vm/sleepimage",
    " sleep                1 (sleep prevented by ExampleMeet, powerd, coreaudiod)",
    " displaysleep         10 (display sleep prevented by ExampleMeet)",
    " lowpowermode         0",
  ]

  @Test func theTokensAreTheDocumentedOnes() {
    #expect(DiagnosticsPowerRedactor.addressToken == "<address>")
    #expect(DiagnosticsPowerRedactor.uuidToken == "<uuid>")
    #expect(DiagnosticsPowerRedactor.deviceToken == "<device>")
    #expect(DiagnosticsPowerRedactor.driverToken == "<driver>")
  }

  @Test func theFixturesHoldATabACarriageReturnAndTheirQuotes() {
    #expect(Array(Self.tab.utf8) == [9])
    #expect(Array(Self.carriageReturn.utf8) == [13])
    #expect(Self.table[4].utf8.filter { $0 == 34 }.count == 2)
    #expect(Self.table[6].utf8.first == 9)
    #expect(Self.address.utf8.count == 17)
    #expect(Self.uuid.utf8.count == 36)
    #expect(Self.table[4].hasSuffix("audio.A4-5E-60-1B-2C-3D:input.context.preventuseridlesleep\"  "))
    #expect(Self.table[4].hasPrefix("   pid 77(coreaudiod): [0x0000000100000001] 00:00:10 PreventUserIdleSystemSleep"))
  }

  @Test(arguments: addresses)
  func sixOrMoreHexPairsJoinedByColonsOrHyphensBecomeTheAddressToken(_ item: Case) {
    #expect(Self.redact(item.input) == item.expected)
  }

  @Test(arguments: notAddresses)
  func textThatIsNotAHardwareAddressIsKept(_ text: String) {
    #expect(Self.redact(text) == text)
  }

  @Test(arguments: uuids)
  func aUUIDBecomesTheUUIDToken(_ item: Case) {
    #expect(Self.redact(item.input) == item.expected)
  }

  @Test(arguments: notUUIDs)
  func textThatIsNotAUUIDIsKept(_ text: String) {
    #expect(Self.redact(text) == text)
  }

  @Test(arguments: products)
  func theValueAfterProductBecomesTheDeviceTokenUpToTheEventTypeTheQuoteOrTheEndOfTheLine(_ item: Case) {
    #expect(Self.redact(item.input) == item.expected)
  }

  @Test(arguments: owners)
  func theValueAfterOwnerBecomesTheDeviceTokenUpToTheEndOfTheLine(_ item: Case) {
    #expect(Self.redact(item.input) == item.expected)
  }

  @Test(arguments: audio)
  func anAudioDeviceIdentifierBecomesTheDeviceTokenUnlessItIsBuiltInOrAlreadyNeutral(_ item: Case) {
    #expect(Self.redact(item.input) == item.expected)
  }

  @Test(arguments: drivers)
  func theNameOfADriverThatWasSlowBecomesTheDriverToken(_ item: Case) {
    #expect(Self.redact(item.input) == item.expected)
  }

  @Test(arguments: kept)
  func processNamesAndTheRestOfALineAreKept(_ line: String) {
    #expect(Self.redact(line) == line)
    #expect(Self.redact(line + "\n") == line + "\n")
  }

  @Test func aWholeAssertionTableKeepsItsProcessesAndLosesItsAddressesUUIDsAndDeviceNames() {
    let input = Self.table.joined(separator: "\n") + "\n"
    let expected = Self.redactedTable.joined(separator: "\n") + "\n"
    let output = Self.redact(input)
    #expect(output == expected)
    for needle in [Self.address, Self.uuid, Self.keyboard, Self.hub, "Dolor"] {
      #expect(input.contains(needle), "the fixture must hold \(needle)")
      #expect(!output.contains(needle), "the output holds \(needle)")
    }
    for name in ["coreaudiod", "ExampleMeet", "WindowServer", Self.idle, "NoDisplaySleepAssertion"] {
      #expect(output.contains(name), "the output lost \(name)")
    }
    #expect(output.split(separator: "\n", omittingEmptySubsequences: false).count == Self.table.count + 1)
  }

  @Test func redactingTwiceChangesNothingMore() {
    let once = Self.redact(Self.table.joined(separator: "\n") + "\n")
    #expect(Self.redact(once) == once)
    for item in Self.addresses + Self.uuids + Self.products + Self.owners + Self.audio + Self.drivers {
      #expect(Self.redact(item.expected) == item.expected, "\(item.expected) changed again")
    }
  }

  @Test func powerSettingsWithNothingToReplaceComeBackByteForByte() {
    let text = Self.settings.joined(separator: "\n") + "\n"
    #expect(Array(Self.redact(text).utf8) == Array(text.utf8))
    #expect(text.contains("SleepDisabled\t\t1\n"))
  }

  @Test(arguments: ["", "\n", "\n\n", "a", "a\n", "\na", "a\n\nb", " \n\t\n"])
  func lineBreaksAndEmptyLinesAreKeptAsTheyAre(_ text: String) {
    #expect(Self.redact(text) == text)
  }

  @Test func aLineBreakEndsEveryValue() {
    let input = "owner=\(Self.hub)\nPID 88(ExampleMeet)\nproduct:\(Self.keyboard)\nPID 89(ExampleMeet)\n"
    #expect(Self.redact(input) == "owner=<device>\nPID 88(ExampleMeet)\nproduct:<device>\nPID 89(ExampleMeet)\n")
    let audio = "Resources: audio-in \(Self.microphone)\nPID 90(ExampleMeet)"
    #expect(Self.redact(audio) == "Resources: audio-in <device>\nPID 90(ExampleMeet)")
    let name = "com.apple.audio.Lorem Mic\n.context.x"
    #expect(Self.redact(name) == "com.apple.audio.<device>\n.context.x")
    let driver = "[\(Self.hub)\n driver is slow(x)]"
    #expect(Self.redact(driver) == driver)
  }
}
