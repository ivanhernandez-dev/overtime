import Foundation
import os

public enum ControlSocketError: Error, Equatable {
  case pathTooLong(Int)
  case notRunning
  case system(call: String, errno: Int32)
  case invalidResponse
}

enum SocketSupport {
  static func makeAddress(_ path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
      throw ControlSocketError.pathTooLong(bytes.count)
    }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
      raw.copyBytes(from: bytes)
      raw[bytes.count] = 0
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return address
  }

  static func withSockaddr<T>(_ address: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
  }

  static func setCloseOnExec(_ descriptor: Int32) {
    _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
  }

  static func setNoSigPipe(_ descriptor: Int32) {
    var on: Int32 = 1
    _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
  }

  static func setTimeouts(_ descriptor: Int32, seconds: Double) {
    let whole = Int(seconds)
    var value = timeval(tv_sec: whole, tv_usec: Int32((seconds - Double(whole)) * 1_000_000))
    let size = socklen_t(MemoryLayout<timeval>.size)
    _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &value, size)
    _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &value, size)
  }

  enum LineRead: Equatable {
    case line(Data)
    case tooLarge
    case failed
  }

  static func readLine(_ descriptor: Int32, maxBytes: Int) -> LineRead {
    var line = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while true {
      let count = buffer.withUnsafeMutableBytes { raw in Darwin.read(descriptor, raw.baseAddress, raw.count) }
      if count < 0 {
        if errno == EINTR { continue }
        return .failed
      }
      if count == 0 {
        return line.isEmpty ? .failed : .line(line)
      }
      let chunk = buffer.prefix(count)
      if let newline = chunk.firstIndex(of: 0x0A) {
        line.append(contentsOf: chunk[..<newline])
        return line.count > maxBytes ? .tooLarge : .line(line)
      }
      line.append(contentsOf: chunk)
      if line.count > maxBytes {
        return .tooLarge
      }
    }
  }

  static func writeAll(_ descriptor: Int32, _ data: Data) -> Bool {
    var offset = 0
    while offset < data.count {
      let written = data.withUnsafeBytes { raw in
        Darwin.write(descriptor, raw.baseAddress?.advanced(by: offset), raw.count - offset)
      }
      if written < 0 {
        if errno == EINTR { continue }
        return false
      }
      offset += written
    }
    return true
  }
}

public final class ControlServer: @unchecked Sendable {
  public static let maxLineBytes = 4_096
  public static let connectionTimeoutSeconds: Double = 2
  public static let handlerTimeoutSeconds: Double = 2

  private struct Running {
    var listener: Int32
    var wakeWrite: Int32
    var finished: DispatchSemaphore
  }

  public static let acceptedPending = "accepted; status pending"

  private let socketPath: String
  private let handler: @Sendable (CtlRequest) async -> CtlResponse
  private let handlerTimeoutSeconds: Double
  private let running = OSAllocatedUnfairLock<Running?>(initialState: nil)

  public init(
    socketPath: String, handlerTimeoutSeconds: Double = ControlServer.handlerTimeoutSeconds,
    handler: @escaping @Sendable (CtlRequest) async -> CtlResponse
  ) {
    self.socketPath = socketPath
    self.handlerTimeoutSeconds = handlerTimeoutSeconds
    self.handler = handler
  }

  public func start() throws {
    var address = try SocketSupport.makeAddress(socketPath)
    let directory = (socketPath as NSString).deletingLastPathComponent
    guard chmod(directory, 0o700) == 0 else { throw ControlSocketError.system(call: "chmod", errno: errno) }
    if unlink(socketPath) != 0 && errno != ENOENT {
      throw ControlSocketError.system(call: "unlink", errno: errno)
    }
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listener >= 0 else { throw ControlSocketError.system(call: "socket", errno: errno) }
    SocketSupport.setCloseOnExec(listener)
    let bound = SocketSupport.withSockaddr(&address) { bind(listener, $0, $1) }
    guard bound == 0 else {
      let code = errno
      close(listener)
      throw ControlSocketError.system(call: "bind", errno: code)
    }
    guard chmod(socketPath, 0o600) == 0, listen(listener, 16) == 0 else {
      let code = errno
      close(listener)
      unlink(socketPath)
      throw ControlSocketError.system(call: "listen", errno: code)
    }
    var wake: [Int32] = [-1, -1]
    guard pipe(&wake) == 0 else {
      let code = errno
      close(listener)
      unlink(socketPath)
      throw ControlSocketError.system(call: "pipe", errno: code)
    }
    let wakeRead = wake[0]
    let wakeWrite = wake[1]
    SocketSupport.setCloseOnExec(wakeRead)
    SocketSupport.setCloseOnExec(wakeWrite)
    let finished = DispatchSemaphore(value: 0)
    running.withLock { $0 = Running(listener: listener, wakeWrite: wakeWrite, finished: finished) }
    let thread = Thread { [self] in
      acceptLoop(listener: listener, wakeRead: wakeRead)
      close(wakeRead)
      finished.signal()
    }
    thread.name = "overtime.control"
    thread.start()
  }

  public func stop() {
    guard
      let current = running.withLock({ state -> Running? in
        defer { state = nil }
        return state
      })
    else { return }
    var byte: UInt8 = 1
    _ = Darwin.write(current.wakeWrite, &byte, 1)
    _ = current.finished.wait(timeout: .now() + 5)
    close(current.wakeWrite)
    close(current.listener)
    unlink(socketPath)
  }

  deinit {
    stop()
  }

  private func acceptLoop(listener: Int32, wakeRead: Int32) {
    while true {
      var descriptors = [
        pollfd(fd: listener, events: Int16(POLLIN), revents: 0),
        pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0),
      ]
      let ready = poll(&descriptors, 2, -1)
      if ready < 0 {
        if errno == EINTR { continue }
        return
      }
      if descriptors[1].revents != 0 { return }
      guard descriptors[0].revents & Int16(POLLIN) != 0 else { continue }
      let client = accept(listener, nil, nil)
      guard client >= 0 else { continue }
      serve(client)
      close(client)
    }
  }

  private func serve(_ client: Int32) {
    SocketSupport.setCloseOnExec(client)
    SocketSupport.setNoSigPipe(client)
    SocketSupport.setTimeouts(client, seconds: Self.connectionTimeoutSeconds)
    var peerUID: uid_t = 0
    var peerGID: gid_t = 0
    guard getpeereid(client, &peerUID, &peerGID) == 0, peerUID == getuid() else {
      _ = SocketSupport.writeAll(client, ControlProtocol.encodeLine(CtlResponse.failure("forbidden")))
      return
    }
    let response: CtlResponse
    switch SocketSupport.readLine(client, maxBytes: Self.maxLineBytes) {
    case .failed:
      return
    case .tooLarge:
      response = .failure("request too large")
    case .line(let line):
      switch ControlProtocol.decodeRequest(line) {
      case .failure(let error):
        response = .failure(error.message)
      case .success(let request):
        response = handle(request)
      }
    }
    _ = SocketSupport.writeAll(client, ControlProtocol.encodeLine(response))
  }

  private func handle(_ request: CtlRequest) -> CtlResponse {
    let box = OSAllocatedUnfairLock<CtlResponse?>(initialState: nil)
    let done = DispatchSemaphore(value: 0)
    let handler = self.handler
    Task {
      let response = await handler(request)
      box.withLock { $0 = response }
      done.signal()
    }
    guard done.wait(timeout: .now() + handlerTimeoutSeconds) == .success, let response = box.withLock({ $0 }) else {
      return Self.pendingResponse(for: request)
    }
    return response
  }
}

extension ControlServer {
  static func pendingResponse(for request: CtlRequest) -> CtlResponse {
    request == .status ? .failure("timeout") : CtlResponse(ok: true, error: acceptedPending)
  }
}

public enum ControlClient {
  public static let timeoutSeconds: Double = 5
  public static let maxResponseBytes = 65_536

  public static func send(
    _ request: CtlRequest, socketPath: String, timeoutSeconds: Double = ControlClient.timeoutSeconds
  ) throws -> CtlResponse {
    let reply = try exchange(
      ControlProtocol.encodeLine(request), socketPath: socketPath, timeoutSeconds: timeoutSeconds)
    guard let response = try? JSONDecoder().decode(CtlResponse.self, from: reply) else {
      throw ControlSocketError.invalidResponse
    }
    return response
  }

  public static func exchange(
    _ bytes: Data, socketPath: String, timeoutSeconds: Double = ControlClient.timeoutSeconds
  ) throws -> Data {
    var address = try SocketSupport.makeAddress(socketPath)
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw ControlSocketError.system(call: "socket", errno: errno) }
    defer { close(descriptor) }
    SocketSupport.setCloseOnExec(descriptor)
    SocketSupport.setNoSigPipe(descriptor)
    SocketSupport.setTimeouts(descriptor, seconds: timeoutSeconds)
    let connected = SocketSupport.withSockaddr(&address) { connect(descriptor, $0, $1) }
    guard connected == 0 else {
      let code = errno
      if code == ENOENT || code == ECONNREFUSED { throw ControlSocketError.notRunning }
      throw ControlSocketError.system(call: "connect", errno: code)
    }
    guard SocketSupport.writeAll(descriptor, bytes) else {
      throw ControlSocketError.system(call: "write", errno: errno)
    }
    guard case .line(let line) = SocketSupport.readLine(descriptor, maxBytes: maxResponseBytes) else {
      throw ControlSocketError.invalidResponse
    }
    return line
  }
}
