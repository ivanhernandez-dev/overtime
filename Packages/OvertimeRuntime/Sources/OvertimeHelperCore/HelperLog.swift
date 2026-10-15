import Foundation

public struct HelperLog: HelperLogPort, Sendable {
  public static let fileName = "helper.log"
  public static let rotatedFileName = "helper.log.1"
  public static let rotateBytes = 524_288
  static let folderMode: mode_t = 0o755
  static let fileMode: mode_t = 0o644

  private let directory: String
  private let requiredOwner: uid_t
  private let now: @Sendable () -> Date

  public init(directory: URL, requiredOwner: uid_t, now: @escaping @Sendable () -> Date = { Date() }) {
    self.directory = HelperFolder.path(of: directory)
    self.requiredOwner = requiredOwner
    self.now = now
  }

  private var path: String { directory + "/" + Self.fileName }

  public func record(_ line: String) {
    guard HelperFolder.ensure(directory, owner: requiredOwner, mode: Self.folderMode) else { return }
    var descriptor = openLog()
    guard descriptor >= 0 else { return }
    var info = stat()
    if fstat(descriptor, &info) == 0, Int(info.st_size) > Self.rotateBytes,
      rename(path, directory + "/" + Self.rotatedFileName) == 0
    {
      close(descriptor)
      descriptor = openLog()
      guard descriptor >= 0 else { return }
    }
    defer { close(descriptor) }
    let text = Self.stamp(now()) + " " + Self.sanitized(line) + "\n"
    _ = HelperFolder.writeAll(Array(text.utf8), to: descriptor)
  }

  static func sanitized(_ line: String) -> String {
    var cleaned = String.UnicodeScalarView()
    for scalar in line.unicodeScalars {
      cleaned.append((0x20...0x7E).contains(scalar.value) ? scalar : "?")
    }
    return String(cleaned)
  }

  static func stamp(_ date: Date) -> String {
    var seconds = time_t(date.timeIntervalSince1970.rounded(.down))
    var parts = tm()
    gmtime_r(&seconds, &parts)
    return String(
      format: "%04d-%02d-%02dT%02d:%02d:%02dZ", parts.tm_year + 1_900, parts.tm_mon + 1, parts.tm_mday,
      parts.tm_hour, parts.tm_min, parts.tm_sec)
  }

  private func openLog() -> Int32 {
    let flags = O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
    let descriptor = open(path, flags, Self.fileMode)
    guard descriptor >= 0 else { return -1 }
    guard HelperFolder.isRegular(descriptor), fchmod(descriptor, Self.fileMode) == 0 else {
      close(descriptor)
      return -1
    }
    return descriptor
  }
}
