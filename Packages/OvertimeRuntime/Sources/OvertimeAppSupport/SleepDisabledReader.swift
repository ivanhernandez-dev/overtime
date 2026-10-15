import Foundation
import OvertimeSystem

public enum SleepDisabledReader {
  public static let pmset = "/usr/bin/pmset"

  public static func parse(_ outcome: ToolOutcome) -> Bool? {
    guard case .finished(0, let stdout, _) = outcome else { return nil }
    for line in stdout.split(separator: "\n") {
      let words = line.split(whereSeparator: \.isWhitespace)
      if words.first == "SleepDisabled", words.count >= 2 {
        return words[1] == "1"
      }
    }
    return false
  }

  public static func read(tools: any ToolPort) -> Bool? {
    parse(tools.run(pmset, ["-g"]))
  }
}
