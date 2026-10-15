import Foundation
import os

public final class ConnectivityProbe: Sendable {
  public static let defaultPrimaryURL = URL(string: "https://api.anthropic.com/")!
  public static let defaultCaptiveURL = URL(string: "https://captive.apple.com/hotspot-detect.html")!
  public static let defaultStaggerSeconds: Double = 1.5
  public static let defaultBudgetSeconds: Double = 4.5
  public static let defaultIdleSeconds: Double = 25
  public static let successMarker = "Success"
  public static let headMethod = "HEAD"
  public static let getMethod = "GET"
  static let queueLabel = "io.github.ivanhernandez-dev.overtime.connectivity-probe"

  struct ProtocolClasses: @unchecked Sendable {
    let classes: [AnyClass]
  }

  private struct Attempt: Sendable {
    var online = false
    var primaryDone = false
    var captiveStarted = false
    var captiveDone = false
    var finished = false
    var tasks: [URLSessionTask] = []
  }

  public let primaryURL: URL
  public let captiveURL: URL
  public let staggerSeconds: Double
  public let budgetSeconds: Double
  public let idleSeconds: Double
  public var successMarker: String { Self.successMarker }

  private struct SessionSlot: Sendable {
    var session: URLSession?
    var generation = 0
    var uses = 0
    var inFlight = 0
  }

  private let protocolClasses: ProtocolClasses?
  private let slot = OSAllocatedUnfairLock(initialState: SessionSlot())
  private let queue = DispatchQueue(label: ConnectivityProbe.queueLabel)

  var sessionGeneration: Int {
    slot.withLock { $0.generation }
  }

  public func invalidate() {
    let dropped = slot.withLock { slot -> URLSession? in
      defer { slot.session = nil }
      return slot.session
    }
    dropped?.finishTasksAndInvalidate()
  }

  deinit {
    slot.withLock { $0.session }?.finishTasksAndInvalidate()
  }

  public init(
    protocolClasses: [AnyClass]? = nil,
    primary: URL = ConnectivityProbe.defaultPrimaryURL,
    captive: URL = ConnectivityProbe.defaultCaptiveURL,
    staggerSeconds: Double = ConnectivityProbe.defaultStaggerSeconds,
    budgetSeconds: Double = ConnectivityProbe.defaultBudgetSeconds,
    idleSeconds: Double = ConnectivityProbe.defaultIdleSeconds
  ) {
    self.protocolClasses = protocolClasses.map(ProtocolClasses.init)
    primaryURL = primary
    captiveURL = captive
    self.staggerSeconds = max(0, staggerSeconds)
    self.budgetSeconds = max(0, budgetSeconds)
    self.idleSeconds = max(0, idleSeconds)
  }

  public func probe() -> Bool {
    let session = beginUse()
    let online = probe(on: session)
    endUse()
    return online
  }

  private func probe(on session: URLSession) -> Bool {
    let attempt = OSAllocatedUnfairLock(initialState: Attempt())
    let done = DispatchSemaphore(value: 0)
    let marker = Data(Self.successMarker.utf8)
    let captive = session.dataTask(with: request(captiveURL, method: Self.getMethod)) { data, response, _ in
      let status = (response as? HTTPURLResponse)?.statusCode
      let online = status == 200 && (data?.range(of: marker) != nil)
      let signal = attempt.withLock { attempt -> Bool in
        attempt.captiveDone = true
        if online { attempt.online = true }
        return online || attempt.primaryDone
      }
      if signal { done.signal() }
    }
    let startCaptive: @Sendable () -> Void = {
      let start = attempt.withLock { attempt -> Bool in
        guard !attempt.finished, !attempt.captiveStarted else { return false }
        attempt.captiveStarted = true
        return true
      }
      if start { captive.resume() }
    }
    let primary = session.dataTask(with: request(primaryURL, method: Self.headMethod)) { _, response, _ in
      let online = response is HTTPURLResponse
      let signal = attempt.withLock { attempt -> Bool in
        attempt.primaryDone = true
        if online { attempt.online = true }
        return online || attempt.captiveDone
      }
      if signal {
        done.signal()
      } else {
        startCaptive()
      }
    }
    attempt.withLock { $0.tasks = [primary, captive] }
    let stagger = DispatchWorkItem(block: startCaptive)
    primary.resume()
    queue.asyncAfter(deadline: .now() + staggerSeconds, execute: stagger)
    _ = done.wait(timeout: .now() + budgetSeconds)
    stagger.cancel()
    let (online, tasks) = attempt.withLock { attempt -> (Bool, [URLSessionTask]) in
      attempt.finished = true
      return (attempt.online, attempt.tasks)
    }
    for task in tasks {
      task.cancel()
    }
    return online
  }

  private func request(_ url: URL, method: String) -> URLRequest {
    var request = URLRequest(
      url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: budgetSeconds)
    request.httpMethod = method
    request.httpShouldHandleCookies = false
    return request
  }

  private func beginUse() -> URLSession {
    slot.withLock { slot -> URLSession in
      slot.uses += 1
      slot.inFlight += 1
      if let current = slot.session { return current }
      let made = makeSession()
      slot.session = made
      slot.generation += 1
      return made
    }
  }

  private func endUse() {
    let use = slot.withLock { slot -> Int in
      slot.inFlight -= 1
      slot.uses += 1
      return slot.uses
    }
    queue.asyncAfter(deadline: .now() + idleSeconds) { [weak self] in
      self?.dropIfIdle(since: use)
    }
  }

  private func dropIfIdle(since use: Int) {
    let dropped = slot.withLock { slot -> URLSession? in
      guard slot.uses == use, slot.inFlight == 0 else { return nil }
      defer { slot.session = nil }
      return slot.session
    }
    dropped?.finishTasksAndInvalidate()
  }

  func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.waitsForConnectivity = false
    configuration.timeoutIntervalForRequest = budgetSeconds
    configuration.timeoutIntervalForResource = budgetSeconds
    if let protocolClasses {
      configuration.protocolClasses = protocolClasses.classes
    }
    return URLSession(configuration: configuration)
  }
}
