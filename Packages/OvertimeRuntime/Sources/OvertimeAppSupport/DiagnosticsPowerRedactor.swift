public enum DiagnosticsPowerRedactor {
  public static let addressToken = "<address>"
  public static let uuidToken = "<uuid>"
  public static let deviceToken = "<device>"
  public static let driverToken = "<driver>"

  static let uuidGroups = [8, 4, 4, 4, 12]
  static let minimumAddressPairs = 6
  static let address = Array(addressToken.utf8)
  static let uuid = Array(uuidToken.utf8)
  static let device = Array(deviceToken.utf8)
  static let driver = Array(driverToken.utf8)
  static let productMarker = Array("product:".utf8)
  static let productEnd = Array(" eventType:".utf8)
  static let ownerMarker = Array("owner=".utf8)
  static let audioMarker = Array("com.apple.audio.".utf8)
  static let audioEnd = Array(".context".utf8)
  static let resourcesMarker = Array("Resources:".utf8)
  static let audioResources = [Array("audio-in ".utf8), Array("audio-out ".utf8)]
  static let driverMarker = Array(" driver is slow".utf8)
  static let builtIn = Array("BuiltIn".utf8)
  static let directions = [Array(":input".utf8), Array(":output".utf8)]
  static let newline = UInt8(ascii: "\n")
  static let quote = UInt8(ascii: "\"")
  static let hyphen = UInt8(ascii: "-")
  static let colon = UInt8(ascii: ":")
  static let bracketOpen = UInt8(ascii: "[")
  static let bracketClose = UInt8(ascii: "]")

  public static func redact(_ text: String) -> String {
    var output = [UInt8]()
    output.reserveCapacity(text.utf8.count)
    let lines = text.utf8.split(separator: newline, omittingEmptySubsequences: false)
    for (index, line) in lines.enumerated() {
      if index > 0 { output.append(newline) }
      output += redactLine(Array(line))
    }
    return String(decoding: output, as: UTF8.self)
  }

  static func redactLine(_ line: [UInt8]) -> [UInt8] {
    var bytes = replacingTokens(in: line)
    bytes = replacingProducts(in: bytes)
    bytes = replacingOwner(in: bytes)
    bytes = replacingAudioNames(in: bytes)
    bytes = replacingAudioResources(in: bytes)
    return replacingDrivers(in: bytes)
  }

  static func replacingTokens(in line: [UInt8]) -> [UInt8] {
    var output = [UInt8]()
    output.reserveCapacity(line.count)
    var index = 0
    while index < line.count {
      if index == 0 || !isHex(line[index - 1]) {
        if let length = uuidLength(in: line, at: index) {
          output += uuid
          index += length
          continue
        }
        if let length = addressLength(in: line, at: index) {
          output += address
          index += length
          continue
        }
      }
      output.append(line[index])
      index += 1
    }
    return output
  }

  static func uuidLength(in line: [UInt8], at start: Int) -> Int? {
    var index = start
    for (position, count) in uuidGroups.enumerated() {
      if position > 0 {
        guard index < line.count, line[index] == hyphen else { return nil }
        index += 1
      }
      guard index + count <= line.count, line[index..<(index + count)].allSatisfy(isHex) else { return nil }
      index += count
    }
    guard index == line.count || !isHex(line[index]) else { return nil }
    return index - start
  }

  static func addressLength(in line: [UInt8], at start: Int) -> Int? {
    guard isPair(line, at: start) else { return nil }
    var pairs = 1
    var index = start + 2
    while index < line.count, line[index] == hyphen || line[index] == colon, isPair(line, at: index + 1) {
      pairs += 1
      index += 3
    }
    if index < line.count, isHex(line[index]) {
      pairs -= 1
      index -= 3
    }
    return pairs >= minimumAddressPairs ? index - start : nil
  }

  static func replacingProducts(in line: [UInt8]) -> [UInt8] {
    var output = [UInt8]()
    var index = 0
    while let marker = find(productMarker, in: line, from: index) {
      let start = marker + productMarker.count
      let limit = valueLimit(of: line, from: start, nextMarker: productMarker)
      let next = find(productMarker, in: line, from: start) ?? line.count
      let end = find(productEnd, in: line, from: start, to: next) ?? limit
      output += line[index..<start]
      if end > start { output += device }
      index = end
    }
    output += line[index...]
    return output
  }

  static func valueLimit(of line: [UInt8], from start: Int, nextMarker: [UInt8]) -> Int {
    let next = find(nextMarker, in: line, from: start) ?? line.count
    let closing = closingQuote(in: line, from: start) ?? trimmedEnd(of: line, from: start)
    return min(next, closing)
  }

  static func closingQuote(in line: [UInt8], from start: Int) -> Int? {
    guard let last = line.lastIndex(of: quote), last >= start else { return nil }
    let after = last + 1
    guard after == trimmedEnd(of: line, from: after) || isBlank(line[after]) else { return nil }
    return last
  }

  static func replacingOwner(in line: [UInt8]) -> [UInt8] {
    guard let marker = find(ownerMarker, in: line, from: 0) else { return line }
    let start = marker + ownerMarker.count
    let end = trimmedEnd(of: line, from: start)
    guard end > start else { return line }
    return Array(line[..<start]) + device + Array(line[end...])
  }

  static func replacingAudioNames(in line: [UInt8]) -> [UInt8] {
    var output = [UInt8]()
    var index = 0
    while let marker = find(audioMarker, in: line, from: index) {
      let start = marker + audioMarker.count
      let limit = valueLimit(of: line, from: start, nextMarker: audioMarker)
      output += line[index..<start]
      index = start
      if let end = find(audioEnd, in: line, from: start, to: limit) {
        let name = Array(line[start..<end])
        output += isNeutral(name) ? name : device
        index = end
        continue
      }
      let unquoted = line[start..<limit].firstIndex(of: quote) ?? limit
      guard !isContextIdentifier(Array(line[start..<unquoted])) else { continue }
      if limit > start { output += device }
      index = limit
    }
    output += line[index...]
    return output
  }

  static let contextPrefix = Array("context".utf8)
  static let dot = UInt8(ascii: ".")

  static func isContextIdentifier(_ name: [UInt8]) -> Bool {
    guard name.starts(with: contextPrefix) else { return false }
    let rest = name.dropFirst(contextPrefix.count)
    let digits = rest.prefix(while: isDigit)
    guard !digits.isEmpty else { return false }
    let suffix = rest.dropFirst(digits.count)
    guard let first = suffix.first else { return true }
    return first == dot && suffix.count > 1 && suffix.dropFirst().allSatisfy(isAlphanumeric)
  }

  static func isDigit(_ byte: UInt8) -> Bool {
    (48...57).contains(byte)
  }

  static func replacingAudioResources(in line: [UInt8]) -> [UInt8] {
    let content = line.drop(while: isBlank)
    guard content.starts(with: resourcesMarker) else { return line }
    let from = content.startIndex + resourcesMarker.count
    let starts = audioResources.compactMap { resource in
      find(resource, in: line, from: from).map { $0 + resource.count }
    }
    guard let start = starts.min() else { return line }
    let end = trimmedEnd(of: line, from: start)
    guard end > start, !isNeutral(Array(line[start..<end])) else { return line }
    return Array(line[..<start]) + device + Array(line[end...])
  }

  static func replacingDrivers(in line: [UInt8]) -> [UInt8] {
    var output = [UInt8]()
    var index = 0
    while let marker = find(driverMarker, in: line, from: index) {
      let next = marker + driverMarker.count
      if let open = line[index..<marker].lastIndex(of: bracketOpen), open + 1 < marker,
        !line[(open + 1)..<marker].contains(bracketClose)
      {
        output += line[index...open]
        output += driver
        output += line[marker..<next]
      } else {
        output += line[index..<next]
      }
      index = next
    }
    output += line[index...]
    return output
  }

  static func isNeutral(_ name: [UInt8]) -> Bool {
    if name.isEmpty || name == uuid { return true }
    if name.starts(with: builtIn) { return name.allSatisfy(isAlphanumeric) }
    guard name.starts(with: address) else { return false }
    let rest = Array(name[address.count...])
    return rest.isEmpty || directions.contains(rest)
  }

  static func find(_ needle: [UInt8], in line: [UInt8], from start: Int, to limit: Int? = nil) -> Int? {
    let end = (limit ?? line.count) - needle.count
    guard start <= end else { return nil }
    return (start...end).first { line[$0..<($0 + needle.count)].elementsEqual(needle) }
  }

  static func trimmedEnd(of line: [UInt8], from start: Int) -> Int {
    var end = line.count
    while end > start, isBlank(line[end - 1]) || line[end - 1] == 13 {
      end -= 1
    }
    return end
  }

  static func isPair(_ line: [UInt8], at index: Int) -> Bool {
    index + 1 < line.count && isHex(line[index]) && isHex(line[index + 1])
  }

  static func isHex(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
  }

  static func isAlphanumeric(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
  }

  static func isBlank(_ byte: UInt8) -> Bool {
    byte == 32 || byte == 9
  }
}
