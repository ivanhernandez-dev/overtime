#if DEBUG
  import Foundation
  import OvertimeCore
  import OvertimeSystem

  struct RecordClamshell: ClamshellPort {
    let path: String

    func write(on: Bool) -> EffectOutcome {
      let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
      guard descriptor >= 0 else { return .failed(code: errno) }
      defer { close(descriptor) }
      let line = Array((on ? "set\n" : "clear\n").utf8)
      let written = line.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
      return written == line.count ? .succeeded : .failed(code: errno)
    }
  }
#endif
