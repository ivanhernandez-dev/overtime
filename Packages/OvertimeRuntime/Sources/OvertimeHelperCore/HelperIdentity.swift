public struct HelperIdentity: Sendable, Equatable {
  public static let version = 2
  public static let certificateRoot = "9c54a8e3e576cc8e7eb6d5a2dc63aa7607b821ce"

  public static let release = HelperIdentity(
    appIdentifier: "io.github.ivanhernandez-dev.overtime", folderName: "Overtime")
  public static let dev = HelperIdentity(
    appIdentifier: "io.github.ivanhernandez-dev.overtime.dev", folderName: "Overtime Dev")

  public let appIdentifier: String
  public let helperIdentifier: String
  public let label: String
  public let machService: String
  public let plistName: String
  public let appRequirement: String
  public let helperRequirement: String
  public let supportDirectory: String
  public let logDirectory: String

  private init(appIdentifier: String, folderName: String) {
    let helperIdentifier = appIdentifier + ".helper"
    self.appIdentifier = appIdentifier
    self.helperIdentifier = helperIdentifier
    label = helperIdentifier
    machService = helperIdentifier
    plistName = helperIdentifier + ".plist"
    appRequirement = Self.requirement(identifier: appIdentifier)
    helperRequirement = Self.requirement(identifier: helperIdentifier)
    supportDirectory = "/Library/Application Support/" + folderName
    logDirectory = "/Library/Logs/" + folderName
  }

  private static func requirement(identifier: String) -> String {
    "identifier \"\(identifier)\" and certificate root = H\"\(certificateRoot)\""
  }
}
