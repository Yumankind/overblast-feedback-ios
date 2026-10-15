#if canImport(UIKit) && !os(visionOS)
import SwiftUI
import UIKit
import XCTest
@testable import OverblastFeedback
@_spi(OverblastPlatform) @testable import OverblastFeedbackCore

/// Renders the report UI's screens to PNG files for a person to look at: the sheet at half and full
/// height, the pick and the screenshot, the pointer, the editor, the confirmation, in light, dark,
/// a brand theme and a large text size. Nothing is asserted about the pixels; the point is the
/// pictures. Skipped unless `OBF_SNAPSHOT_DIR` names a folder (with xcodebuild:
/// `TEST_RUNNER_OBF_SNAPSHOT_DIR=/path xcodebuild test …`).
@MainActor
final class SnapshotRenders: XCTestCase {
  private var out: URL!
  private var appWindow: UIWindow!
  private var cart: SnapshotCartController!
  private let size = CGSize(width: 393, height: 852)

  override func setUp() async throws {
    try await super.setUp()
    guard let dir = ProcessInfo.processInfo.environment["OBF_SNAPSHOT_DIR"], !dir.isEmpty else {
      throw XCTSkip("set OBF_SNAPSHOT_DIR to render the screens")
    }
    out = URL(fileURLWithPath: dir, isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
  }

  override func tearDown() async throws {
    appWindow?.rootViewController?.presentedViewController?.dismiss(animated: false)
    appWindow?.isHidden = true
    appWindow = nil
    try await super.tearDown()
  }

  private func start(theme: FeedbackTheme = .system, categories: [FeedbackCategory] = FeedbackCategory.allCases, style: UIUserInterfaceStyle = .light) throws {
    let defaults = scratchDefaults("obf-snap")
    let cached = RemoteConfigStore.Cached(config: FeedbackRemoteConfig(categories: categories), etag: nil, fetchedAt: Date())
    defaults.set(try JSONEncoder().encode(cached), forKey: RemoteConfigStore.cacheKey)
    OverblastFeedback.configure(
      key: "obfk_TESTKEY00000000000000000", endpoint: URL(string: "https://feedback.test/v1/feedback")!, reporter: nil,
      options: FeedbackOptions(captureOSLog: false, retryPendingOnStart: false, theme: theme),
      session: nil, store: PendingStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("obf-snap-\(UUID().uuidString)")),
      defaults: defaults
    )
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    appWindow = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
    appWindow.frame = CGRect(origin: .zero, size: size)
    appWindow.overrideUserInterfaceStyle = style
    appWindow.tintColor = .systemIndigo
    cart = SnapshotCartController()
    appWindow.rootViewController = cart
    appWindow.makeKeyAndVisible()
    appWindow.layoutIfNeeded()
  }

  /// The frozen screenshot as the sheet takes it, drawn with `layer.render` (see `save`), with the
  /// private parts painted over the same way.
  private func snapshotCapture() -> ScreenCapture {
    appWindow.layoutIfNeeded()
    let masks = PrivacyMask.rects(in: appWindow)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 3
    format.opaque = true
    let image = UIGraphicsImageRenderer(bounds: appWindow.bounds, format: format).image { ctx in
      UIColor.systemBackground.resolvedColor(with: appWindow.traitCollection).setFill()
      ctx.fill(appWindow.bounds)
      appWindow.layer.render(in: ctx.cgContext)
      ScreenCapture.maskColor.setFill()
      for rect in masks { ctx.fill(rect) }
    }
    return ScreenCapture(image: image, windowSize: appWindow.bounds.size, privateRects: masks)
  }

  /// The first row's Remove button.
  private let removePoint = CGPoint(x: 345, y: 98)

  private func pause(_ seconds: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
  }

  private func save(_ window: UIWindow, _ name: String) throws {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 3
    window.layoutIfNeeded()
    // `layer.render`, not `drawHierarchy`: the test host's windows are not on a display, and the
    // render server answers `drawHierarchy` for them with a blank picture. Materials (blur) come out
    // as their tint here; the shapes, text and colours are what the picture is for.
    let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { ctx in
      UIColor.systemBackground.resolvedColor(with: window.traitCollection).setFill()
      ctx.fill(window.bounds)
      window.layer.render(in: ctx.cgContext)
    }
    try XCTUnwrap(image.pngData()).write(to: out.appendingPathComponent("\(name).png"))
  }

  /// The sheet as the presenter shows it, drawn the way UIKit's page sheet draws it: over the app,
  /// dimmed, at half height (or full) with rounded top corners and the grabber. The test host has no
  /// window scene, so a real presentation never reaches the screen; the sheet's own view controller
  /// and its layout are the real ones.
  private func presentSheet(category: FeedbackCategory? = nil, message: String = "", contentSize: UIContentSizeCategory? = nil, large: Bool = false) async -> FeedbackSheetController {
    let capture = snapshotCapture()
    // Picked now, while the app's screen is all there is in the window (the sheet is drawn into the
    // same window below).
    pick = ElementPicker.select(at: removePoint, in: appWindow, privateRects: capture.privateRects)
    let sheet = FeedbackSheetController(capture: capture, appWindow: appWindow, category: category, message: message, onFinish: {})
    let nav = UINavigationController(rootViewController: sheet)
    nav.view.tintColor = ThemeUI.accent(appWindow)
    if let contentSize, #available(iOS 17.0, *) {
      nav.traitOverrides.preferredContentSizeCategory = contentSize
    }
    let dim = UIView(frame: appWindow.bounds)
    dim.backgroundColor = UIColor.black.withAlphaComponent(0.25)
    cart.view.addSubview(dim)
    let top: CGFloat = large ? 54 : size.height * 0.48
    let frame = CGRect(x: 0, y: top, width: size.width, height: size.height - top)
    cart.addChild(nav)
    nav.view.frame = frame
    nav.view.layer.cornerRadius = max(16, ThemeUI.radius + 8)
    nav.view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    nav.view.clipsToBounds = true
    cart.view.addSubview(nav.view)
    nav.didMove(toParent: cart)
    let grabber = UIView(frame: CGRect(x: size.width / 2 - 18, y: top + 5, width: 36, height: 5))
    grabber.backgroundColor = .tertiaryLabel
    grabber.layer.cornerRadius = 2.5
    cart.view.addSubview(grabber)
    sheetFrames[ObjectIdentifier(sheet)] = (nav, grabber)
    appWindow.layoutIfNeeded()
    await pause(0.5)
    return sheet
  }

  private var sheetFrames: [ObjectIdentifier: (UINavigationController, UIView)] = [:]
  private var pick: ElementPicker.Selection?

  /// What `growToLarge` does in a real page sheet.
  private func makeLarge(_ sheet: FeedbackSheetController) {
    guard let (nav, grabber) = sheetFrames[ObjectIdentifier(sheet)] else { return }
    nav.view.frame = CGRect(x: 0, y: 54, width: size.width, height: size.height - 54)
    grabber.frame.origin.y = 59
    appWindow.layoutIfNeeded()
  }

  private func fill(_ sheet: FeedbackSheetController) async {
    sheet.messageView.text = "The total doesn't update when I remove an item from the cart."
    sheet.selection = pick
    sheet.includeScreenshot = true
    sheet.screenshotSwitch.isOn = true
    sheet.edits = [ScreenshotEdit(rect: CGRect(x: 16, y: 330, width: 240, height: 32), kind: .blur)]
    sheet.refresh()
    makeLarge(sheet)
    await pause(0.6)
  }

  func test01SheetAtHalfHeight() async throws {
    try start()
    _ = await presentSheet()
    try save(appWindow, "01-sheet-medium-light")
  }

  func test02SheetFilledAtFullHeight() async throws {
    try start()
    let sheet = await presentSheet()
    await fill(sheet)
    try save(appWindow, "02-sheet-large-pick-screenshot-light")
  }

  func test03SheetDark() async throws {
    try start(style: .dark)
    let sheet = await presentSheet()
    await fill(sheet)
    try save(appWindow, "03-sheet-large-dark")
  }

  func test04BrandTheme() async throws {
    try start(theme: FeedbackTheme(accent: FeedbackTheme.Color(hex: "#E8590C"), fontFamily: "Avenir Next", cornerRadius: 20))
    let sheet = await presentSheet(category: .idea)
    await fill(sheet)
    try save(appWindow, "04-sheet-brand-theme")
  }

  func test05ProblemReportsOnlyAndLargeText() async throws {
    try start(categories: [.bug])
    _ = await presentSheet(contentSize: .accessibilityLarge)
    try save(appWindow, "05-sheet-bug-only-accessibility-large-text")
  }

  func test06Pointer() async throws {
    try start()
    let capture = snapshotCapture()
    let pointer = PointerViewController(image: capture.image, appWindow: appWindow, privateRects: capture.privateRects, selection: nil) { _ in }
    let window = overlay()
    window.rootViewController = pointer
    window.makeKeyAndVisible()
    await pause(0.4)
    try save(window, "06-pointer-hint")
    pointer.selection = ElementPicker.select(at: removePoint, in: appWindow, privateRects: capture.privateRects)
    pointer.updateSelectionUI()
    await pause(0.3)
    try save(window, "07-pointer-picked-confirm")
    window.isHidden = true
  }

  func test08Editor() async throws {
    try start()
    let capture = snapshotCapture()
    let cg = try XCTUnwrap(capture.image.cgImage)
    let model = ScreenshotEditorModel(original: cg, pointSize: capture.windowSize, masks: capture.privateRects, edits: [
      ScreenshotEdit(rect: CGRect(x: 16, y: 135, width: 140, height: 36), kind: .cover),
      ScreenshotEdit(rect: CGRect(x: 16, y: 330, width: 240, height: 32), kind: .blur),
    ])
    model.mode = .blur
    let host = UIHostingController(rootView: ScreenshotEditorView(model: model))
    let window = overlay()
    window.rootViewController = host
    window.makeKeyAndVisible()
    await pause(0.6)
    try save(window, "08-editor-cover-and-blur")
    window.isHidden = true
  }

  func test09Confirmation() async throws {
    try start()
    let sheet = await presentSheet()
    sheet.showConfirmation(OverblastFeedback.options.messages.sent, symbol: "checkmark.circle.fill")
    await pause(0.6)
    try save(appWindow, "09-sent-confirmation")
  }

  func test10KnownIssueConfirmation() async throws {
    try start()
    let sheet = await presentSheet()
    sheet.showConfirmation(OverblastFeedback.options.messages.sentKnownIssue, symbol: "checkmark.circle.fill")
    await pause(0.6)
    try save(appWindow, "10-sent-known-issue")
  }

  func test11ErrorPill() async throws {
    try start(theme: FeedbackTheme(accent: FeedbackTheme.Color(hex: "#E8590C")))
    guard let pill = PromptPill.show(onReport: {}, onClose: {}, onTimeout: {}) else {
      throw XCTSkip("the pill needs a window scene, and this test host has none")
    }
    await pause(0.5)
    let shot = UIGraphicsImageRenderer(bounds: appWindow.bounds).image { _ in
      appWindow.drawHierarchy(in: appWindow.bounds, afterScreenUpdates: true)
      for w in appWindow.windowScene?.windows ?? [] where w is PromptWindow {
        w.drawHierarchy(in: w.frame, afterScreenUpdates: true)
      }
    }
    try XCTUnwrap(shot.pngData()).write(to: out.appendingPathComponent("11-error-pill.png"))
    pill.remove()
  }

  private func overlay() -> UIWindow {
    let window = appWindow.windowScene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
    window.frame = CGRect(origin: .zero, size: size)
    window.overrideUserInterfaceStyle = appWindow.overrideUserInterfaceStyle
    return window
  }
}

/// A small shopping screen for the sheet to sit over.
final class SnapshotCartController: UIViewController {
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    let title = UILabel()
    title.text = "Your cart"
    title.font = .preferredFont(forTextStyle: .largeTitle)
    let rows = ["Coffee beans", "Filter papers", "Grinder"].map { name -> UIView in
      let label = UILabel()
      label.text = name
      let remove = UIButton(type: .system)
      remove.setTitle("Remove", for: .normal)
      remove.accessibilityIdentifier = "cart.remove"
      let row = UIStackView(arrangedSubviews: [label, remove])
      row.distribution = .equalSpacing
      return row
    }
    let card = UILabel()
    card.text = "Visa ending 4242 · €1,204.55"
    card.overblastPrivate = true
    let pin = UITextField()
    pin.placeholder = "Card PIN"
    pin.isSecureTextEntry = true
    pin.borderStyle = .roundedRect
    let note = UILabel()
    note.text = "Delivery: Thursday, after 6 pm"
    note.textColor = .secondaryLabel
    let checkout = UIButton(configuration: .filled())
    checkout.setTitle("Checkout", for: .normal)
    let stack = UIStackView(arrangedSubviews: [title] + rows + [card, pin, note, checkout])
    stack.axis = .vertical
    stack.spacing = 22
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
      stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
      stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
    ])
  }
}
#endif
