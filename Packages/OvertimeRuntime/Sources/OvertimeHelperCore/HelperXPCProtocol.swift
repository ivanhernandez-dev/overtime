import Foundation

@objc public protocol HelperXPCProtocol {
  func setSleepDisabled(
    _ enabled: Bool, batteryFloorPercent: Int, temperatureCeilingCelsius: Int,
    reply: @escaping @Sendable (Int32, String) -> Void)
  func status(appHelperVersion: Int, reply: @escaping @Sendable (Data) -> Void)
}
