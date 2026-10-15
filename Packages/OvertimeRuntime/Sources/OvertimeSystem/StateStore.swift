import Foundation
import OvertimeCore

public enum StateStore {
  public static let maxFileBytes = 65_536

  public static func read(at url: URL) -> PersistedSnapshot {
    let path = url.path(percentEncoded: false)
    var info = stat()
    guard lstat(path, &info) == 0 else { return errno == ENOENT ? .missing : .corrupt }
    guard info.st_mode & S_IFMT == S_IFREG, info.st_size <= maxFileBytes,
      let data = FileManager.default.contents(atPath: path)
    else { return .corrupt }
    return StateCodec.decode(data)
  }

  public static func write(_ state: PersistedState, to url: URL) throws {
    try StateCodec.encode(state).write(to: url, options: .atomic)
    guard chmod(url.path(percentEncoded: false), 0o600) == 0 else {
      throw CocoaError(.fileWriteNoPermission, userInfo: [NSURLErrorKey: url])
    }
  }
}

public enum StatusReport {
  public static func json(_ snapshot: PersistedSnapshot) -> String {
    switch snapshot {
    case .missing:
      return #"{"state":"missing"}"#
    case .corrupt:
      return #"{"state":"corrupt"}"#
    case .state(let state):
      guard let data = try? StateCodec.encode(state) else { return #"{"state":"unencodable"}"# }
      return String(decoding: data, as: UTF8.self)
    }
  }
}
