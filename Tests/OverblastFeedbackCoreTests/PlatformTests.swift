import XCTest
@testable import OverblastFeedbackCore

/// `context.os`, where shake exists, and the version every report carries. `context.platform` is
/// `ios` on every Apple system (contract §3.1 has no `macos` or `visionos`); `os` says which.
final class PlatformTests: XCTestCase {
  func testOSNameForEveryRuntime() {
    XCTAssertEqual(DeviceInfo.osName(runtime: .iOS, model: "iPhone15,3"), "iOS")
    XCTAssertEqual(DeviceInfo.osName(runtime: .iOS, model: "iPad13,4"), "iPadOS")
    XCTAssertEqual(DeviceInfo.osName(runtime: .iOS, model: "iPod9,1"), "iOS")
    XCTAssertEqual(DeviceInfo.osName(runtime: .visionOS, model: "RealityDevice14,1"), "visionOS")
    // An iPad app on Apple Vision Pro is on visionOS, whatever it was built for.
    XCTAssertEqual(DeviceInfo.osName(runtime: .iOSAppOnVision, model: "RealityDevice14,1"), "visionOS")
    XCTAssertEqual(DeviceInfo.osName(runtime: .macOS, model: "Mac14,2"), "macOS")
    XCTAssertEqual(DeviceInfo.osName(runtime: .macCatalyst, model: "Mac14,2"), "macOS")
    XCTAssertEqual(DeviceInfo.osName(runtime: .iOSAppOnMac, model: "iPad13,4"), "macOS")
  }

  func testThisProcessIsAMac() {
    // `swift test` runs on a Mac, natively.
    #if os(macOS)
    XCTAssertEqual(DeviceInfo.runtime, .macOS)
    XCTAssertEqual(DeviceInfo.osName, "macOS")
    XCTAssertFalse(DeviceInfo.isiOSAppOnVision)
    #endif
  }

  func testShakeOnlyOnAnIPhoneOrIPad() {
    for runtime in DeviceInfo.Runtime.allCases {
      XCTAssertEqual(DeviceInfo.deliversShake(on: runtime), runtime == .iOS, "\(runtime)")
    }
  }

  func testShakeIsOffAndCannotBeTurnedOnWhereThereIsNone() {
    let defaults = FeedbackOptions()
    XCTAssertEqual(defaults.shakeToReport, DeviceInfo.deliversShake)
    XCTAssertEqual(OverblastFeedback.isShakeAvailable, DeviceInfo.deliversShake)
    #if os(macOS)
    XCTAssertFalse(defaults.shakeToReport)
    XCTAssertFalse(FeedbackOptions(shakeToReport: true).shakeToReport)
    #endif
    // Button mode on an iPhone is asked for the same way everywhere.
    XCTAssertFalse(FeedbackOptions(shakeToReport: false).shakeToReport)
  }

  func testTheContextSaysWhichSystemButStaysPlatformIOS() {
    let context = DeviceInfo.baseContext(deviceId: nil, extra: nil)
    XCTAssertEqual(context.platform, "ios")
    XCTAssertEqual(context.os, DeviceInfo.osName)
    XCTAssertEqual(context.sdk?.version, "0.2.1")
  }
}
