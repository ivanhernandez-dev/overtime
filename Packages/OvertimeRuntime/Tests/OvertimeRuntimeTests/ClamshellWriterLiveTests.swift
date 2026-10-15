import Darwin
import Foundation
import OvertimeClamshell
import Testing

struct ClamshellWriterLiveTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["OVERTIME_LIVE_IOKIT"] == "1"))
  func writesOneThenZeroWithTheLidOpen() throws {
    let writer = try ClamshellWriter.open()
    let set = writer.write(on: true)
    let cleared = writer.clear()
    #expect(set == KERN_SUCCESS)
    #expect(cleared == KERN_SUCCESS)
  }
}
