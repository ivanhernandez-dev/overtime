import Foundation

enum TempDirectoryError: Error {
  case creationFailed(Int32)
}

final class TempDirectory: Sendable {
  let url: URL

  init() throws {
    url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "overtime-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  private init(existing: URL) {
    url = existing
  }

  static func short() throws -> TempDirectory {
    var template = Array("/tmp/ot.XXXXXX".utf8CString)
    let created = template.withUnsafeMutableBufferPointer { buffer in
      mkdtemp(buffer.baseAddress) != nil
    }
    guard created else { throw TempDirectoryError.creationFailed(errno) }
    let bytes = template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return TempDirectory(existing: URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self), isDirectory: true))
  }

  var path: String {
    url.path(percentEncoded: false)
  }

  deinit {
    try? FileManager.default.removeItem(at: url)
  }
}
