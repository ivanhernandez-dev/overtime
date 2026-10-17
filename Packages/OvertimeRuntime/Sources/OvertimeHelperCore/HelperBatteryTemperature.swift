public enum HelperBatteryTemperature {
  public static let plausibleCentidegrees = -4000...10000

  public static func celsius(centidegrees: Int) -> Int? {
    guard plausibleCentidegrees.contains(centidegrees) else { return nil }
    return centidegrees >= 0 ? centidegrees / 100 : -((-centidegrees + 99) / 100)
  }
}
