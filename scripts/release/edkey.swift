import CryptoKit
import Foundation

struct EdKeyFailure: Error {
  let message: String
}

func writeError(_ message: String) {
  FileHandle.standardError.write(Data((message + "\n").utf8))
}

func readData(_ path: String) throws -> Data {
  guard let data = FileManager.default.contents(atPath: path) else {
    throw EdKeyFailure(message: "edkey: cannot read \(path)")
  }
  return data
}

func publicKey(seedFile: String) throws -> String {
  let data = try readData(seedFile)
  let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  guard let seed = Data(base64Encoded: text), seed.count == 32 else {
    throw EdKeyFailure(message: "edkey: the seed is not the base64 of 32 bytes")
  }
  let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
  return key.publicKey.rawRepresentation.base64EncodedString()
}

func appPublicKey(plistPath: String) throws -> Curve25519.Signing.PublicKey {
  let data = try readData(plistPath)
  let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
  guard let info = plist as? [String: Any], let text = info["SUPublicEDKey"] as? String,
    let raw = Data(base64Encoded: text), raw.count == 32
  else {
    throw EdKeyFailure(message: "edkey: no valid SUPublicEDKey in \(plistPath)")
  }
  return try Curve25519.Signing.PublicKey(rawRepresentation: raw)
}

func captures(_ pattern: String, in text: String) throws -> [[String]] {
  let regex = try NSRegularExpression(pattern: pattern)
  let range = NSRange(text.startIndex..<text.endIndex, in: text)
  return regex.matches(in: text, range: range).map { match in
    (0..<match.numberOfRanges).map { index in
      guard let found = Range(match.range(at: index), in: text) else { return "" }
      return String(text[found])
    }
  }
}

func attribute(_ name: String, in element: String) throws -> String? {
  let pattern = "\\s" + NSRegularExpression.escapedPattern(for: name) + "=\"([^\"]*)\""
  return try captures(pattern, in: element).first?[1]
}

func verifySignedFeed(_ feed: Data, key: Curve25519.Signing.PublicKey) throws -> Data {
  let marker = Data("<!-- sparkle-signatures:".utf8)
  guard let markerRange = feed.range(of: marker, options: .backwards) else {
    throw EdKeyFailure(message: "edkey: feed signature missing")
  }
  let trailer = String(decoding: feed[markerRange.upperBound...], as: UTF8.self)
  guard let signatureText = try captures("edSignature: *([A-Za-z0-9+/=]+)", in: trailer).first?[1],
    let lengthText = try captures("length: *([0-9]+)", in: trailer).first?[1],
    let length = Int(lengthText), let signature = Data(base64Encoded: signatureText)
  else {
    throw EdKeyFailure(message: "edkey: feed signature comment malformed")
  }
  let signedEnd = feed.startIndex + length
  guard length > 0, signedEnd <= markerRange.lowerBound else {
    throw EdKeyFailure(message: "edkey: feed signature length \(length) out of range")
  }
  let signed = feed[feed.startIndex..<signedEnd]
  guard key.isValidSignature(signature, for: signed) else {
    throw EdKeyFailure(message: "edkey: feed signature invalid")
  }
  return Data(signed)
}

func verifyArchive(feed: Data, archivePath: String, key: Curve25519.Signing.PublicKey) throws {
  let text = String(decoding: feed, as: UTF8.self)
  let enclosures = try captures("<enclosure\\b[^>]*>", in: text)
  guard enclosures.count == 1, let element = enclosures.first?.first else {
    throw EdKeyFailure(message: "edkey: expected one enclosure, found \(enclosures.count)")
  }
  guard let url = try attribute("url", in: element),
    let lengthText = try attribute("length", in: element), let length = Int(lengthText),
    let signatureText = try attribute("sparkle:edSignature", in: element),
    let signature = Data(base64Encoded: signatureText)
  else {
    throw EdKeyFailure(message: "edkey: enclosure lacks url, length or sparkle:edSignature")
  }
  let archive = try readData(archivePath)
  guard archive.count == length else {
    throw EdKeyFailure(message: "edkey: archive length \(archive.count) differs from enclosure length \(length)")
  }
  let name = (archivePath as NSString).lastPathComponent
  guard url.hasSuffix("/" + name) else {
    throw EdKeyFailure(message: "edkey: enclosure url \(url) does not end with \(name)")
  }
  guard key.isValidSignature(signature, for: archive) else {
    throw EdKeyFailure(message: "edkey: archive signature invalid")
  }
}

func report(_ error: Error) {
  if let failure = error as? EdKeyFailure {
    writeError(failure.message)
  } else {
    writeError("edkey: \(error)")
  }
}

func verifyFeed(plistPath: String, appcastPath: String, archivePath: String) -> Bool {
  let signedFeed: Data
  let key: Curve25519.Signing.PublicKey
  do {
    key = try appPublicKey(plistPath: plistPath)
    signedFeed = try verifySignedFeed(try readData(appcastPath), key: key)
    print("edkey: feed signature valid")
  } catch {
    report(error)
    return false
  }
  do {
    try verifyArchive(feed: signedFeed, archivePath: archivePath, key: key)
    print("edkey: archive signature valid")
    return true
  } catch {
    report(error)
    return false
  }
}

let arguments = Array(CommandLine.arguments.dropFirst())
let usage = "usage: edkey pub <seed-file> | edkey verify-feed <Info.plist> <appcast.xml> <archive>"

switch (arguments.first, arguments.count) {
case ("pub", 2):
  do {
    print(try publicKey(seedFile: arguments[1]))
  } catch {
    report(error)
    exit(1)
  }
case ("verify-feed", 4):
  exit(verifyFeed(plistPath: arguments[1], appcastPath: arguments[2], archivePath: arguments[3]) ? 0 : 1)
default:
  writeError(usage)
  exit(64)
}
