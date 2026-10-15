#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import OverblastFeedback
@_spi(OverblastPlatform) @testable import OverblastFeedbackCore

final class CartViewController: NSViewController {
  override func loadView() { view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 800)) }
}

final class CartRowView: NSView {}

/// The Mac half, under `swift test`: element picking in the live AppKit hierarchy, masking, the
/// window capture, SwiftUI markers, the context, and the sheet on a real window. Rectangles are
/// written top-left (the contract's orientation); AppKit frames below are bottom-left, so a view at
/// top-left y = Y with height H sits at AppKit y = 800 - Y - H.
@MainActor
final class AppKitTests: XCTestCase {
  private var window: NSWindow!
  private var row: CartRowView!
  private var title: NSTextField!
  private var button: NSButton!
  private var password: NSSecureTextField!
  private var note: NSTextField!
  private var balance: NSTextField!

  /// A frame given from the top-left of an 800-point-high content view.
  private func frame(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, inHeight height: CGFloat = 800) -> NSRect {
    NSRect(x: x, y: height - y - h, width: w, height: h)
  }

  override func setUp() async throws {
    try await super.setUp()
    _ = NSApplication.shared
    window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    // Light, so the pixel checks below do not depend on the Mac running them.
    window.appearance = NSAppearance(named: .aqua)
    let vc = CartViewController()
    window.contentViewController = vc
    window.setContentSize(NSSize(width: 400, height: 800))
    let content = try XCTUnwrap(window.contentView)

    row = CartRowView(frame: frame(0, 100, 400, 60))
    content.addSubview(row)
    title = NSTextField(labelWithString: "Coffee beans")
    title.frame = frame(10, 10, 200, 40, inHeight: 60)
    row.addSubview(title)
    button = NSButton(title: "Remove", target: nil, action: nil)
    button.frame = frame(300, 10, 90, 40, inHeight: 60)
    button.setAccessibilityIdentifier("cart.remove")
    row.addSubview(button)

    password = NSSecureTextField(frame: frame(10, 300, 380, 44))
    password.placeholderString = "PIN"
    password.stringValue = "1234"
    content.addSubview(password)

    note = NSTextField(frame: frame(10, 360, 380, 30))
    note.placeholderString = "Note"
    note.stringValue = "deliver after 6"
    content.addSubview(note)

    balance = NSTextField(labelWithString: "€1,204.55")
    balance.frame = frame(10, 400, 200, 40)
    balance.overblastPrivate = true
    content.addSubview(balance)
    content.layoutSubtreeIfNeeded()
  }

  override func tearDown() async throws {
    window.orderOut(nil)
    window = nil
    try await super.tearDown()
  }

  func testALabelIsFoundWithItsPathAndTopLeftRect() throws {
    let s = try XCTUnwrap(ElementPicker.select(at: CGPoint(x: 50, y: 130), in: window))
    XCTAssertEqual(s.element.type, "NSTextField")
    XCTAssertEqual(s.element.label, "Coffee beans")
    XCTAssertEqual(s.element.path, ["NSWindow", "CartViewController", "CartRowView", "NSTextField"])
    XCTAssertEqual(s.element.rect, FeedbackRect(x: 0.025, y: 0.1375, w: 0.5, h: 0.05))
    XCTAssertEqual(s.element.viewport, FeedbackElementViewport(w: 400, h: 800))
    XCTAssertEqual(s.frame, CGRect(x: 10, y: 110, width: 200, height: 40))
  }

  func testAButtonIsOnePieceWithItsIdentifier() throws {
    let s = try XCTUnwrap(ElementPicker.select(at: CGPoint(x: 340, y: 130), in: window))
    XCTAssertEqual(s.element.type, "NSButton")
    XCTAssertEqual(s.element.id, "cart.remove")
    XCTAssertEqual(s.element.label, "Remove")
  }

  func testAFieldGivesItsPlaceholderNeverItsText() throws {
    let plain = try XCTUnwrap(ElementPicker.select(at: CGPoint(x: 100, y: 375), in: window))
    XCTAssertEqual(plain.element.type, "NSTextField")
    XCTAssertEqual(plain.element.label, "Note")
    // A secure field is private: not even the placeholder.
    let secure = try XCTUnwrap(ElementPicker.select(at: CGPoint(x: 100, y: 320), in: window, privateRects: PrivacyMask.rects(in: window)))
    XCTAssertEqual(secure.element.type, "NSSecureTextField")
    XCTAssertNil(secure.element.label)
  }

  func testPrivateViewsAndSecureFieldsAreMaskedTopLeft() throws {
    let rects = PrivacyMask.rects(in: window)
    XCTAssertTrue(rects.contains(CGRect(x: 10, y: 300, width: 380, height: 44)), "\(rects)")
    XCTAssertTrue(rects.contains(CGRect(x: 10, y: 400, width: 200, height: 40)), "\(rects)")
    XCTAssertEqual(rects.count, 2)

    let content = try XCTUnwrap(window.contentView)
    let code = NSTextField(frame: frame(0, 500, 100, 30))
    code.contentType = .oneTimeCode
    content.addSubview(code)
    let tagged = NSView(frame: frame(0, 600, 100, 30))
    tagged.setAccessibilityIdentifier("overblast.private.balance")
    content.addSubview(tagged)
    XCTAssertEqual(PrivacyMask.rects(in: window).count, 4)
  }

  func testALabelInsideAPrivateViewIsLeftOut() throws {
    let s = try XCTUnwrap(ElementPicker.select(at: CGPoint(x: 50, y: 420), in: window, privateRects: PrivacyMask.rects(in: window)))
    XCTAssertNil(s.element.label)
  }

  func testHiddenViewsAreNotPicked() throws {
    title.isHidden = true
    let s = try XCTUnwrap(ElementPicker.select(at: CGPoint(x: 50, y: 130), in: window))
    XCTAssertEqual(s.element.type, "CartRowView")
    XCTAssertNil(ElementPicker.select(at: CGPoint(x: 50, y: 900), in: window))
  }

  func testTheCaptureIsTheWindowsOwnContentMaskedAndEncoded() throws {
    let capture = try XCTUnwrap(ScreenCapture.take(of: window))
    XCTAssertEqual(capture.windowSize, CGSize(width: 400, height: 800))
    XCTAssertLessThanOrEqual(max(capture.image.width, capture.image.height), 2400)
    XCTAssertEqual(capture.privateRects.count, 2)

    // The masked area is the mask colour, whatever was drawn there: top-left (100, 420) is the balance.
    let pixel = try XCTUnwrap(color(of: capture.image, atTopLeft: CGPoint(x: 100, y: 420), size: capture.windowSize))
    XCTAssertEqual(pixel.r, pixel.g, accuracy: 0.02)
    XCTAssertEqual(pixel.r, 0.18, accuracy: 0.03)
    // And somewhere unmasked is not.
    let open = try XCTUnwrap(color(of: capture.image, atTopLeft: CGPoint(x: 200, y: 700), size: capture.windowSize))
    XCTAssertGreaterThan(abs(open.r - 0.18), 0.1)

    let element = try XCTUnwrap(ElementPicker.select(at: CGPoint(x: 340, y: 130), in: window)).element
    let shot = try XCTUnwrap(ScreenshotRenderer.screenshot(from: capture, element: element))
    XCTAssertEqual(shot.contentType, "image/jpeg")
    XCTAssertTrue(shot.highlighted)
    XCTAssertLessThanOrEqual(shot.decodedByteCount, FeedbackLimits.screenshotBytes)
    let data = try XCTUnwrap(Data(base64Encoded: shot.base64))
    XCTAssertEqual(Array(data.prefix(3)), [0xFF, 0xD8, 0xFF])
    XCTAssertNotNil(NSImage(data: data))
    XCTAssertFalse(try XCTUnwrap(ScreenshotRenderer.screenshot(from: capture, element: nil)).highlighted)

    // The highlight is drawn where the element is: the box's red edge just outside the button.
    let boxed = ScreenshotRenderer.highlighted(capture.image, rect: CGRect(x: 300, y: 110, width: 90, height: 40), size: capture.windowSize)
    let edge = try XCTUnwrap(color(of: boxed, atTopLeft: CGPoint(x: 345, y: 108.5), size: capture.windowSize))
    XCTAssertGreaterThan(edge.r, 0.7)
    XCTAssertLessThan(edge.g, 0.45)
  }

  func testTheContextNamesTheViewControllerAndTheContentSize() {
    window.title = "Your cart"
    let context = ScreenContext.current(window: window)
    XCTAssertEqual(context.screen, "CartViewController")
    XCTAssertEqual(context.title, "Your cart")
    XCTAssertEqual(context.viewport?.w, 400)
    XCTAssertEqual(context.viewport?.h, 800)
    XCTAssertEqual(context.viewport?.dpr, Double(window.backingScaleFactor))
  }

  func testThereIsNoShakeOnAMac() {
    OverblastFeedback.isShakeEnabled = true
    XCTAssertFalse(OverblastFeedback.isShakeEnabled)
    XCTAssertFalse(OverblastFeedback.isShakeAvailable)
  }

  func testThePointerPictureFitsTheWindow() {
    // A big window shows the picture at nearly its own size; a tiny one borrows the screen.
    let big = PointerModel.displayScale(content: CGSize(width: 1200, height: 800), window: CGSize(width: 1200, height: 800), screen: CGSize(width: 1512, height: 944))
    XCTAssertEqual(big, (800 - 96 - 40) / 800, accuracy: 0.001)
    let tiny = PointerModel.displayScale(content: CGSize(width: 300, height: 120), window: CGSize(width: 300, height: 120), screen: CGSize(width: 1512, height: 944))
    XCTAssertEqual(tiny, 1)
  }

  // MARK: The room for the sheet

  func testTheSheetIsHeldToTheRoomUnderTheWindowsContent() {
    let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)
    // The content's height, less the margin.
    XCTAssertEqual(SheetSpace.available(content: CGRect(x: 100, y: 300, width: 800, height: 500), visible: visible), 476)
    // A window running off the bottom of the screen: only what is visible under its top counts.
    XCTAssertEqual(SheetSpace.available(content: CGRect(x: 100, y: -200, width: 800, height: 700), visible: visible), 451)
    // Taller than the screen: the screen.
    XCTAssertEqual(SheetSpace.available(content: CGRect(x: 0, y: 25, width: 800, height: 2000), visible: visible), 851)
    XCTAssertTrue(SheetSpace.usesPanel(available: 300))
    XCTAssertFalse(SheetSpace.usesPanel(available: 500))
    XCTAssertEqual(SheetSpace.panelHeight(visible: visible), 720)
    XCTAssertEqual(SheetSpace.panelHeight(visible: CGRect(x: 0, y: 0, width: 1024, height: 600)), 552)
  }

  /// The bug: with the screenshot on, the sheet grew to its content (about 770 points) and ran past a
  /// 500-point window and off the screen.
  func testTheTallStateStaysInsideAShortWindow() async throws {
    OverblastFeedback.configure(
      key: "obfk_TESTKEY00000000000000000", endpoint: URL(string: "https://feedback.test/v1/feedback")!, reporter: nil,
      options: FeedbackOptions(captureOSLog: false, retryPendingOnStart: false),
      session: nil, store: PendingStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("obf-mac-\(UUID().uuidString)")),
      defaults: UserDefaults(suiteName: "obf-tests-\(UUID().uuidString)")
    )
    let short = NSWindow(contentRect: NSRect(x: 100, y: 200, width: 800, height: 500), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    short.isReleasedWhenClosed = false
    short.appearance = NSAppearance(named: .aqua)
    short.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
    short.orderFront(nil)
    defer { FeedbackPresenter.shared.dismiss(); short.orderOut(nil) }
    FeedbackPresenter.shared.present(in: short)
    let model = try XCTUnwrap(FeedbackPresenter.shared.model)
    model.message = "It overflows"
    model.includeScreenshot = true
    try await Task.sleep(nanoseconds: 800_000_000)
    let sheet = try XCTUnwrap(short.attachedSheet)
    let room = SheetSpace.available(content: short.convertToScreen(short.contentLayoutRect), visible: short.screen?.visibleFrame)
    XCTAssertLessThanOrEqual(sheet.frame.height, room + 1, "sheet \(sheet.frame) in room \(room)")
    XCTAssertGreaterThan(sheet.frame.height, 300)

    // The window is made shorter: the sheet follows.
    short.setContentSize(NSSize(width: 800, height: 440))
    try await Task.sleep(nanoseconds: 800_000_000)
    let smaller = SheetSpace.available(content: short.convertToScreen(short.contentLayoutRect), visible: short.screen?.visibleFrame)
    XCTAssertLessThanOrEqual(try XCTUnwrap(short.attachedSheet).frame.height, smaller + 1)
  }

  func testATooShortWindowGetsAPanelInstead() async throws {
    OverblastFeedback.configure(
      key: "obfk_TESTKEY00000000000000000", endpoint: URL(string: "https://feedback.test/v1/feedback")!, reporter: nil,
      options: FeedbackOptions(captureOSLog: false, retryPendingOnStart: false),
      session: nil, store: PendingStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("obf-mac-\(UUID().uuidString)")),
      defaults: UserDefaults(suiteName: "obf-tests-\(UUID().uuidString)")
    )
    let tiny = NSWindow(contentRect: NSRect(x: 100, y: 200, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    tiny.isReleasedWhenClosed = false
    tiny.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
    tiny.orderFront(nil)
    defer { FeedbackPresenter.shared.dismiss(); tiny.orderOut(nil) }
    FeedbackPresenter.shared.present(in: tiny)
    try await Task.sleep(nanoseconds: 500_000_000)
    XCTAssertTrue(FeedbackPresenter.shared.usesPanel)
    XCTAssertNil(tiny.attachedSheet)
    let panel = try XCTUnwrap(NSApplication.shared.windows.first { $0 is FeedbackSheetWindow && $0.isVisible })
    XCTAssertTrue(panel.styleMask.contains(.resizable))
    if let visible = panel.screen?.visibleFrame {
      XCTAssertTrue(visible.contains(panel.frame), "\(panel.frame) inside \(visible)")
    }
  }

  // MARK: SwiftUI

  private func hostSwiftUI() throws {
    let host = NSHostingView(rootView:
      VStack(spacing: 0) {
        Spacer().frame(height: 200)
        Button("Checkout") {}
          .frame(width: 200, height: 60)
          .overblastElement("cart.checkout", label: "Checkout")
        Text("Visa ending 4242").frame(height: 40).overblastPrivate()
        Spacer()
      }
      .frame(width: 400, height: 800)
    )
    host.frame = NSRect(x: 0, y: 0, width: 400, height: 800)
    let content = try XCTUnwrap(window.contentView)
    content.subviews.forEach { $0.removeFromSuperview() }
    content.addSubview(host)
    host.layoutSubtreeIfNeeded()
    content.layoutSubtreeIfNeeded()
  }

  func testSwiftUIElementsAreFoundThroughTheirMarker() throws {
    try hostSwiftUI()
    let s = try XCTUnwrap(ElementPicker.select(at: CGPoint(x: 200, y: 230), in: window))
    XCTAssertEqual(s.element.id, "cart.checkout", "\(s.element)")
    XCTAssertEqual(s.element.label, "Checkout")
    XCTAssertEqual(s.element.type, "Button")
    XCTAssertEqual(s.frame.size, CGSize(width: 200, height: 60))
    XCTAssertEqual(s.frame.minY, 200, accuracy: 0.5)
  }

  func testAnUnmarkedSwiftUIClickNamesTheHostAndWhere() throws {
    try hostSwiftUI()
    let s = try XCTUnwrap(ElementPicker.select(at: CGPoint(x: 200, y: 600), in: window))
    XCTAssertTrue(s.element.path.contains("NSHostingView"), "\(s.element.path)")
    XCTAssertEqual(s.frame, CGRect(x: 178, y: 578, width: 44, height: 44))
  }

  func testTheSwiftUIPrivateMarkerMasksAndIsNeverPicked() throws {
    try hostSwiftUI()
    let rects = PrivacyMask.rects(in: window)
    XCTAssertEqual(rects.filter { abs($0.minY - 260) < 1 && abs($0.height - 40) < 1 }.count, 1, "\(rects)")
    let s = try XCTUnwrap(ElementPicker.select(at: CGPoint(x: 200, y: 280), in: window, privateRects: rects))
    XCTAssertFalse(s.element.path.contains { $0.contains("Marker") }, "\(s.element.path)")
    XCTAssertNil(s.element.label)
  }

  // MARK: The sheet

  func testPresentAttachesTheSheetAndDismissTakesItAway() async throws {
    OverblastFeedback.configure(
      key: "obfk_TESTKEY00000000000000000",
      endpoint: URL(string: "https://feedback.test/v1/feedback")!,
      reporter: nil,
      options: FeedbackOptions(captureOSLog: false, retryPendingOnStart: false),
      session: nil,
      store: PendingStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("overblast-feedback-mac-\(UUID().uuidString)")),
      defaults: UserDefaults(suiteName: "overblast-feedback-tests-\(UUID().uuidString)")
    )
    window.orderFront(nil)
    FeedbackPresenter.shared.present(category: .idea, message: "hello", in: window)
    XCTAssertTrue(OverblastFeedback.isPresenting)
    XCTAssertTrue(window.attachedSheet is FeedbackSheetWindow)
    let first = window.attachedSheet
    // A second call while one is open does nothing.
    FeedbackPresenter.shared.present(in: window)
    XCTAssertTrue(window.attachedSheet === first)
    FeedbackPresenter.shared.dismiss()
    XCTAssertFalse(OverblastFeedback.isPresenting)
  }

  private func color(of image: CGImage, atTopLeft point: CGPoint, size: CGSize) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
    let scale = CGFloat(image.width) / size.width
    let x = Int(point.x * scale), y = Int(point.y * scale)
    var data = [UInt8](repeating: 0, count: 4)
    guard let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    // CoreGraphics draws from the bottom-left: the pixel row `y` from the top is `height - 1 - y`.
    ctx.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
    return (CGFloat(data[0]) / 255, CGFloat(data[1]) / 255, CGFloat(data[2]) / 255)
  }
}
#endif
