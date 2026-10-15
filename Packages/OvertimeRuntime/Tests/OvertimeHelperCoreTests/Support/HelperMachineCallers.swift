import OvertimeHelperCore

extension HelperConnectionID {
  static let app = HelperConnectionID(1)
  static let other = HelperConnectionID(2)
}

extension HelperMachine {
  func set() -> HelperReply {
    set(from: .app)
  }

  func status(appVersion: Int) -> (status: HelperStatus, exitAfterReply: Bool) {
    status(appVersion: appVersion, from: .app)
  }

  func connectionEnded(remaining: Int) {
    connectionEnded(.app, remaining: remaining)
  }
}
