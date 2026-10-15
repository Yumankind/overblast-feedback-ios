import XCTest
@testable import OverblastFeedbackCore

final class PendingStoreTests: XCTestCase {
  private var directory: URL!

  override func setUp() {
    super.setUp()
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("overblast-feedback-tests-\(UUID().uuidString)")
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: directory)
    super.tearDown()
  }

  private func payload(_ message: String) -> FeedbackPayload {
    FeedbackPayload(message: message, context: FeedbackContext(deviceId: "dev1"))
  }

  func testRoundTrip() throws {
    let store = PendingStore(directory: directory)
    let full = PayloadEncodingTests.fullPayload()
    let draft = try store.save(full)
    let read = store.all()
    XCTAssertEqual(read.count, 1)
    XCTAssertEqual(read.first?.id, draft.id)
    XCTAssertEqual(read.first?.payload, full)
    store.remove(draft.id)
    XCTAssertEqual(store.all().count, 0)
  }

  func testRetrySendsOncePerDraftAndRemovesDelivered() async throws {
    let store = PendingStore(directory: directory)
    let t0 = Date()
    try store.save(payload("one"), now: t0)
    try store.save(payload("two"), now: t0.addingTimeInterval(1))
    let sent = Box<[String]>([])
    let delivered = await store.retry(using: { p in
      sent.mutate { $0.append(p.message) }
      return FeedbackReceipt(id: "fbr", taskId: "t", conversationId: nil)
    }, now: t0.addingTimeInterval(2))
    XCTAssertEqual(delivered, 2)
    XCTAssertEqual(sent.value, ["one", "two"])
    XCTAssertTrue(store.all().isEmpty)
  }

  func testARateLimitStopsTheRunAndKeepsTheRest() async throws {
    let store = PendingStore(directory: directory)
    let t0 = Date()
    try store.save(payload("one"), now: t0)
    try store.save(payload("two"), now: t0.addingTimeInterval(1))
    let calls = Box(0)
    let delivered = await store.retry(using: { _ in
      calls.mutate { $0 += 1 }
      throw FeedbackError.rateLimited(retryAfter: 60, message: "later")
    }, now: t0.addingTimeInterval(2))
    XCTAssertEqual(delivered, 0)
    XCTAssertEqual(calls.value, 1, "one refusal ends the run: no loop")
    let left = store.all()
    XCTAssertEqual(left.map(\.payload.message), ["one", "two"])
    XCTAssertEqual(left.first?.attempts, 2)
  }

  func testARefusalForGoodDropsTheDraft() async throws {
    let store = PendingStore(directory: directory)
    try store.save(payload("bad"))
    _ = await store.retry(using: { _ in
      throw FeedbackError.refused(status: 400, code: "invalid_field", message: "no", field: "message")
    })
    XCTAssertTrue(store.all().isEmpty)
  }

  func testPruneKeepsTheNewestTenAndNothingOlderThanAWeek() throws {
    let store = PendingStore(directory: directory)
    let now = Date()
    try store.save(payload("ancient"), now: now.addingTimeInterval(-8 * 24 * 3600))
    for i in 0..<12 {
      try store.save(payload("m\(i)"), now: now.addingTimeInterval(Double(i)))
    }
    store.prune(now: now.addingTimeInterval(20))
    let left = store.all().map(\.payload.message)
    XCTAssertEqual(left.count, 10)
    XCTAssertEqual(left.first, "m2")
    XCTAssertEqual(left.last, "m11")
  }

  func testAnUnreadableFileIsDeleted() throws {
    let store = PendingStore(directory: directory)
    try store.save(payload("ok"))
    try Data("not json".utf8).write(to: directory.appendingPathComponent("junk.json"))
    XCTAssertEqual(store.all().count, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("junk.json").path))
  }

  // MARK: Through the public API

  func testReportKeepsA429AndRetryPendingDeliversIt() async throws {
    let store = PendingStore(directory: directory)
    OverblastFeedback.configure(
      key: "obfk_TESTKEY00000000000000000",
      endpoint: URL(string: "https://feedback.test/v1/feedback")!,
      reporter: FeedbackReporter(accountRef: "cus_1"),
      options: FeedbackOptions(captureOSLog: false, retryPendingOnStart: false),
      session: StubProtocol.session(),
      store: store,
      defaults: scratchDefaults("overblast-feedback-tests")
    )
    OverblastFeedback.logBuffer.removeAll()
    OverblastFeedback.log(.error, "boom with password=hunter2")

    StubProtocol.reset([.http(429, #"{"code":"rate_limited","error":"Later.","retryAfter":5}"#, [:])])
    do {
      try await OverblastFeedback.report(message: "it broke", category: .question)
      XCTFail("expected a rate limit")
    } catch let error as FeedbackError {
      XCTAssertEqual(error, .rateLimited(retryAfter: 5, message: "Later."))
    }
    XCTAssertEqual(OverblastFeedback.pendingCount, 1)

    let sent = try XCTUnwrap(StubProtocol.seen.first)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
    XCTAssertEqual(json["category"] as? String, "question")
    XCTAssertEqual((json["reporter"] as? [String: Any])?["accountRef"] as? String, "cus_1")
    let logs = try XCTUnwrap(json["logs"] as? [[String: Any]])
    XCTAssertEqual(logs.last?["msg"] as? String, "boom with password=[redacted]")
    let context = try XCTUnwrap(json["context"] as? [String: Any])
    XCTAssertEqual(context["platform"] as? String, "ios")
    XCTAssertNotNil(context["deviceId"])

    StubProtocol.reset([])
    let delivered = await OverblastFeedback.retryPending()
    XCTAssertEqual(delivered, 1)
    XCTAssertEqual(OverblastFeedback.pendingCount, 0)
  }

  func testSetReporterBeforeAndAfterConfigure() {
    OverblastFeedback.setReporter(email: "ana@example.com", name: "Ana")
    XCTAssertEqual(OverblastFeedback.reporter, FeedbackReporter(email: "ana@example.com", name: "Ana"))
    OverblastFeedback.setReporter()
    XCTAssertNil(OverblastFeedback.reporter)
    XCTAssertEqual(
      OverblastFeedback.merge(FeedbackReporter(email: "a@b.co", accountRef: "x"), FeedbackReporter(email: "c@d.co")),
      FeedbackReporter(email: "c@d.co", accountRef: "x")
    )
  }
}

/// A value shared with a `@Sendable` closure in a test.
final class Box<T: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var _value: T
  init(_ value: T) { _value = value }
  var value: T {
    lock.lock()
    defer { lock.unlock() }
    return _value
  }
  func mutate(_ change: (inout T) -> Void) {
    lock.lock()
    change(&_value)
    lock.unlock()
  }
}
