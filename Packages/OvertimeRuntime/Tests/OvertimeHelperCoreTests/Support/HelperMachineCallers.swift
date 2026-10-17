import OvertimeHelperCore

extension HelperConnectionID {
  static let app = HelperConnectionID(1)
  static let other = HelperConnectionID(2)
}

extension HelperMachine {
  func set() -> HelperReply {
    set(from: .app)
  }

  func set(floor: Int, ceiling: Int = HelperSafetyLimits.notGiven) -> HelperReply {
    set(
      from: .app,
      limits: HelperSafetyLimits(requestedBatteryFloorPercent: floor, requestedTemperatureCeilingCelsius: ceiling))
  }

  func status(appVersion: Int) -> (status: HelperStatus, exitAfterReply: Bool) {
    status(appVersion: appVersion, from: .app)
  }

  func connectionEnded(remaining: Int) {
    connectionEnded(.app, remaining: remaining)
  }
}
