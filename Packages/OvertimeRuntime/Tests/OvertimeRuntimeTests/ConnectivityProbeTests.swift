import Foundation
import Testing
import os

@testable import OvertimeSystem

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
  enum Behaviour: Sendable, Equatable {
    case respond(status: Int, body: String)
    case fail
    case failAfter(seconds: Double)
    case hang
  }

  struct Request: Sendable, Equatable {
    var host: String
    var method: String?
    var headers: [String: String]
    var cachePolicy: UInt
    var handlesCookies: Bool
  }

  private struct Table: Sendable {
    var behaviours: [String: Behaviour] = [:]
    var requests: [Request] = []
    var stops: [String] = []
  }

  private static let table = OSAllocatedUnfairLock(initialState: Table())
  private let stopped = OSAllocatedUnfairLock(initialState: false)

  static func set(_ behaviour: Behaviour, for host: String) {
    table.withLock { $0.behaviours[host] = behaviour }
  }

  static func requests(to host: String) -> [Request] {
    table.withLock { $0.requests.filter { $0.host == host } }
  }

  static func stops(of host: String) -> Int {
    table.withLock { $0.stops.filter { $0 == host }.count }
  }

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    let request = request
    let host = request.url?.host ?? ""
    let behaviour = Self.table.withLock { table -> Behaviour in
      table.requests.append(
        Request(
          host: host, method: request.httpMethod, headers: request.allHTTPHeaderFields ?? [:],
          cachePolicy: request.cachePolicy.rawValue, handlesCookies: request.httpShouldHandleCookies))
      return table.behaviours[host] ?? .fail
    }
    switch behaviour {
    case .respond(let status, let body):
      guard
        let url = request.url,
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)
      else {
        client?.urlProtocol(self, didFailWithError: URLError(.badURL))
        return
      }
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      if !body.isEmpty {
        client?.urlProtocol(self, didLoad: Data(body.utf8))
      }
      client?.urlProtocolDidFinishLoading(self)
    case .fail:
      client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
    case .failAfter(let seconds):
      let stopped = stopped
      let client = client
      DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in
        guard !stopped.withLock({ $0 }) else { return }
        client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
      }
    case .hang:
      break
    }
  }

  override func stopLoading() {
    stopped.withLock { $0 = true }
    let host = request.url?.host ?? ""
    Self.table.withLock { $0.stops.append(host) }
  }
}

struct StubbedProbe {
  let primaryHost = "primary-\(UUID().uuidString.lowercased()).test"
  let captiveHost = "captive-\(UUID().uuidString.lowercased()).test"
  let probe: ConnectivityProbe

  init(
    primary: StubURLProtocol.Behaviour, captive: StubURLProtocol.Behaviour, staggerSeconds: Double = 0.3,
    budgetSeconds: Double = 0.9, idleSeconds: Double = ConnectivityProbe.defaultIdleSeconds
  ) {
    StubURLProtocol.set(primary, for: primaryHost)
    StubURLProtocol.set(captive, for: captiveHost)
    probe = ConnectivityProbe(
      protocolClasses: [StubURLProtocol.self],
      primary: URL(string: "https://\(primaryHost)/")!,
      captive: URL(string: "https://\(captiveHost)/hotspot-detect.html")!,
      staggerSeconds: staggerSeconds,
      budgetSeconds: budgetSeconds,
      idleSeconds: idleSeconds)
  }

  func run() async -> Bool? {
    let probe = probe
    return await OffPool.bounded(seconds: 10) { probe.probe() }
  }

  func timedRun() async -> (online: Bool?, seconds: Double) {
    let start = ContinuousClock.now
    let online = await run()
    let elapsed = ContinuousClock.now - start
    return (online, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
  }
}

struct ConnectivityProbeTests {
  static let success = StubURLProtocol.Behaviour.respond(status: 200, body: "<HTML><BODY>Success</BODY></HTML>")

  @Test func anyAnswerFromThePrimaryEndpointIsOnline() async {
    let stubbed = StubbedProbe(primary: .respond(status: 404, body: ""), captive: .fail)
    #expect(await stubbed.run() == true)
  }

  @Test func bothEndpointsFailingIsOffline() async {
    let stubbed = StubbedProbe(primary: .fail, captive: .fail)
    #expect(await stubbed.run() == false)
    #expect(StubURLProtocol.requests(to: stubbed.primaryHost).count == 1)
    #expect(StubURLProtocol.requests(to: stubbed.captiveHost).count == 1)
  }

  @Test func aPrimaryAnswerOf200IsOnlineWithoutAskingTheCaptiveEndpoint() async {
    let stubbed = StubbedProbe(primary: .respond(status: 200, body: ""), captive: Self.success)
    #expect(await stubbed.run() == true)
    #expect(StubURLProtocol.requests(to: stubbed.captiveHost).isEmpty)
  }

  @Test func aPrimaryThatFailsFastStartsTheCaptiveCheckBeforeTheStagger() async {
    let stubbed = StubbedProbe(primary: .fail, captive: Self.success, staggerSeconds: 8, budgetSeconds: 9)
    let (online, seconds) = await stubbed.timedRun()
    #expect(online == true)
    #expect(seconds < 4, "the captive request started at the primary's failure, not after the 8 s stagger")
    #expect(StubURLProtocol.requests(to: stubbed.captiveHost).count == 1)
  }

  @Test func aPrimaryThatHangsStartsTheCaptiveCheckAtTheStagger() async {
    let stubbed = StubbedProbe(primary: .hang, captive: Self.success, budgetSeconds: 15)
    let (online, seconds) = await stubbed.timedRun()
    #expect(online == true)
    #expect(seconds >= 0.3, "the captive request waits for the stagger while the primary has not answered")
    #expect(seconds < 7.5, "the first online verdict ends the probe long before the 15 s budget")
  }

  @Test func aCaptivePortalPageIsOffline() async {
    let portal = StubURLProtocol.Behaviour.respond(
      status: 200, body: "<html><body>Sign in to the network</body></html>")
    let stubbed = StubbedProbe(primary: .fail, captive: portal)
    #expect(await stubbed.run() == false)
  }

  @Test(arguments: [302, 500])
  func aCaptiveAnswerOtherThan200IsOfflineEvenWithTheMarker(status: Int) async {
    let stubbed = StubbedProbe(primary: .fail, captive: .respond(status: status, body: "Success"))
    #expect(await stubbed.run() == false)
  }

  @Test func bothEndpointsHangingIsOfflineAtTheBudgetAndBothRequestsAreStopped() async {
    let stubbed = StubbedProbe(primary: .hang, captive: .hang, staggerSeconds: 4.5, budgetSeconds: 5)
    let (online, seconds) = await stubbed.timedRun()
    #expect(online == false)
    #expect(seconds >= 4.95)
    #expect(seconds < 7.5, "the budget ends the probe, not the captive request's own timeout 5 s after the stagger")
    let stopped = await OffPool.eventually {
      StubURLProtocol.stops(of: stubbed.primaryHost) == 1 && StubURLProtocol.stops(of: stubbed.captiveHost) == 1
    }
    #expect(stopped)
  }

  @Test func anOnlineVerdictStopsTheOtherRequest() async {
    let stubbed = StubbedProbe(primary: .hang, captive: Self.success, budgetSeconds: 30)
    #expect(await stubbed.run() == true)
    let stopped = await OffPool.eventually(seconds: 10) { StubURLProtocol.stops(of: stubbed.primaryHost) == 1 }
    #expect(stopped, "the hanging primary is cancelled at the verdict, long before its own 30 s timeout")
  }

  @Test func aPrimaryThatFailsAfterTheCaptiveCheckEndsTheProbeAtOnce() async {
    let stubbed = StubbedProbe(
      primary: .failAfter(seconds: 0.5), captive: .fail, staggerSeconds: 0.1, budgetSeconds: 20)
    let (online, seconds) = await stubbed.timedRun()
    #expect(online == false)
    #expect(seconds >= 0.45)
    #expect(seconds < 10, "both requests have failed, so the probe does not wait for the 20 s budget")
  }

  @Test func thePrimaryIsAHeadAndTheCaptiveCheckAGetWithNoCookieAndNoCache() async throws {
    let stubbed = StubbedProbe(primary: .fail, captive: .fail)
    #expect(await stubbed.run() == false)
    let primary = try #require(StubURLProtocol.requests(to: stubbed.primaryHost).first)
    let captive = try #require(StubURLProtocol.requests(to: stubbed.captiveHost).first)
    #expect(primary.method == "HEAD")
    #expect(captive.method == "GET")
    let reload = URLRequest.CachePolicy.reloadIgnoringLocalAndRemoteCacheData.rawValue
    for request in [primary, captive] {
      #expect(!request.handlesCookies)
      #expect(request.cachePolicy == reload)
    }
  }

  @Test func theSessionKeepsNoCookieStoreAndAttachesNoCookies() {
    let session = StubbedProbe(primary: .fail, captive: .fail).probe.makeSession()
    defer { session.invalidateAndCancel() }
    #expect(session.configuration.httpCookieStorage == nil)
    #expect(!session.configuration.httpShouldSetCookies)
  }

  @Test func twoProbesInARowShareOneSession() async {
    let stubbed = StubbedProbe(primary: .respond(status: 204, body: ""), captive: .fail)
    #expect(await stubbed.run() == true)
    #expect(stubbed.probe.sessionGeneration == 1)
    #expect(await stubbed.run() == true)
    #expect(stubbed.probe.sessionGeneration == 1)
  }

  @Test func invalidatingMakesTheNextProbeBuildANewSession() async {
    let stubbed = StubbedProbe(primary: .respond(status: 204, body: ""), captive: .fail)
    #expect(await stubbed.run() == true)
    #expect(stubbed.probe.sessionGeneration == 1)
    stubbed.probe.invalidate()
    #expect(await stubbed.run() == true)
    #expect(stubbed.probe.sessionGeneration == 2)
  }

  @Test func aSessionUnusedForTheIdleTimeIsDroppedAndTheNextProbeBuildsANewOne() async throws {
    let stubbed = StubbedProbe(primary: .respond(status: 204, body: ""), captive: .fail, idleSeconds: 0.2)
    #expect(await stubbed.run() == true)
    #expect(stubbed.probe.sessionGeneration == 1)
    try await Task.sleep(for: .milliseconds(400))
    #expect(await stubbed.run() == true)
    #expect(stubbed.probe.sessionGeneration == 2)
  }

  @Test func theDefaultsAreTheTwoHTTPSEndpointsAndTheDecidedTimings() {
    let probe = ConnectivityProbe()
    #expect(probe.primaryURL.absoluteString == "https://api.anthropic.com/")
    #expect(probe.captiveURL.absoluteString == "https://captive.apple.com/hotspot-detect.html")
    #expect(probe.staggerSeconds == 1.5)
    #expect(probe.budgetSeconds == 4.5)
    #expect(probe.idleSeconds == 25)
    #expect(probe.successMarker == "Success")
  }
}
