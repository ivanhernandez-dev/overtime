import Foundation
import OvertimeHelperCore
import Testing

struct HelperMachineTests {
  typealias Call = FakeHelperSystem.Call

  static let ownedSet: [Call] = [
    .readSleepDisabled, .recordWrite(owns: true, prior: false), .writeSleepDisabled(true), .readSleepDisabled,
  ]

  func make(
    sleepDisabled: Bool? = false, lid: Bool? = true, stored: HelperRecordRead = .missing
  ) -> (machine: HelperMachine, fake: FakeHelperSystem) {
    let fake = FakeHelperSystem(sleepDisabled: sleepDisabled, lid: lid, stored: stored)
    return (HelperMachine(system: fake, record: fake, log: fake, clock: fake), fake)
  }

  func owned(lid: Bool? = true) -> (machine: HelperMachine, fake: FakeHelperSystem) {
    let pair = make(lid: lid)
    #expect(pair.machine.set().code == .owned)
    pair.fake.forget()
    return pair
  }

  func alreadyOn() -> (machine: HelperMachine, fake: FakeHelperSystem) {
    let pair = make(sleepDisabled: true)
    #expect(pair.machine.set().code == .alreadyOn)
    pair.fake.forget()
    return pair
  }

  @Test func setRecordsOwnershipBeforeItSetsSleepDisabledAndThenVerifies() {
    let (machine, fake) = make()
    #expect(machine.set() == HelperReply(code: .owned, message: "owned"))
    #expect(fake.holdCalls == Self.ownedSet)
    #expect(fake.storedRecord?.owns == true)
    #expect(fake.storedRecord?.prior == false)
    #expect(fake.sleepDisabled == true)
    #expect(fake.logLines == ["set owned prior=0"])
  }

  @Test func everyPmsetOf1FollowsAnOwningRecordWrite() {
    let (machine, fake) = make()
    _ = machine.set()
    _ = machine.clear()
    _ = machine.set()
    _ = machine.set()
    _ = machine.clear()
    fake.setSleepDisabled(true)
    _ = machine.set()
    fake.setSleepDisabled(false)
    _ = machine.set()
    let holdCalls = fake.holdCalls
    let sets = holdCalls.indices.filter { holdCalls[$0] == .writeSleepDisabled(true) }
    #expect(sets.count == 3)
    for index in sets {
      let lastRecordWrite = holdCalls[..<index].last {
        if case .recordWrite = $0 { return true }
        return false
      }
      #expect(lastRecordWrite == .recordWrite(owns: true, prior: false))
    }
  }

  @Test func theOwnershipRecordCarriesTheClockTime() {
    let (machine, fake) = make()
    fake.advance(seconds: 234)
    _ = machine.set()
    #expect(fake.storedRecord?.at == FakeHelperSystem.startSeconds + 234)
  }

  @Test func aFailedRecordWriteRefusesTheSetAndNeverRunsPmset() {
    let (machine, fake) = make()
    fake.setRecordWriteSucceeds(false)
    #expect(machine.set() == HelperReply(code: .refused, message: "recordWrite"))
    #expect(fake.holdCalls == [.readSleepDisabled, .recordWrite(owns: true, prior: false)])
    #expect(fake.pmsetWrites.isEmpty)
    #expect(fake.sleepDisabled == false)
    #expect(fake.stored == .missing)
    #expect(fake.logLines == ["set refused reason=recordWrite"])
  }

  @Test func aSleepDisabledThatIsAlreadyOnIsRecordedAsNotOwnedAndLeftAlone() {
    let (machine, fake) = make(sleepDisabled: true)
    #expect(machine.set() == HelperReply(code: .alreadyOn, message: "alreadyOn"))
    #expect(fake.holdCalls == [.readSleepDisabled, .recordWrite(owns: false, prior: true)])
    #expect(fake.pmsetWrites.isEmpty)
    #expect(fake.sleepDisabled == true)
    #expect(fake.logLines == ["set alreadyOn prior=1"])
  }

  @Test func aFailedRecordWriteAlsoRefusesASetOverAValueThatIsAlreadyOn() {
    let (machine, fake) = make(sleepDisabled: true)
    fake.setRecordWriteSucceeds(false)
    #expect(machine.set() == HelperReply(code: .refused, message: "recordWrite"))
    #expect(fake.pmsetWrites.isEmpty)
    #expect(fake.edgeCount == 0)
    #expect(fake.sleepDisabled == true)
  }

  @Test func anUnreadableSleepDisabledRefusesTheSetAndWritesNothing() {
    let (machine, fake) = make(sleepDisabled: nil)
    #expect(machine.set() == HelperReply(code: .refused, message: "unreadable"))
    #expect(fake.holdCalls == [.readSleepDisabled])
    #expect(fake.stored == .missing)
    #expect(fake.logLines == ["set refused reason=unreadable"])
  }

  @Test func clearAfterAnOwnedSetRunsTheReleaseSequenceInOrder() {
    let (machine, fake) = owned()
    #expect(machine.clear() == HelperReply(code: .cleared, message: "cleared"))
    #expect(
      fake.calls == [
        .writeSleepDisabled(false), .readSleepDisabled, .lidClosed, .clamshellEdge,
        .recordWrite(owns: false, prior: false), .log("release reason=clear sleepDisabled=0 edge=done"),
      ])
    #expect(fake.sleepDisabled == false)
    #expect(fake.storedRecord?.owns == false)
  }

  @Test func clearAfterAnAlreadyOnSetRunsNoPmsetAndNoEdge() {
    let (machine, fake) = alreadyOn()
    #expect(machine.clear() == HelperReply(code: .cleared, message: "cleared"))
    #expect(fake.calls == [.log("release skipped reason=notOwned")])
    #expect(fake.sleepDisabled == true)
  }

  @Test(arguments: [false, true])
  func clearWithNothingHeldRunsNoPmsetAndNoEdge(sleepDisabled: Bool) {
    let (machine, fake) = make(sleepDisabled: sleepDisabled)
    #expect(machine.clear() == HelperReply(code: .cleared, message: "cleared"))
    #expect(fake.calls == [.log("release skipped reason=notOwned")])
    #expect(fake.sleepDisabled == sleepDisabled)
  }

  @Test func aSecondClearAfterAReleaseRunsNothingMore() {
    let (machine, fake) = owned()
    _ = machine.clear()
    fake.forget()
    #expect(machine.clear().code == .cleared)
    #expect(fake.calls == [.log("release skipped reason=notOwned")])
  }

  @Test func theVerifyPollsEvery50MillisecondsUntilTheRegistryReads0() {
    let (machine, fake) = owned()
    fake.setRegistryLagReads(3)
    #expect(machine.clear().code == .cleared)
    #expect(
      fake.actions == [
        .writeSleepDisabled(false), .readSleepDisabled, .pause(50), .readSleepDisabled, .pause(50),
        .readSleepDisabled, .pause(50), .readSleepDisabled, .lidClosed, .clamshellEdge,
        .recordWrite(owns: false, prior: false),
      ])
  }

  @Test func aVerifyThatStillReads1AfterTwoSecondsWritesNoEdgeAndKeepsTheRecordOwning() {
    let (machine, fake) = owned()
    fake.setRegistryFollowsWrites(false)
    let before = fake.seconds
    #expect(machine.clear() == HelperReply(code: .refused, message: "verify"))
    #expect(fake.edgeCount == 0)
    #expect(!fake.calls.contains(.lidClosed))
    #expect(fake.holdCalls.filter { $0 != .readSleepDisabled } == [.writeSleepDisabled(false)])
    #expect(fake.sleepDisabledReads == 41)
    #expect(fake.pauses == Array(repeating: 50, count: 40))
    #expect(abs(fake.seconds - before - 2) < 0.001)
    #expect(fake.storedRecord?.owns == true)
    #expect(fake.logLines == ["ERROR release failed step=verify retryIn=5"])
  }

  @Test(arguments: [(40, true), (41, false)])
  func theRegistryMustFollowInsideTheTwoSecondWindow(lagReads: Int, released: Bool) {
    let (machine, fake) = owned()
    fake.setRegistryLagReads(lagReads)
    #expect((machine.clear().code == .cleared) == released)
    #expect(fake.edgeCount == (released ? 1 : 0))
    #expect(fake.storedRecord?.owns == !released)
  }

  @Test func anUnreadableVerifyCountsAsNotCleared() {
    let (machine, fake) = owned()
    fake.setRegistryFollowsWrites(false)
    fake.setSleepDisabled(nil)
    #expect(machine.clear() == HelperReply(code: .refused, message: "verify"))
    #expect(fake.edgeCount == 0)
    #expect(fake.storedRecord?.owns == true)
  }

  @Test func aFailedPmsetClearSkipsTheVerifyAndTheEdge() {
    let (machine, fake) = owned()
    fake.setWriteSucceeds(false)
    #expect(machine.clear() == HelperReply(code: .refused, message: "pmset"))
    #expect(fake.actions == [.writeSleepDisabled(false)])
    #expect(fake.storedRecord?.owns == true)
    #expect(fake.logLines == ["ERROR release failed step=pmset retryIn=5"])
  }

  @Test func aReleaseWithTheLidOpenWritesNoEdge() {
    let (machine, fake) = owned()
    fake.setLid(false)
    #expect(machine.clear().code == .cleared)
    #expect(fake.edgeCount == 0)
    #expect(fake.pmsetWrites == [false])
    #expect(fake.storedRecord?.owns == false)
    #expect(fake.logLines == ["release reason=clear sleepDisabled=0 edge=skipped"])
  }

  @Test func aReleaseWithTheLidUnknownWritesTheEdge() {
    let (machine, fake) = owned()
    fake.setLid(nil)
    #expect(machine.clear().code == .cleared)
    #expect(fake.edgeCount == 1)
    #expect(fake.logLines == ["release reason=clear sleepDisabled=0 edge=done"])
  }

  @Test func aSecondSetWhileOwningKeepsTheOwnership() {
    let (machine, fake) = owned()
    #expect(machine.set() == HelperReply(code: .owned, message: "owned"))
    #expect(fake.pmsetWrites.isEmpty)
    #expect(fake.holdCalls == [.readSleepDisabled, .recordWrite(owns: true, prior: false)])
    #expect(fake.storedRecord?.owns == true)
    fake.forget()
    #expect(machine.clear().code == .cleared)
    #expect(fake.pmsetWrites == [false])
    #expect(fake.sleepDisabled == false)
  }

  @Test func aSetAfterTheOtherOwnerClearedItsValueTakesOwnership() {
    let (machine, fake) = alreadyOn()
    fake.setSleepDisabled(false)
    #expect(machine.set().code == .owned)
    #expect(fake.holdCalls == Self.ownedSet)
    fake.forget()
    #expect(machine.clear().code == .cleared)
    #expect(fake.pmsetWrites == [false])
  }

  @Test func aSetAfterAReleaseNeverClaimsAValueSomeoneElseTurnedOn() {
    let (machine, fake) = owned()
    _ = machine.clear()
    fake.setSleepDisabled(true)
    fake.forget()
    #expect(machine.set().code == .alreadyOn)
    #expect(machine.clear().code == .cleared)
    #expect(fake.pmsetWrites.isEmpty)
    #expect(fake.edgeCount == 0)
    #expect(fake.sleepDisabled == true)
  }

  @Test func aSetWhoseRegistryNeverReads1UndoesItselfAndRefuses() {
    let (machine, fake) = make()
    fake.setRegistryFollowsWrites(false)
    #expect(machine.set() == HelperReply(code: .refused, message: "verify"))
    #expect(fake.pmsetWrites == [true, false])
    #expect(fake.storedRecord?.owns == false)
    #expect(fake.logLines == ["release reason=setFailed sleepDisabled=0 edge=done", "set refused reason=verify"])
  }

  @Test func aSetWhosePmsetFailsRunsTheReleaseAndRefuses() {
    let (machine, fake) = make()
    fake.setWriteSucceeds(false)
    #expect(machine.set() == HelperReply(code: .refused, message: "pmset"))
    #expect(fake.pmsetWrites == [true, false])
    #expect(fake.edgeCount == 0)
    #expect(fake.logLines.last == "set refused reason=pmset")
  }

  @Test func aRefusedSetOverAnOwnedHoldReleasesIt() {
    let (machine, fake) = owned()
    fake.setSleepDisabled(nil)
    fake.setRegistryFollowsWrites(true)
    #expect(machine.set() == HelperReply(code: .refused, message: "unreadable"))
    #expect(fake.pmsetWrites == [false])
    #expect(fake.sleepDisabled == false)
    #expect(fake.storedRecord?.owns == false)
  }

  @Test func everyLogLineUsesFixedWordsOnly() {
    var lines: [String] = []
    let first = owned()
    _ = first.machine.set()
    _ = first.machine.clear()
    _ = first.machine.clear()
    lines += first.fake.logLines
    let second = alreadyOn()
    _ = second.machine.clear()
    lines += second.fake.logLines
    let third = make(sleepDisabled: nil)
    _ = third.machine.set()
    lines += third.fake.logLines
    let fourth = owned()
    fourth.fake.setWriteSucceeds(false)
    _ = fourth.machine.clear()
    lines += fourth.fake.logLines
    #expect(lines.count >= 6)
    for line in lines {
      #expect(line.unicodeScalars.allSatisfy { Self.isLogScalar($0) }, "\(line)")
    }
  }

  static func isLogScalar(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar {
    case "a"..."z", "A"..."Z", "0"..."9", " ", "=":
      return true
    default:
      return false
    }
  }

  @Test func aStatusRoundTripsThroughItsEncoding() {
    let status = HelperStatus(
      helperVersion: 7, sleepDisabled: true, owns: true, prior: false, engaged: true, batteryPercent: 42,
      onBattery: true, warningLevel: 2, thermalLevel: 1, thermalCritical: false, lastReleaseReason: "clear",
      exiting: true)
    #expect(HelperStatus.decode(status.encoded()) == status)
    #expect(HelperStatus.decode(HelperStatus().encoded()) == HelperStatus())
  }

  @Test func aStatusDecodesLenientlyFieldByField() {
    #expect(HelperStatus.decode(Data("{}".utf8)) == HelperStatus())
    let mixed = Data(
      #"{"helperVersion":"x","owns":1,"sleepDisabled":"yes","engaged":true,"batteryPercent":42,"extra":[1]}"#.utf8)
    #expect(HelperStatus.decode(mixed) == HelperStatus(engaged: true, batteryPercent: 42))
  }

  @Test(arguments: ["", "[]", "true", "nope", "{"])
  func somethingThatIsNotAJSONObjectIsNotAStatus(text: String) {
    #expect(HelperStatus.decode(Data(text.utf8)) == nil)
  }

  @Test func theReplyCodesAreTheWireValues() {
    #expect(HelperReplyCode.owned.rawValue == 0)
    #expect(HelperReplyCode.alreadyOn.rawValue == 1)
    #expect(HelperReplyCode.cleared.rawValue == 2)
    #expect(HelperReplyCode.refused.rawValue == -1)
    #expect(HelperReplyCode(rawValue: 3) == nil)
  }

  enum Trigger: CaseIterable, Sendable {
    case clear
    case connectionEnded
    case sigterm
    case sigint
    case sighup
    case heartbeat
    case batteryEvent
    case batteryWatch
    case batteryOnPowerEvent
    case batteryOnPowerWatch
    case warningEarly
    case warningFinal
    case powerUnreadable
    case powerUnreadableWatch
    case thermalTrapping
    case thermalSleeping
    case thermalCritical
    case thermalWatch
    case thermalUnreadable
    case thermalUnreadableWatch
    case lidOpen
    case lidUnreadable

    var reason: String {
      switch self {
      case .clear: return "clear"
      case .connectionEnded: return "connection"
      case .sigterm: return "sigterm"
      case .sigint: return "sigint"
      case .sighup: return "sighup"
      case .heartbeat: return "heartbeat"
      case .batteryEvent, .batteryWatch, .batteryOnPowerEvent, .batteryOnPowerWatch: return "battery"
      case .warningEarly, .warningFinal: return "lowBatteryWarning"
      case .powerUnreadable, .powerUnreadableWatch: return "powerUnreadable"
      case .thermalTrapping, .thermalSleeping, .thermalCritical, .thermalWatch: return "thermal"
      case .thermalUnreadable, .thermalUnreadableWatch: return "thermalUnreadable"
      case .lidOpen: return "lidOpen"
      case .lidUnreadable: return "lidUnreadable"
      }
    }

    var edge: String { self == .lidOpen ? "skipped" : "done" }
  }

  static let floorOnAnySource: Comment =
    "03-REVIEW.md H-CR-01: the helper releases at or below 10 % whatever the power source"

  static func battery(_ percent: Int) -> HelperPowerFacts {
    HelperPowerFacts(onBattery: true, percent: percent, warningLevel: HelperPowerFacts.warningNone)
  }

  static func onPower(_ percent: Int) -> HelperPowerFacts {
    HelperPowerFacts(onBattery: false, percent: percent, warningLevel: HelperPowerFacts.warningNone)
  }

  static func warning(_ level: Int) -> HelperPowerFacts {
    HelperPowerFacts(onBattery: false, percent: 80, warningLevel: level)
  }

  static func pressure(_ level: Int, critical: Bool = false) -> HelperThermalFacts {
    HelperThermalFacts(pressureLevel: level, critical: critical)
  }

  func fire(_ trigger: Trigger, _ machine: HelperMachine, _ fake: FakeHelperSystem) {
    switch trigger {
    case .clear:
      _ = machine.clear()
    case .connectionEnded:
      machine.connectionEnded(remaining: 0)
    case .sigterm:
      machine.signal(SIGTERM)
    case .sigint:
      machine.signal(SIGINT)
    case .sighup:
      machine.signal(SIGHUP)
    case .heartbeat:
      fake.advance(seconds: 55)
      machine.watch()
    case .batteryEvent:
      machine.power(Self.battery(10))
    case .batteryWatch:
      fake.setPower(Self.battery(5))
      machine.watch()
    case .batteryOnPowerEvent:
      machine.power(Self.onPower(10))
    case .batteryOnPowerWatch:
      fake.setPower(Self.onPower(5))
      machine.watch()
    case .warningEarly:
      machine.power(Self.warning(HelperPowerFacts.warningEarly))
    case .warningFinal:
      machine.power(Self.warning(HelperPowerFacts.warningFinal))
    case .powerUnreadable:
      machine.power(nil)
    case .powerUnreadableWatch:
      fake.setPower(nil)
      machine.watch()
    case .thermalTrapping:
      machine.thermal(Self.pressure(3))
    case .thermalSleeping:
      machine.thermal(Self.pressure(4))
    case .thermalCritical:
      machine.thermal(Self.pressure(0, critical: true))
    case .thermalWatch:
      fake.setThermal(Self.pressure(4))
      machine.watch()
    case .thermalUnreadable:
      machine.thermal(nil)
    case .thermalUnreadableWatch:
      fake.setThermal(nil)
      machine.watch()
    case .lidOpen:
      fake.setLid(false)
      machine.watch()
    case .lidUnreadable:
      fake.setLid(nil)
      machine.watch()
    }
  }

  @Test(arguments: Trigger.allCases)
  func everyTriggerReleasesAnOwnedHoldThroughTheFullSequence(trigger: Trigger) {
    let (machine, fake) = owned()
    fire(trigger, machine, fake)
    let edge: [Call] = trigger == .lidOpen ? [] : [.clamshellEdge]
    #expect(
      fake.holdCalls == [.writeSleepDisabled(false), .readSleepDisabled] + edge
        + [.recordWrite(owns: false, prior: false)])
    #expect(fake.sleepDisabled == false)
    #expect(fake.storedRecord?.owns == false)
    #expect(fake.logLines.last == "release reason=\(trigger.reason) sleepDisabled=0 edge=\(trigger.edge)")
    #expect(!machine.needsWatch)
    #expect(machine.status(appVersion: 1).status.lastReleaseReason == trigger.reason)
  }

  @Test func noTriggerEverClearsASleepDisabledTheHelperDoesNotOwn() {
    let stores: [HelperRecordRead] = [.missing, .loaded(HelperRecord(owns: false, prior: true, at: 1))]
    for stored in stores {
      let (machine, fake) = make(sleepDisabled: true, stored: stored)
      machine.launched()
      for trigger in Trigger.allCases {
        fire(trigger, machine, fake)
      }
      #expect(fake.pmsetWrites.isEmpty)
      #expect(fake.edgeCount == 0)
      #expect(fake.sleepDisabled == true)
    }
    for trigger in Trigger.allCases {
      let (machine, fake) = make(sleepDisabled: true)
      machine.launched()
      #expect(machine.set().code == .alreadyOn)
      #expect(machine.needsWatch)
      fire(trigger, machine, fake)
      #expect(fake.pmsetWrites.isEmpty, "\(trigger)")
      #expect(fake.edgeCount == 0, "\(trigger)")
      #expect(fake.sleepDisabled == true, "\(trigger)")
      #expect(!machine.needsWatch, "\(trigger)")
      #expect(fake.logLines.last == "release skipped reason=notOwned", "\(trigger)")
    }
  }

  @Test func withNoConnectionAndNoRecordNoTriggerRunsPmsetOrTheEdge() {
    let (machine, fake) = make()
    machine.launched()
    fake.forget()
    for trigger in Trigger.allCases {
      fire(trigger, machine, fake)
    }
    #expect(fake.holdCalls.isEmpty)
    #expect(!machine.needsWatch)
  }

  @Test func watchingWhileIdleReadsNothing() {
    let (machine, fake) = make()
    machine.watch()
    fake.advance(seconds: 600)
    machine.watch()
    #expect(fake.calls.isEmpty)
  }

  @Test func watchingAHealthyHoldReadsTheLidPowerAndThermalAndNothingElse() {
    let (machine, fake) = owned()
    machine.watch()
    #expect(fake.calls == [.lidClosed, .power, .thermal])
    #expect(machine.needsWatch)
  }

  @Test func theHelperNeedsWatchingOnlyWhileItHolds() {
    let idle = make()
    #expect(!idle.machine.needsWatch)
    let owning = owned()
    #expect(owning.machine.needsWatch)
    _ = owning.machine.clear()
    #expect(!owning.machine.needsWatch)
    let other = alreadyOn()
    #expect(other.machine.needsWatch)
    _ = other.machine.clear()
    #expect(!other.machine.needsWatch)
  }

  @Test(arguments: [(11, false), (10, true)])
  func onBatteryTheFloorIs10Percent(percent: Int, releases: Bool) {
    let (machine, fake) = owned()
    machine.power(Self.battery(percent))
    #expect(fake.pmsetWrites == (releases ? [false] : []))
    #expect(machine.needsWatch == !releases)
  }

  @Test(arguments: [(54.0, false), (55.0, true)])
  func theHeartbeatTimeoutIs55Seconds(seconds: Double, releases: Bool) {
    let (machine, fake) = owned()
    fake.advance(seconds: seconds)
    machine.watch()
    #expect(fake.pmsetWrites == (releases ? [false] : []))
    #expect(machine.needsWatch == !releases)
  }

  @Test(arguments: [0.001, 0.5, 1, 2.5, 4, 4.999, 5])
  func withTheWatchPeriodTheHeartbeatReleaseLandsWithin60SecondsOfTheLastContact(firstWatch: Double) {
    let (machine, fake) = owned()
    let lastContact = fake.seconds
    fake.advance(seconds: firstWatch)
    machine.watch()
    while fake.pmsetWrites.isEmpty, fake.seconds - lastContact < 120 {
      fake.advance(seconds: HelperMachine.watchPeriodSeconds)
      machine.watch()
    }
    let elapsed = fake.seconds - lastContact
    #expect(fake.pmsetWrites == [false])
    #expect(fake.logLines.last == "release reason=heartbeat sleepDisabled=0 edge=done")
    #expect(elapsed <= 60)
    #expect(elapsed >= 55)
  }

  @Test func theHeartbeatTimeoutPlusOneWatchPeriodStaysWithinTheADR0011Limit() {
    #expect(HelperMachine.heartbeatTimeoutSeconds + HelperMachine.watchPeriodSeconds <= 60)
  }

  @Test(arguments: [(2, false), (3, true)])
  func thermalReleasesAtTrapping(level: Int, releases: Bool) {
    let (machine, fake) = owned()
    machine.thermal(Self.pressure(level))
    #expect(fake.pmsetWrites == (releases ? [false] : []))
    #expect(machine.needsWatch == !releases)
  }

  @Test func aLowBatteryOnExternalPowerReleasesWhateverThePowerSource() {
    let event = owned()
    event.machine.power(Self.onPower(5))
    #expect(event.fake.pmsetWrites == [false], Self.floorOnAnySource)
    #expect(event.fake.sleepDisabled == false, Self.floorOnAnySource)
    #expect(event.fake.logLines == ["release reason=battery sleepDisabled=0 edge=done"], Self.floorOnAnySource)
    #expect(!event.machine.needsWatch, Self.floorOnAnySource)

    let watched = owned()
    watched.fake.setPower(Self.onPower(5))
    watched.machine.watch()
    #expect(watched.fake.pmsetWrites == [false], Self.floorOnAnySource)
    #expect(watched.fake.sleepDisabled == false, Self.floorOnAnySource)
    #expect(watched.fake.logLines == ["release reason=battery sleepDisabled=0 edge=done"], Self.floorOnAnySource)
    #expect(!watched.machine.needsWatch, Self.floorOnAnySource)
  }

  @Test(arguments: [(11, false), (10, true), (9, true), (0, true)])
  func onExternalPowerAtOrBelow10PercentReleases(percent: Int, releases: Bool) {
    let event = owned()
    event.machine.power(Self.onPower(percent))
    #expect(event.fake.pmsetWrites == (releases ? [false] : []), Self.floorOnAnySource)
    #expect(event.machine.needsWatch == !releases, Self.floorOnAnySource)

    let watched = owned()
    watched.fake.setPower(Self.onPower(percent))
    watched.machine.watch()
    #expect(watched.fake.pmsetWrites == (releases ? [false] : []), Self.floorOnAnySource)
    #expect(watched.machine.needsWatch == !releases, Self.floorOnAnySource)
  }

  @Test(arguments: [(11, HelperReplyCode.owned), (10, .refused), (5, .refused)])
  func aSetOnExternalPowerAtOrBelowTheFloorIsRefused(percent: Int, code: HelperReplyCode) {
    let (machine, fake) = make()
    fake.setPower(Self.onPower(percent))
    let reply = machine.set()
    #expect(reply.code == code, Self.floorOnAnySource)
    #expect(fake.pmsetWrites == (code == .owned ? [true] : []), Self.floorOnAnySource)
    #expect(fake.sleepDisabled == (code == .owned), Self.floorOnAnySource)
    #expect(machine.needsWatch == (code == .owned), Self.floorOnAnySource)
    if code == .refused {
      #expect(reply.message == "battery", Self.floorOnAnySource)
      #expect(fake.stored == .missing, Self.floorOnAnySource)
    }
  }

  @Test func theFloorReadsTheChargeAndNeverThePowerSource() {
    for onBattery in [true, false] {
      for percent in [0, 10, 11, 100] {
        let (machine, fake) = owned()
        machine.power(
          HelperPowerFacts(onBattery: onBattery, percent: percent, warningLevel: HelperPowerFacts.warningNone))
        #expect(fake.pmsetWrites == (percent <= 10 ? [false] : []), Self.floorOnAnySource)
      }
    }
  }

  @Test func statusAndSetRefreshTheLastContact() {
    let (machine, fake) = owned()
    fake.advance(seconds: 54)
    _ = machine.status(appVersion: 1)
    fake.advance(seconds: 54)
    machine.watch()
    #expect(fake.pmsetWrites.isEmpty)
    #expect(machine.set().code == .owned)
    fake.advance(seconds: 54)
    machine.watch()
    #expect(fake.pmsetWrites.isEmpty)
    fake.advance(seconds: 1)
    machine.watch()
    #expect(fake.pmsetWrites == [false])
    #expect(fake.logLines.last == "release reason=heartbeat sleepDisabled=0 edge=done")
  }

  enum Unsafe: CaseIterable, Sendable {
    case lidOpen
    case lidUnreadable
    case battery
    case batteryOnPower
    case warningEarly
    case warningFinal
    case powerUnreadable
    case thermalTrapping
    case thermalSleeping
    case thermalCritical
    case thermalUnreadable

    var reason: String {
      switch self {
      case .lidOpen: return "lidOpen"
      case .lidUnreadable: return "lidUnreadable"
      case .battery, .batteryOnPower: return "battery"
      case .warningEarly, .warningFinal: return "lowBatteryWarning"
      case .powerUnreadable: return "powerUnreadable"
      case .thermalTrapping, .thermalSleeping, .thermalCritical: return "thermal"
      case .thermalUnreadable: return "thermalUnreadable"
      }
    }
  }

  func arrange(_ state: Unsafe, _ fake: FakeHelperSystem) {
    switch state {
    case .lidOpen: fake.setLid(false)
    case .lidUnreadable: fake.setLid(nil)
    case .battery: fake.setPower(Self.battery(10))
    case .batteryOnPower: fake.setPower(Self.onPower(10))
    case .warningEarly: fake.setPower(Self.warning(HelperPowerFacts.warningEarly))
    case .warningFinal: fake.setPower(Self.warning(HelperPowerFacts.warningFinal))
    case .powerUnreadable: fake.setPower(nil)
    case .thermalTrapping: fake.setThermal(Self.pressure(3))
    case .thermalSleeping: fake.setThermal(Self.pressure(4))
    case .thermalCritical: fake.setThermal(Self.pressure(0, critical: true))
    case .thermalUnreadable: fake.setThermal(nil)
    }
  }

  @Test(arguments: Unsafe.allCases)
  func setRefusesInEveryStateThatWouldReleaseIt(state: Unsafe) {
    let (machine, fake) = make()
    arrange(state, fake)
    #expect(machine.set() == HelperReply(code: .refused, message: state.reason))
    #expect(fake.holdCalls.isEmpty)
    #expect(fake.stored == .missing)
    #expect(fake.logLines == ["set refused reason=\(state.reason)"])
    #expect(!machine.needsWatch)
  }

  @Test(arguments: Unsafe.allCases)
  func aSetInAnUnsafeStateReleasesTheHoldItHad(state: Unsafe) {
    let (machine, fake) = owned()
    arrange(state, fake)
    #expect(machine.set() == HelperReply(code: .refused, message: state.reason))
    #expect(fake.pmsetWrites == [false])
    #expect(fake.storedRecord?.owns == false)
    #expect(!machine.needsWatch)
  }

  @Test func setEngagesJustInsideEachLimit() {
    let (machine, fake) = make()
    fake.setPower(Self.battery(11))
    fake.setThermal(Self.pressure(2))
    #expect(machine.set().code == .owned)
    #expect(fake.actions.prefix(4) == [.lidClosed, .power, .thermal, .readSleepDisabled])
  }

  @Test func aFailedPmsetClearIsRetriedFiveSecondsLater() {
    let (machine, fake) = owned()
    fake.setWriteSucceeds(false)
    #expect(machine.clear() == HelperReply(code: .refused, message: "pmset"))
    #expect(machine.needsWatch)
    #expect(fake.edgeCount == 0)
    #expect(fake.storedRecord?.owns == true)
    fake.setWriteSucceeds(true)
    fake.forget()
    fake.advance(seconds: 4.5)
    machine.watch()
    #expect(fake.calls.isEmpty)
    fake.advance(seconds: 0.5)
    machine.watch()
    #expect(
      fake.holdCalls == [
        .writeSleepDisabled(false), .readSleepDisabled, .clamshellEdge, .recordWrite(owns: false, prior: false),
      ])
    #expect(fake.logLines == ["release reason=clear sleepDisabled=0 edge=done"])
    #expect(!machine.needsWatch)
  }

  @Test func aFailedVerifyIsRetriedFiveSecondsLater() {
    let (machine, fake) = owned()
    fake.setRegistryFollowsWrites(false)
    #expect(machine.clear() == HelperReply(code: .refused, message: "verify"))
    #expect(machine.needsWatch)
    fake.setRegistryFollowsWrites(true)
    fake.forget()
    fake.advance(seconds: 4)
    machine.watch()
    #expect(fake.calls.isEmpty)
    fake.advance(seconds: 1.5)
    machine.watch()
    #expect(fake.pmsetWrites == [false])
    #expect(fake.edgeCount == 1)
    #expect(fake.storedRecord?.owns == false)
    #expect(!machine.needsWatch)
  }

  @Test func aReleaseThatKeepsFailingIsRetriedEveryFiveSecondsWithAnErrorLineEachTime() {
    let (machine, fake) = owned()
    fake.setWriteSucceeds(false)
    _ = machine.clear()
    for _ in 0..<3 {
      fake.advance(seconds: 5)
      machine.watch()
    }
    #expect(fake.logLines == Array(repeating: "ERROR release failed step=pmset retryIn=5", count: 4))
    #expect(fake.pmsetWrites == [false, false, false, false])
    #expect(fake.edgeCount == 0)
    #expect(machine.needsWatch)
  }

  @Test func aFailedEdgeIsRetriedWithoutASecondPmset() {
    let (machine, fake) = owned()
    fake.setEdgeSucceeds(false)
    #expect(machine.clear() == HelperReply(code: .refused, message: "edge"))
    #expect(fake.pmsetWrites == [false])
    #expect(fake.storedRecord?.owns == true)
    #expect(machine.needsWatch)
    #expect(fake.logLines == ["ERROR release failed step=edge retryIn=5"])
    fake.setEdgeSucceeds(true)
    fake.forget()
    fake.advance(seconds: 5)
    machine.watch()
    #expect(fake.holdCalls == [.clamshellEdge, .recordWrite(owns: false, prior: false)])
    #expect(fake.logLines == ["release reason=clear sleepDisabled=0 edge=done"])
    #expect(!machine.needsWatch)
  }

  @Test func aFailedRecordRewriteIsRetriedWithoutASecondPmsetOrEdge() {
    let (machine, fake) = owned()
    fake.setRecordWriteSucceeds(false)
    #expect(machine.clear() == HelperReply(code: .refused, message: "record"))
    #expect(fake.pmsetWrites == [false])
    #expect(fake.edgeCount == 1)
    #expect(fake.sleepDisabled == false)
    #expect(machine.needsWatch)
    fake.setRecordWriteSucceeds(true)
    fake.forget()
    fake.advance(seconds: 5)
    machine.watch()
    #expect(fake.holdCalls == [.recordWrite(owns: false, prior: false)])
    #expect(fake.logLines == ["release reason=clear sleepDisabled=0 edge=done"])
    #expect(!machine.needsWatch)
  }

  @Test func aSetWhileAFailedReleaseIsPendingKeepsTheOwnership() {
    let (machine, fake) = owned()
    fake.setWriteSucceeds(false)
    _ = machine.clear()
    fake.setWriteSucceeds(true)
    fake.forget()
    #expect(machine.set().code == .owned)
    #expect(fake.holdCalls == [.readSleepDisabled, .recordWrite(owns: true, prior: false)])
    fake.advance(seconds: 5)
    machine.watch()
    #expect(fake.pmsetWrites.isEmpty)
    #expect(machine.clear().code == .cleared)
    #expect(fake.pmsetWrites == [false])
    #expect(fake.sleepDisabled == false)
  }

  @Test func aPendingEdgeRetryNeverTurnsIntoAClaimOnAForeignValue() {
    let (machine, fake) = owned()
    fake.setEdgeSucceeds(false)
    _ = machine.clear()
    fake.setEdgeSucceeds(true)
    fake.setSleepDisabled(true)
    fake.forget()
    #expect(machine.set().code == .alreadyOn)
    fake.advance(seconds: 5)
    machine.watch()
    #expect(machine.clear().code == .cleared)
    #expect(fake.pmsetWrites.isEmpty)
    #expect(fake.edgeCount == 0)
    #expect(fake.sleepDisabled == true)
    #expect(!machine.needsWatch)
  }

  static let holderRule: Comment =
    "03-REVIEW.md H-WR-02: only the connection that engaged refreshes the heartbeat, and the end of that connection releases"
  static let clearRule: Comment =
    "03-REVIEW.md H-WR-02: a clear is still accepted from any connection that passes the requirement"

  @Test func theEndOfTheConnectionThatEngagedReleasesWhateverElseIsConnected() {
    let (machine, fake) = owned()
    machine.connectionOpened()
    machine.connectionOpened()
    machine.connectionOpened()
    machine.connectionEnded(.app, remaining: 2)
    #expect(fake.pmsetWrites == [false], Self.holderRule)
    #expect(fake.sleepDisabled == false, Self.holderRule)
    #expect(fake.logLines == ["release reason=connection sleepDisabled=0 edge=done"], Self.holderRule)
    #expect(!machine.needsWatch, Self.holderRule)
  }

  @Test func theEndOfAnotherConnectionDoesNotReleaseWhileTheOneThatEngagedIsOpen() {
    let (machine, fake) = owned()
    machine.connectionOpened()
    machine.connectionOpened()
    machine.connectionEnded(.other, remaining: 1)
    #expect(fake.calls.isEmpty, Self.holderRule)
    #expect(fake.sleepDisabled == true, Self.holderRule)
    #expect(machine.needsWatch, Self.holderRule)
    machine.connectionEnded(.app, remaining: 0)
    #expect(fake.pmsetWrites == [false], Self.holderRule)
    #expect(fake.logLines == ["release reason=connection sleepDisabled=0 edge=done"], Self.holderRule)
  }

  @Test func whenNoConnectionRemainsAnEngagedHelperReleasesWhicheverConnectionEnded() {
    let (machine, fake) = owned()
    machine.connectionEnded(.other, remaining: 0)
    #expect(fake.pmsetWrites == [false])
    #expect(fake.logLines == ["release reason=connection sleepDisabled=0 edge=done"])
    #expect(!machine.needsWatch)
  }

  @Test func aStatusFromAnotherConnectionAnswersAndDoesNotRefreshTheHeartbeat() {
    let (machine, fake) = owned()
    fake.advance(seconds: 54)
    let another = machine.status(appVersion: 1, from: .other)
    #expect(another.status.engaged, Self.holderRule)
    #expect(another.status.owns, Self.holderRule)
    #expect(another.status.sleepDisabled == true, Self.holderRule)
    #expect(another.status.batteryPercent == 80, Self.holderRule)
    #expect(!another.exitAfterReply, Self.holderRule)
    let uncounted = machine.status(appVersion: 1, from: nil)
    #expect(uncounted.status.engaged, Self.holderRule)
    #expect(fake.pmsetWrites.isEmpty, Self.holderRule)
    fake.advance(seconds: 1)
    machine.watch()
    #expect(fake.pmsetWrites == [false], Self.holderRule)
    #expect(fake.logLines.last == "release reason=heartbeat sleepDisabled=0 edge=done", Self.holderRule)
  }

  @Test func aStatusFromTheConnectionThatEngagedRefreshesTheHeartbeat() {
    let (machine, fake) = owned()
    fake.advance(seconds: 54)
    #expect(machine.status(appVersion: 1, from: .app).status.engaged, Self.holderRule)
    fake.advance(seconds: 54)
    machine.watch()
    #expect(fake.pmsetWrites.isEmpty, Self.holderRule)
    #expect(machine.needsWatch, Self.holderRule)
    fake.advance(seconds: 1)
    machine.watch()
    #expect(fake.pmsetWrites == [false], Self.holderRule)
  }

  @Test func aStatusFromAnyConnectionWhileNothingIsEngagedHoldsNothing() {
    let (machine, fake) = make()
    for caller in [HelperConnectionID.app, .other, nil] {
      #expect(!machine.status(appVersion: 1, from: caller).status.engaged)
    }
    fake.advance(seconds: 600)
    machine.watch()
    #expect(fake.holdCalls == [.readSleepDisabled, .readSleepDisabled, .readSleepDisabled])
    #expect(!machine.needsWatch)
  }

  @Test func aSetFromAnotherConnectionMakesThatConnectionTheOneThatEngaged() {
    let (machine, fake) = owned()
    #expect(machine.set(from: .other) == HelperReply(code: .owned, message: "owned"))
    fake.forget()
    machine.connectionEnded(.app, remaining: 1)
    #expect(fake.calls.isEmpty, Self.holderRule)
    fake.advance(seconds: 54)
    _ = machine.status(appVersion: 1, from: .app)
    fake.advance(seconds: 1)
    machine.watch()
    #expect(fake.pmsetWrites == [false], Self.holderRule)
    #expect(fake.logLines.last == "release reason=heartbeat sleepDisabled=0 edge=done", Self.holderRule)
  }

  @Test func theConnectionThatEngagedLastKeepsTheHoldWithItsOwnStatusAndReleasesItWhenItEnds() {
    let (machine, fake) = owned()
    #expect(machine.set(from: .other).code == .owned)
    fake.forget()
    fake.advance(seconds: 54)
    _ = machine.status(appVersion: 1, from: .other)
    fake.advance(seconds: 54)
    machine.watch()
    #expect(fake.pmsetWrites.isEmpty, Self.holderRule)
    machine.connectionEnded(.other, remaining: 1)
    #expect(fake.pmsetWrites == [false], Self.holderRule)
    #expect(fake.logLines.last == "release reason=connection sleepDisabled=0 edge=done", Self.holderRule)
  }

  @Test func afterAReleaseNoConnectionIsTheOneThatEngaged() {
    let (machine, fake) = owned()
    #expect(machine.clear().code == .cleared, Self.clearRule)
    #expect(machine.set(from: .other).code == .owned)
    fake.forget()
    machine.connectionEnded(.app, remaining: 1)
    #expect(fake.calls.isEmpty, Self.holderRule)
    #expect(machine.needsWatch, Self.holderRule)
    fake.advance(seconds: 54)
    _ = machine.status(appVersion: 1, from: .app)
    fake.advance(seconds: 1)
    machine.watch()
    #expect(fake.pmsetWrites == [false], Self.holderRule)
  }

  @Test func aSetOverAValueThatWasAlreadyOnAlsoTiesTheHoldToItsConnection() {
    let (machine, fake) = alreadyOn()
    fake.advance(seconds: 54)
    _ = machine.status(appVersion: 1, from: .other)
    #expect(machine.needsWatch)
    machine.connectionEnded(.other, remaining: 1)
    #expect(machine.needsWatch, Self.holderRule)
    #expect(fake.logLines.isEmpty, Self.holderRule)
    fake.advance(seconds: 1)
    machine.watch()
    #expect(!machine.needsWatch, Self.holderRule)
    #expect(fake.logLines == ["release skipped reason=notOwned"], Self.holderRule)
    #expect(fake.pmsetWrites.isEmpty)
    #expect(fake.sleepDisabled == true)
  }

  @Test func aStaleVersionFromAnotherConnectionStillDefersTheExitToTheNextRelease() {
    let (machine, fake) = owned()
    let answer = machine.status(appVersion: 2, from: .other)
    #expect(!answer.exitAfterReply)
    #expect(!machine.shouldExit)
    #expect(fake.logLines == ["status stale exit=deferred"])
    #expect(machine.clear().code == .cleared, Self.clearRule)
    #expect(machine.shouldExit)
  }

  @Test func aConnectionEndingWhileNotEngagedDoesAndLogsNothing() {
    let (machine, fake) = make(sleepDisabled: true)
    machine.connectionOpened()
    machine.connectionEnded(remaining: 0)
    #expect(fake.calls.isEmpty)
  }

  @Test func connectionsAreCounted() {
    let (machine, _) = make()
    #expect(machine.connections == 0)
    machine.connectionOpened()
    machine.connectionOpened()
    #expect(machine.connections == 2)
    machine.connectionEnded(remaining: 1)
    #expect(machine.connections == 1)
    machine.connectionEnded(remaining: -4)
    #expect(machine.connections == 0)
  }

  @Test(arguments: [SIGTERM, SIGINT, SIGHUP])
  func aSignalReleasesAndAsksToExit(number: Int32) {
    let (machine, fake) = owned()
    #expect(!machine.shouldExit)
    machine.signal(number)
    #expect(fake.pmsetWrites == [false])
    #expect(fake.edgeCount == 1)
    #expect(machine.shouldExit)
  }

  @Test func aSignalWithNothingHeldAsksToExitAndTouchesNothing() {
    let (machine, fake) = make(sleepDisabled: true)
    machine.signal(SIGTERM)
    #expect(machine.shouldExit)
    #expect(fake.calls == [.log("received sigterm")])
  }

  @Test func aSignalWhoseReleaseFailsExitsOnlyAfterARetrySucceeds() {
    let (machine, fake) = owned()
    fake.setWriteSucceeds(false)
    machine.signal(SIGTERM)
    #expect(!machine.shouldExit)
    #expect(machine.needsWatch)
    fake.setWriteSucceeds(true)
    fake.advance(seconds: 5)
    machine.watch()
    #expect(machine.shouldExit)
    #expect(fake.sleepDisabled == false)
    #expect(fake.logLines.last == "release reason=sigterm sleepDisabled=0 edge=done")
  }

  @Test func aSetAfterASignalIsRefused() {
    let (machine, fake) = make()
    machine.signal(SIGHUP)
    fake.forget()
    #expect(machine.set() == HelperReply(code: .refused, message: "exiting"))
    #expect(fake.calls == [.log("set refused reason=exiting")])
  }

  @Test func anUnknownSignalStillReleasesAndExits() {
    let (machine, fake) = owned()
    machine.signal(SIGUSR1)
    #expect(fake.pmsetWrites == [false])
    #expect(machine.shouldExit)
    #expect(fake.logLines.first == "received signal")
  }

  static let owningRecord = HelperRecordRead.loaded(HelperRecord(owns: true, prior: false, at: 1))

  @Test(arguments: [false, true])
  func aMissingRecordAtLaunchReleasesNothing(sleepDisabled: Bool) {
    let (machine, fake) = make(sleepDisabled: sleepDisabled)
    machine.launched()
    #expect(fake.calls == [.recordRead, .log("reconcile none"), .recordWrite(owns: false, prior: false)])
    #expect(fake.sleepDisabled == sleepDisabled)
    #expect(!machine.needsWatch)
  }

  @Test func anOwningRecordAtLaunchRunsTheFullSequence() {
    let (machine, fake) = make(sleepDisabled: true, stored: Self.owningRecord)
    machine.launched()
    #expect(
      fake.calls == [
        .recordRead, .log("reconcile owned"), .writeSleepDisabled(false), .readSleepDisabled, .lidClosed,
        .clamshellEdge, .recordWrite(owns: false, prior: false),
        .log("release reason=reconcile sleepDisabled=0 edge=done"),
      ])
    #expect(fake.sleepDisabled == false)
    #expect(fake.storedRecord?.owns == false)
    #expect(!machine.needsWatch)
  }

  @Test func aRecordThatDoesNotOwnAtLaunchReleasesNothingAndIsReset() {
    let stored = HelperRecordRead.loaded(HelperRecord(owns: false, prior: true, at: 1))
    let (machine, fake) = make(sleepDisabled: true, stored: stored)
    machine.launched()
    #expect(fake.calls == [.recordRead, .log("reconcile none"), .recordWrite(owns: false, prior: false)])
    #expect(fake.sleepDisabled == true)
    #expect(fake.storedRecord?.prior == false)
  }

  @Test(arguments: [false, true])
  func anUnreadableRecordAtLaunchCountsAsOwnedAndIsLogged(sleepDisabled: Bool) {
    let (machine, fake) = make(sleepDisabled: sleepDisabled, stored: .unreadable)
    machine.launched()
    #expect(
      fake.calls == [
        .recordRead, .log("reconcile ambiguous"), .writeSleepDisabled(false), .readSleepDisabled, .lidClosed,
        .clamshellEdge, .recordWrite(owns: false, prior: false),
        .log("release reason=reconcile sleepDisabled=0 edge=done"),
      ])
    #expect(fake.sleepDisabled == false)
    #expect(fake.storedRecord?.owns == false)
  }

  @Test func aLaunchReleaseThatFailsIsRetried() {
    let (machine, fake) = make(sleepDisabled: true, stored: Self.owningRecord)
    fake.setWriteSucceeds(false)
    machine.launched()
    #expect(machine.needsWatch)
    #expect(fake.logLines == ["reconcile owned", "ERROR release failed step=pmset retryIn=5"])
    fake.setWriteSucceeds(true)
    fake.advance(seconds: 5)
    machine.watch()
    #expect(fake.sleepDisabled == false)
    #expect(fake.storedRecord?.owns == false)
    #expect(!machine.needsWatch)
  }

  @Test func aFailedRecordResetAtLaunchIsLoggedAndOwnsNothing() {
    let (machine, fake) = make(sleepDisabled: true)
    fake.setRecordWriteSucceeds(false)
    machine.launched()
    #expect(fake.logLines == ["reconcile none", "ERROR reconcile record write failed"])
    #expect(fake.pmsetWrites.isEmpty)
    #expect(!machine.needsWatch)
  }

  @Test func statusReportsTheHoldAndTheReadingsAndChangesNothing() {
    let (machine, fake) = owned()
    let answer = machine.status(appVersion: 1)
    #expect(
      answer.status
        == HelperStatus(
          helperVersion: 1, sleepDisabled: true, owns: true, prior: false, engaged: true, batteryPercent: 80,
          onBattery: false, warningLevel: 1, thermalLevel: 0, thermalCritical: false, lastReleaseReason: nil,
          exiting: false))
    #expect(!answer.exitAfterReply)
    #expect(fake.calls == [.readSleepDisabled, .power, .thermal])
  }

  @Test func statusAfterAReleaseNamesTheReason() {
    let (machine, _) = owned()
    machine.connectionEnded(remaining: 0)
    let status = machine.status(appVersion: 1).status
    #expect(status.sleepDisabled == false)
    #expect(!status.owns)
    #expect(!status.engaged)
    #expect(status.lastReleaseReason == "connection")
  }

  @Test func statusOfAnAlreadyOnHoldReportsThePriorValue() {
    let (machine, _) = alreadyOn()
    let status = machine.status(appVersion: 1).status
    #expect(status.sleepDisabled == true)
    #expect(!status.owns)
    #expect(status.prior == true)
    #expect(status.engaged)
  }

  @Test func statusWithUnreadableReadingsLeavesThemOut() {
    let (machine, fake) = make(sleepDisabled: nil)
    fake.setPower(nil)
    fake.setThermal(nil)
    #expect(machine.status(appVersion: 1).status == HelperStatus(helperVersion: 1))
  }

  @Test func aStaleHelperThatIsNotEngagedExitsAfterItsReply() {
    let (machine, fake) = make(sleepDisabled: true)
    let answer = machine.status(appVersion: 2)
    #expect(answer.status.exiting)
    #expect(answer.exitAfterReply)
    #expect(machine.shouldExit)
    #expect(fake.holdCalls == [.readSleepDisabled])
    #expect(fake.logLines == ["status stale exit=now"])
  }

  @Test func aStaleHelperThatIsEngagedDefersItsExitToTheNextRelease() {
    let (machine, fake) = owned()
    for _ in 0..<2 {
      let answer = machine.status(appVersion: 2)
      #expect(!answer.status.exiting)
      #expect(!answer.exitAfterReply)
      #expect(!machine.shouldExit)
    }
    #expect(fake.logLines == ["status stale exit=deferred"])
    #expect(fake.pmsetWrites.isEmpty)
    #expect(machine.clear().code == .cleared)
    #expect(machine.shouldExit)
    #expect(machine.status(appVersion: 2).status.exiting)
  }

  @Test func aStaleHelperHoldingAValueItDoesNotOwnAlsoDefers() {
    let (machine, fake) = alreadyOn()
    #expect(!machine.status(appVersion: 2).exitAfterReply)
    #expect(!machine.shouldExit)
    machine.connectionEnded(remaining: 0)
    #expect(machine.shouldExit)
    #expect(fake.pmsetWrites.isEmpty)
  }

  @Test func aDeferredExitWaitsForAReleaseThatCompletes() {
    let (machine, fake) = owned()
    _ = machine.status(appVersion: 2)
    fake.setWriteSucceeds(false)
    _ = machine.clear()
    #expect(!machine.shouldExit)
    fake.setWriteSucceeds(true)
    fake.advance(seconds: 5)
    machine.watch()
    #expect(machine.shouldExit)
  }

  @Test func aCurrentVersionNeverAsksToExit() {
    let (machine, fake) = make()
    let answer = machine.status(appVersion: 1)
    #expect(!answer.status.exiting)
    #expect(!answer.exitAfterReply)
    #expect(!machine.shouldExit)
    #expect(fake.logLines.isEmpty)
  }

  @Test func theVersionComesFromTheInitialiser() {
    let fake = FakeHelperSystem()
    let machine = HelperMachine(system: fake, record: fake, log: fake, clock: fake, version: 5)
    #expect(machine.status(appVersion: 5).status.helperVersion == 5)
    #expect(!machine.shouldExit)
    #expect(machine.status(appVersion: 1).exitAfterReply)
  }

  @Test func aSetOnAHelperThatIsAboutToExitIsRefused() {
    let (machine, fake) = make()
    _ = machine.status(appVersion: 2)
    fake.forget()
    #expect(machine.set() == HelperReply(code: .refused, message: "exiting"))
    #expect(fake.holdCalls.isEmpty)
  }

  @Test func aSetWhileASignalsReleaseIsStillRetryingIsRefused() {
    let (machine, fake) = owned()
    fake.setWriteSucceeds(false)
    machine.signal(SIGTERM)
    fake.setWriteSucceeds(true)
    fake.forget()
    #expect(machine.set() == HelperReply(code: .refused, message: "exiting"))
    #expect(fake.calls == [.log("set refused reason=exiting")])
    #expect(machine.needsWatch)
    fake.advance(seconds: 5)
    machine.watch()
    #expect(fake.sleepDisabled == false)
    #expect(fake.storedRecord?.owns == false)
    #expect(machine.shouldExit)
  }

  @Test func powerAndThermalEventsWhileIdleDoAndLogNothing() {
    let (machine, fake) = make(sleepDisabled: true)
    machine.power(nil)
    machine.power(Self.battery(3))
    machine.thermal(nil)
    machine.thermal(Self.pressure(4))
    #expect(fake.calls.isEmpty)
    #expect(machine.status(appVersion: 1).status.lastReleaseReason == nil)
  }

  @Test func theLimitsAreTheDocumentedOnes() {
    #expect(HelperMachine.heartbeatTimeoutSeconds == 55)
    #expect(HelperMachine.watchPeriodSeconds == 5)
    #expect(HelperMachine.batteryFloorPercent == 10)
    #expect(HelperMachine.thermalTrappingLevel == 3)
    #expect(HelperMachine.verifyPollMilliseconds == 50)
    #expect(HelperMachine.verifyWindowSeconds == 2)
    #expect(HelperMachine.retrySeconds == 5)
  }

  @Test func everyLineOfEveryTriggerUsesFixedWordsOnly() {
    var lines: [String] = []
    for trigger in Trigger.allCases {
      let (machine, fake) = owned()
      fire(trigger, machine, fake)
      lines += fake.logLines
    }
    for state in Unsafe.allCases {
      let (machine, fake) = make()
      arrange(state, fake)
      _ = machine.set()
      lines += fake.logLines
    }
    for stored in [HelperRecordRead.missing, Self.owningRecord, .unreadable] {
      let (machine, fake) = make(sleepDisabled: true, stored: stored)
      fake.setEdgeSucceeds(false)
      machine.launched()
      _ = machine.status(appVersion: 2)
      lines += fake.logLines
    }
    let failing = make()
    failing.fake.setRecordWriteSucceeds(false)
    failing.machine.launched()
    lines += failing.fake.logLines
    #expect(lines.count > 40)
    for line in lines {
      #expect(line.unicodeScalars.allSatisfy { Self.isLogScalar($0) }, "\(line)")
    }
  }
}
