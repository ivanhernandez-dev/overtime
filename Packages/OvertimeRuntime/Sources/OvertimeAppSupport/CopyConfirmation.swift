import Foundation

public enum CopyConfirmation {
  public static let copiedLabel = "Copied"
  public static let copiedSymbol = "checkmark"
  public static let announcement = "Command copied."
  public static let seconds: Double = 2
}

public struct CommandText: Equatable, Sendable {
  public var sentence: String
  public var command: String?

  public init(sentence: String, command: String? = nil) {
    self.sentence = sentence
    self.command = command
  }

  public static func split(_ text: String) -> CommandText {
    let command = Hints.sleepDisabledCommand
    guard text.hasSuffix(command) else { return CommandText(sentence: text) }
    return CommandText(sentence: String(text.dropLast(command.count)), command: command)
  }
}
