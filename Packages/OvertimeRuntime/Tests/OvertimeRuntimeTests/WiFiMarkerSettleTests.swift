import Foundation
import OvertimeCore
import OvertimeSystem
import Testing
import os

struct WiFiMarkerSettleTests {
  static let readPower = CycleFixture.readPower
  static let expired = Decision(keyword: .net, verb: "marker expired")

  final class Sink: Sendable {
    private let box = OSAllocatedUnfairLock<[Decision]>(initialState: [])

    var decisions: [Decision] {
      box.withLock { $0 }
    }

    func append(_ decision: Decision) {
      box.withLock { $0.append(decision) }
    }
  }

  static func timedOutOff(pending: Bool) -> FakeWiFiRadio.Script {
    FakeWiFiRadio.Script(setPowerResults: [.failure(.timedOut)], powerCallPending: pending)
  }

  @Test func aTimedOutOffWhoseCallHasReturnedRemovesTheMarkerOnceOnIsSeenWithNoExtraWait() throws {
    let fixture = try CycleFixture(Self.timedOutOff(pending: false), toolSwitchesPower: true)
    #expect(fixture.controller.cycleWifi() == .succeeded)
    #expect(fixture.pauses.seconds == [WiFiController.offSeconds])
    #expect(!fixture.markerExists)
    #expect(fixture.radio.powered == true)
  }

  @Test func aTimedOutOffStillRunningAfterTheWatchKeepsTheMarkerWithWiFiOn() throws {
    let fixture = try CycleFixture(Self.timedOutOff(pending: true), toolSwitchesPower: true)
    #expect(fixture.controller.cycleWifi() == .succeeded)
    #expect(fixture.pauses.seconds == [WiFiController.offSeconds, WiFiController.settleSeconds])
    #expect(fixture.pauses.pauses.last?.marker != nil)
    #expect(fixture.radio.calls.suffix(1) == [Self.readPower])
    #expect(fixture.radio.powered == true)
    #expect(fixture.marker.read() == .present(interface: CycleFixture.interface))
  }

  @Test func anOffToolThatTimedOutIsAlsoWatchedBeforeTheMarkerGoes() throws {
    let fixture = try CycleFixture(
      FakeWiFiRadio.Script(setPowerResults: [CycleFixture.failure]), output: .timedOut)
    #expect(fixture.controller.cycleWifi() == WiFiController.Code.offFailed.outcome)
    #expect(fixture.pauses.seconds == [WiFiController.offSeconds, WiFiController.settleSeconds])
    #expect(!fixture.markerExists)
  }

  @Test func aLateOffThatLandsDuringTheWatchIsUndoneAndTheMarkerKeptWhileTheCallMayStillRun() throws {
    let fixture = try CycleFixture(Self.timedOutOff(pending: true), toolSwitchesPower: true)
    let radio = fixture.radio
    fixture.pauses.onPause { seconds in
      if seconds == WiFiController.settleSeconds { radio.update { $0.powered = false } }
    }
    _ = fixture.controller.cycleWifi()
    #expect(radio.powered == true)
    #expect(fixture.marker.read() == .present(interface: CycleFixture.interface))
    #expect(fixture.controller.recoverIfLeftOff(waitSeconds: 1) == .succeeded)
    #expect(fixture.marker.read() == .present(interface: CycleFixture.interface))
    radio.update { $0.powerCallPending = false }
    #expect(fixture.controller.recoverIfLeftOff(waitSeconds: 1) == .succeeded)
    #expect(!fixture.markerExists)
    #expect(radio.powered == true)
  }

  @Test func aLateOffThatLandsAndReturnsDuringTheWatchIsUndoneAndTheMarkerRemoved() throws {
    let fixture = try CycleFixture(Self.timedOutOff(pending: true), toolSwitchesPower: true)
    let radio = fixture.radio
    fixture.pauses.onPause { seconds in
      guard seconds == WiFiController.settleSeconds else { return }
      radio.update { script in
        script.powered = false
        script.powerCallPending = false
      }
    }
    _ = fixture.controller.cycleWifi()
    #expect(radio.powered == true)
    #expect(!fixture.markerExists)
  }

  @Test func aMarkerKeptForAPendingOffNeverExpiresSoTheLateOffIsUndoneHoursLater() throws {
    let fixture = try CycleFixture(Self.timedOutOff(pending: true), toolSwitchesPower: true)
    let sink = Sink()
    fixture.controller.attachLog { sink.append($0) }
    _ = fixture.controller.cycleWifi()
    #expect(fixture.marker.read() == .present(interface: CycleFixture.interface))
    fixture.clock.advance(seconds: 3600)
    fixture.radio.update { script in
      script.powered = false
      script.powerCallPending = false
    }
    #expect(fixture.controller.recoverIfLeftOff(waitSeconds: 1) == .succeeded)
    #expect(fixture.radio.powered == true)
    #expect(!fixture.markerExists)
    #expect(sink.decisions.isEmpty)
  }

  @Test func aMarkerKeptByACycleThatCouldNotTurnWiFiBackOnNeverExpires() throws {
    let failure = CycleFixture.failure
    let fixture = try CycleFixture(FakeWiFiRadio.Script(setPowerResults: [.success(()), failure, failure]))
    let sink = Sink()
    fixture.controller.attachLog { sink.append($0) }
    #expect(fixture.controller.cycleWifi() == WiFiController.Code.stillOff.outcome)
    #expect(fixture.radio.powered == false)
    fixture.clock.advance(seconds: 3600)
    #expect(fixture.controller.recoverIfLeftOff(waitSeconds: 1) == .succeeded)
    #expect(fixture.radio.powered == true)
    #expect(!fixture.markerExists)
    #expect(sink.decisions.isEmpty)
  }

  @Test(arguments: [601.0, 3600.0, 30 * 86400.0])
  func anUnsettledMarkerIsHonouredAtAnyAge(_ age: Double) throws {
    let fixture = try CycleFixture(FakeWiFiRadio.Script(powered: false))
    let sink = Sink()
    fixture.controller.attachLog { sink.append($0) }
    #expect(fixture.marker.write(interface: "en0", startedAt: fixture.clock.wall().addingTimeInterval(-age)))
    #expect(fixture.controller.recoverIfLeftOff(waitSeconds: 1) == .succeeded)
    #expect(fixture.radio.powered == true)
    #expect(!fixture.markerExists)
    #expect(sink.decisions.isEmpty)
  }

  @Test func aMarkerWrittenBeforeTheSettledFlagExistedIsHonoured() throws {
    let fixture = try CycleFixture(FakeWiFiRadio.Script(powered: false))
    try Data(#"{"interface":"en0","startedAt":0,"version":1}"#.utf8).write(to: fixture.marker.url)
    #expect(fixture.controller.recoverIfLeftOff(waitSeconds: 1) == .succeeded)
    #expect(fixture.radio.powered == true)
    #expect(!fixture.markerExists)
  }

  @Test(arguments: [601.0, 3600.0])
  func anExpiredMarkerIsRemovedWithOneLineAndNeverTurnsWiFiOn(_ age: Double) throws {
    let fixture = try CycleFixture(FakeWiFiRadio.Script(powered: false))
    let sink = Sink()
    fixture.controller.attachLog { sink.append($0) }
    #expect(
      fixture.marker.write(
        interface: "en0", startedAt: fixture.clock.wall().addingTimeInterval(-age), settled: true))
    #expect(fixture.controller.recoverIfLeftOff(waitSeconds: 1) == .succeeded)
    #expect(!fixture.markerExists)
    #expect(fixture.radio.writes.isEmpty)
    #expect(fixture.radio.powered == false)
    #expect(sink.decisions == [Self.expired])
    #expect(fixture.controller.recoverIfLeftOff(waitSeconds: 1) == .succeeded)
    #expect(sink.decisions == [Self.expired])
    let line = DecisionFormatter.line(Self.expired, wall: Date(), timeZone: .current)
    #expect(line.hasSuffix(" NET marker expired"))
  }

  @Test(arguments: [0.0, 599.0])
  func aSettledMarkerUnderTenMinutesOldIsRemovedWithoutTouchingTheRadioPower(_ age: Double) throws {
    let fixture = try CycleFixture(FakeWiFiRadio.Script(powered: false))
    let sink = Sink()
    fixture.controller.attachLog { sink.append($0) }
    #expect(
      fixture.marker.write(
        interface: "en0", startedAt: fixture.clock.wall().addingTimeInterval(-age), settled: true))
    #expect(fixture.controller.recoverIfLeftOff(waitSeconds: 1) == .succeeded)
    #expect(!fixture.markerExists)
    #expect(fixture.radio.writes.isEmpty)
    #expect(fixture.toolCalls.isEmpty)
    #expect(fixture.radio.powered == false)
    #expect(sink.decisions.isEmpty)
  }

  @Test func theControllerKnowsWhetherItKeptAMarkerWithoutReadingTheFileAgain() throws {
    let failure = CycleFixture.failure
    let fixture = try CycleFixture(FakeWiFiRadio.Script(setPowerResults: [.success(()), failure, failure]))
    #expect(!fixture.controller.markerKept)
    #expect(fixture.controller.cycleWifi() == WiFiController.Code.stillOff.outcome)
    #expect(fixture.controller.markerKept)
    #expect(fixture.marker.remove())
    #expect(fixture.controller.markerKept)
    fixture.plantMarker()
    #expect(fixture.controller.recoverIfLeftOff(waitSeconds: 1) == .succeeded)
    #expect(!fixture.markerExists)
    #expect(!fixture.controller.markerKept)
    #expect(fixture.controller.cycleWifi() == .succeeded)
    #expect(!fixture.controller.markerKept)
  }

  @Test func aMarkerPresentBeforeTheFirstQueryIsSeenOnce() throws {
    let fixture = try CycleFixture()
    fixture.plantMarker()
    #expect(fixture.controller.markerKept)
    #expect(fixture.marker.remove())
    #expect(fixture.controller.markerKept)
  }

  @Test func aMarkerKeptForAPendingOffIsTracked() throws {
    let fixture = try CycleFixture(Self.timedOutOff(pending: true), toolSwitchesPower: true)
    #expect(fixture.controller.cycleWifi() == .succeeded)
    #expect(fixture.controller.markerKept)
    #expect(fixture.controller.recoverIfLeftOff(waitSeconds: 1) == .succeeded)
    #expect(fixture.controller.markerKept)
    fixture.radio.update { $0.powerCallPending = false }
    #expect(fixture.controller.recoverIfLeftOff(waitSeconds: 1) == .succeeded)
    #expect(!fixture.controller.markerKept)
  }

  @Test func anExpiredMarkerSeenBeforeAJoinIsRemovedWithoutTouchingTheRadioPower() async throws {
    let fixture = try CycleFixture(FakeWiFiRadio.Script(powered: false))
    #expect(
      fixture.marker.write(
        interface: "en0", startedAt: fixture.clock.wall().addingTimeInterval(-601), settled: true))
    let controller = fixture.controller
    _ = await OffPool.run { controller.joinHotspot(WiFiControllerJoinTests.hotspot) }
    #expect(!fixture.radio.writes.contains(CycleFixture.power(true)))
    #expect(!fixture.markerExists)
  }

  @Test func theLivePortPassesTheExpiryLineToItsSink() async throws {
    let fixture = try await NetworkCompositionTests.PortFixture(FakeWiFiRadio.Script(powered: false))
    let sink = NetworkCompositionTests.Sink()
    fixture.port.attachLog { sink.append($0) }
    #expect(
      fixture.marker.write(
        interface: "en0", startedAt: fixture.clock.wall().addingTimeInterval(-601), settled: true))
    _ = fixture.port.facts(lidClosed: true)
    _ = fixture.port.facts(lidClosed: false)
    #expect(await OffPool.eventually(seconds: 5) { !sink.decisions.isEmpty })
    try await NetworkCompositionTests.settle()
    #expect(sink.decisions == [Self.expired])
    #expect(fixture.marker.read() == .absent)
    #expect(fixture.radio.writes.isEmpty)
  }
}
