import XCTest
@testable import OverblastFeedbackCore

final class LimitsTests: XCTestCase {
  private func payload(_ message: String = "hi") -> FeedbackPayload {
    FeedbackPayload(message: message, context: FeedbackContext())
  }

  func testMessageIsCutTo4000UTF16UnitsWithoutSplittingACharacter() throws {
    let long = String(repeating: "a", count: 3999) + "😀😀"
    let cut = try payload(long).sanitized().message
    XCTAssertLessThanOrEqual(cut.utf16.count, 4000)
    XCTAssertTrue(cut.hasSuffix("…"))
    // No lone surrogate: the string round-trips through UTF-8.
    XCTAssertEqual(String(decoding: Data(cut.utf8), as: UTF8.self), cut)
  }

  func testAnEmptyMessageIsRefusedBeforeSending() {
    XCTAssertThrowsError(try payload("  \n ").sanitized()) { error in
      XCTAssertEqual(error as? FeedbackError, .invalidReport(field: "message", message: "Please say what happened."))
    }
  }

  func testABadEmailIsRefusedAndAGoodOneKept() throws {
    var p = payload()
    p.reporter = FeedbackReporter(email: "ana@example")
    XCTAssertThrowsError(try p.sanitized()) { error in
      guard case .invalidReport(field: "reporter.email", _) = error as? FeedbackError else { return XCTFail("\(error)") }
    }
    p.reporter = FeedbackReporter(email: " ana@example.com ", name: String(repeating: "n", count: 200), accountRef: String(repeating: "r", count: 300))
    let r = try XCTUnwrap(try p.sanitized().reporter)
    XCTAssertEqual(r.email, "ana@example.com")
    XCTAssertEqual(r.name?.utf16.count, 120)
    XCTAssertEqual(r.accountRef, String(repeating: "r", count: 200))
  }

  func testContextFieldsAreCut() throws {
    var p = payload()
    p.context = FeedbackContext(
      screen: String(repeating: "s", count: 500),
      appVersion: String(repeating: "1", count: 100),
      device: String(repeating: "d", count: 100),
      deviceId: "not valid!",
      extra: Dictionary(uniqueKeysWithValues: (0..<30).map { ("k\(String(format: "%02d", $0))", String(repeating: "v", count: 300)) })
    )
    let c = try p.sanitized().context
    XCTAssertEqual(c.screen?.utf16.count, 200)
    XCTAssertEqual(c.appVersion?.count, 40)
    XCTAssertEqual(c.device?.count, 80)
    XCTAssertNil(c.deviceId)
    XCTAssertEqual(c.extra?.count, 20)
    XCTAssertEqual(c.extra?["k00"]?.utf16.count, 200)
    XCTAssertNil(c.extra?["k25"])
  }

  func testLogsKeepTheNewest500OldestFirstAndRedacted() throws {
    var p = payload()
    p.logs = (0..<700).map { FeedbackLogEntry(t: Int64(700 - $0), level: .info, msg: "line \(700 - $0) Bearer abcdefghijklmnop") }
    let logs = try XCTUnwrap(try p.sanitized().logs)
    XCTAssertEqual(logs.count, 500)
    XCTAssertEqual(logs.first?.t, 201)
    XCTAssertEqual(logs.last?.t, 700)
    XCTAssertTrue(logs.allSatisfy { $0.msg.hasSuffix("Bearer [redacted]") })
  }

  func testLogsAreHeldTo256KBDroppingTheOldest() throws {
    var p = payload()
    p.logs = (0..<500).map { FeedbackLogEntry(t: Int64($0), level: .debug, msg: String(repeating: "x", count: 3000), src: "app") }
    let logs = try XCTUnwrap(try p.sanitized().logs)
    let size = try FeedbackPayload.encoder().encode(logs).count
    XCTAssertLessThanOrEqual(size, FeedbackLimits.logBytes)
    XCTAssertLessThan(logs.count, 500)
    XCTAssertEqual(logs.last?.t, 499)
  }

  func testALogLineIsCutTo4000AndItsSourceTo40() throws {
    var p = payload()
    p.logs = [FeedbackLogEntry(t: 1, level: .warn, msg: String(repeating: "m", count: 9000), src: String(repeating: "s", count: 99))]
    let line = try XCTUnwrap(try p.sanitized().logs?.first)
    XCTAssertEqual(line.msg.utf16.count, 4000)
    XCTAssertEqual(line.src?.utf16.count, 40)
  }

  func testNetworkKeepsTheNewest100AndNoQueryString() throws {
    var p = payload()
    p.network = (0..<150).map {
      FeedbackNetworkEntry(t: Int64($0), method: "get", url: "https://user:pw@api.example.com/v1/items/\($0)?token=secret#frag", status: 200, ms: -3)
    }
    let net = try XCTUnwrap(try p.sanitized().network)
    XCTAssertEqual(net.count, 100)
    XCTAssertEqual(net.first?.t, 50)
    XCTAssertEqual(net.last?.url, "https://api.example.com/v1/items/149")
    XCTAssertEqual(net.last?.method, "GET")
    XCTAssertEqual(net.last?.ms, 0)
  }

  func testNetworkURLIsCutTo500() throws {
    var p = payload()
    p.network = [FeedbackNetworkEntry(t: 1, method: "GET", url: "https://a.example/" + String(repeating: "p", count: 900), status: 0, ms: 1)]
    XCTAssertEqual(try p.sanitized().network?.first?.url.utf16.count, 500)
  }

  func testScreenshotOver5MBOrOfAnotherTypeIsRefused() {
    var p = payload()
    p.screenshot = FeedbackScreenshot(jpeg: Data(count: FeedbackLimits.screenshotBytes + 1), highlighted: false)
    XCTAssertThrowsError(try p.sanitized())
    p.screenshot = FeedbackScreenshot(contentType: "image/gif", base64: "AAAA", highlighted: false)
    XCTAssertThrowsError(try p.sanitized())
    p.screenshot = FeedbackScreenshot(jpeg: Data(count: 1000), highlighted: false)
    XCTAssertNoThrow(try p.sanitized())
  }

  func testEmailPlausibility() {
    XCTAssertTrue(FeedbackText.isPlausibleEmail("a@b.co"))
    XCTAssertFalse(FeedbackText.isPlausibleEmail("a@b"))
    XCTAssertFalse(FeedbackText.isPlausibleEmail("a b@c.com"))
    XCTAssertFalse(FeedbackText.isPlausibleEmail("@c.com"))
    XCTAssertFalse(FeedbackText.isPlausibleEmail("a@@c.com"))
  }
}
