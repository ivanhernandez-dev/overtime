import CIOKitShim
import IOKit
import IOKit.pwr_mgt

public enum ClamshellWriterError: Error, Equatable {
  case serviceNotFound
  case openFailed(kern_return_t)
}

public final class ClamshellWriter: Sendable {
  private let connection: io_connect_t

  private init(connection: io_connect_t) {
    self.connection = connection
  }

  public static func open() throws -> ClamshellWriter {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard service != 0 else { throw ClamshellWriterError.serviceNotFound }
    defer { IOObjectRelease(service) }
    var connection: io_connect_t = 0
    let result = IOServiceOpen(service, OTTaskSelf(), 0, &connection)
    guard result == KERN_SUCCESS else { throw ClamshellWriterError.openFailed(result) }
    return ClamshellWriter(connection: connection)
  }

  public func write(on: Bool) -> kern_return_t {
    var input: [UInt64] = [on ? 1 : 0]
    return IOConnectCallScalarMethod(connection, UInt32(kPMSetClamshellSleepState), &input, 1, nil, nil)
  }

  public func clear() -> kern_return_t {
    write(on: false)
  }

  deinit {
    IOServiceClose(connection)
  }
}
