import Foundation

public struct DiagnosticsRedactor: Sendable {
  public static let homePlaceholder = "~"
  public static let networkPlaceholder = "<network>"

  enum SlashStyle: CaseIterable, Sendable {
    case plain
    case backslash
    case unicode
  }

  struct Pattern: Sendable, Equatable {
    var bytes: [UInt8]
    var replacement: [UInt8]
  }

  let patterns: [Pattern]
  private let byFirstByte: [[Pattern]]

  public init(homeDirectory: String, realHomeDirectory: String? = nil, networkNames: [String]) {
    var seen = Set<[UInt8]>()
    var patterns: [Pattern] = []
    let home = Array(Self.homePlaceholder.utf8)
    let network = Array(Self.networkPlaceholder.utf8)
    let directories = [homeDirectory, realHomeDirectory ?? ""].map(Self.trimmedDirectory)
    for directory in directories where directory.utf8.count > 1 {
      for form in Self.forms(of: directory) where seen.insert(form).inserted {
        patterns.append(Pattern(bytes: form, replacement: home))
      }
    }
    for name in networkNames where !name.isEmpty {
      for form in Self.forms(of: name) where seen.insert(form).inserted {
        patterns.append(Pattern(bytes: form, replacement: network))
      }
    }
    self.patterns = patterns
    var table = [[Pattern]](repeating: [], count: 256)
    for pattern in patterns.sorted(by: { $0.bytes.count > $1.bytes.count }) {
      table[Int(pattern.bytes[0])].append(pattern)
    }
    byFirstByte = table
  }

  public func redact(_ text: String) -> String {
    String(decoding: redact(Data(text.utf8)), as: UTF8.self)
  }

  public func redact(_ data: Data) -> Data {
    guard !patterns.isEmpty else { return data }
    let input = [UInt8](data)
    var output = [UInt8]()
    output.reserveCapacity(input.count)
    var copied = 0
    var index = 0
    while index < input.count {
      guard let pattern = match(in: input, at: index) else {
        index += 1
        continue
      }
      output.append(contentsOf: input[copied..<index])
      output.append(contentsOf: pattern.replacement)
      index += pattern.bytes.count
      copied = index
    }
    output.append(contentsOf: input[copied...])
    return Data(output)
  }

  private func match(in input: [UInt8], at index: Int) -> Pattern? {
    let remaining = input.count - index
    return byFirstByte[Int(input[index])].first { pattern in
      pattern.bytes.count <= remaining && input[index..<(index + pattern.bytes.count)].elementsEqual(pattern.bytes)
    }
  }

  static func trimmedDirectory(_ path: String) -> String {
    var trimmed = path
    while trimmed.count > 1, trimmed.hasSuffix("/") {
      trimmed.removeLast()
    }
    return trimmed
  }

  static func forms(of secret: String) -> [[UInt8]] {
    var forms = [Array(secret.utf8)]
    for slash in SlashStyle.allCases {
      for asciiOnly in [false, true] {
        for upperHex in [false, true] {
          let form = Array(escaped(secret, slash: slash, asciiOnly: asciiOnly, upperHex: upperHex).utf8)
          if !forms.contains(form) { forms.append(form) }
        }
      }
    }
    return forms
  }

  static func escaped(_ text: String, slash: SlashStyle, asciiOnly: Bool, upperHex: Bool) -> String {
    var result = ""
    for scalar in text.unicodeScalars {
      switch scalar {
      case "\"": result += "\\\""
      case "\\": result += "\\\\"
      case "/":
        switch slash {
        case .plain: result += "/"
        case .backslash: result += "\\/"
        case .unicode: result += unicodeEscape(scalar, upperHex: upperHex)
        }
      case "\n": result += "\\n"
      case "\r": result += "\\r"
      case "\t": result += "\\t"
      case "\u{08}": result += "\\b"
      case "\u{0C}": result += "\\f"
      default:
        if scalar.value < 0x20 || (asciiOnly && scalar.value >= 0x80) {
          result += unicodeEscape(scalar, upperHex: upperHex)
        } else {
          result.unicodeScalars.append(scalar)
        }
      }
    }
    return result
  }

  static func unicodeEscape(_ scalar: Unicode.Scalar, upperHex: Bool) -> String {
    String(scalar).utf16.reduce(into: "") { result, unit in
      let digits = String(unit, radix: 16, uppercase: upperHex)
      result += "\\u" + String(repeating: "0", count: 4 - digits.count) + digits
    }
  }
}
