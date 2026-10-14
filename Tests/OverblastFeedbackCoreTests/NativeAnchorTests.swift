import CoreGraphics
import XCTest
@testable import OverblastFeedbackCore

final class NativeAnchorTests: XCTestCase {
  func testRectIsFractionsOfTheViewport() {
    let e = NativeAnchorBuilder.build(
      path: ["UIWindow", "CartViewController", "UIButton"], type: "UIButton", id: "cart.remove", label: "Remove",
      frame: CGRect(x: 100, y: 200, width: 50, height: 40), viewport: CGSize(width: 400, height: 800)
    )
    XCTAssertEqual(e.kind, "native")
    XCTAssertEqual(e.rect, FeedbackRect(x: 0.25, y: 0.25, w: 0.125, h: 0.05))
    XCTAssertEqual(e.viewport, FeedbackElementViewport(w: 400, h: 800))
  }

  func testRectIsClampedInto0To1KeepingTheVisiblePart() {
    let e = NativeAnchorBuilder.build(
      path: ["UIWindow"], type: "UIView",
      frame: CGRect(x: -100, y: 700, width: 300, height: 400), viewport: CGSize(width: 400, height: 800)
    )
    XCTAssertEqual(e.rect.x, 0)
    XCTAssertEqual(e.rect.w, 0.5)
    XCTAssertEqual(e.rect.y, 0.875)
    XCTAssertEqual(e.rect.h, 0.125)
    for v in [e.rect.x, e.rect.y, e.rect.w, e.rect.h] { XCTAssertTrue((0...1).contains(v)) }
    XCTAssertLessThanOrEqual(e.rect.x + e.rect.w, 1)
    XCTAssertLessThanOrEqual(e.rect.y + e.rect.h, 1)
  }

  func testNonFiniteRectsBecomeZero() {
    let r = NativeAnchorBuilder.clampRect(FeedbackRect(x: .nan, y: .infinity, w: 2, h: -1))
    XCTAssertEqual(r.x, 0)
    XCTAssertTrue((0...1).contains(r.w))
    XCTAssertEqual(r.h, 0)
  }

  func testPathKeepsTheWindowAndTheElevenNearestSteps() {
    let path = ["UIWindow"] + (1...20).map { "Step\($0)" }
    let e = NativeAnchorBuilder.clamp(FeedbackElement(path: path, type: "Step20", rect: FeedbackRect(x: 0, y: 0, w: 0, h: 0), viewport: .init(w: 1, h: 1)))
    XCTAssertEqual(e.path.count, 12)
    XCTAssertEqual(e.path.first, "UIWindow")
    XCTAssertEqual(e.path[1], "Step10")
    XCTAssertEqual(e.path.last, "Step20")
  }

  func testStringsAreCutAndEmptiesLeftOut() {
    let e = NativeAnchorBuilder.clamp(FeedbackElement(
      path: [String(repeating: "p", count: 200), ""],
      type: String(repeating: "t", count: 200),
      id: "",
      label: String(repeating: "l", count: 300),
      rect: FeedbackRect(x: 0, y: 0, w: 1, h: 1),
      viewport: .init(w: 1, h: 1)
    ))
    XCTAssertEqual(e.path.count, 1)
    XCTAssertEqual(e.path[0].utf16.count, 80)
    XCTAssertEqual(e.type.utf16.count, 80)
    XCTAssertNil(e.id)
    XCTAssertEqual(e.label?.utf16.count, 120)
  }

  func testEmptyTypeFallsBackToTheLastStep() {
    let e = NativeAnchorBuilder.clamp(FeedbackElement(path: ["UIWindow", "UILabel"], type: " ", rect: FeedbackRect(x: 0, y: 0, w: 0, h: 0), viewport: .init(w: 1, h: 1)))
    XCTAssertEqual(e.type, "UILabel")
  }

  func testTypeNamesAreCleaned() {
    XCTAssertEqual(NativeAnchorBuilder.cleanTypeName("MyApp.CartView"), "CartView")
    XCTAssertEqual(NativeAnchorBuilder.cleanTypeName("UIButton"), "UIButton")
    XCTAssertEqual(NativeAnchorBuilder.cleanTypeName("_UIHostingView<ModifiedContent<AnyView, RootModifier>>"), "_UIHostingView")
    XCTAssertEqual(NativeAnchorBuilder.cleanTypeName("UIHostingController<ContentView>"), "UIHostingController")
    XCTAssertEqual(
      NativeAnchorBuilder.cleanTypeName("SwiftUI.PlatformViewHost<SwiftUI.PlatformViewRepresentableAdaptor<MyApp.MapView>>"),
      "MapView"
    )
    XCTAssertEqual(NativeAnchorBuilder.cleanTypeName("Outer.Inner<A, B<C>>"), "Inner")
    XCTAssertEqual(NativeAnchorBuilder.cleanTypeName("ModifiedContent<Button<Text>, AccessibilityAttachmentModifier>"), "Button")
    XCTAssertEqual(NativeAnchorBuilder.cleanTypeName("UIKitPlatformViewHost<PlatformViewRepresentableAdaptor<PlatformTextFieldAdaptor>>"), "PlatformTextFieldAdaptor")
  }
}
