import XCTest
@testable import OverblastFeedbackCore

/// Answers every request from a closure, and remembers what was asked.
final class StubProtocol: URLProtocol, @unchecked Sendable {
  enum Reply {
    case http(Int, String, [String: String])
    case failure(URLError.Code)
  }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var _replies: [Reply] = []
  nonisolated(unsafe) private static var _seen: [(request: URLRequest, body: Data)] = []

  static func reset(_ replies: [Reply]) {
    lock.lock()
    _replies = replies
    _seen = []
    lock.unlock()
  }

  static var seen: [(request: URLRequest, body: Data)] {
    lock.lock()
    defer { lock.unlock() }
    return _seen
  }

  static func session() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    return URLSession(configuration: config)
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    var body = request.httpBody ?? Data()
    if body.isEmpty, let stream = request.httpBodyStream {
      stream.open()
      var buffer = [UInt8](repeating: 0, count: 65_536)
      while stream.hasBytesAvailable {
        let n = stream.read(&buffer, maxLength: buffer.count)
        if n <= 0 { break }
        body.append(buffer, count: n)
      }
      stream.close()
    }
    Self.lock.lock()
    Self._seen.append((request, body))
    let reply = Self._replies.isEmpty ? .http(201, #"{"id":"fbr_1","taskId":"t1","conversationId":null}"#, [:]) : Self._replies.removeFirst()
    Self.lock.unlock()

    switch reply {
    case let .http(status, text, headers):
      let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(text.utf8))
      client?.urlProtocolDidFinishLoading(self)
    case let .failure(code):
      client?.urlProtocol(self, didFailWithError: URLError(code))
    }
  }

  override func stopLoading() {}
}

final class ClientTests: XCTestCase {
  private let endpoint = URL(string: "https://feedback.test/v1/feedback")!

  private func client() -> FeedbackClient {
    FeedbackClient(endpoint: endpoint, key: "obfk_TESTKEY00000000000000000", session: StubProtocol.session())
  }

  private func payload() throws -> FeedbackPayload {
    try FeedbackPayload(message: "broken", context: FeedbackContext(deviceId: "dev1")).sanitized()
  }

  private func expect(_ reply: StubProtocol.Reply, file: StaticString = #filePath, line: UInt = #line) async throws -> FeedbackError {
    StubProtocol.reset([reply])
    do {
      _ = try await client().send(try payload())
      XCTFail("expected a refusal", file: file, line: line)
      throw FeedbackError.notStarted
    } catch let error as FeedbackError {
      return error
    }
  }

  func testCreatedReturnsTheReceiptAndSendsTheKeyAndJSON() async throws {
    StubProtocol.reset([.http(201, #"{"id":"fbr_abc","taskId":"todo_1","conversationId":"c:ana@example.com"}"#, [:])])
    let receipt = try await client().send(try payload())
    XCTAssertEqual(receipt, FeedbackReceipt(id: "fbr_abc", taskId: "todo_1", conversationId: "c:ana@example.com"))

    let sent = try XCTUnwrap(StubProtocol.seen.first)
    XCTAssertEqual(sent.request.httpMethod, "POST")
    XCTAssertEqual(sent.request.url, endpoint)
    XCTAssertEqual(sent.request.value(forHTTPHeaderField: "X-Overblast-Feedback-Key"), "obfk_TESTKEY00000000000000000")
    XCTAssertEqual(sent.request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
    XCTAssertEqual(json["v"] as? Int, 1)
    XCTAssertEqual(json["message"] as? String, "broken")
  }

  func testInvalidFieldCarriesTheFieldAndTheSentence() async throws {
    let error = try await expect(.http(400, #"{"code":"invalid_field","field":"context.platform","error":"context.platform must be one of web, ios, android, flutter."}"#, [:]))
    XCTAssertEqual(error, .refused(status: 400, code: "invalid_field", message: "context.platform must be one of web, ios, android, flutter.", field: "context.platform"))
    XCTAssertFalse(error.keepsForLater)
  }

  func testUnknownKeyAndDisabledKey() async throws {
    let unknown = try await expect(.http(401, #"{"code":"unknown_key","error":"This feedback key was revoked."}"#, [:]))
    XCTAssertEqual(unknown.code, "unknown_key")
    XCTAssertEqual(unknown.message, "This feedback key was revoked.")
    let disabled = try await expect(.http(403, #"{"code":"key_disabled","error":"Paused."}"#, [:]))
    XCTAssertEqual(disabled, .refused(status: 403, code: "key_disabled", message: "Paused.", field: nil))
  }

  func testTooLargeAndMisconfigured() async throws {
    let large = try await expect(.http(413, #"{"code":"too_large","error":"Too big."}"#, [:]))
    XCTAssertEqual(large.code, "too_large")
    let broken = try await expect(.http(500, #"{"code":"misconfigured","error":"FEEDBACK_KV is missing."}"#, [:]))
    XCTAssertEqual(broken, .refused(status: 500, code: "misconfigured", message: "FEEDBACK_KV is missing.", field: nil))
  }

  func testRateLimitedReadsRetryAfterFromTheBodyThenTheHeader() async throws {
    let fromBody = try await expect(.http(429, #"{"code":"rate_limited","error":"Slow down.","retryAfter":120}"#, [:]))
    XCTAssertEqual(fromBody, .rateLimited(retryAfter: 120, message: "Slow down."))
    XCTAssertTrue(fromBody.keepsForLater)
    let fromHeader = try await expect(.http(429, "", ["Retry-After": "30"]))
    guard case .rateLimited(30, _) = fromHeader else { return XCTFail("\(fromHeader)") }
  }

  func testStorageFullMeansFiled() async throws {
    let error = try await expect(.http(507, #"{"code":"storage_full","error":"Filed without the screenshot."}"#, [:]))
    XCTAssertEqual(error, .storageFull(message: "Filed without the screenshot."))
    XCTAssertTrue(error.wasFiled)
    XCTAssertFalse(error.keepsForLater)
  }

  func testEdgeErrorsAndNoConnectionAreKeptForLater() async throws {
    let edge = try await expect(.http(503, "<html>Service Unavailable</html>", [:]))
    guard case .offline = edge else { return XCTFail("\(edge)") }
    let offline = try await expect(.failure(.notConnectedToInternet))
    guard case .offline = offline else { return XCTFail("\(offline)") }
    XCTAssertTrue(offline.keepsForLater)
  }

  func testARefusalWithoutABodyStillHasASentence() async throws {
    let error = try await expect(.http(418, "", [:]))
    XCTAssertEqual(error.code, "http_418")
    XCTAssertFalse(error.message.isEmpty)
  }
}
