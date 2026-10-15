import Foundation
import OvertimeCore
import OvertimeEngine
import OvertimeSystem
import Testing

@Suite(.serialized)
struct ControlSocketTests {
  static let status = StatusSnapshot(mode: "shadow", busy: true, wanted: false, reason: "paused", pause: "indefinite")

  static func mode(of path: String) throws -> Int? {
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue
  }

  static func inode(of path: String) -> UInt64? {
    var info = stat()
    guard lstat(path, &info) == 0 else { return nil }
    return UInt64(info.st_ino)
  }

  static let patientHandlerSeconds: Double = 30
  static let patientClientSeconds: Double = 40

  static func startServer(
    in temp: TempDirectory, answerAfter: Duration = .zero
  ) throws -> (server: ControlServer, path: String) {
    let path = temp.url.appendingPathComponent("overtimed-shadow.sock").path(percentEncoded: false)
    let server = ControlServer(socketPath: path, handlerTimeoutSeconds: Self.patientHandlerSeconds) { request in
      if answerAfter > .zero {
        try? await Task.sleep(for: answerAfter)
      }
      return request == .status ? CtlResponse(ok: true, status: Self.status) : CtlResponse.failure("unexpected")
    }
    try server.start()
    return (server, path)
  }

  static func patientSend(_ request: CtlRequest, path: String) throws -> CtlResponse {
    try ControlClient.send(request, socketPath: path, timeoutSeconds: patientClientSeconds)
  }

  static func roundTrip(_ request: CtlRequest, path: String) async throws -> CtlResponse {
    let outcome = await OffPool.run {
      Result { try patientSend(request, path: path) }
    }
    return try outcome.get()
  }

  @Test func aStatusRequestRoundTrips() async throws {
    let temp = try TempDirectory.short()
    let (server, path) = try Self.startServer(in: temp)
    defer { server.stop() }
    let response = try await Self.roundTrip(.status, path: path)
    #expect(response == CtlResponse(ok: true, status: Self.status))
  }

  @Test func anAnswerSlowerThanTheProductionHandlerBoundStillRoundTrips() async throws {
    let temp = try TempDirectory.short()
    let (server, path) = try Self.startServer(
      in: temp, answerAfter: .seconds(ControlServer.handlerTimeoutSeconds + 0.3))
    defer { server.stop() }
    let response = try await Self.roundTrip(.status, path: path)
    #expect(response == CtlResponse(ok: true, status: Self.status))
  }

  @Test func theClientDeadlineIsInjectedAndTheDefaultStaysFiveSeconds() async throws {
    let temp = try TempDirectory.short()
    let (server, path) = try Self.startServer(in: temp, answerAfter: .milliseconds(800))
    defer { server.stop() }
    let hurried = await OffPool.run {
      Result { try ControlClient.send(.status, socketPath: path, timeoutSeconds: 0.2) }
    }
    #expect(throws: ControlSocketError.invalidResponse) { try hurried.get() }
    let response = try await Self.roundTrip(.status, path: path)
    #expect(response == CtlResponse(ok: true, status: Self.status))
  }

  @Test func theProductionTimeoutsKeepTheirValues() {
    #expect(ControlClient.timeoutSeconds == 5)
    #expect(ControlServer.handlerTimeoutSeconds == 2)
    #expect(ControlServer.connectionTimeoutSeconds == 2)
  }

  @Test func theSocketIsPrivateInsideAPrivateDirectory() throws {
    let temp = try TempDirectory.short()
    _ = chmod(temp.path, 0o755)
    let (server, path) = try Self.startServer(in: temp)
    defer { server.stop() }
    #expect(try Self.mode(of: path) == 0o600)
    #expect(try Self.mode(of: temp.path) == 0o700)
  }

  @Test func stopRemovesTheSocketAndTheClientThenReportsNotRunning() throws {
    let temp = try TempDirectory.short()
    let (server, path) = try Self.startServer(in: temp)
    server.stop()
    #expect(!FileManager.default.fileExists(atPath: path))
    #expect(throws: ControlSocketError.notRunning) { try ControlClient.send(.status, socketPath: path) }
  }

  @Test func aPathLongerThanSunPathIsRejectedNotTruncated() throws {
    let path = "/tmp/" + String(repeating: "a", count: 105)
    #expect(path.utf8.count == 110)
    let server = ControlServer(socketPath: path) { _ in CtlResponse(ok: true) }
    #expect(throws: ControlSocketError.pathTooLong(110)) { try server.start() }
    #expect(!FileManager.default.fileExists(atPath: path))
  }

  @Test func aSecondInstanceIsRefusedBeforeItTouchesTheSocket() async throws {
    let temp = try TempDirectory.short()
    let paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path], homeDirectory: "/Users/dev")
    let settings = Settings(transcriptRoots: [temp.url.appendingPathComponent("root").path(percentEncoded: false)])
    let launch = {
      try Composition.launchShadow(
        paths: paths, settings: settings, environment: [:], homeDirectory: "/Users/dev", once: false)
    }
    let first = try launch()
    defer { first.shutdown() }
    let socketPath = paths.controlSocket(.shadow).path(percentEncoded: false)
    let before = Self.inode(of: socketPath)
    #expect(before != nil)
    #expect(throws: CompositionError.alreadyRunning(.shadow)) { _ = try launch() }
    #expect(Self.inode(of: socketPath) == before)
    let response = try ControlClient.send(.status, socketPath: socketPath)
    #expect(response.ok)
    #expect(response.status?.mode == "shadow")
  }

  @Test func aPauseThroughTheSocketReachesTheEngine() async throws {
    let temp = try TempDirectory.short()
    let paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path], homeDirectory: "/Users/dev")
    let settings = Settings(transcriptRoots: [temp.url.appendingPathComponent("root").path(percentEncoded: false)])
    let instance = try Composition.launchShadow(
      paths: paths, settings: settings, environment: [:], homeDirectory: "/Users/dev", once: false)
    defer { instance.shutdown() }
    let socketPath = paths.controlSocket(.shadow).path(percentEncoded: false)
    let response = try ControlClient.send(.pause(.forSeconds(900)), socketPath: socketPath)
    #expect(response.ok)
    #expect(response.status?.pause == "timed")
    #expect(response.status?.pauseUntil != nil)
    let log = try String(contentsOf: paths.decisionLog(.shadow), encoding: .utf8)
    #expect(log.contains(" OVERRIDE pause until="))
  }

  @Test func forceReleaseAndResumeThroughTheSocketUpdateTheStatus() async throws {
    let temp = try TempDirectory.short()
    let paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path], homeDirectory: "/Users/dev")
    let settings = Settings(transcriptRoots: [temp.url.appendingPathComponent("root").path(percentEncoded: false)])
    let instance = try Composition.launchShadow(
      paths: paths, settings: settings, environment: [:], homeDirectory: "/Users/dev", once: false)
    defer { instance.shutdown() }
    let socketPath = paths.controlSocket(.shadow).path(percentEncoded: false)
    let forced = try ControlClient.send(.force(.forSeconds(1800)), socketPath: socketPath)
    #expect(forced.status?.force == "timed")
    #expect(forced.status?.forceUntil != nil)
    let released = try ControlClient.send(.releaseUntilIdle, socketPath: socketPath)
    #expect(released.status?.override == true)
    let resumed = try ControlClient.send(.resume, socketPath: socketPath)
    #expect(resumed.status?.force == nil)
    #expect(resumed.status?.override == false)
    #expect(resumed.status?.pause == nil)
    let log = try String(contentsOf: paths.decisionLog(.shadow), encoding: .utf8)
    #expect(log.contains(" OVERRIDE force until="))
    #expect(log.contains(" OVERRIDE releaseUntilIdle"))
    #expect(log.contains(" OVERRIDE resume"))
  }

  @Test func aSlowHandlerReportsAcceptedForCommandsAndTimeoutForStatus() throws {
    let temp = try TempDirectory.short()
    let path = temp.url.appendingPathComponent("slow.sock").path(percentEncoded: false)
    let server = ControlServer(socketPath: path, handlerTimeoutSeconds: 0.2) { _ in
      try? await Task.sleep(for: .seconds(1))
      return CtlResponse(ok: true, status: Self.status)
    }
    try server.start()
    defer { server.stop() }
    let paused = try ControlClient.send(.pause(.indefinite), socketPath: path)
    #expect(paused == CtlResponse(ok: true, error: ControlServer.acceptedPending))
    let status = try ControlClient.send(.status, socketPath: path)
    #expect(status == CtlResponse.failure("timeout"))
  }

  @Test func aCommandIsAnsweredOnceReducedWhileItsEffectsAreStillRunning() async throws {
    let temp = try TempDirectory()
    let paths = Paths.resolve(environment: ["OVERTIME_HOME": temp.path], homeDirectory: temp.path)
    let recorder = HoldRecorder(stateFile: paths.stateFile(.live))
    let port = GatedClamshellPort(recorder: recorder)
    let clock = FakeClock()
    let engine = try Composition.makeLiveEngine(
      paths: paths,
      settings: Settings(transcriptRoots: [temp.path + "/projects"]),
      ports: LivePorts(
        assertions: FakeAssertionPort(), tools: NoTools(), clamshell: port, stateFile: paths.stateFile(.live),
        makeSentinel: { FakeSentinelPort(recorder: recorder) }),
      environment: [:], homeDirectory: temp.path, once: true, clock: clock, callTimeoutSeconds: 30)
    await engine.step(.tick(TickFacts(fullWake: true)))
    await engine.step(.transcriptActivity(TranscriptActivity(at: clock.mono())))
    try #require(await engine.state.hold.lidClose == .held)
    port.holdNextWrite()
    let response = await engine.handle(.pause(.indefinite))
    #expect(response.ok)
    #expect(response.status?.pause == "indefinite")
    #expect(await EffectOrderTests.poll(within: 5) { port.waiting })
    port.release()
    #expect(await EffectOrderTests.poll(within: 5) { await engine.state.hold.lidClose == .released })
  }

  static func connectSilently(_ path: String, receiveTimeoutSeconds: Int) -> Int32 {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return -1 }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
      raw.copyBytes(from: bytes)
      raw[bytes.count] = 0
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    var timeout = timeval(tv_sec: receiveTimeoutSeconds, tv_usec: 0)
    _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connected == 0 else {
      close(descriptor)
      return -1
    }
    return descriptor
  }

  static func answer(_ line: String, path: String) throws -> CtlResponse {
    let reply = try ControlClient.exchange(Data(line.utf8), socketPath: path)
    return try JSONDecoder().decode(CtlResponse.self, from: reply)
  }

  @Test func aLineOverFourKiBIsRefused() throws {
    let temp = try TempDirectory.short()
    let (server, path) = try Self.startServer(in: temp)
    defer { server.stop() }
    #expect(try Self.answer(String(repeating: "a", count: 5000) + "\n", path: path) == .failure("request too large"))
    let padded = #"{"command":"status","pad":""# + String(repeating: "x", count: 4100) + "\"}\n"
    #expect(try Self.answer(padded, path: path) == .failure("request too large"))
    #expect(try Self.patientSend(.status, path: path).ok)
  }

  @Test func aClientThatSendsNothingIsDroppedAfterAboutTwoSeconds() throws {
    let temp = try TempDirectory.short()
    let (server, path) = try Self.startServer(in: temp)
    defer { server.stop() }
    let descriptor = Self.connectSilently(path, receiveTimeoutSeconds: 6)
    #expect(descriptor >= 0)
    let started = ContinuousClock.now
    var byte: UInt8 = 0
    let count = read(descriptor, &byte, 1)
    let elapsed = ContinuousClock.now - started
    close(descriptor)
    #expect(count == 0)
    #expect(elapsed >= .milliseconds(1500))
    #expect(elapsed < .seconds(4))
    #expect(try Self.patientSend(.status, path: path).ok)
  }

  @Test func unknownCommandsAndMalformedJSONGetErrorAnswers() throws {
    let temp = try TempDirectory.short()
    let (server, path) = try Self.startServer(in: temp)
    defer { server.stop() }
    #expect(try Self.answer(#"{"command":"reboot"}"# + "\n", path: path) == .failure("unknown command"))
    #expect(try Self.answer("nope\n", path: path) == .failure("invalid request"))
    #expect(try Self.answer(#"{"command":"pause","seconds":1e300}"# + "\n", path: path) == .failure("invalid request"))
  }

  @Test func aBurstOfTwentySequentialClientsAllGetAnswers() throws {
    let temp = try TempDirectory.short()
    let (server, path) = try Self.startServer(in: temp)
    defer { server.stop() }
    for index in 0..<20 {
      #expect(
        try Self.patientSend(.status, path: path) == CtlResponse(ok: true, status: Self.status),
        "client \(index)")
    }
  }

  @Test(arguments: [
    CtlRequest.pause(.forSeconds(900)),
    .pause(.until(Date(timeIntervalSince1970: 1_800_000_000))),
    .pause(.indefinite),
    .force(.forSeconds(1800)),
    .force(.indefinite),
    .releaseUntilIdle,
    .resume,
    .status,
    .sleepNow,
  ])
  func everyRequestRoundTripsThroughItsWireForm(_ request: CtlRequest) {
    #expect(ControlProtocol.decodeRequest(ControlProtocol.encodeLine(request).dropLast()) == .success(request))
  }

  @Test func sleepNowHasTheWireFormSleepNow() throws {
    let line = ControlProtocol.encodeLine(CtlRequest.sleepNow)
    #expect(String(decoding: line, as: UTF8.self) == "{\"command\":\"sleepNow\"}\n")
    #expect(ControlProtocol.decodeRequest(Data(#"{"command":"sleepNow"}"#.utf8)) == .success(.sleepNow))
  }

  @Test(arguments: [
    (#"{"command":"pause","seconds":60,"indefinite":true}"#, CtlRequestError.invalidRequest),
    (#"{"command":"pause"}"#, .invalidRequest),
    (#"{"command":"pause","seconds":-5}"#, .invalidRequest),
    (#"{"command":"pause","indefinite":false}"#, .invalidRequest),
    (#"{"command":"pause","until":"tomorrow"}"#, .invalidRequest),
    (#"{"command":"force","until":"2026-09-27T08:00:00Z"}"#, .invalidRequest),
    (#"{"command":"reboot"}"#, .unknownCommand),
    (#"{"cmd":"status"}"#, .invalidRequest),
    (#"[1,2]"#, .invalidRequest),
    ("not json", .invalidRequest),
  ])
  func malformedAndUnknownRequestsAreRejected(_ line: String, _ error: CtlRequestError) {
    #expect(ControlProtocol.decodeRequest(Data(line.utf8)) == .failure(error))
  }

  @Test func ctlArgumentsParseIntoRequests() throws {
    #expect(
      try CommandLineOptions.parseInvocation(["ctl", "pause", "--minutes", "15"])
        == .ctl(CtlOptions(request: .pause(.forSeconds(900)))))
    #expect(
      try CommandLineOptions.parseInvocation(["ctl", "--live", "pause", "--until", "2027-01-15T08:00:00Z"])
        == .ctl(CtlOptions(mode: .live, request: .pause(.until(Date(timeIntervalSince1970: 1_800_000_000))))))
    #expect(
      try CommandLineOptions.parseInvocation(["ctl", "pause", "--indefinite"])
        == .ctl(CtlOptions(request: .pause(.indefinite))))
    #expect(
      try CommandLineOptions.parseInvocation(["ctl", "force", "--minutes", "30"])
        == .ctl(CtlOptions(request: .force(.forSeconds(1800)))))
    #expect(
      try CommandLineOptions.parseInvocation(["ctl", "release-until-idle"])
        == .ctl(CtlOptions(request: .releaseUntilIdle)))
    #expect(try CommandLineOptions.parseInvocation(["ctl", "resume"]) == .ctl(CtlOptions(request: .resume)))
    #expect(
      try CommandLineOptions.parseInvocation(["ctl", "status", "--shadow"]) == .ctl(CtlOptions(request: .status)))
    for arguments in [
      ["ctl"], ["ctl", "pause"], ["ctl", "pause", "--minutes", "0"], ["ctl", "pause", "--until", "soon"],
      ["ctl", "force", "--until", "2027-01-15T08:00:00Z"], ["ctl", "status", "extra"], ["ctl", "reboot"],
    ] {
      #expect(throws: CommandLineError.self) { try CommandLineOptions.parseInvocation(arguments) }
    }
  }
}
