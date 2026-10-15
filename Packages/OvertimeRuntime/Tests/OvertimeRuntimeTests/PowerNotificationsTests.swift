import CIOKitShim
import Foundation
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing
import os

struct PowerNotificationsTests {
  static let boundSeconds: Double = 10

  @Test func startRegistersAndStopDeregistersWithoutTouchingSleep() async {
    let notifications = PowerNotifications()
    let stream = notifications.start()
    #expect(notifications.isRegistered)
    #expect(notifications.watchesClamshell)
    notifications.stop()
    #expect(!notifications.isRegistered)
    #expect(!notifications.watchesClamshell)
    let received = OSAllocatedUnfairLock<[Event]>(initialState: [])
    #expect(
      await Engine.bounded(seconds: Self.boundSeconds) {
        for await event in stream {
          received.withLock { $0.append(event) }
        }
      })
    #expect(received.withLock { $0 }.isEmpty)
  }

  @Test func aSecondStartReplacesTheFirstRegistration() {
    let notifications = PowerNotifications()
    let first = notifications.start()
    let second = notifications.start()
    withExtendedLifetime((first, second)) {
      #expect(notifications.isRegistered)
      notifications.stop()
      #expect(!notifications.isRegistered)
    }
  }

  @Test func sleepMessagesAreAcknowledgedAndWakeMessagesBecomeEvents() {
    #expect(PowerNotifications.needsAcknowledgement(message: OTMessageCanSystemSleep))
    #expect(PowerNotifications.needsAcknowledgement(message: OTMessageSystemWillSleep))
    #expect(!PowerNotifications.needsAcknowledgement(message: OTMessageSystemHasPoweredOn))
    #expect(PowerNotifications.systemEvent(message: OTMessageSystemWillSleep) == .systemWillSleep)
    #expect(PowerNotifications.systemEvent(message: OTMessageSystemHasPoweredOn) == .systemHasPoweredOn)
    #expect(PowerNotifications.systemEvent(message: OTMessageCanSystemSleep) == nil)
    #expect(PowerNotifications.systemEvent(message: OTMessageSystemWillPowerOn) == nil)
  }

  @Test func clamshellMessagesCarryTheLidAndSleepBits() {
    let message = OTPMMessageClamshellStateChange
    #expect(
      PowerNotifications.interestEvent(message: message, argument: OTClamshellStateBit | OTClamshellSleepBit)
        == .lidChanged(closed: true, sleepBit: true, externalDisplays: nil))
    #expect(
      PowerNotifications.interestEvent(message: message, argument: 0)
        == .lidChanged(closed: false, sleepBit: false, externalDisplays: nil))
    #expect(PowerNotifications.interestEvent(message: OTPMMessageSystemPowerEventOccurred, argument: 1) == nil)
  }

  @Test func theEngineStepsSystemPowerEventsFromItsStream() async throws {
    let clock = FakeClock()
    let interpreter = CapturingInterpreter()
    let (events, continuation) = AsyncStream<Event>.makeStream()
    let engine = Engine(
      mode: .live,
      settings: Settings(),
      clock: clock,
      interpreter: interpreter,
      sources: EngineSources(
        transcriptSeed: { [] }, sampleTick: { TickFacts(fullWake: true) }, systemPowerStream: { events })
    )
    await engine.step(.tick(TickFacts(fullWake: true)))
    await engine.step(.transcriptActivity(TranscriptActivity(at: clock.mono())))
    #expect(await engine.state.hold.lidClose == .held)
    let running = Task { await engine.run() }
    continuation.yield(.systemHasPoweredOn)
    let deadline = ContinuousClock.now + .seconds(5)
    while await engine.state.hold.wakeBurst.isEmpty && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await engine.state.hold.wakeBurst.count == 6)
    #expect(
      await Engine.bounded(seconds: Self.boundSeconds) {
        await engine.stop()
        continuation.finish()
        await running.value
      })
  }
}
