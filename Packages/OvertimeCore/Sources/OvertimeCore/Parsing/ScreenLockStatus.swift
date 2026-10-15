import Foundation

public enum ScreenLockStatus: Sendable, Equatable {
  case immediate
  case delayed(seconds: Int)
  case off
  case unknown

  static let immediateForm = "screenLock delay is immediate"
  static let delayPrefix = "screenLock delay is "
  static let offForm = "screenLock is off"

  public static func parse(output: String, exitCode: Int32?, timedOut: Bool) -> ScreenLockStatus {
    guard !timedOut, exitCode == 0 else { return .unknown }
    if output.contains(immediateForm) { return .immediate }
    if output.contains(offForm) { return .off }
    guard let range = output.range(of: delayPrefix) else { return .unknown }
    let rest = output[range.upperBound...]
    let digits = rest.prefix { $0.isASCII && $0.isNumber }
    guard !digits.isEmpty, digits.count <= 9, let seconds = Int(digits),
      rest.dropFirst(digits.count).hasPrefix(" second")
    else { return .unknown }
    return .delayed(seconds: seconds)
  }
}
