import Foundation

public struct ProcArgs: Sendable, Equatable {
  public var execPath: String
  public var argv0: String
  public var argv1: String?
  public var claudeConfigDirectory: String?

  public init(execPath: String, argv0: String, argv1: String?, claudeConfigDirectory: String? = nil) {
    self.execPath = execPath
    self.argv0 = argv0
    self.argv1 = argv1
    self.claudeConfigDirectory = claudeConfigDirectory
  }
}

public enum ProcArgsParser {
  public static let configDirectoryVariable = "CLAUDE_CONFIG_DIR"
  public static let maxConfigDirectoryBytes = 1024

  public static func parse(_ bytes: [UInt8]) -> ProcArgs? {
    let argcSize = MemoryLayout<Int32>.size
    guard bytes.count >= argcSize else { return nil }
    let argc = Int32(
      bitPattern: UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24)
    guard argc > 0 else { return nil }
    guard let (execPath, afterExecPath) = terminatedString(bytes, from: argcSize) else { return nil }
    var index = afterExecPath
    while index < bytes.count && bytes[index] == 0 {
      index += 1
    }
    guard let (argv0, afterArgv0) = terminatedString(bytes, from: index) else { return nil }
    var argv1: String?
    if argc >= 2, let (second, _) = terminatedString(bytes, from: afterArgv0) {
      argv1 = second
    }
    return ProcArgs(
      execPath: execPath, argv0: argv0, argv1: argv1,
      claudeConfigDirectory: configDirectory(bytes, argumentsStart: index, argc: Int(argc)))
  }

  private static let configDirectoryPrefix = Array((configDirectoryVariable + "=").utf8)

  private static func configDirectory(_ bytes: [UInt8], argumentsStart: Int, argc: Int) -> String? {
    var index = argumentsStart
    for _ in 0..<argc {
      guard let end = terminator(bytes, from: index) else { return nil }
      index = end + 1
    }
    while let end = terminator(bytes, from: index) {
      guard end > index else { return nil }
      let entry = bytes[index..<end]
      if entry.starts(with: configDirectoryPrefix) {
        let value = entry.dropFirst(configDirectoryPrefix.count)
        guard (1...maxConfigDirectoryBytes).contains(value.count) else { return nil }
        return String(bytes: value, encoding: .utf8)
      }
      index = end + 1
    }
    return nil
  }

  private static func terminator(_ bytes: [UInt8], from start: Int) -> Int? {
    guard start >= 0, start < bytes.count else { return nil }
    return bytes[start...].firstIndex(of: 0)
  }

  private static func terminatedString(_ bytes: [UInt8], from start: Int) -> (String, Int)? {
    guard start >= 0, start < bytes.count else { return nil }
    guard let end = bytes[start...].firstIndex(of: 0) else { return nil }
    return (String(decoding: bytes[start..<end], as: UTF8.self), end + 1)
  }
}
