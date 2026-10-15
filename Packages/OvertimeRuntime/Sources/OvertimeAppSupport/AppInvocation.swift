import Foundation

public enum ResetBackendChoice: Sendable, Equatable {
  case iokit
  case record(String)
}

public enum AppInvocation: Sendable, Equatable {
  case app
  case reset(ResetBackendChoice)
  case uninstall(purge: Bool)
  case usage(String)

  public static let resetFlag = "--reset"
  public static let clearBackendFlag = "--clear-backend"
  public static let recordPrefix = "record:"
  public static let uninstallFlag = "--uninstall"
  public static let purgeFlag = "--purge"
  public static let usageExitCode: Int32 = 64

  public static func parse(_ arguments: [String], allowsRecordBackend: Bool) -> AppInvocation {
    if arguments.first == uninstallFlag {
      let rest = Array(arguments.dropFirst())
      if rest.isEmpty {
        return .uninstall(purge: false)
      }
      if rest == [purgeFlag] {
        return .uninstall(purge: true)
      }
      return .usage(usage(allowsRecordBackend: allowsRecordBackend))
    }
    guard arguments.first == resetFlag else { return .app }
    let rest = Array(arguments.dropFirst())
    if rest.isEmpty {
      return .reset(.iokit)
    }
    if allowsRecordBackend, rest.count == 2, rest[0] == clearBackendFlag, rest[1].hasPrefix(recordPrefix) {
      let path = String(rest[1].dropFirst(recordPrefix.count))
      if !path.isEmpty {
        return .reset(.record(path))
      }
    }
    return .usage(usage(allowsRecordBackend: allowsRecordBackend))
  }

  static func usage(allowsRecordBackend: Bool) -> String {
    var text = "usage: Overtime --reset"
    if allowsRecordBackend {
      text += "\n       Overtime --reset --clear-backend record:<path>"
    }
    text += "\n       Overtime --uninstall [--purge]"
    return text
  }
}
