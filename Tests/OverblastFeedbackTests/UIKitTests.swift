#if canImport(UIKit)
import ObjectiveC
import SwiftUI
import UIKit
import XCTest
@testable import OverblastFeedback
@_spi(OverblastPlatform) import OverblastFeedbackCore

final class CartViewController: UIViewController {}
final class CartRowView: UIView {}

@MainActor
final class UIKitTests: XCTestCase {
  private var window: UIWindow!
  private var row: CartRowView!
  private var title: UILabel!
  private var button: UIButton!
  private var password: UITextField!
  private var balance: UILabel!

  override func setUp() async throws {
    try await super.setUp()
    window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
    let vc = CartViewController()
    window.rootViewController = vc
    window.isHidden = false
    vc.view.frame = window.bounds

    row = CartRowView(frame: CGRect(x: 0, y: 100, width: 400, height: 60))
    vc.view.addSubview(row)
    title = UILabel(frame: CGRect(x: 10, y: 10, width: 200, height: 40))
    title.text = "Coffee beans"
    row.addSubview(title)
    button = UIButton(type: .system)
    button.frame = CGRect(x: 300, y: 10, width: 90, height: 40)
    button.setTitle("Remove", for: .normal)
    button.accessibilityIdentifier = "cart.remove"
    row.addSubview(button)

    password = UITextField(frame: CGRect(x: 10, y: 300, width: 380, height: 44))
    password.isSecureTextEntry = true
    password.placeholder = "PIN"
    password.text = "1234"
    vc.view.addSubview(password)

    balance = UILabel(frame: CGRect(x: 10, y: 400, width: 200, height: 40))
    balance.text = "€1,204.55"
    balance.overblastPrivate = true
    vc.view.addSubview(balance)
    window.layoutIfNeeded()
  }

  override func tearDown() async throws {
    window.isHidden = true
    window = nil
    try await super.tearDown()
  }

  func testALabelIsFoundEvenThoughItTakesNoTouches() throws {
    let s = try XCTUnwrap(ElementPicker.select(at: CGPoint(x: 50, y: 130), in: window))
    XCTAssertEqual(s.element.type, "UILabel")
    XCTAssertEqual(s.element.label, "Coffee beans")
    XCTAssertEqual(s.element.path, ["UIWindow", "CartViewController", "CartRowView", "UILabel"])
    XCTAssertEqual(s.element.rect, FeedbackRect(x: 0.025, y: 0.1375, w: 0.5, h: 0.05))
    XCTAssertEqual(s.element.viewport, FeedbackElementViewport(w: 400, h: 800))
  }

  func testAControlIsOnePiece() throws {
    let s = try XCTUnwrap(ElementPicker.select(at: CGPoint(x: 340, y: 130), in: window))
    XCTAssertEqual(s.element.type, "UIButton")
    XCTAssertEqual(s.element.id, "cart.remove")
    XCTAssertEqual(s.element.label, "Remove")
  }

  func testATextFieldGivesItsPlaceholderNeverItsText() throws {
    let s = try XCTUnwrap(ElementPicker.select(at: CGPoint(x: 100, y: 320), in: window, privateRects: PrivacyMask.rects(in: window)))
    XCTAssertEqual(s.element.type, "UITextField")
    // Secure, so private: not even the placeholder.
    XCTAssertNil(s.element.label)
    password.isSecureTextEntry = false
    let plain = try XCTUnwrap(ElementPicker.select(at: CGPoint(x: 100, y: 320), in: window))
    XCTAssertEqual(plain.element.label, "PIN")
  }

  func testPrivateViewsAndSecureFieldsAreMasked() {
    let rects = PrivacyMask.rects(in: window)
    XCTAssertTrue(rects.contains(CGRect(x: 10, y: 300, width: 380, height: 44)))
    XCTAssertTrue(rects.contains(CGRect(x: 10, y: 400, width: 200, height: 40)))
    XCTAssertEqual(rects.count, 2)

    let card = UITextField(frame: CGRect(x: 0, y: 500, width: 100, height: 30))
    card.textContentType = .creditCardNumber
    window.rootViewController?.view.addSubview(card)
    let tagged = UIView(frame: CGRect(x: 0, y: 600, width: 100, height: 30))
    tagged.accessibilityIdentifier = "overblast.private.balance"
    window.rootViewController?.view.addSubview(tagged)
    XCTAssertEqual(PrivacyMask.rects(in: window).count, 4)
  }

  func testALabelInsideAPrivateViewIsLeftOut() throws {
    let s = try XCTUnwrap(ElementPicker.select(at: CGPoint(x: 50, y: 420), in: window, privateRects: PrivacyMask.rects(in: window)))
    XCTAssertEqual(s.element.type, "UILabel")
    XCTAssertNil(s.element.label)
  }

  func testHiddenViewsAreNotPicked() throws {
    title.isHidden = true
    let s = try XCTUnwrap(ElementPicker.select(at: CGPoint(x: 50, y: 130), in: window))
    XCTAssertEqual(s.element.type, "CartRowView")
  }

  func testTheScreenshotIsMaskedSizedAndEncoded() throws {
    let capture = ScreenCapture.take(of: window)
    XCTAssertEqual(capture.windowSize, CGSize(width: 400, height: 800))
    XCTAssertLessThanOrEqual(max(capture.image.size.width, capture.image.size.height) * capture.image.scale, 2400)
    XCTAssertEqual(capture.privateRects.count, 2)

    // The masked area is the mask colour, whatever was drawn there.
    let pixel = try XCTUnwrap(color(of: capture.image, at: CGPoint(x: 100, y: 420)))
    XCTAssertEqual(pixel.r, pixel.g, accuracy: 0.02)
    XCTAssertEqual(pixel.r, 0.18, accuracy: 0.03)

    let element = try XCTUnwrap(ElementPicker.select(at: CGPoint(x: 340, y: 130), in: window)).element
    let shot = try XCTUnwrap(ScreenshotRenderer.screenshot(from: capture, element: element))
    XCTAssertEqual(shot.contentType, "image/jpeg")
    XCTAssertTrue(shot.highlighted)
    XCTAssertLessThanOrEqual(shot.decodedByteCount, FeedbackLimits.screenshotBytes)
    XCTAssertNotNil(UIImage(data: try XCTUnwrap(Data(base64Encoded: shot.base64))))
    XCTAssertFalse(try XCTUnwrap(ScreenshotRenderer.screenshot(from: capture, element: nil)).highlighted)
  }

  #if !os(visionOS)
  func testTheShakeHookIsUIWindowsAloneAndInstallsOnce() {
    let selector = #selector(UIResponder.motionEnded(_:with:))
    let responderIMP = method_getImplementation(class_getInstanceMethod(UIResponder.self, selector)!)
    ShakeDetector.install()
    ShakeDetector.install()
    let windowIMP = method_getImplementation(class_getInstanceMethod(UIWindow.self, selector)!)
    XCTAssertEqual(method_getImplementation(class_getInstanceMethod(UIResponder.self, selector)!), responderIMP)
    XCTAssertEqual(method_getImplementation(class_getInstanceMethod(UIView.self, selector)!), responderIMP)
    XCTAssertNotEqual(windowIMP, responderIMP)
    // Calling through it is safe with shake off and nothing configured.
    ShakeDetector.isEnabled = false
    window.motionEnded(.motionShake, with: nil)
  }
  #endif

  func testTopViewControllerWalksPresentedAndNavigation() {
    let inner = CartViewController()
    inner.title = "Your cart"
    let nav = UINavigationController(rootViewController: inner)
    XCTAssertTrue(ScreenContext.topViewController(from: nav) === inner)
    let tab = UITabBarController()
    tab.viewControllers = [nav]
    XCTAssertTrue(ScreenContext.topViewController(from: tab) === inner)
    let context = ScreenContext.current(window: window)
    XCTAssertEqual(context.screen, "CartViewController")
    XCTAssertEqual(context.viewport?.w, 400)
  }

  private func hostSwiftUI() {
    let host = UIHostingController(rootView:
      VStack(spacing: 0) {
        Spacer().frame(height: 200)
        Button("Checkout") {}
          .accessibilityIdentifier("cart.checkout")
          .frame(width: 200, height: 60)
          .overblastElement("cart.checkout", label: "Checkout")
        Text("Visa ending 4242").frame(height: 40).overblastPrivate()
        Spacer()
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    )
    window.rootViewController = host
    host.view.frame = window.bounds
    window.layoutIfNeeded()
    host.view.layoutIfNeeded()
  }

  func testSwiftUIElementsAreFoundThroughTheirMarker() throws {
    hostSwiftUI()
    let s = try XCTUnwrap(ElementPicker.select(at: CGPoint(x: 200, y: 230), in: window))
    XCTAssertEqual(s.element.id, "cart.checkout")
    XCTAssertEqual(s.element.label, "Checkout")
    // With VoiceOver off the type comes from the marked view's own type; with it on, from traits.
    XCTAssertEqual(s.element.type, "Button")
    XCTAssertEqual(s.frame.size, CGSize(width: 200, height: 60))
  }

  func testAnUnmarkedSwiftUITapNamesTheHostAndWhere() throws {
    hostSwiftUI()
    let s = try XCTUnwrap(ElementPicker.select(at: CGPoint(x: 200, y: 600), in: window))
    XCTAssertEqual(s.element.type, "_UIHostingView")
    XCTAssertEqual(s.frame, CGRect(x: 178, y: 578, width: 44, height: 44))
  }

  func testTheSwiftUIPrivateMarkerMasksAndIsNeverPicked() throws {
    hostSwiftUI()
    let rects = PrivacyMask.rects(in: window)
    XCTAssertEqual(rects.filter { $0.minY >= 259 && $0.minY <= 261 }.count, 1, "\(rects)")
    let s = try XCTUnwrap(ElementPicker.select(at: CGPoint(x: 200, y: 280), in: window, privateRects: rects))
    XCTAssertFalse(s.element.path.contains { $0.contains("Marker") }, "\(s.element.path)")
    XCTAssertNil(s.element.label)
  }

  /// A system bar down one side (iPhone Duo's closed display, a phone in landscape) is a sideways
  /// safe-area inset; the sheet's content stays inside it instead of running under the clock and
  /// the bar buttons UIKit moves there.
  func testTheSheetStaysInsideASidewaysSafeArea() throws {
    #if os(visionOS)
    // The package's xctest host on the visionOS simulator is not a visionOS app (no `.vision`
    // idiom), and UIKit cannot even make the sheet's UISwitch there ("Nil UISwitch visual
    // element"). The rule under test is the iPhone's; visionOS shows the sheet as a form sheet.
    throw XCTSkip("UISwitch cannot be drawn in the visionOS xctest host")
    #else
    let sheet = FeedbackSheetController(capture: ScreenCapture.take(of: window), appWindow: window, category: .bug, message: "", onFinish: {})
    // A window in a scene where there is one: visionOS's controls (the screenshot switch) draw only
    // in a window that has the scene's traits.
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    let host = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
    host.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
    host.rootViewController = UINavigationController(rootViewController: sheet)
    host.isHidden = false
    defer { host.isHidden = true }
    sheet.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 60)
    host.layoutIfNeeded()
    sheet.view.layoutIfNeeded()
    func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
      if let match = view as? T { return match }
      for sub in view.subviews { if let found = find(type, in: sub) { return found } }
      return nil
    }
    let category = try XCTUnwrap(find(UISegmentedControl.self, in: sheet.view))
    let frame = category.convert(category.bounds, to: sheet.view)
    let safe = sheet.view.bounds.inset(by: sheet.view.safeAreaInsets)
    XCTAssertGreaterThanOrEqual(frame.minX, safe.minX, "\(frame) in \(safe)")
    XCTAssertLessThanOrEqual(frame.maxX, safe.maxX, "\(frame) in \(safe)")
    let message = try XCTUnwrap(find(UITextView.self, in: sheet.view))
    XCTAssertLessThanOrEqual(message.convert(message.bounds, to: sheet.view).maxX, safe.maxX)
    #endif
  }

  private func color(of image: UIImage, at point: CGPoint) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
    guard let cg = image.cgImage else { return nil }
    let x = Int(point.x * image.scale), y = Int(point.y * image.scale)
    var data = [UInt8](repeating: 0, count: 4)
    guard let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.draw(cg, in: CGRect(x: -x, y: y - cg.height + 1, width: cg.width, height: cg.height))
    return (CGFloat(data[0]) / 255, CGFloat(data[1]) / 255, CGFloat(data[2]) / 255)
  }
}
#endif
