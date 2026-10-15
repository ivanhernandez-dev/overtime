import Foundation

public enum PauseSpec: Sendable, Equatable, Codable {
  case forSeconds(Double)
  case until(Date)
  case indefinite
}

public enum ForceSpec: Sendable, Equatable, Codable {
  case forSeconds(Double)
  case indefinite
}

public enum UserCommand: Sendable, Equatable {
  case pause(PauseSpec)
  case force(ForceSpec)
  case releaseUntilIdle
  case resume
  case sleepNow
}

public enum PauseState: Sendable, Equatable {
  case untilMono(Instant, wall: Date)
  case untilWall(Date)
  case indefinite
}

public enum ForceState: Sendable, Equatable {
  case untilMono(Instant)
  case indefinite
}
