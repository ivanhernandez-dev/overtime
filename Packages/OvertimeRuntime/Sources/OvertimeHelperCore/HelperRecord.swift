import Foundation

public struct HelperRecord: Codable, Sendable, Equatable {
  public let owns: Bool
  public let prior: Bool
  public let at: Double

  public init(owns: Bool, prior: Bool, at: Double) {
    self.owns = owns
    self.prior = prior
    self.at = at
  }
}

public enum HelperRecordRead: Sendable, Equatable {
  case missing
  case loaded(HelperRecord)
  case unreadable
}

public protocol HelperRecordPort {
  func read() -> HelperRecordRead
  func write(_ record: HelperRecord) -> Bool
}

enum HelperFolder {
  enum State {
    case missing
    case usable
    case refused
  }

  static func path(of directory: URL) -> String {
    var path = directory.path(percentEncoded: false)
    while path.count > 1, path.hasSuffix("/") {
      path.removeLast()
    }
    return path
  }

  static func state(_ path: String, owner: uid_t) -> State {
    var info = stat()
    guard lstat(path, &info) == 0 else { return errno == ENOENT ? .missing : .refused }
    guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == owner, info.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
      return .refused
    }
    return .usable
  }

  static func ensure(_ path: String, owner: uid_t, mode: mode_t) -> Bool {
    if state(path, owner: owner) == .missing {
      mkdir(path, mode)
    }
    return state(path, owner: owner) == .usable
  }

  static func isRegular(_ descriptor: Int32) -> Bool {
    var info = stat()
    return fstat(descriptor, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
  }

  static func writeAll(_ bytes: [UInt8], to descriptor: Int32) -> Bool {
    var offset = 0
    while offset < bytes.count {
      let count = bytes[offset...].withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
      if count < 0 {
        if errno == EINTR { continue }
        return false
      }
      guard count > 0 else { return false }
      offset += count
    }
    return true
  }
}

public struct HelperRecordStore: HelperRecordPort, Sendable {
  public static let fileName = "helper-state.json"
  public static let maxBytes = 4_096
  static let folderMode: mode_t = 0o700
  static let fileMode: mode_t = 0o600

  private let directory: String
  private let requiredOwner: uid_t

  public init(directory: URL, requiredOwner: uid_t) {
    self.directory = HelperFolder.path(of: directory)
    self.requiredOwner = requiredOwner
  }

  private var path: String { directory + "/" + Self.fileName }

  public func read() -> HelperRecordRead {
    switch HelperFolder.state(directory, owner: requiredOwner) {
    case .missing: return .missing
    case .refused: return .unreadable
    case .usable: break
    }
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { return errno == ENOENT ? .missing : .unreadable }
    defer { close(descriptor) }
    guard HelperFolder.isRegular(descriptor), let contents = Self.contents(of: descriptor),
      let record = try? JSONDecoder().decode(HelperRecord.self, from: contents)
    else { return .unreadable }
    return .loaded(record)
  }

  public func write(_ record: HelperRecord) -> Bool {
    guard HelperFolder.ensure(directory, owner: requiredOwner, mode: Self.folderMode) else { return false }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let encoded = try? encoder.encode(record) else { return false }
    let temporary = path + ".tmp"
    let flags = O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
    let descriptor = open(temporary, flags, Self.fileMode)
    guard descriptor >= 0 else { return false }
    var stored =
      HelperFolder.isRegular(descriptor) && fchmod(descriptor, Self.fileMode) == 0
      && HelperFolder.writeAll(Array(encoded), to: descriptor)
      && (fcntl(descriptor, F_FULLFSYNC) == 0 || fsync(descriptor) == 0)
    stored = close(descriptor) == 0 && stored
    guard stored, rename(temporary, path) == 0 else {
      unlink(temporary)
      return false
    }
    return syncFolder()
  }

  private func syncFolder() -> Bool {
    let descriptor = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    return fsync(descriptor) == 0
  }

  private static func contents(of descriptor: Int32) -> Data? {
    var contents = Data()
    var buffer = [UInt8](repeating: 0, count: maxBytes + 1)
    while contents.count <= maxBytes {
      let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
      if count < 0 {
        if errno == EINTR { continue }
        return nil
      }
      if count == 0 { break }
      contents.append(contentsOf: buffer[0..<count])
    }
    return contents.count <= maxBytes ? contents : nil
  }
}
