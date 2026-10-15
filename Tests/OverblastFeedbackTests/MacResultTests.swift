#if os(macOS)
import AppKit
import XCTest
@testable import OverblastFeedback
@_spi(OverblastPlatform) @testable import OverblastFeedbackCore

/// Answers every request with one canned reply. Its own, because the core tests' stub lives in the
/// other test target.
final class ResultStubProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var reply: (status: Int, body: String) = (201, "{}")

  static func session() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ResultStubProtocol.self]
    return URLSession(configuration: config)
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let (status, body) = Self.reply
    let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

/// What Send in the Mac sheet hands back to the app, and the fallback panel's level.
@MainActor
final class MacResultTests: XCTestCase {
  private var window: NSWindow!

  override func setUp() async throws {
    try await super.setUp()
    _ = NSApplication.shared
    OverblastFeedback.configure(
      key: "obfk_TESTKEY00000000000000000",
      endpoint: URL(string: "https://feedback.test/v1/feedback")!,
      reporter: FeedbackReporter(email: "ana@example.com"),
      options: FeedbackOptions(captureOSLog: false, retryPendingOnStart: false),
      session: ResultStubProtocol.session(),
      store: PendingStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("obf-mac-result-\(UUID().uuidString)")),
      defaults: scratchDefaults("obf-tests")
    )
    window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
    window.orderFront(nil)
  }

  override func tearDown() async throws {
    FeedbackPresenter.shared.dismiss()
    OverblastFeedback.onReportResult = nil
    window.orderOut(nil)
    window = nil
    try await super.tearDown()
  }

  /// Opens the sheet, types, presses Send, and waits for the outcome.
  private func sendOnce(reply: (Int, String)) async throws -> (opener: [FeedbackResult], app: [FeedbackResult]) {
    ResultStubProtocol.reply = reply
    var opener: [FeedbackResult] = []
    var app: [FeedbackResult] = []
    let done = expectation(description: "result")
    OverblastFeedback.onReportResult = { app.append($0); done.fulfill() }
    FeedbackPresenter.shared.present(category: .bug, message: "", in: window, onResult: { opener.append($0) })
    let model = try XCTUnwrap(FeedbackPresenter.shared.model)
    model.message = "Checkout froze"
    model.send()
    await fulfillment(of: [done], timeout: 10)
    return (opener, app)
  }

  func testASentReportHandsBackItsIds() async throws {
    let (opener, app) = try await sendOnce(reply: (201, #"{"id":"fbr_123","taskId":"task_9","conversationId":"conv_4","known":true}"#))
    XCTAssertEqual(opener.count, 1)
    XCTAssertEqual(app.count, 1, "once per Send")
    let receipt = try XCTUnwrap(try? opener[0].get())
    XCTAssertEqual(receipt, FeedbackReceipt(id: "fbr_123", taskId: "task_9", conversationId: "conv_4", known: true))
    XCTAssertEqual(try? app[0].get(), receipt)
  }

  func testARefusalHandsBackItsCodeAndTheSheetStays() async throws {
    let (opener, app) = try await sendOnce(reply: (401, #"{"code":"unknown_key","error":"Feedback is not accepted from this app right now."}"#))
    guard case let .failure(error) = try XCTUnwrap(opener.first) else { return XCTFail("expected a failure") }
    XCTAssertEqual(error.code, "unknown_key")
    XCTAssertEqual(error.message, "Feedback is not accepted from this app right now.")
    XCTAssertFalse(error.keepsForLater)
    XCTAssertEqual(app.count, 1)
    // A refusal leaves the sheet open for another try.
    XCTAssertTrue(OverblastFeedback.isPresenting)
    XCTAssertEqual(FeedbackPresenter.shared.model?.isFinished, false)
  }

  func testCancellingIsNotAResult() async throws {
    var calls = 0
    OverblastFeedback.onReportResult = { _ in calls += 1 }
    FeedbackPresenter.shared.present(in: window, onResult: { _ in calls += 1 })
    let model = try XCTUnwrap(FeedbackPresenter.shared.model)
    model.message = "never mind"
    model.cancel()
    try await Task.sleep(nanoseconds: 200_000_000)
    XCTAssertEqual(calls, 0)
    XCTAssertFalse(OverblastFeedback.isPresenting)
  }

  // MARK: The panel's level

  func testThePanelSitsAboveTheWindowItReportsOn() {
    XCTAssertEqual(SheetSpace.panelLevel(over: .normal), .floating)
    XCTAssertEqual(SheetSpace.panelLevel(over: .floating).rawValue, NSWindow.Level.floating.rawValue + 1)
    XCTAssertEqual(SheetSpace.panelLevel(over: .statusBar).rawValue, NSWindow.Level.statusBar.rawValue + 1)
    XCTAssertEqual(SheetSpace.panelLevel(over: .popUpMenu).rawValue, NSWindow.Level.popUpMenu.rawValue + 1)
  }

  func testAPanelOverARaisedWindowTakesALevelAboveIt() async throws {
    // A short window (so the report opens in a panel) at a menu-bar popover's height.
    let raised = NSWindow(contentRect: NSRect(x: 100, y: 200, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    raised.isReleasedWhenClosed = false
    raised.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
    raised.level = .popUpMenu
    raised.orderFront(nil)
    defer { FeedbackPresenter.shared.dismiss(); raised.orderOut(nil) }
    FeedbackPresenter.shared.present(in: raised)
    try await Task.sleep(nanoseconds: 300_000_000)
    XCTAssertTrue(FeedbackPresenter.shared.usesPanel)
    let panel = try XCTUnwrap(NSApplication.shared.windows.first { $0 is FeedbackSheetWindow && $0.isVisible })
    XCTAssertGreaterThan(panel.level.rawValue, raised.level.rawValue)
  }
}
#endif
