import Darwin
import Foundation

public enum MarkerState: Sendable, Equatable {
  case absent
  case present(interface: String)
  case unreadable
}

public struct WiFiCycleMarker: Sendable {
  public static let maxBytes = 4096
  public static let version = 1
  static let maxStartedAtSeconds: Double = 1e15

  struct Contents: Codable, Equatable {
    var version: Int
    var interface: String
    var startedAt: Int64
    var settled: Bool?
  }

  public let url: URL

  public init(url: URL) {
    self.url = url
  }

  public func write(interface: String, startedAt: Date, settled: Bool = false) -> Bool {
    let seconds = startedAt.timeIntervalSince1970.rounded(.down)
    guard WiFiController.isValidInterface(interface), seconds.isFinite, abs(seconds) < Self.maxStartedAtSeconds
    else { return false }
    let contents = Contents(
      version: Self.version, interface: interface, startedAt: Int64(seconds), settled: settled ? true : nil)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(contents), data.count <= Self.maxBytes else { return false }
    let temporary = url.deletingLastPathComponent()
      .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
      .path(percentEncoded: false)
    let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { return false }
    let written = fchmod(descriptor, 0o600) == 0 && Self.writeAll(data, to: descriptor) && fsync(descriptor) == 0
    let closed = close(descriptor) == 0
    guard written, closed, rename(temporary, url.path(percentEncoded: false)) == 0 else {
      unlink(temporary)
      return false
    }
    return true
  }

  public func read() -> MarkerState {
    readWithStart().state
  }

  public func readWithStart() -> (state: MarkerState, startedAt: Date?, settled: Bool) {
    switch PrivateFile.read(at: url.path(percentEncoded: false), maxBytes: Self.maxBytes) {
    case .missing:
      return (.absent, nil, false)
    case .data(let data):
      guard let contents = try? JSONDecoder().decode(Contents.self, from: data), contents.version == Self.version,
        WiFiController.isValidInterface(contents.interface)
      else { return (.unreadable, nil, false) }
      let startedAt = Date(timeIntervalSince1970: Double(contents.startedAt))
      return (.present(interface: contents.interface), startedAt, contents.settled == true)
    case .notRegular, .tooLarge, .failed:
      return (.unreadable, nil, false)
    }
  }

  public func remove() -> Bool {
    unlink(url.path(percentEncoded: false)) == 0 || errno == ENOENT
  }

  private static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
    data.withUnsafeBytes { buffer -> Bool in
      guard let base = buffer.baseAddress else { return buffer.isEmpty }
      var offset = 0
      while offset < buffer.count {
        let count = Darwin.write(descriptor, base + offset, buffer.count - offset)
        if count < 0 {
          if errno == EINTR { continue }
          return false
        }
        offset += count
      }
      return true
    }
  }
}
