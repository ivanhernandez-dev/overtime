import Foundation
import OvertimeCore

public enum CtlRequestError: Error, Equatable {
  case invalidRequest
  case unknownCommand

  public var message: String {
    switch self {
    case .invalidRequest: "invalid request"
    case .unknownCommand: "unknown command"
    }
  }
}

public enum CtlRequest: Sendable, Equatable, Codable {
  case pause(PauseSpec)
  case force(ForceSpec)
  case releaseUntilIdle
  case resume
  case status
  case sleepNow

  public static let maxSeconds: Double = 366 * 24 * 3600

  private enum CodingKeys: String, CodingKey {
    case command
    case seconds
    case until
    case indefinite
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard let command = try? container.decode(String.self, forKey: .command) else {
      throw CtlRequestError.invalidRequest
    }
    switch command {
    case "pause":
      let duration = try Self.duration(container, allowsUntil: true)
      switch duration {
      case .seconds(let seconds): self = .pause(.forSeconds(seconds))
      case .until(let date): self = .pause(.until(date))
      case .indefinite: self = .pause(.indefinite)
      }
    case "force":
      let duration = try Self.duration(container, allowsUntil: false)
      switch duration {
      case .seconds(let seconds): self = .force(.forSeconds(seconds))
      case .until: throw CtlRequestError.invalidRequest
      case .indefinite: self = .force(.indefinite)
      }
    case "releaseUntilIdle":
      self = .releaseUntilIdle
    case "resume":
      self = .resume
    case "status":
      self = .status
    case "sleepNow":
      self = .sleepNow
    default:
      throw CtlRequestError.unknownCommand
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .pause(let spec):
      try container.encode("pause", forKey: .command)
      switch spec {
      case .forSeconds(let seconds): try container.encode(seconds, forKey: .seconds)
      case .until(let date): try container.encode(Want.iso8601(date), forKey: .until)
      case .indefinite: try container.encode(true, forKey: .indefinite)
      }
    case .force(let spec):
      try container.encode("force", forKey: .command)
      switch spec {
      case .forSeconds(let seconds): try container.encode(seconds, forKey: .seconds)
      case .indefinite: try container.encode(true, forKey: .indefinite)
      }
    case .releaseUntilIdle:
      try container.encode("releaseUntilIdle", forKey: .command)
    case .resume:
      try container.encode("resume", forKey: .command)
    case .status:
      try container.encode("status", forKey: .command)
    case .sleepNow:
      try container.encode("sleepNow", forKey: .command)
    }
  }

  private enum Duration {
    case seconds(Double)
    case until(Date)
    case indefinite
  }

  private static func duration(_ container: KeyedDecodingContainer<CodingKeys>, allowsUntil: Bool) throws -> Duration {
    let present = [CodingKeys.seconds, .until, .indefinite].filter { container.contains($0) }
    guard present.count == 1, let key = present.first else { throw CtlRequestError.invalidRequest }
    switch key {
    case .seconds:
      guard let seconds = try? container.decode(Double.self, forKey: .seconds), seconds.isFinite, seconds > 0,
        seconds <= maxSeconds
      else { throw CtlRequestError.invalidRequest }
      return .seconds(seconds)
    case .until:
      guard allowsUntil, let text = try? container.decode(String.self, forKey: .until),
        let date = ControlProtocol.parseDate(text)
      else { throw CtlRequestError.invalidRequest }
      return .until(date)
    case .indefinite:
      guard (try? container.decode(Bool.self, forKey: .indefinite)) == true else {
        throw CtlRequestError.invalidRequest
      }
      return .indefinite
    case .command:
      throw CtlRequestError.invalidRequest
    }
  }
}

public struct StatusSnapshot: Sendable, Equatable, Codable {
  public var mode: String
  public var busy: Bool?
  public var wanted: Bool?
  public var reason: String?
  public var pause: String?
  public var pauseUntil: String?
  public var force: String?
  public var forceUntil: String?
  public var override: Bool
  public var batteryBlocked: Bool
  public var holdIdle: String?
  public var holdDisplay: String?
  public var holdError: Bool?

  public init(
    mode: String,
    busy: Bool? = nil,
    wanted: Bool? = nil,
    reason: String? = nil,
    pause: String? = nil,
    pauseUntil: String? = nil,
    force: String? = nil,
    forceUntil: String? = nil,
    override: Bool = false,
    batteryBlocked: Bool = false,
    holdIdle: String? = nil,
    holdDisplay: String? = nil,
    holdError: Bool? = nil
  ) {
    self.mode = mode
    self.busy = busy
    self.wanted = wanted
    self.reason = reason
    self.pause = pause
    self.pauseUntil = pauseUntil
    self.force = force
    self.forceUntil = forceUntil
    self.override = override
    self.batteryBlocked = batteryBlocked
    self.holdIdle = holdIdle
    self.holdDisplay = holdDisplay
    self.holdError = holdError
  }
}

public struct CtlResponse: Sendable, Equatable, Codable {
  public var ok: Bool
  public var status: StatusSnapshot?
  public var error: String?

  public init(ok: Bool, status: StatusSnapshot? = nil, error: String? = nil) {
    self.ok = ok
    self.status = status
    self.error = error
  }

  public static func failure(_ message: String) -> CtlResponse {
    CtlResponse(ok: false, error: message)
  }
}

public enum ControlProtocol {
  public static func decodeRequest(_ line: Data) -> Result<CtlRequest, CtlRequestError> {
    do {
      return .success(try JSONDecoder().decode(CtlRequest.self, from: line))
    } catch let error as CtlRequestError {
      return .failure(error)
    } catch {
      return .failure(.invalidRequest)
    }
  }

  public static func encodeLine<T: Encodable>(_ value: T) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data = (try? encoder.encode(value)) ?? Data(#"{"ok":false,"error":"encoding failed"}"#.utf8)
    data.append(0x0A)
    return data
  }

  public static func parseDate(_ text: String) -> Date? {
    if let date = try? Date(text, strategy: Date.ISO8601FormatStyle()) {
      return date
    }
    return try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
  }
}
