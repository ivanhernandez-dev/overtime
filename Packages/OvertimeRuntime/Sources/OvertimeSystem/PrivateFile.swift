import Darwin
import Foundation

package enum PrivateFileRead: Equatable {
  case data(Data)
  case missing
  case notRegular
  case tooLarge
  case failed
}

package enum PrivateFile {
  package static func read(at path: String, maxBytes: Int, followSymlinks: Bool = false) -> PrivateFileRead {
    let flags = O_RDONLY | O_NONBLOCK | O_CLOEXEC | (followSymlinks ? 0 : O_NOFOLLOW)
    let descriptor = open(path, flags)
    guard descriptor >= 0 else {
      switch errno {
      case ENOENT: return .missing
      case ELOOP: return .notRegular
      default: return .failed
      }
    }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0 else { return .failed }
    guard info.st_mode & S_IFMT == S_IFREG else { return .notRegular }
    guard info.st_size <= maxBytes else { return .tooLarge }
    return readAll(descriptor, maxBytes: maxBytes)
  }

  package static func readTail(at path: String, maxBytes: Int) -> (read: PrivateFileRead, cut: Bool) {
    let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      switch errno {
      case ENOENT: return (.missing, false)
      case ELOOP: return (.notRegular, false)
      default: return (.failed, false)
      }
    }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0 else { return (.failed, false) }
    guard info.st_mode & S_IFMT == S_IFREG else { return (.notRegular, false) }
    guard info.st_size > maxBytes else { return (readAll(descriptor, maxBytes: maxBytes), false) }
    let start = info.st_size - off_t(maxBytes) - 1
    guard lseek(descriptor, start, SEEK_SET) == start, let read = readUpTo(descriptor, count: maxBytes + 1) else {
      return (.failed, false)
    }
    let newline = UInt8(ascii: "\n")
    guard let first = read.firstIndex(of: newline) else { return (.data(Data(read.suffix(maxBytes))), true) }
    return (.data(Data(read[read.index(after: first)...])), true)
  }

  private static func readUpTo(_ descriptor: Int32, count limit: Int) -> Data? {
    var contents = Data()
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while contents.count < limit {
      let wanted = min(buffer.count, limit - contents.count)
      let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, wanted) }
      if count < 0 {
        if errno == EINTR { continue }
        return nil
      }
      if count == 0 { break }
      contents.append(contentsOf: buffer[0..<count])
    }
    return contents
  }

  private static func readAll(_ descriptor: Int32, maxBytes: Int) -> PrivateFileRead {
    var contents = Data()
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while contents.count <= maxBytes {
      let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
      if count < 0 {
        if errno == EINTR { continue }
        return .failed
      }
      if count == 0 { break }
      contents.append(contentsOf: buffer[0..<count])
    }
    guard contents.count <= maxBytes else { return .tooLarge }
    return .data(contents)
  }
}
