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
