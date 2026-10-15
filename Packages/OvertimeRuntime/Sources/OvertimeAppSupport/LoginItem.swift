import Foundation
import OvertimeSystem

public enum LoginItemStatus: Sendable, Equatable {
  case enabled
  case requiresApproval
  case notRegistered
  case notFound

  public var isOn: Bool {
    self == .enabled || self == .requiresApproval
  }
}

public protocol LoginItemService: Sendable {
  var status: LoginItemStatus { get }
  func register() throws
  func unregister() throws
  func openSystemSettings()
}

public struct LoginItemCaption: Sendable, Equatable {
  public enum Tone: Sendable, Equatable {
    case warning
    case error
  }

  public static let toggleLabel = "Launch at login"
  public static let openLabel = "Open Login Items"
  public static let approvalText = "Needs your approval in System Settings > General > Login Items."
  public static let errorText =
    "Couldn't change the login item. Try again, or add Overtime in System Settings > General > Login Items."

  public let text: String
  public let tone: Tone

  public init(text: String, tone: Tone) {
    self.text = text
    self.tone = tone
  }

  public var actionLabel: String {
    Self.openLabel
  }

  public static func `for`(status: LoginItemStatus, lastError: String?) -> LoginItemCaption? {
    if lastError != nil { return LoginItemCaption(text: errorText, tone: .error) }
    guard status == .requiresApproval else { return nil }
    return LoginItemCaption(text: approvalText, tone: .warning)
  }
}

public struct LoginItemPanel: Sendable {
  public let service: any LoginItemService
  public private(set) var lastError: String?

  public init(service: any LoginItemService) {
    self.service = service
  }

  public var isOn: Bool {
    service.status.isOn
  }

  public var caption: LoginItemCaption? {
    LoginItemCaption.for(status: service.status, lastError: lastError)
  }

  public mutating func setEnabled(_ enabled: Bool, log: (String) -> Void) {
    guard enabled != isOn else { return }
    do {
      if enabled {
        try service.register()
      } else {
        try service.unregister()
      }
      lastError = nil
    } catch {
      let message = String(describing: error)
      lastError = message
      log(message)
    }
  }

  public func openSystemSettings() {
    service.openSystemSettings()
  }
}

public enum LoginItemRecordState: Sendable, Equatable {
  case missing
  case recorded(LoginItemRecord)
  case unreadable
}

public struct LoginItemRecord: Codable, Sendable, Equatable {
  public static let maxFileBytes = 4_096

  public var offered: Bool
  public var at: Date

  public init(offered: Bool, at: Date) {
    self.offered = offered
    self.at = at
  }

  public static func read(at url: URL) -> LoginItemRecordState {
    let data: Data
    switch PrivateFile.read(at: url.path(percentEncoded: false), maxBytes: maxFileBytes) {
    case .data(let contents): data = contents
    case .missing: return .missing
    case .notRegular, .tooLarge, .failed: return .unreadable
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let record = try? decoder.decode(LoginItemRecord.self, from: data) else { return .unreadable }
    return .recorded(record)
  }

  public func write(to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(self).write(to: url, options: .atomic)
    guard chmod(url.path(percentEncoded: false), 0o600) == 0 else {
      throw CocoaError(.fileWriteNoPermission, userInfo: [NSURLErrorKey: url])
    }
  }
}

public enum FirstRunLogin {
  public static func shouldRegister(record: LoginItemRecordState) -> Bool {
    record == .missing
  }

  @discardableResult
  public static func apply(
    service: any LoginItemService, recordURL: URL, now: Date, log: (String) -> Void = { _ in }
  ) -> Bool {
    guard shouldRegister(record: LoginItemRecord.read(at: recordURL)) else { return false }
    var registered = false
    if service.status.isOn {
      registered = true
    } else {
      do {
        try service.register()
        registered = true
      } catch {
        log(String(describing: error))
      }
    }
    do {
      try LoginItemRecord(offered: true, at: now).write(to: recordURL)
    } catch {
      log(String(describing: error))
    }
    return registered
  }
}
