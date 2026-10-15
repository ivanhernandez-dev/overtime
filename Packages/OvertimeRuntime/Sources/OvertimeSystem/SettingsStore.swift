import Foundation
import OvertimeCore

public enum SettingsLoadResult: Sendable, Equatable {
  case missing
  case loaded(Settings)
  case invalid(reason: String)
}

public enum SettingsStoreError: Error, Equatable {
  case invalid(String)
}

public enum SettingsStore {
  public static let maxFileBytes = 1_048_576

  public static func load(from url: URL) -> SettingsLoadResult {
    let path = url.path(percentEncoded: false)
    var info = stat()
    guard stat(path, &info) == 0 else {
      return errno == ENOENT ? .missing : .invalid(reason: "unreadable")
    }
    guard info.st_mode & S_IFMT == S_IFREG else { return .invalid(reason: "notAFile") }
    guard Int(info.st_size) <= maxFileBytes else { return .invalid(reason: "tooLarge") }
    guard let handle = FileHandle(forReadingAtPath: path) else { return .invalid(reason: "unreadable") }
    defer { try? handle.close() }
    let data: Data
    do {
      data = try handle.read(upToCount: maxFileBytes + 1) ?? Data()
    } catch {
      return .invalid(reason: "unreadable")
    }
    guard data.count <= maxFileBytes else { return .invalid(reason: "tooLarge") }
    let settings: Settings
    do {
      settings = try JSONDecoder().decode(Settings.self, from: data)
    } catch {
      return .invalid(reason: "malformed")
    }
    if let problem = validationProblem(settings) {
      return .invalid(reason: problem)
    }
    return .loaded(settings)
  }

  public static func save(_ settings: Settings, to url: URL) throws {
    if let problem = validationProblem(settings) {
      throw SettingsStoreError.invalid(problem)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    try encoder.encode(settings).write(to: url, options: .atomic)
    guard chmod(url.path(percentEncoded: false), 0o600) == 0 else {
      throw CocoaError(.fileWriteNoPermission, userInfo: [NSURLErrorKey: url])
    }
  }

  public static func validationProblem(_ settings: Settings) -> String? {
    let percentages = 0...100
    guard percentages.contains(settings.batteryLowPercent) else { return "batteryLowPercent" }
    guard percentages.contains(settings.batteryResumePercent) else { return "batteryResumePercent" }
    guard settings.batteryLowPercent < settings.batteryResumePercent else { return "batteryLowPercent" }
    guard positive(settings.transcriptWindowSeconds) else { return "transcriptWindowSeconds" }
    guard positive(settings.releaseGraceSeconds) else { return "releaseGraceSeconds" }
    guard positive(settings.stuckWindowSeconds) else { return "stuckWindowSeconds" }
    guard settings.stuckWindowSeconds >= settings.transcriptWindowSeconds else { return "stuckWindowSeconds" }
    if let roots = settings.transcriptRoots, roots.contains(where: { !$0.hasPrefix("/") }) {
      return "transcriptRoots"
    }
    return nil
  }

  static func positive(_ value: Double) -> Bool {
    value.isFinite && value > 0
  }
}
