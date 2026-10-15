import Darwin
import Dispatch
import Foundation
import IOKit.ps
import OvertimeHelperCore
import notify

guard getuid() == 0 else {
  let refusal = "overtime-helper must be started by launchd as root\n"
  _ = refusal.withCString { write(STDERR_FILENO, $0, strlen($0)) }
  exit(EX_NOPERM)
}

#if DEBUG
  let identity = HelperIdentity.dev
#else
  let identity = HelperIdentity.release
#endif

let daemon = HelperDaemon(identity: identity)
daemon.start()
dispatchMain()

final class HelperDaemon: @unchecked Sendable {
  static let terminationSignals = [SIGTERM, SIGINT, SIGHUP]
  static let replyGraceMilliseconds = 200
  static let rootOwner: uid_t = 0
  static let stalledExitStatus = EX_SOFTWARE
  static let stalledExitGraceSeconds = 1

  private let queue = DispatchQueue(label: "overtime.helper")
  private let watchdogQueue = DispatchQueue(label: "overtime.helper.watchdog")
  private let identity: HelperIdentity
  private let log: HelperLog
  private let system: RealHelperSystem
  private let machine: HelperMachine
  private let timer: any DispatchSourceTimer
  private let watchdogTimer: any DispatchSourceTimer
  private let clock = HelperUptimeClock()
  private var watchdog = HelperWatchdog()
  private var signalSources: [any DispatchSourceSignal] = []
  private var service: HelperXPCService?
  private var listener: NSXPCListener?
  private var watching = false
  private var signalled = false
  private var exiting = false

  init(identity: HelperIdentity) {
    let log = HelperLog(
      directory: URL(fileURLWithPath: identity.logDirectory, isDirectory: true), requiredOwner: Self.rootOwner)
    let record = HelperRecordStore(
      directory: URL(fileURLWithPath: identity.supportDirectory, isDirectory: true), requiredOwner: Self.rootOwner)
    let system = RealHelperSystem()
    self.identity = identity
    self.log = log
    self.system = system
    machine = HelperMachine(system: system, record: record, log: log, clock: clock)
    timer = DispatchSource.makeTimerSource(queue: queue)
    watchdogTimer = DispatchSource.makeTimerSource(queue: watchdogQueue)
  }

  func start() {
    watchQueue()
    queue.sync {
      watchSignals()
      log.record("helper start version=\(HelperIdentity.version)")
      machine.launched()
      watchNotifications()
      timer.setEventHandler { [unowned self] in
        self.machine.watch()
        self.settle()
      }
      settle()
      serve()
    }
  }

  private func watchQueue() {
    let period = DispatchTimeInterval.milliseconds(Int(HelperWatchdog.checkSeconds * 1_000))
    watchdogTimer.setEventHandler { [unowned self] in
      self.checkQueue()
    }
    let leeway = DispatchTimeInterval.milliseconds(Int(HelperWatchdog.leewaySeconds * 1_000))
    watchdogTimer.schedule(deadline: .now() + period, repeating: period, leeway: leeway)
    watchdogTimer.resume()
  }

  private func checkQueue() {
    switch watchdog.check(now: clock.now()) {
    case .ask:
      queue.async { [unowned self] in
        self.watchdogQueue.async {
          self.watchdog.answered()
        }
      }
    case .wait:
      break
    case .stalled:
      let status = Self.stalledExitStatus
      DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(Self.stalledExitGraceSeconds)) {
        _exit(status)
      }
      log.record("ERROR queue stalled exit=now")
      _exit(status)
    }
  }

  private func watchSignals() {
    for number in Self.terminationSignals {
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
      source.setEventHandler { [unowned self] in
        self.signalled = true
        self.machine.signal(number)
        self.settle()
      }
      source.resume()
      signalSources.append(source)
    }
  }

  private func watchNotifications() {
    register(kOSThermalNotificationPressureLevelName, as: "thermal") { [unowned self] in
      self.machine.thermal(self.system.thermal())
    }
    register(kIOPSNotifyLowBattery, as: "lowBattery") { [unowned self] in
      self.machine.power(self.system.power())
    }
    register(kIOPSNotifyPowerSource, as: "powerSource") { [unowned self] in
      self.machine.power(self.system.power())
    }
  }

  private func register(
    _ name: UnsafePointer<CChar>?, as label: String, _ event: @escaping @Sendable () -> Void
  ) {
    var token = NOTIFY_TOKEN_INVALID
    let status = notify_register_dispatch(name, &token, queue) { [unowned self] _ in
      event()
      self.settle()
    }
    if status != NOTIFY_STATUS_OK {
      log.record("ERROR notify \(label) status=\(status)")
    }
  }

  private func serve() {
    let service = HelperXPCService(
      machine: machine, log: log, queue: queue,
      afterEvent: { [unowned self] in self.refreshWatch() },
      onExit: { [unowned self] in self.leave(afterMilliseconds: Self.replyGraceMilliseconds) })
    let listener = NSXPCListener(machServiceName: identity.machService)
    service.configure(listener, requirement: identity.appRequirement)
    listener.resume()
    self.service = service
    self.listener = listener
  }

  private func settle() {
    if machine.shouldExit {
      leave(afterMilliseconds: 0)
    }
    refreshWatch()
  }

  private func refreshWatch() {
    let needed = machine.needsWatch
    guard needed != watching else { return }
    watching = needed
    guard needed else { return timer.suspend() }
    let period = DispatchTimeInterval.milliseconds(Int(HelperMachine.watchPeriodSeconds * 1_000))
    timer.schedule(deadline: .now() + period, repeating: period)
    timer.resume()
  }

  private func leave(afterMilliseconds delay: Int) {
    guard !exiting else { return }
    exiting = true
    log.record("exit reason=\(signalled ? "signal" : "staleVersion")")
    queue.asyncAfter(deadline: .now() + .milliseconds(delay)) { exit(0) }
  }
}
