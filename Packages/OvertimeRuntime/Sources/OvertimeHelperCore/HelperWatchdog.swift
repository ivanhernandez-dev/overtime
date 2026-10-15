public struct HelperWatchdog: Sendable, Equatable {
  public static let checkSeconds: Double = 5
  public static let stallSeconds: Double = 30
  public static let leewaySeconds: Double = 1

  public enum Step: Sendable, Equatable {
    case ask
    case wait
    case stalled
  }

  private var askedAt: Double?

  public init() {}

  public mutating func check(now: Double) -> Step {
    guard let askedAt else {
      self.askedAt = now
      return .ask
    }
    return now - askedAt >= Self.stallSeconds ? .stalled : .wait
  }

  public mutating func answered() {
    askedAt = nil
  }
}
