import Darwin
import Foundation
import IOKit
import IOKit.ps
import OvertimeHelperCore
import notify

struct RealHelperSystem: HelperSystemPort {
  static let rootDomainClass = "IOPMrootDomain"
  static let sleepDisabledKey = "SleepDisabled"
  static let lidStateKey = "AppleClamshellState"
  static let nullDevice = "/dev/null"
  static let pmsetPollMicroseconds: useconds_t = 50_000
  static let pmsetPollCount = 100

  private let thermalToken: Int32

  init() {
    var token = NOTIFY_TOKEN_INVALID
    let status = notify_register_check(kOSThermalNotificationPressureLevelName, &token)
    thermalToken = status == NOTIFY_STATUS_OK ? token : NOTIFY_TOKEN_INVALID
  }

  func readSleepDisabled() -> Bool? {
    rootDomainBool(Self.sleepDisabledKey)
  }

  func lidClosed() -> Bool? {
    rootDomainBool(Self.lidStateKey)
  }

  func writeSleepDisabled(_ disabled: Bool) -> Bool {
    var attributes: posix_spawnattr_t?
    var actions: posix_spawn_file_actions_t?
    posix_spawnattr_init(&attributes)
    posix_spawn_file_actions_init(&actions)
    defer {
      posix_spawnattr_destroy(&attributes)
      posix_spawn_file_actions_destroy(&actions)
    }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, Self.nullDevice, O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, Self.nullDevice, O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, Self.nullDevice, O_WRONLY, 0)
    let arguments = [HelperCommands.pmset] + HelperCommands.arguments(disable: disabled)
    var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
    defer { for pointer in argv { free(pointer) } }
    var pid: pid_t = 0
    guard posix_spawn(&pid, HelperCommands.pmset, &actions, &attributes, &argv, environ) == 0 else { return false }
    return Self.exitedCleanly(pid)
  }

  func clamshellEdge() -> Bool {
    guard let matching = IOServiceMatching(Self.rootDomainClass) else { return false }
    let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
    guard service != IO_OBJECT_NULL else { return false }
    defer { IOObjectRelease(service) }
    var connection: io_connect_t = IO_OBJECT_NULL
    guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return false }
    defer { IOServiceClose(connection) }
    let raised = Self.writeClamshell(connection, on: true)
    let lowered = Self.writeClamshell(connection, on: false)
    return raised && lowered
  }

  func power() -> HelperPowerFacts? {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
      let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
      let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
    else { return nil }
    for source in list {
      guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
        description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
      else { continue }
      guard let current = description[kIOPSCurrentCapacityKey] as? Int, current >= 0,
        let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0
      else { return nil }
      return HelperPowerFacts(
        onBattery: providing != kIOPSACPowerValue, percent: min(100, current * 100 / maximum),
        warningLevel: Int(IOPSGetBatteryWarningLevel().rawValue))
    }
    return nil
  }

  func thermal() -> HelperThermalFacts? {
    var level: UInt64 = 0
    guard thermalToken != NOTIFY_TOKEN_INVALID, notify_get_state(thermalToken, &level) == NOTIFY_STATUS_OK else {
      return nil
    }
    return HelperThermalFacts(
      pressureLevel: Int(clamping: level), critical: ProcessInfo.processInfo.thermalState == .critical)
  }

  func pause(milliseconds: Int) {
    usleep(useconds_t(clamping: milliseconds) * 1_000)
  }

  private func rootDomainBool(_ key: String) -> Bool? {
    guard let matching = IOServiceMatching(Self.rootDomainClass) else { return nil }
    let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
    guard service != IO_OBJECT_NULL else { return nil }
    defer { IOObjectRelease(service) }
    let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    if let flag = value as? Bool { return flag }
    return (value as? NSNumber)?.boolValue
  }

  private static func writeClamshell(_ connection: io_connect_t, on: Bool) -> Bool {
    var input: [UInt64] = [on ? 1 : 0]
    return IOConnectCallScalarMethod(connection, HelperCommands.clamshellSleepSelector, &input, 1, nil, nil)
      == KERN_SUCCESS
  }

  private static func exitedCleanly(_ pid: pid_t) -> Bool {
    var status: Int32 = 0
    for _ in 0..<pmsetPollCount {
      let waited = waitpid(pid, &status, WNOHANG)
      if waited == pid { return status == 0 }
      if waited < 0 && errno != EINTR { return false }
      usleep(pmsetPollMicroseconds)
    }
    kill(pid, SIGKILL)
    while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    return false
  }
}

struct HelperUptimeClock: HelperClock {
  func now() -> Double {
    Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
  }
}
