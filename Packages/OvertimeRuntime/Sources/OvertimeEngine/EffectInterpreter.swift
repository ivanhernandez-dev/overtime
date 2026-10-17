import Foundation
import OvertimeCore
import OvertimeSystem

public protocol EffectInterpreter: Sendable {
  /// Reserves the batch's place in execution order before returning. Batches run in the order
  /// `enqueue` was called, so a caller on an actor keeps reducer order by calling it synchronously
  /// right after `Reducer.reduce`, with no suspension point in between.
  func enqueue(_ effects: [Effect], wall: Date) -> Task<[Event], Never>
  /// Writes one decision line without waiting behind queued batches, so a bounded stop stays bounded.
  func logNow(_ decision: Decision, wall: Date)
  var networkEvents: AsyncStream<Event>? { get }
  func closeNetwork()
  func drainNetwork() async
}

extension EffectInterpreter {
  public var networkEvents: AsyncStream<Event>? { nil }

  public func closeNetwork() {}

  public func drainNetwork() async {}

  public func perform(_ effects: [Effect], wall: Date) async -> [Event] {
    await enqueue(effects, wall: wall).value
  }

  public func logNow(_ decision: Decision, wall: Date) {
    _ = enqueue([.log(decision)], wall: wall)
  }
}

public struct RecordingInterpreter: EffectInterpreter {
  public let logger: FileLogger
  public let timeZone: TimeZone
  public let paths: Paths?

  public init(logger: FileLogger, timeZone: TimeZone = .current, paths: Paths? = nil) {
    self.logger = logger
    self.timeZone = timeZone
    self.paths = paths
  }

  public func enqueue(_ effects: [Effect], wall: Date) -> Task<[Event], Never> {
    let results = performNow(effects, wall: wall)
    return Task { results }
  }

  func performNow(_ effects: [Effect], wall: Date) -> [Event] {
    var results: [Event] = []
    for effect in effects {
      switch effect {
      case .log(let decision):
        logger.log(decision, wall: wall, timeZone: timeZone)
      case .persist(let state):
        guard let paths else { continue }
        do {
          try StateStore.write(state, to: paths.stateFile(.shadow))
        } catch {
          logger.log(Decision(keyword: .error, verb: "state write failed"), wall: wall, timeZone: timeZone)
        }
      case .idleAssertion(_, let id), .displayAssertion(_, let id), .clamshell(_, let id, _),
        .displaySleepNow(let id), .requestSleep(let id), .helper(_, let id, _):
        results.append(.effectResult(id, .succeeded))
      case .sentinel, .net:
        continue
      }
    }
    return results
  }
}
