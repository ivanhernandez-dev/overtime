import Foundation
import OvertimeCore
import OvertimeSystem
import Testing
import os

struct PowerSourceMonitorTests {
  final class ScriptedReader: Sendable {
    private let readings: OSAllocatedUnfairLock<[PowerReading?]>
    private let calls = OSAllocatedUnfairLock(initialState: 0)

    init(_ readings: [PowerReading?]) {
      self.readings = OSAllocatedUnfairLock(initialState: readings)
    }

    func next() -> PowerReading? {
      calls.withLock { $0 += 1 }
      return readings.withLock { list in
        list.count > 1 ? list.removeFirst() : list.first ?? nil
      }
    }

    var callCount: Int {
      calls.withLock { $0 }
    }
  }

  final class ScriptedTemperature: Sendable {
    private let readings: OSAllocatedUnfairLock<[BatteryTemperatureReading]>
    private let calls = OSAllocatedUnfairLock(initialState: 0)

    init(_ readings: [BatteryTemperatureReading]) {
      self.readings = OSAllocatedUnfairLock(initialState: readings)
    }

    func next() -> BatteryTemperatureReading {
      calls.withLock { $0 += 1 }
      return readings.withLock { list in
        list.count > 1 ? list.removeFirst() : list.first ?? .unavailable
      }
    }

    var callCount: Int {
      calls.withLock { $0 }
    }
  }

  func bounded<T: Sendable>(_ task: Task<T, Never>, timeout: Double) async -> T? {
    await withTaskGroup(of: T?.self) { group in
      group.addTask { await task.value }
      group.addTask {
        try? await Task.sleep(for: .milliseconds(Int(timeout * 1000)))
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }
  }

  func eventually(timeout: Double, _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .milliseconds(Int(timeout * 1000))
    while ContinuousClock.now < deadline {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
  }

  @Test func theTemperatureStreamYieldsTheFirstReadingAndThenOnlyChanges() async {
    let temperature = ScriptedTemperature([
      .celsius(30), .celsius(30), .celsius(31), .unreadable, .unreadable, .celsius(31),
    ])
    let monitor = PowerSourceMonitor(
      pollSeconds: 0.05, reader: { .ac(percent: 80) }, temperatureReader: { temperature.next() })
    let values = await collect(monitor.startTemperatureReporting(), count: 4, timeout: 5)
    #expect(values == [.celsius(30), .celsius(31), .unreadable, .celsius(31)])
    monitor.stop()
  }

  @Test func bothStreamsRunOnOneMonitorAndStopEndsBoth() async {
    let power = ScriptedReader([.ac(percent: 80)])
    let temperature = ScriptedTemperature([.celsius(30)])
    let monitor = PowerSourceMonitor(
      pollSeconds: 0.05, reader: { power.next() }, temperatureReader: { temperature.next() })
    let powerStream = monitor.startReporting()
    let temperatureStream = monitor.startTemperatureReporting()
    let powerCount = OSAllocatedUnfairLock(initialState: 0)
    let temperatureCount = OSAllocatedUnfairLock(initialState: 0)
    let powerConsumer = Task {
      for await _ in powerStream { powerCount.withLock { $0 += 1 } }
      return powerCount.withLock { $0 }
    }
    let temperatureConsumer = Task {
      for await _ in temperatureStream { temperatureCount.withLock { $0 += 1 } }
      return temperatureCount.withLock { $0 }
    }
    #expect(await eventually(timeout: 5) { powerCount.withLock { $0 } == 1 && temperatureCount.withLock { $0 } == 1 })
    #expect(monitor.isActive)
    monitor.stop()
    #expect(await bounded(powerConsumer, timeout: 5) == 1)
    #expect(await bounded(temperatureConsumer, timeout: 5) == 1)
    #expect(!monitor.isActive)
    let powerCalls = power.callCount
    let temperatureCalls = temperature.callCount
    try? await Task.sleep(for: .milliseconds(200))
    #expect(power.callCount == powerCalls)
    #expect(temperature.callCount == temperatureCalls)
  }

  @Test func endingTheTemperatureStreamKeepsThePowerStreamRunning() async {
    let level = OSAllocatedUnfairLock<PowerReading?>(initialState: .ac(percent: 80))
    let monitor = PowerSourceMonitor(
      pollSeconds: 0.05, reader: { level.withLock { $0 } }, temperatureReader: { .celsius(30) })
    let powerStream = monitor.startReporting()
    let temperatureStream = monitor.startTemperatureReporting()
    let seen = OSAllocatedUnfairLock<[PowerReading?]>(initialState: [])
    let temperatureStarted = OSAllocatedUnfairLock(initialState: false)
    let powerConsumer = Task {
      for await reading in powerStream { seen.withLock { $0.append(reading) } }
    }
    let temperatureConsumer = Task {
      for await _ in temperatureStream { temperatureStarted.withLock { $0 = true } }
    }
    #expect(await eventually(timeout: 5) { temperatureStarted.withLock { $0 } && !seen.withLock { $0 }.isEmpty })
    temperatureConsumer.cancel()
    _ = await bounded(temperatureConsumer, timeout: 5)
    try? await Task.sleep(for: .milliseconds(100))
    #expect(monitor.isActive)
    level.withLock { $0 = .ac(percent: 81) }
    #expect(await eventually(timeout: 5) { seen.withLock { $0 }.contains(.ac(percent: 81)) })
    #expect(monitor.isActive)
    monitor.stop()
    #expect(!monitor.isActive)
    _ = await bounded(powerConsumer, timeout: 5)
  }

  @Test func readTemperatureAsksTheReader() {
    let monitor = PowerSourceMonitor(reader: { .noBattery }, temperatureReader: { .celsius(41) })
    #expect(monitor.readTemperature() == .celsius(41))
  }

  func collect<T: Sendable>(_ stream: AsyncStream<T>, count: Int, timeout: Double) async -> [T] {
    await withTaskGroup(of: [T]?.self) { group in
      group.addTask {
        var values: [T] = []
        for await value in stream {
          values.append(value)
          if values.count == count { break }
        }
        return values
      }
      group.addTask {
        try? await Task.sleep(for: .milliseconds(Int(timeout * 1000)))
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first ?? []
    }
  }

  @Test func readReturnsThisMacsPowerSource() {
    let reading = PowerSourceMonitor().read()
    #expect(reading != nil)
  }

  @Test func startYieldsTheCurrentReadingFirstAndStopCancelsEverything() async {
    let monitor = PowerSourceMonitor()
    let current = monitor.read()
    let stream = monitor.start()
    #expect(monitor.isActive)
    let first = await collect(stream, count: 1, timeout: 5)
    #expect(first.count == 1)
    switch (first.first, current) {
    case (.ac?, .ac?), (.battery?, .battery?), (.noBattery?, .noBattery?):
      break
    default:
      Issue.record(
        "first reading \(String(describing: first.first)) differs from read() \(String(describing: current))")
    }
    monitor.stop()
    #expect(!monitor.isActive)
  }

  @Test func onlyChangedReadingsAreYieldedAndFailuresAreReported() async {
    let reader = ScriptedReader([
      .battery(percent: 50), .battery(percent: 50), .battery(percent: 9), nil, nil, .ac(percent: 9),
    ])
    let monitor = PowerSourceMonitor(pollSeconds: 0.05, reader: { reader.next() })
    let values = await collect(monitor.startReporting(), count: 4, timeout: 5)
    #expect(values == [.battery(percent: 50), .battery(percent: 9), nil, .ac(percent: 9)])
    monitor.stop()
    #expect(!monitor.isActive)
    let callsAfterStop = reader.callCount
    try? await Task.sleep(for: .milliseconds(200))
    #expect(reader.callCount == callsAfterStop)
  }

  @Test func startDropsFailedReadings() async {
    let reader = ScriptedReader([nil, .battery(percent: 30)])
    let monitor = PowerSourceMonitor(pollSeconds: 0.05, reader: { reader.next() })
    let values = await collect(monitor.start(), count: 1, timeout: 5)
    #expect(values == [.battery(percent: 30)])
    monitor.stop()
  }

  @Test func stopFinishesTheStream() async {
    let monitor = PowerSourceMonitor(pollSeconds: 60, reader: { .noBattery })
    let stream = monitor.startReporting()
    let finished = Task {
      var count = 0
      for await _ in stream { count += 1 }
      return count
    }
    try? await Task.sleep(for: .milliseconds(100))
    monitor.stop()
    #expect(await finished.value == 1)
  }

  @Test func classifyMapsProvidingTypeAndSources() {
    let battery = PowerSourceDescription(type: "InternalBattery", currentCapacity: 69, maxCapacity: 100)
    #expect(PowerSourceMonitor.classify(providingType: "AC Power", sources: [battery]) == .ac(percent: 69))
    #expect(PowerSourceMonitor.classify(providingType: "Battery Power", sources: [battery]) == .battery(percent: 69))
    #expect(PowerSourceMonitor.classify(providingType: "AC Power", sources: []) == .noBattery)
    #expect(PowerSourceMonitor.classify(providingType: nil, sources: []) == .noBattery)
    let noCapacity = PowerSourceDescription(type: "InternalBattery")
    #expect(
      PowerSourceMonitor.classify(providingType: "Battery Power", sources: [noCapacity]) == .battery(percent: nil))
    let scaled = PowerSourceDescription(type: "InternalBattery", currentCapacity: 2500, maxCapacity: 5000)
    #expect(PowerSourceMonitor.classify(providingType: "Battery Power", sources: [scaled]) == .battery(percent: 50))
    let ups = PowerSourceDescription(type: "UPS", currentCapacity: 90, maxCapacity: 100)
    #expect(
      PowerSourceMonitor.classify(providingType: "Battery Power", sources: [ups, battery]) == .battery(percent: 69))
  }
}
