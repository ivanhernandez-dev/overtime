import CoreFoundation
import Darwin
import Dispatch
import OvertimeClamshell

let exitUsage: Int32 = 64
let exitIOKitOpenFailed: Int32 = 71
let exitClearFailed: Int32 = 70
let clearRetryMicroseconds: useconds_t = 250_000
let terminationSignals = [SIGTERM, SIGHUP, SIGINT]

struct SentinelOptions {
  var timeoutSeconds: UInt64 = 45
  var parent: pid_t = 0
  var logPath = ""
  var recordPath: String?
  var clearBudgetSeconds: UInt64 = SentinelWatch.defaultClearBudgetSeconds
  var relaunch: RelaunchConfiguration?
  var relaunchRecordPath: String?
}

func usageExit(_ message: String) -> Never {
  let text = "overtime-sentinel: \(message)\n"
  _ = text.withCString { write(STDERR_FILENO, $0, strlen($0)) }
  exit(exitUsage)
}

func parseOptions(_ arguments: [String]) -> SentinelOptions {
  var options = SentinelOptions()
  var sawParent = false
  var sawLog = false
  var relaunchApp: String?
  var relaunchHistory: String?
  var relaunchSuppress: String?
  var index = 1
  func value(after flag: String) -> String {
    index += 1
    guard index < arguments.count else { usageExit("\(flag) needs a value") }
    return arguments[index]
  }
  while index < arguments.count {
    let flag = arguments[index]
    switch flag {
    case "--timeout":
      guard let seconds = UInt64(value(after: flag)), seconds > 0, seconds <= 86_400 else {
        usageExit("invalid --timeout")
      }
      options.timeoutSeconds = seconds
    case "--parent":
      guard let pid = pid_t(value(after: flag)), pid > 1 else { usageExit("invalid --parent") }
      options.parent = pid
      sawParent = true
    case "--log":
      options.logPath = value(after: flag)
      sawLog = !options.logPath.isEmpty
    case RelaunchFlags.app:
      let path = absolutePath(value(after: flag), flag: flag)
      guard RelaunchFlags.isAppBundlePath(path) else { usageExit("\(flag) needs a path to an .app bundle") }
      relaunchApp = path
    case RelaunchFlags.history:
      relaunchHistory = absolutePath(value(after: flag), flag: flag)
    case RelaunchFlags.suppress:
      relaunchSuppress = absolutePath(value(after: flag), flag: flag)
    #if DEBUG
      case "--clear-backend":
        let backend = value(after: flag)
        guard backend.hasPrefix("record:"), backend.count > "record:".count else {
          usageExit("invalid --clear-backend")
        }
        options.recordPath = String(backend.dropFirst("record:".count))
      case "--clear-budget":
        guard let seconds = UInt64(value(after: flag)), seconds <= 60 else { usageExit("invalid --clear-budget") }
        options.clearBudgetSeconds = seconds
      case RelaunchFlags.spawner:
        let spawner = value(after: flag)
        guard spawner.hasPrefix("record:"), spawner.count > "record:".count else {
          usageExit("invalid \(RelaunchFlags.spawner)")
        }
        options.relaunchRecordPath = String(spawner.dropFirst("record:".count))
    #endif
    default:
      usageExit("unknown argument \(flag)")
    }
    index += 1
  }
  guard sawParent, sawLog else { usageExit("--parent and --log are required") }
  switch (relaunchApp, relaunchHistory, relaunchSuppress) {
  case (nil, nil, nil):
    guard options.relaunchRecordPath == nil else { usageExit("\(RelaunchFlags.spawner) needs the relaunch flags") }
  case (let app?, let history?, let suppress?):
    options.relaunch = RelaunchConfiguration(appPath: app, historyPath: history, suppressionPath: suppress)
  default:
    usageExit("\(RelaunchFlags.app), \(RelaunchFlags.history) and \(RelaunchFlags.suppress) go together")
  }
  return options
}

func absolutePath(_ path: String, flag: String) -> String {
  guard path.hasPrefix("/") else { usageExit("\(flag) needs an absolute path") }
  return path
}

func appendLine(_ line: String, to descriptor: Int32) -> Bool {
  guard descriptor >= 0 else { return false }
  let text = line + "\n"
  let written = text.withCString { write(descriptor, $0, strlen($0)) }
  return written == text.utf8.count
}

func openAppending(_ path: String) -> Int32 {
  open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
}

func timestamp() -> String {
  var now = time(nil)
  var parts = tm()
  gmtime_r(&now, &parts)
  var buffer = [CChar](repeating: 0, count: 32)
  let count = strftime(&buffer, buffer.count, "%Y-%m-%dT%H:%M:%SZ", &parts)
  return String(decoding: buffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

func wallClockNanoseconds() -> Int64 {
  var now = timespec()
  clock_gettime(CLOCK_REALTIME, &now)
  return Int64(now.tv_sec) * RelaunchPolicy.nanosecondsPerSecond + Int64(now.tv_nsec)
}

func uptimeNanoseconds() -> UInt64 {
  clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
}

final class SentinelLog: Sendable {
  private let descriptor: Int32

  init(path: String) {
    descriptor = openAppending(path)
  }

  func record(_ event: String) {
    _ = appendLine("\(timestamp()) \(event)", to: descriptor)
  }
}

enum ClearBackend {
  case writer(ClamshellWriter)
  #if DEBUG
    case record(path: String)
  #endif

  var name: String {
    switch self {
    case .writer: return "iokit"
    #if DEBUG
      case .record: return "record"
    #endif
    }
  }

  func clear(reason: String) -> kern_return_t {
    switch self {
    case .writer(let writer):
      return writer.clear()
    #if DEBUG
      case .record(let path):
        let descriptor = openAppending(path)
        defer { if descriptor >= 0 { close(descriptor) } }
        return appendLine("clear \(reason)", to: descriptor) ? KERN_SUCCESS : KERN_FAILURE
    #endif
    }
  }
}

final class Sentinel: @unchecked Sendable {
  private let queue = DispatchQueue(label: "overtime.sentinel")
  private let options: SentinelOptions
  private let backend: ClearBackend
  private let log: SentinelLog
  private var watch: SentinelWatch
  private var buffer = SentinelLineBuffer()
  private var sources: [any DispatchSourceProtocol] = []
  private var input: (any DispatchSourceRead)?
  private var inputEnded = false
  private var terminatingParent = false
  private var terminateSentAtNanoseconds: Int64?
  private var clearFailed = false

  init(options: SentinelOptions, backend: ClearBackend, log: SentinelLog) {
    self.options = options
    self.backend = backend
    self.log = log
    self.watch = SentinelWatch(
      timeoutNanoseconds: options.timeoutSeconds * 1_000_000_000, nowUptime: uptimeNanoseconds())
  }

  func start() {
    for signalNumber in terminationSignals {
      let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
      source.setEventHandler { [unowned self] in self.handleSignal(signalNumber) }
      sources.append(source)
    }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1), leeway: .milliseconds(100))
    timer.setEventHandler { [unowned self] in self.tick() }
    sources.append(timer)
    let input = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: queue)
    input.setEventHandler { [unowned self] in self.readInput() }
    sources.append(input)
    self.input = input
    for source in sources { source.resume() }
  }

  private func readInput() {
    guard !inputEnded else { return }
    var chunk = [UInt8](repeating: 0, count: 512)
    let count = chunk.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress, $0.count) }
    if count > 0 {
      for line in buffer.append(Array(chunk[0..<count])) {
        let wasArmed = watch.armed
        let action = watch.receive(line, nowUptime: uptimeNanoseconds())
        if watch.armed != wasArmed { log.record(watch.armed ? "armed" : "disarmed") }
        perform(action, context: "bye")
      }
      return
    }
    if count < 0 && (errno == EINTR || errno == EAGAIN) { return }
    inputEnded = true
    input?.cancel()
    perform(watch.endOfInput(), context: "eof")
  }

  private func drainPendingInput() {
    for _ in 0..<64 where !inputEnded {
      var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
      guard poll(&descriptor, 1, 0) > 0, descriptor.revents & Int16(POLLIN | POLLHUP) != 0 else { return }
      readInput()
    }
  }

  private func handleSignal(_ signalNumber: Int32) {
    log.record("signal \(signalNumber)")
    drainPendingInput()
    perform(watch.signalReceived(), context: "signal")
  }

  private func tick() {
    perform(watch.check(nowUptime: uptimeNanoseconds()), context: "heartbeat-timeout")
  }

  private func perform(_ action: SentinelWatch.Action, context: String) {
    switch action {
    case .none:
      return
    case .exitWithoutClear:
      finish(context)
    case .clearAndExit(let reason):
      clear(reason)
      guard !awaitsParentExit(reason) else { return }
      finish(reason)
    case .clearThenTerminateParent(let reason):
      clear(reason)
      terminateParent(reason)
    }
  }

  private func awaitsParentExit(_ reason: String) -> Bool {
    terminatingParent && terminateSentAtNanoseconds != nil && (reason == "eof" || reason == "bye")
  }

  private func clear(_ reason: String) {
    let deadline = uptimeNanoseconds() + options.clearBudgetSeconds * 1_000_000_000
    var result = backend.clear(reason: reason)
    var attempts = 1
    if result != KERN_SUCCESS { log.record("clear \(reason) kr=\(result) retry") }
    while result != KERN_SUCCESS && uptimeNanoseconds() < deadline {
      usleep(clearRetryMicroseconds)
      result = backend.clear(reason: reason)
      attempts += 1
    }
    clearFailed = result != KERN_SUCCESS
    log.record("clear \(reason) kr=\(result)" + (attempts > 1 ? " attempts=\(attempts)" : ""))
  }

  private func terminateParent(_ reason: String) {
    guard !terminatingParent else { return }
    terminatingParent = true
    let parent = options.parent
    guard getppid() == parent else {
      log.record("parentGone ppid=\(getppid())")
      finish(reason)
    }
    terminateSentAtNanoseconds = wallClockNanoseconds()
    log.record("parentTerm result=\(kill(parent, SIGTERM))")
    queue.asyncAfter(deadline: .now() + .seconds(2)) { [unowned self] in
      if getppid() == parent {
        self.log.record("parentKill result=\(kill(parent, SIGKILL))")
      }
      self.awaitParentExit(parent, remaining: Self.parentExitPolls)
    }
  }

  static let parentExitPolls = 20

  private func awaitParentExit(_ parent: pid_t, remaining: Int) {
    guard getppid() == parent, remaining > 0 else {
      drainPendingInput()
      perform(watch.parentTerminated(), context: "post-terminate")
      return
    }
    queue.asyncAfter(deadline: .now() + .milliseconds(50)) { [unowned self] in
      self.awaitParentExit(parent, remaining: remaining - 1)
    }
  }

  private func finish(_ reason: String) -> Never {
    if let relaunch = options.relaunch {
      Relauncher(
        configuration: relaunch, recordPath: options.relaunchRecordPath, parent: options.parent, log: log,
        terminatedAtNanoseconds: terminateSentAtNanoseconds
      ).run(after: reason)
    }
    log.record("exit reason=\(reason)" + (clearFailed ? " clearFailed" : ""))
    exit(clearFailed ? exitClearFailed : 0)
  }
}

struct Relauncher {
  static let parentPollMicroseconds: useconds_t = 10_000
  static let parentPollWindowNanoseconds: UInt64 = 1_000_000_000
  static let lockRetryMicroseconds: useconds_t = 50_000
  static let lockRetryCount = 40
  static let openWaitMicroseconds: useconds_t = 50_000
  static let openWaitCount = 100
  static let openPath = "/usr/bin/open"

  let configuration: RelaunchConfiguration
  let recordPath: String?
  let parent: pid_t
  let log: SentinelLog
  let terminatedAtNanoseconds: Int64?

  func run(after reason: String) {
    guard let exit = exitKind(for: reason) else {
      log.record("relaunch skipped reason=\(reason)")
      return
    }
    let descriptor = open(
      configuration.historyPath, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else {
      log.record("relaunch failed errno=\(errno) step=history")
      return
    }
    defer { close(descriptor) }
    guard isPrivateRegularFile(descriptor), fchmod(descriptor, 0o600) == 0 else {
      log.record("relaunch skipped reason=historyNotPrivate")
      return
    }
    guard lock(descriptor) else {
      log.record("relaunch skipped reason=locked")
      return
    }
    let now = Int64(time(nil))
    let target = appTarget()
    let excluded = terminatedAtNanoseconds != nil && getppid() != parent ? parent : nil
    let decision = RelaunchPolicy.decide(
      exit: exit, now: now, history: RelaunchPolicy.parseHistory(readHistory(descriptor), now: now),
      suppressedAtNanoseconds: modificationTime(configuration.suppressionPath),
      appRunning: appIsRunning(excluding: excluded), appExists: target != .missing,
      terminatedAtNanoseconds: terminatedAtNanoseconds, appValid: target == .valid)
    switch decision {
    case .skip(let skipReason):
      log.record("relaunch skipped reason=\(skipReason)")
    case .relaunch(let history):
      guard writeHistory(history, to: descriptor) else {
        log.record("relaunch failed errno=\(errno) step=history")
        return
      }
      spawn()
    }
  }

  func exitKind(for reason: String) -> RelaunchExit? {
    switch reason {
    case "bye": return .bye
    case "signal": return .signal
    case "eof": return .endOfInput(parentGone: parentIsGone())
    case "post-terminate", "heartbeat-timeout": return .heartbeatTimeoutTerminated
    default: return nil
    }
  }

  func parentIsGone() -> Bool {
    let deadline = uptimeNanoseconds() + Self.parentPollWindowNanoseconds
    while uptimeNanoseconds() < deadline {
      if getppid() != parent { return true }
      usleep(Self.parentPollMicroseconds)
    }
    return getppid() != parent
  }

  func lock(_ descriptor: Int32) -> Bool {
    for _ in 0..<Self.lockRetryCount {
      if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return true }
      usleep(Self.lockRetryMicroseconds)
    }
    return flock(descriptor, LOCK_EX | LOCK_NB) == 0
  }

  func readHistory(_ descriptor: Int32) -> String {
    var bytes = [UInt8](repeating: 0, count: RelaunchPolicy.maximumHistoryBytes)
    let count = bytes.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, 0) }
    guard count > 0 else { return "" }
    return String(decoding: bytes[0..<count], as: UTF8.self)
  }

  func writeHistory(_ history: [Int64], to descriptor: Int32) -> Bool {
    let bytes = Array(RelaunchPolicy.serializeHistory(history).utf8)
    guard ftruncate(descriptor, 0) == 0 else { return false }
    let written = bytes.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
    return written == bytes.count
  }

  func isPrivateRegularFile(_ descriptor: Int32) -> Bool {
    var info = stat()
    return fstat(descriptor, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_uid == getuid()
  }

  func modificationTime(_ path: String) -> Int64? {
    var info = stat()
    guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { return nil }
    return RelaunchPolicy.nanoseconds(
      seconds: Int64(info.st_mtimespec.tv_sec), nanoseconds: Int64(info.st_mtimespec.tv_nsec))
  }

  enum AppTarget {
    case missing
    case invalid
    case valid
  }

  func appTarget() -> AppTarget {
    let path = configuration.appPath
    var info = stat()
    guard stat(path, &info) == 0 else { return .missing }
    guard info.st_mode & S_IFMT == S_IFDIR, isTrustedOwner(info.st_uid) else { return .invalid }
    let executable = path + "/" + RelaunchFlags.appExecutable
    var program = stat()
    guard stat(executable, &program) == 0, program.st_mode & S_IFMT == S_IFREG, isTrustedOwner(program.st_uid),
      access(executable, X_OK) == 0
    else { return .invalid }
    guard let identifier = bundleIdentifier(path), RelaunchFlags.bundleIdentifiers.contains(identifier) else {
      return .invalid
    }
    return .valid
  }

  func isTrustedOwner(_ owner: uid_t) -> Bool {
    owner == getuid() || owner == 0
  }

  func bundleIdentifier(_ appPath: String) -> String? {
    let path = appPath + "/" + RelaunchFlags.appInfoPlist
    var info = stat()
    guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= Self.maxInfoPlistBytes else {
      return nil
    }
    let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { return nil }
    defer { close(descriptor) }
    var bytes = [UInt8](repeating: 0, count: Self.maxInfoPlistBytes)
    let count = bytes.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, 0) }
    guard count > 0, let data = CFDataCreate(nil, bytes, count),
      let plist = CFPropertyListCreateWithData(nil, data, 0, nil, nil)?.takeRetainedValue(),
      CFGetTypeID(plist) == CFDictionaryGetTypeID()
    else { return nil }
    let dictionary = unsafeDowncast(plist, to: CFDictionary.self)
    let key = CFStringCreateWithCString(nil, "CFBundleIdentifier", CFStringBuiltInEncodings.UTF8.rawValue)
    guard let key, let value = CFDictionaryGetValue(dictionary, unsafeBitCast(key, to: UnsafeRawPointer.self)) else {
      return nil
    }
    let object = unsafeBitCast(value, to: CFTypeRef.self)
    guard CFGetTypeID(object) == CFStringGetTypeID() else { return nil }
    var buffer = [CChar](repeating: 0, count: 256)
    guard
      CFStringGetCString(
        unsafeDowncast(object, to: CFString.self), &buffer, buffer.count, CFStringBuiltInEncodings.UTF8.rawValue)
    else { return nil }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  static let maxInfoPlistBytes = 65_536

  func canonicalPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  func appIsRunning(excluding excluded: pid_t?) -> Bool {
    let executable = canonicalPath(configuration.appPath + "/" + RelaunchFlags.appExecutable)
    let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
    guard needed > 0 else { return false }
    var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.size + 64)
    let filled = pids.withUnsafeMutableBytes {
      proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count))
    }
    guard filled > 0 else { return false }
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    for pid in pids.prefix(Int(filled) / MemoryLayout<pid_t>.size) where pid > 0 && pid != excluded {
      let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
      guard count > 0 else { continue }
      let path = String(decoding: buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
      if path == executable { return true }
    }
    return false
  }

  func spawn() {
    #if DEBUG
      if let recordPath {
        let descriptor = openAppending(recordPath)
        defer { if descriptor >= 0 { close(descriptor) } }
        let recorded = appendLine("relaunch \(configuration.appPath)", to: descriptor)
        log.record(recorded ? "relaunch spawned pid=0 status=record" : "relaunch failed errno=\(errno) step=record")
        return
      }
    #endif
    var attributes: posix_spawnattr_t?
    var actions: posix_spawn_file_actions_t?
    posix_spawnattr_init(&attributes)
    posix_spawn_file_actions_init(&actions)
    defer {
      posix_spawnattr_destroy(&attributes)
      posix_spawn_file_actions_destroy(&actions)
    }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
    let arguments = [Self.openPath, "-g", configuration.appPath]
    var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
    defer { for pointer in argv { free(pointer) } }
    var pid: pid_t = 0
    let result = posix_spawn(&pid, Self.openPath, &actions, &attributes, &argv, environ)
    guard result == 0 else {
      log.record("relaunch failed errno=\(result)")
      return
    }
    log.record("relaunch spawned pid=\(pid) status=\(awaitExit(pid))")
  }

  func awaitExit(_ pid: pid_t) -> String {
    var status: Int32 = 0
    for _ in 0..<Self.openWaitCount {
      let waited = waitpid(pid, &status, WNOHANG)
      if waited == pid { return String(status) }
      if waited < 0 && errno != EINTR { return "unknown" }
      usleep(Self.openWaitMicroseconds)
    }
    return "timeout"
  }
}

signal(SIGPIPE, SIG_IGN)
for signalNumber in terminationSignals { signal(signalNumber, SIG_IGN) }
let options = parseOptions(CommandLine.arguments)
let log = SentinelLog(path: options.logPath)
let parentAtStart = getppid()
if parentAtStart != options.parent && parentAtStart != 1 {
  log.record("exit reason=parent-mismatch ppid=\(parentAtStart) parent=\(options.parent)")
  exit(exitUsage)
}

func makeBackend(_ options: SentinelOptions, log: SentinelLog) -> ClearBackend {
  #if DEBUG
    if let recordPath = options.recordPath { return .record(path: recordPath) }
  #endif
  do {
    return .writer(try ClamshellWriter.open())
  } catch ClamshellWriterError.openFailed(let result) {
    log.record("open failed kr=\(result)")
  } catch {
    log.record("open failed service-not-found")
  }
  exit(exitIOKitOpenFailed)
}

let backend = makeBackend(options, log: log)
log.record(
  "start pid=\(getpid()) parent=\(options.parent) ppid=\(parentAtStart) timeout=\(options.timeoutSeconds) "
    + "backend=\(backend.name)")
let sentinel = Sentinel(options: options, backend: backend, log: log)
sentinel.start()
_ = appendLine("READY", to: STDOUT_FILENO)
dispatchMain()
