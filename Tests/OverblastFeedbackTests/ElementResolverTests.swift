#if os(macOS)
import AppKit
import XCTest
@testable import OverblastFeedback
@_spi(OverblastPlatform) @testable import OverblastFeedbackCore

/// `OverblastFeedback.elementResolver`: the app names what the library cannot see (a sticker drawn on
/// a canvas), it is asked first, and a nil answer leaves the library's own search in charge. Driven
/// through the real AppKit picker; the UIKit picker shares the same selection rule.
@MainActor
final class ElementResolverTests: XCTestCase {
  private var window: NSWindow!

  override func setUp() async throws {
    try await super.setUp()
    window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 800))
    window.contentView = content
    // One canvas the size of the window: the kind of view that draws stickers itself.
    content.addSubview(NSView(frame: content.bounds))
  }

  override func tearDown() async throws {
    OverblastFeedback.elementResolver = nil
    window = nil
    try await super.tearDown()
  }

  func testTheAppsAnswerIsTakenFirstWithItsTypeIdLabelAndFrame() throws {
    var asked: CGPoint?
    OverblastFeedback.elementResolver = { point, _ in
      asked = point
      return .init(type: "sticker", id: "stk_42", label: "Sunflower", frame: CGRect(x: 100, y: 200, width: 80, height: 80))
    }
    let s = try XCTUnwrap(ElementPicker.select(at: CGPoint(x: 120, y: 230), in: window))
    XCTAssertEqual(asked, CGPoint(x: 120, y: 230))
    XCTAssertEqual(s.element.type, "sticker")
    XCTAssertEqual(s.element.id, "stk_42")
    XCTAssertEqual(s.element.label, "Sunflower")
    XCTAssertEqual(s.element.path.last, "sticker")
    XCTAssertEqual(s.frame, CGRect(x: 100, y: 200, width: 80, height: 80))
  }

  func testNoFrameMeansASpotRoundThePointAndAFrameOffScreenIsKeptOnIt() throws {
    OverblastFeedback.elementResolver = { _, _ in .init(type: "sticker", id: "stk_1") }
    let spot = try XCTUnwrap(ElementPicker.select(at: CGPoint(x: 200, y: 400), in: window))
    XCTAssertEqual(spot.frame, CGRect(x: 178, y: 378, width: 44, height: 44))

    OverblastFeedback.elementResolver = { _, _ in .init(type: "sticker", frame: CGRect(x: 380, y: 780, width: 100, height: 100)) }
    let edge = try XCTUnwrap(ElementPicker.select(at: CGPoint(x: 390, y: 790), in: window))
    XCTAssertEqual(edge.frame, CGRect(x: 380, y: 780, width: 20, height: 20))
  }

  func testALabelInAPrivateAreaIsDropped() throws {
    OverblastFeedback.elementResolver = { _, _ in .init(type: "sticker", id: "stk_7", label: "Card 4242", frame: CGRect(x: 10, y: 10, width: 50, height: 50)) }
    let s = try XCTUnwrap(ElementPicker.select(at: CGPoint(x: 20, y: 20), in: window, privateRects: [CGRect(x: 0, y: 0, width: 100, height: 100)]))
    XCTAssertEqual(s.element.id, "stk_7")
    XCTAssertNil(s.element.label)
  }

  func testANilAnswerLeavesTheLibrarysOwnSearch() throws {
    OverblastFeedback.elementResolver = { _, _ in nil }
    let s = try XCTUnwrap(ElementPicker.select(at: CGPoint(x: 200, y: 400), in: window))
    XCTAssertNotEqual(s.element.type, "sticker")
    XCTAssertEqual(s.element.type, "NSView")
  }

  func testAHostingViewOutsideTheSwiftUIModuleCountsAsSwiftUI() {
    // iOS 26's floating toolbar wraps SwiftUI in a system class named ...HostingView: its markers
    // must be searched, so it has to read as a SwiftUI host.
    final class FloatingBarHostingView: NSView {}
    XCTAssertTrue(ElementPicker.isSwiftUIHost(FloatingBarHostingView()))
    XCTAssertFalse(ElementPicker.isSwiftUIHost(NSView()))
    XCTAssertFalse(ElementPicker.isSwiftUIHost(NSTextField()))
  }
}
#endif
