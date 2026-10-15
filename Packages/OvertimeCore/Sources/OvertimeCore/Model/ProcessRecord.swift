import Foundation

public struct ProcessRecord: Sendable, Equatable {
  public static let noDevice = UInt32(bitPattern: -1)

  public var pid: Int32
  public var ppid: Int32
  public var uid: UInt32
  public var comm: String
  public var ttyDevice: UInt32
  public var startMono: Instant?
  public var argv0: String?
  public var argv1: String?
  public var execPath: String?
  public var pidPath: String?
  public var claudeConfigDirectory: String?

  public init(
    pid: Int32,
    ppid: Int32,
    uid: UInt32,
    comm: String,
    ttyDevice: UInt32 = ProcessRecord.noDevice,
    startMono: Instant? = nil,
    argv0: String? = nil,
    argv1: String? = nil,
    execPath: String? = nil,
    pidPath: String? = nil,
    claudeConfigDirectory: String? = nil
  ) {
    self.pid = pid
    self.ppid = ppid
    self.uid = uid
    self.comm = comm
    self.ttyDevice = ttyDevice
    self.startMono = startMono
    self.argv0 = argv0
    self.argv1 = argv1
    self.execPath = execPath
    self.pidPath = pidPath
    self.claudeConfigDirectory = claudeConfigDirectory
  }

  public var hasControllingTerminal: Bool {
    ttyDevice != UInt32(bitPattern: -1)
  }
}
