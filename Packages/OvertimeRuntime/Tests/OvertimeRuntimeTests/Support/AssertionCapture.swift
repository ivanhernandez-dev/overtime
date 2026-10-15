import Foundation
import OvertimeSystem

enum AssertionCaptureError: Error, Equatable {
  case unreadable(String)
  case noRows(String)
}

enum AssertionCapture {
  struct Row: Sendable, Equatable {
    let pid: Int32
    let processName: String
    let type: String
  }

  static let ordinaryMac = "pmset-assertions-ordinary-mac.txt"
  static let activeLevel = 255

  static func rows(at url: URL) throws -> [Row] {
    let path = url.path(percentEncoded: false)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
      throw AssertionCaptureError.unreadable(path)
    }
    let rows = text.split(separator: "\n").compactMap { row(in: $0) }
    guard !rows.isEmpty else { throw AssertionCaptureError.noRows(path) }
    return rows
  }

  static func rows(named name: String) throws -> [Row] {
    let fixtures = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures")
    return try rows(at: fixtures.appendingPathComponent(name))
  }

  static func table(from rows: [Row]) -> CoexistenceProbe.AssertionTable {
    var table: CoexistenceProbe.AssertionTable = [:]
    for row in rows {
      table[row.pid, default: []].append([
        "AssertLevel": NSNumber(value: activeLevel), "AssertType": row.type, "Process Name": row.processName,
      ])
    }
    return table
  }

  static func row(in line: Substring) -> Row? {
    let content = line.drop { $0 == " " }
    guard content.hasPrefix("pid ") else { return nil }
    let afterKeyword = content.dropFirst(4)
    let digits = afterKeyword.prefix { $0.isASCII && $0.isNumber }
    guard let pid = Int32(digits) else { return nil }
    let afterPID = afterKeyword.dropFirst(digits.count)
    guard afterPID.hasPrefix("("), let nameEnd = afterPID.range(of: "): [0x"),
      let named = afterPID.range(of: " named:", range: nameEnd.upperBound..<afterPID.endIndex),
      let type = afterPID[nameEnd.upperBound..<named.lowerBound].split(separator: " ").last
    else { return nil }
    let name = afterPID[afterPID.index(after: afterPID.startIndex)..<nameEnd.lowerBound]
    return Row(pid: pid, processName: String(name), type: String(type))
  }
}
