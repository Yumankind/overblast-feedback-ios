import XCTest
@testable import OverblastFeedbackCore

/// The worker refuses an unknown top-level field by name, so the key sets are pinned exactly, at
/// every level, against contract §3.1 and §3.2.
final class PayloadEncodingTests: XCTestCase {
  static func fullPayload() -> FeedbackPayload {
    FeedbackPayload(
      message: "The total doesn't update when I remove an item",
      category: .bug,
      reporter: FeedbackReporter(email: "ana@example.com", name: "Ana", accountRef: "cus_8812"),
      context: FeedbackContext(
        platform: "ios",
        url: "https://example.com/cart?step=2",
        screen: "CartViewController",
        title: "Your cart",
        appVersion: "2.4.1",
        build: "412",
        os: "iOS",
        osVersion: "18.2",
        device: "iPhone15,3",
        locale: "pt-PT",
        timeZone: "Europe/Lisbon",
        viewport: FeedbackViewport(w: 393, h: 852, dpr: 3),
        userAgent: "ua",
        sdk: FeedbackSDK(name: "overblast-feedback-ios", version: "0.1.0"),
        deviceId: "8c1f00aa",
        extra: ["plan": "pro"]
      ),
      element: FeedbackElement(
        path: ["UIWindow", "UINavigationController", "CartView", "UIButton"],
        type: "UIButton",
        id: "cart.remove",
        label: "Remove",
        rect: FeedbackRect(x: 0.61, y: 0.42, w: 0.2, h: 0.05),
        viewport: FeedbackElementViewport(w: 393, h: 852)
      ),
      screenshot: FeedbackScreenshot(contentType: "image/jpeg", base64: "AAAA", highlighted: true),
      logs: [FeedbackLogEntry(t: 1_760_440_000_123, level: .error, msg: "TypeError", src: "oslog")],
      network: [FeedbackNetworkEntry(t: 1_760_440_000_100, method: "POST", url: "https://api.example.com/cart", status: 500, ms: 312)]
    )
  }

  private func object(_ value: some Encodable) throws -> [String: Any] {
    let data = try FeedbackPayload.encoder().encode(value)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  func testEveryKeyIsAContractKeyAtEveryLevel() throws {
    let json = try object(Self.fullPayload())
    XCTAssertEqual(Set(json.keys), ["v", "message", "category", "reporter", "context", "element", "screenshot", "logs", "network"])
    XCTAssertEqual(json["v"] as? Int, 1)
    XCTAssertEqual(json["category"] as? String, "bug")

    let reporter = try XCTUnwrap(json["reporter"] as? [String: Any])
    XCTAssertEqual(Set(reporter.keys), ["email", "name", "accountRef"])

    let context = try XCTUnwrap(json["context"] as? [String: Any])
    XCTAssertEqual(Set(context.keys), [
      "platform", "url", "screen", "title", "appVersion", "build", "os", "osVersion", "device",
      "locale", "timeZone", "viewport", "userAgent", "sdk", "deviceId", "extra",
    ])
    XCTAssertEqual(Set(try XCTUnwrap(context["viewport"] as? [String: Any]).keys), ["w", "h", "dpr"])
    XCTAssertEqual(Set(try XCTUnwrap(context["sdk"] as? [String: Any]).keys), ["name", "version"])

    let element = try XCTUnwrap(json["element"] as? [String: Any])
    XCTAssertEqual(Set(element.keys), ["kind", "path", "type", "id", "label", "rect", "viewport"])
    XCTAssertEqual(element["kind"] as? String, "native")
    XCTAssertEqual(Set(try XCTUnwrap(element["rect"] as? [String: Any]).keys), ["x", "y", "w", "h"])
    XCTAssertEqual(Set(try XCTUnwrap(element["viewport"] as? [String: Any]).keys), ["w", "h"])

    XCTAssertEqual(Set(try XCTUnwrap(json["screenshot"] as? [String: Any]).keys), ["contentType", "base64", "highlighted"])
    let log = try XCTUnwrap((json["logs"] as? [[String: Any]])?.first)
    XCTAssertEqual(Set(log.keys), ["t", "level", "msg", "src"])
    let net = try XCTUnwrap((json["network"] as? [[String: Any]])?.first)
    XCTAssertEqual(Set(net.keys), ["t", "method", "url", "status", "ms"])
  }

  func testNilsAreLeftOutRatherThanSentAsNull() throws {
    let payload = FeedbackPayload(message: "hi", context: FeedbackContext())
    let json = try object(payload)
    XCTAssertEqual(Set(json.keys), ["v", "message", "category", "context"])
    XCTAssertEqual(Set(try XCTUnwrap(json["context"] as? [String: Any]).keys), ["platform"])
    let text = String(decoding: try FeedbackPayload.encoder().encode(payload), as: UTF8.self)
    XCTAssertFalse(text.contains("null"))
  }

  func testSanitizedLeavesOutEmptySections() throws {
    var payload = FeedbackPayload(message: "  hi  ", reporter: FeedbackReporter(email: " ", name: ""), context: FeedbackContext(), logs: [], network: [])
    payload = try payload.sanitized()
    let json = try object(payload)
    XCTAssertEqual(Set(json.keys), ["v", "message", "category", "context"])
    XCTAssertEqual(json["message"] as? String, "hi")
  }

  func testAPayloadRoundTripsThroughDiskShape() throws {
    let payload = Self.fullPayload()
    let data = try FeedbackPayload.encoder().encode(payload)
    XCTAssertEqual(try JSONDecoder().decode(FeedbackPayload.self, from: data), payload)
  }

  func testSlashesAreNotEscaped() throws {
    let text = String(decoding: try FeedbackPayload.encoder().encode(Self.fullPayload()), as: UTF8.self)
    XCTAssertTrue(text.contains("https://api.example.com/cart"))
  }

  func testScreenshotDecodedSize() {
    let data = Data(repeating: 7, count: 1000)
    XCTAssertEqual(FeedbackScreenshot(jpeg: data, highlighted: false).decodedByteCount, 1000)
    XCTAssertEqual(FeedbackScreenshot(jpeg: Data(repeating: 1, count: 1001), highlighted: false).decodedByteCount, 1001)
    XCTAssertEqual(FeedbackScreenshot(jpeg: Data(repeating: 1, count: 1002), highlighted: false).decodedByteCount, 1002)
  }

  func testBaseContextIsIOSAndCarriesTheSDK() {
    let context = DeviceInfo.baseContext(deviceId: "abc", extra: [:])
    XCTAssertEqual(context.platform, "ios")
    XCTAssertEqual(context.sdk, FeedbackSDK(name: "overblast-feedback-ios", version: DeviceInfo.sdkVersion))
    XCTAssertNil(context.extra)
    XCTAssertFalse((context.device ?? "").isEmpty)
    XCTAssertFalse((context.timeZone ?? "").isEmpty)
  }

  func testDeviceIdIsStableAndShaped() throws {
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "overblast-feedback-tests-\(UUID().uuidString)"))
    let first = DeviceInfo.deviceId(defaults: defaults)
    XCTAssertEqual(first, DeviceInfo.deviceId(defaults: defaults))
    XCTAssertEqual(first.count, 32)
    XCTAssertTrue(FeedbackText.isValidDeviceId(first))
  }
}
