import Foundation

public enum StateCodec {
  public static let maxBootSessionLength = 128

  public static func encode(_ state: PersistedState) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(state)
  }

  public static func decode(_ data: Data) -> PersistedSnapshot {
    guard let object = try? JSONSerialization.jsonObject(with: data), let fields = object as? [String: Any] else {
      return .corrupt
    }
    guard let owns = boolean(fields["ownsHold"]) else { return .corrupt }
    var state = PersistedState()
    if let version = integer(fields["version"]), version >= 0, version <= Int64(Int32.max) {
      state.version = Int(version)
    }
    if let boot = fields["bootSessionUUID"] as? String, !boot.isEmpty, boot.utf8.count <= maxBootSessionLength {
      state.bootSessionUUID = boot
    }
    state.ownsHold = owns
    state.sentinelArmed = boolean(fields["sentinelArmed"]) ?? false
    state.switchedToHotspot = boolean(fields["switchedToHotspot"]) ?? false
    state.releaseUntilIdle = boolean(fields["releaseUntilIdle"]) ?? false
    state.forceActive = boolean(fields["forceActive"]) ?? false
    state.hotspotJoinStarted = boolean(fields["hotspotJoinStarted"]) ?? false
    state.pause = pause(fields["pause"])
    return .state(state)
  }

  static func pause(_ value: Any?) -> PersistedPause? {
    guard let fields = value as? [String: Any], let kind = fields["kind"] as? String else { return nil }
    let mono = integer(fields["monoDeadlineNanoseconds"]).flatMap { $0 >= 0 ? UInt64($0) : nil }
    let wall = (fields["wallDeadline"] as? String).flatMap(date)
    switch kind {
    case PersistedPause.timed:
      guard let mono, let wall else { return nil }
      return PersistedPause(kind: kind, monoDeadlineNanoseconds: mono, wallDeadline: wall)
    case PersistedPause.until:
      guard let wall else { return nil }
      return PersistedPause(kind: kind, wallDeadline: wall)
    case PersistedPause.indefinite:
      return PersistedPause(kind: kind)
    default:
      return nil
    }
  }

  static func boolean(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
    return number.boolValue
  }

  static func integer(_ value: Any?) -> Int64? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
      !CFNumberIsFloatType(number)
    else { return nil }
    return number.int64Value
  }

  static func date(_ text: String) -> Date? {
    try? Date(text, strategy: Date.ISO8601FormatStyle())
  }
}
