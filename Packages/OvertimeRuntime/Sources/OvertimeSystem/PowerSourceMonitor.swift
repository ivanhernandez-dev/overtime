import Darwin
import Foundation
import IOKit.ps
import OvertimeCore
import notify

public struct PowerSourceDescription: Sendable, Equatable {
  public var type: String?
  public var currentCapacity: Int?
  public var maxCapacity: Int?

  public init(type: String? = nil, currentCapacity: Int? = nil, maxCapacity: Int? = nil) {
    self.type = type
    self.currentCapacity = currentCapacity
    self.maxCapacity = maxCapacity
  }
}

public final class PowerSourceMonitor: @unchecked Sendable {
  private let pollSeconds: Double
  private let reader: @Sendable () -> PowerReading?
  private let temperatureReader: @Sendable () -> BatteryTemperatureReading
  private let queue = DispatchQueue(label: "io.github.ivanhernandez-dev.overtime.power-source-monitor")
  private var token: Int32 = NOTIFY_TOKEN_INVALID
  private var timer: (any DispatchSourceTimer)?
  private var continuation: AsyncStream<PowerReading?>.Continuation?
  private var lastPublished: PowerReading??
  private var powerGeneration = 0
  private var temperatureContinuation: AsyncStream<BatteryTemperatureReading>.Continuation?
  private var lastTemperature: BatteryTemperatureReading?
  private var temperatureGeneration = 0
  private var retainedSelf: PowerSourceMonitor?

  public init(
    pollSeconds: Double = Timing.batteryPollSeconds,
    reader: @escaping @Sendable () -> PowerReading? = PowerSourceMonitor.readSystem,
    temperatureReader: @escaping @Sendable () -> BatteryTemperatureReading = BatteryTemperatureReader.readSystem
  ) {
    self.pollSeconds = pollSeconds
    self.reader = reader
    self.temperatureReader = temperatureReader
  }

  deinit {
    if token != NOTIFY_TOKEN_INVALID {
      notify_cancel(token)
    }
    timer?.cancel()
    continuation?.finish()
    temperatureContinuation?.finish()
  }

  public func read() -> PowerReading? {
    reader()
  }

  public func readTemperature() -> BatteryTemperatureReading {
    temperatureReader()
  }

  public func startTemperatureReporting() -> AsyncStream<BatteryTemperatureReading> {
    let (stream, continuation) = AsyncStream.makeStream(
      of: BatteryTemperatureReading.self, bufferingPolicy: .bufferingNewest(16))
    let previous: AsyncStream<BatteryTemperatureReading>.Continuation? = queue.sync {
      let previous = temperatureContinuation
      temperatureGeneration += 1
      let generation = temperatureGeneration
      continuation.onTermination = { [weak self] _ in
        self?.endTemperature(generation)
      }
      temperatureContinuation = continuation
      lastTemperature = nil
      startSources()
      publishTemperature()
      return previous
    }
    previous?.finish()
    return stream
  }

  public var isActive: Bool {
    queue.sync { token != NOTIFY_TOKEN_INVALID || timer != nil }
  }

  public func start() -> AsyncStream<PowerReading> {
    let reports = startReporting()
    return AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
      let task = Task {
        for await reading in reports {
          if let reading {
            continuation.yield(reading)
          }
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }

  public func startReporting() -> AsyncStream<PowerReading?> {
    let (stream, continuation) = AsyncStream.makeStream(of: PowerReading?.self, bufferingPolicy: .bufferingNewest(16))
    let previous: AsyncStream<PowerReading?>.Continuation? = queue.sync {
      let previous = self.continuation
      powerGeneration += 1
      let generation = powerGeneration
      continuation.onTermination = { [weak self] _ in
        self?.endPower(generation)
      }
      self.continuation = continuation
      lastPublished = nil
      startSources()
      publishPower()
      return previous
    }
    previous?.finish()
    return stream
  }

  public func stop() {
    let finished:
      (
        power: AsyncStream<PowerReading?>.Continuation?,
        temperature: AsyncStream<BatteryTemperatureReading>.Continuation?
      ) = queue.sync {
        let current = (power: continuation, temperature: temperatureContinuation)
        continuation = nil
        lastPublished = nil
        temperatureContinuation = nil
        lastTemperature = nil
        stopSources()
        return current
      }
    finished.power?.finish()
    finished.temperature?.finish()
  }

  private func endPower(_ generation: Int) {
    queue.sync {
      guard generation == powerGeneration, continuation != nil else { return }
      continuation = nil
      lastPublished = nil
      if temperatureContinuation == nil {
        stopSources()
      }
    }
  }

  private func endTemperature(_ generation: Int) {
    queue.sync {
      guard generation == temperatureGeneration, temperatureContinuation != nil else { return }
      temperatureContinuation = nil
      lastTemperature = nil
      if continuation == nil {
        stopSources()
      }
    }
  }

  private func startSources() {
    retainedSelf = self
    if token == NOTIFY_TOKEN_INVALID {
      var newToken = NOTIFY_TOKEN_INVALID
      let status = notify_register_dispatch(kIOPSNotifyAnyPowerSource, &newToken, queue) { [weak self] _ in
        self?.publish()
      }
      if status == NOTIFY_STATUS_OK {
        token = newToken
      }
    }
    guard timer == nil else { return }
    let interval = DispatchTimeInterval.nanoseconds(Int(clamping: Instant.nanoseconds(forSeconds: pollSeconds)))
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(500))
    timer.setEventHandler { [weak self] in
      self?.publish()
    }
    timer.resume()
    self.timer = timer
  }

  private func stopSources() {
    if token != NOTIFY_TOKEN_INVALID {
      notify_cancel(token)
      token = NOTIFY_TOKEN_INVALID
    }
    timer?.cancel()
    timer = nil
    retainedSelf = nil
  }

  private func publish() {
    publishPower()
    publishTemperature()
  }

  private func publishPower() {
    guard let continuation else { return }
    let reading = reader()
    if let lastPublished, lastPublished == reading { return }
    lastPublished = .some(reading)
    continuation.yield(reading)
  }

  private func publishTemperature() {
    guard let temperatureContinuation else { return }
    let reading = temperatureReader()
    if let lastTemperature, lastTemperature == reading { return }
    lastTemperature = reading
    temperatureContinuation.yield(reading)
  }

  public static func classify(providingType: String?, sources: [PowerSourceDescription]) -> PowerReading {
    guard !sources.isEmpty else { return .noBattery }
    let battery = sources.first { $0.type == kIOPSInternalBatteryType } ?? sources.first
    let percent = battery.flatMap(percentage)
    if providingType == kIOPSACPowerValue {
      return .ac(percent: percent)
    }
    return .battery(percent: percent)
  }

  static func percentage(_ source: PowerSourceDescription) -> Int? {
    guard let current = source.currentCapacity, current >= 0 else { return nil }
    guard let maximum = source.maxCapacity, maximum > 0, maximum != 100 else { return min(current, 100) }
    return min(100, Int((Double(current) * 100 / Double(maximum)).rounded()))
  }

  @Sendable public static func readSystem() -> PowerReading? {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
      let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
    else { return nil }
    let providingType = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
    let sources = list.compactMap { source -> PowerSourceDescription? in
      guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
      else { return nil }
      return PowerSourceDescription(
        type: description[kIOPSTypeKey] as? String,
        currentCapacity: description[kIOPSCurrentCapacityKey] as? Int,
        maxCapacity: description[kIOPSMaxCapacityKey] as? Int
      )
    }
    return classify(providingType: providingType, sources: sources)
  }
}
